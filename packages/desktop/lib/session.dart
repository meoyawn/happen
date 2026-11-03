import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/scheduler.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';
import 'package:telemetry/telemetry.dart';

import 'project_identity.dart';
import 'dictation.dart';
import 'composer_attachments.dart';
import 'composer_text_controller.dart';
import 'appearance.dart';
import 'terminal.dart';
import 'panel_state.dart';

class Project {
  Project(this.checkoutKey, this.id, this.path, [List<DesktopTask>? tasks])
    : tasks = tasks ?? [];
  final String checkoutKey, path;
  String id;
  String? branch, avatarColor, displayName;
  Uint8List? avatarImage;
  final List<DesktopTask> tasks;
  bool available = true, removing = false;
  String get folderName => path.split(Platform.pathSeparator).where((part) => part.isNotEmpty).lastOrNull ?? path;
  String get name => displayName ?? folderName;
}

class DesktopTask {
  DesktopTask(this.id, this.title, {this.sideParentID, this.sideDraftID, this.tracing = false});
  final String id, title;
  final String? sideParentID;
  final String? sideDraftID;
  bool tracing;
  String get draftKey => sideDraftID ?? id;
  bool sidePreparing = false;
  CancellationToken? sidePreparation;
  String? sideError;
  String? sideAttachmentStatus;
  CancellationToken? sideSubmission;
  bool sideSubmitting = false;
  final events = <int, Json>{};
  final messages = <String, Json>{};
  final projectionState = <String, dynamic>{};
  final liveEvents = <Json>[];
  int through = 0;
  final pending = <String, Json>{};
  final questions = <String, Json>{};
  final questionDrafts = <String, QuestionDraft>{};
  bool running = false, loaded = false, loading = false, archived = false, archiving = false;
  bool loadingEarlier = false;
  String? historyBefore;
  String streamingText = '';
  late final liveText = ValueNotifier<String>(streamingText);
  String? retryStatus;
  String? loadError;
  String? provider, model, reasoning, nextReasoning;
  bool reasoningUpdates = false;
  num? contextLimit;
  int lastActivity = 0;
  int? runStartedAt;
  List<ChatEntry>? _conversation;
  List<Json>? _conversationEvents, _conversationPending, _legacyRecords;
  Object? _conversationState;
}

class QuestionDraft {
  QuestionDraft(int count)
    : answers = List.generate(count, (_) => <String>{}),
      custom = List.filled(count, '');
  factory QuestionDraft.fromRequest(Json request) {
    final questions = (request['questions'] as List).cast<Json>();
    final draft = QuestionDraft(questions.length);
    if (request['async'] == true) {
      for (var i = 0; i < questions.length; i++) {
        final options = questions[i]['options'] as List;
        if (options.isNotEmpty) draft.answers[i].add(options.first['label'] as String);
      }
    }
    return draft;
  }
  int tab = 0;
  bool minimized = false;
  final List<Set<String>> answers;
  final List<String> custom;
  final customOn = <int>{};

  List<String> answer(int index) => {
    ...answers[index],
    if (customOn.contains(index) && custom[index].trim().isNotEmpty) custom[index].trim(),
  }.toList();
}

class SessionDraft {
  SessionDraft(this.id, this.checkoutKey, {this.provider, this.model, this.reasoning, this.tracing = false});
  final String id;
  String? checkoutKey, provider, model, reasoning;
  bool tracing;
}

/// UI state only. Task execution and durable history stay behind the WebSocket.
class DesktopSession extends ChangeNotifier {
  DesktopSession(this.client, this.database, {String? attachmentDirectory})
    : attachmentDirectory = attachmentDirectory ?? '${Directory.systemTemp.path}/happen-attachments-${newId()}' {
    _events = client.events.stream.listen(
      _onEvent,
      onDone: () {
        if (_lifetime.isCancelled) return;
        connected = false;
        unawaited(_dictation?.cancel());
        error = 'Connection closed. Reopen Happen to reconnect.';
        notifyListeners();
      },
    );
    _disconnect = CancellationHook(_lifetime, () => unawaited(client.close()));
  }

  final AgentClient client;
  final IsolateOwner database;
  final projects = <Project>[];
  final sideChats = <String, DesktopTask>{};
  final terminals = DesktopTerminals();
  final panelLayouts = <String, SessionPanelState>{};
  final _changedPanelLayouts = <String>{};
  bool _panelsLoaded = false;
  final drafts = <String, String>{};
  late final sessionDrafts = <SessionDraft>[];
  late final draftSelections = <String, TextSelection>{};
  String? _activeDraftId;
  Timer? _draftSave;
  late final fileDrafts = <String, List<ComposerFileReference>>{};
  final String attachmentDirectory;
  TraceStore? _traceStore;
  Future<TraceStore> get tracing async =>
    _traceStore ??= await client.startTracing(File(attachmentDirectory).parent.path);
  Future<void> _restoreTracing(DesktopTask target, bool enabled) async {
    target.tracing = enabled;
    if (!enabled) return;
    await tracing;
    _lifetime.throwIfCancelled();
    client.traceSession(target.id);
  }
  final _traceFrames = <String>{};
  final attachmentDrafts = <String, List<ComposerAttachment>>{};
  CancellationToken? _submission;
  String? attachmentStatus;
  void cancelUpload({DesktopTask? target}) => (target == null ? _submission : target.sideSubmission)?.cancel();
  DictationService? _dictation;
  DictationService get dictation => _dictation ??= DictationService(client);
  final _lifetime = CancellationToken();
  late final StreamSubscription<Json> _events;
  late final CancellationHook _disconnect;
  final _earlyEvents = <Json>[];
  List<Json> providers = [];
  String? _provider, _model, _reasoning;
  String deliveryMode = 'steer';
  String dictationMode = 'live';
  String projectAvatarStyle = 'letters';
  OpenCodeLayout openCodeLayout = OpenCodeLayout.top;
  bool sidebarOpen = true, inboxWorkingExpanded = true;
  bool viewingConversation = true;
  int? inboxSince;
  final openTabIds = <String>[];
  final viewedTasks = <String, int>{};
  double sidebarWidth = 248;
  double openCodeSidebarWidth = 276;
  final collapsedSidebarSections = <String>{};
  final pinnedTaskIds = <String>[];
  final pinnedProjectKeys = <String>[];
  Project? project;
  DesktopTask? task;
  String? error;
  bool connected = true, submitting = false;
  bool signingIn = false, loginSucceeded = false;
  String? loginUrl, loginMessage, loginError, loginCode, loginProvider, signingOut;
  String? _loginId;
  bool _loginCancelled = false;
  Future<void> Function(String)? _openLogin;

  SessionDraft get currentDraft {
    final existing = sessionDrafts.where((draft) => draft.id == _activeDraftId).firstOrNull;
    if (existing != null) return existing;
    final draft = SessionDraft('draft:${newId()}', project?.checkoutKey,
      provider: _provider, model: _model, reasoning: _reasoning);
    sessionDrafts.add(draft);
    _activeDraftId = draft.id;
    openTabIds.add(draft.id);
    saveDrafts();
    return draft;
  }
  String get draftKey => task?.id ?? currentDraft.id;
  Json? get _draftModel {
    if (task != null) return null;
    final draft = currentDraft;
    return models.where((model) => model['provider'] == draft.provider && model['id'] == draft.model).firstOrNull;
  }
  String? get providerId {
    final selected = task?.provider ?? (_draftModel?['provider'] as String?) ?? _provider;
    return selected == 'gpt' ? 'openai' : selected;
  }
  String? get modelId => task?.model ?? (_draftModel?['id'] as String?) ?? _model;
  String? get reasoning {
    final selected = task?.nextReasoning ?? task?.reasoning;
    if (selected != null) return selected;
    final model = _draftModel;
    if (model == null) return _reasoning;
    final saved = currentDraft.reasoning;
    return (model['reasoning_levels'] as List? ?? const []).contains(saved)
        ? saved : model['default_reasoning'] as String?;
  }
  Json? get providerInfo =>
      providers.where((p) => p['id'] == providerId).firstOrNull;
  List<Json> get models => [
    for (final provider in providers)
      for (final model in provider['models'] as List? ?? [])
        {...jsonObject(model), 'provider': provider['id']},
  ];
  Json? get modelInfo => models.where((m) => m['provider'] == providerId && m['id'] == modelId).firstOrNull;
  Json? modelFor(DesktopTask? target) => target == null ? modelInfo
    : models.where((model) => model['provider'] == target.provider && model['id'] == target.model).firstOrNull;
  String? effortFor(DesktopTask? target) => target == null ? reasoning : target.nextReasoning ?? target.reasoning;
  bool authenticatedFor(DesktopTask? target) => {
    'signed_in',
    'refresh_required',
  }.contains(providers.where((provider) => provider['id'] == (target?.provider ?? providerId)).firstOrNull?['status']);
  bool get authenticated => authenticatedFor(null);

  Future<void> refreshProviders() async {
    final result = jsonObject(await _request('providers.list'));
    providers = (result['providers'] as List).map(jsonObject)
        .where((provider) => {'openai', 'opencode'}.contains(provider['id'])).toList();
    if (!models.any((m) => m['provider'] == _provider && m['id'] == _model)) {
      final provider = providers.firstOrNull;
      final available = (provider?['models'] as List? ?? []).map(jsonObject);
      final model = available.where((m) => m['id'] == provider?['default_model']).firstOrNull ?? available.firstOrNull;
      _provider = provider?['id'] as String?;
      _model = model?['id'] as String?;
      _reasoning = model?['default_reasoning'] as String?;
    }
    notifyListeners();
  }

  /// Like OpenCode's client cache, sidebar references are refreshed from the
  /// server's durable session list; they are never session registration.
  Future<void> refreshSessions({Project? owner}) async {
    final active = jsonObject(jsonObject(await _request('session.active'))['data']);
    String key(String path) => Directory(path).absolute.uri.normalizePath().toString();
    final owners = {for (final project in owner == null ? projects : [owner]) key(project.path): project};
    String? cursor;
    do {
      _lifetime.throwIfCancelled();
      final page = jsonObject(await _request('session.list', {
        'limit': 200, if (owner != null) 'directory': owner.path, 'cursor': ?cursor,
      }));
      final entries = (page['data'] as List).map(jsonObject).toList();
      for (final info in entries) {
        final folder = info['location']?['directory'] as String?;
        final project = folder == null ? null : owners[key(folder)];
        if (project == null || project.removing || !projects.contains(project)) continue;
        final id = requiredString(info, 'id');
        final existing = project.tasks.where((task) => task.id == id).firstOrNull;
        final target = existing ?? DesktopTask(id, info['title'] as String? ?? 'New session');
        if (existing == null) project.tasks.add(target);
        await _restoreTracing(target, info['tracing'] == true);
        if (!target.loaded) target.running = active.containsKey(id);
        target.projectionState['summary'] = info;
        final busy = info['time']?['busy'] as int?;
        final idle = info['time']?['idle'] as int?;
        target.runStartedAt = busy != null && (idle == null || busy >= idle) ? busy : null;
        if (!target.archiving) target.archived = info['time']?['archived'] != null;
        final updated = info['time']?['updated'] as int? ?? info['time']?['created'] as int? ?? 0;
        if (updated > target.lastActivity) target.lastActivity = updated;
        await callIsolate(database.port, 'task.add', {
          'id': id, 'checkout_key': project.checkoutKey, 'title': target.title,
          'archived': target.archived, 'last_activity': target.lastActivity,
        }, cancellation: _lifetime);
      }
      cursor = entries.isEmpty ? null : page['cursor']?['next'] as String?;
    } while (cursor != null);
    if (!_lifetime.isCancelled) notifyListeners();
  }

  Future<void> chooseDeliveryMode(String mode) async {
    if (!{'steer', 'queue'}.contains(mode)) {
      throw ArgumentError('Invalid delivery mode');
    }
    await _setting('delivery_mode', mode);
    deliveryMode = mode;
    notifyListeners();
  }

  Future<void> _setting(String key, String value) async {
    await callIsolate(database.port, 'settings.set', {
      'key': key,
      'value': value,
    }, cancellation: _lifetime);
  }

  Future<void> chooseDictationMode(String mode) async {
    if (!{'live', 'on_stop'}.contains(mode)) throw ArgumentError('Invalid dictation mode');
    await _setting('dictation_mode', mode);
    dictationMode = mode;
    notifyListeners();
  }

  Future<void> chooseProjectAvatarStyle(String style) async {
    if (!{'letters', 'generated'}.contains(style)) throw ArgumentError('Invalid project avatar style');
    await _setting('project_avatar_style', style);
    projectAvatarStyle = style;
    notifyListeners();
  }

  Future<void> chooseProjectAvatarColor(Project target, String? color) async {
    if (color != null && !opencodeProjectColors.containsKey(color)) throw ArgumentError('Invalid project avatar color');
    if (!projects.contains(target) || target.removing) return;
    await _setting('project_avatar_color:${target.checkoutKey}', color ?? '');
    target.avatarColor = color;
    notifyListeners();
  }

  Future<void> renameProject(Project target, String name) async {
    if (!projects.contains(target) || target.removing) return;
    final trimmed = name.trim();
    final value = trimmed.isEmpty || trimmed == target.folderName ? null : trimmed;
    await _setting('project_name:${target.checkoutKey}', value ?? '');
    target.displayName = value;
    notifyListeners();
  }

  Future<void> chooseProjectAvatarImage(Project target, Uint8List? image) async {
    if (!projects.contains(target) || target.removing) return;
    await _setting('project_avatar_image:${target.checkoutKey}', image == null ? '' : base64Encode(image));
    target.avatarImage = image;
    notifyListeners();
  }

  Future<void> chooseSidebarWidth(double width) async {
    if (!width.isFinite || width <= 0) throw ArgumentError('Invalid sidebar width');
    openCodeSidebarWidth = width;
    notifyListeners();
    await _setting('opencode_sidebar_width', width.toString());
  }

  Future<void> chooseSidebarOpen(bool open) async {
    sidebarOpen = open;
    notifyListeners();
    await _setting('sidebar_open', open.toString());
  }

  SessionPanelState panelsFor(DesktopTask target) => panelLayouts.putIfAbsent(target.id, SessionPanelState.new);

  Future<void> loadPanelLayouts(CancellationToken cancellation) async {
    if (_panelsLoaded) return;
    final saved = jsonObject(await callIsolate(database.port, 'load', {}, cancellation: cancellation));
    try {
      final decoded = jsonDecode(saved['settings']?['session_panels'] as String? ?? '{}');
      if (decoded is Map) {
        for (final entry in jsonObject(decoded).entries) {
          if (entry.value is Map && !_changedPanelLayouts.contains(entry.key)) {
            panelLayouts[entry.key] = readSessionPanels(jsonObject(entry.value));
          }
        }
      }
    } on FormatException { /* Optional presentation preferences. */ }
    _panelsLoaded = true;
    notifyListeners();
  }

  void _savePanels(DesktopTask target) {
    _changedPanelLayouts.add(target.id);
    notifyListeners();
    unawaited(loadPanelLayouts(_lifetime).then((_) {
      _saveNavigation('session_panels', jsonEncode({
        for (final entry in panelLayouts.entries) entry.key: writeSessionPanels(entry.value),
      }));
    }).catchError((Object failure) {
      if (!_lifetime.isCancelled) showError(failure);
    }));
  }

  void toggleSidePanel(DesktopTask target) {
    final state = panelsFor(target);
    state.opened = !state.opened;
    if (state.opened && state.tabs.isEmpty) {
      state.tabs.add('new:${newId()}');
      state.active = state.tabs.single;
    }
    _savePanels(target);
  }

  void openSessionPanel(DesktopTask target, String tab, {bool toggle = false, int? line}) {
    final state = panelsFor(target);
    if (toggle && state.opened && state.active == tab) {
      state.opened = false;
    } else {
      final launcher = state.active;
      if (launcher?.startsWith('new:') == true) state.tabs.remove(launcher);
      if (!state.tabs.contains(tab)) state.tabs.insert(0, tab);
      state.closed.remove(tab);
      state.active = tab;
      state.opened = true;
      if (isFilePanel(tab)) {
        state.fileReveals[tab] = (line: line, revision: (state.fileReveals[tab]?.revision ?? 0) + 1);
      }
    }
    _savePanels(target);
  }

  void newSessionPanelTab(DesktopTask target) {
    final state = panelsFor(target);
    final tab = 'new:${newId()}';
    state.tabs.add(tab);
    state.active = tab;
    state.opened = true;
    _savePanels(target);
  }

  void openBrowserPanel(DesktopTask target, {String url = ''}) {
    final state = panelsFor(target);
    final existing = url.isEmpty ? null : state.tabs.where(isBrowserPanel).where((tab) =>
      state.browserPages[tab]?.url == url).firstOrNull;
    final tab = existing ?? 'browser:${newId()}';
    state.browserPages.putIfAbsent(tab, () => (url: url, title: ''));
    openSessionPanel(target, tab);
  }

  void updateBrowserPanel(DesktopTask target, String tab, String url, String title) {
    final state = panelsFor(target);
    if (!state.tabs.contains(tab)) return;
    final page = (url: url, title: title);
    if (state.browserPages[tab] == page) return;
    state.browserPages[tab] = page;
    _savePanels(target);
  }

  void selectSessionPanel(DesktopTask target, String tab) {
    final state = panelsFor(target);
    if (!state.tabs.contains(tab)) return;
    state.active = tab;
    _savePanels(target);
  }

  void closeSessionPanel(DesktopTask target, String tab) {
    final state = panelsFor(target);
    final index = state.tabs.indexOf(tab);
    if (index < 0) return;
    state.tabs.removeAt(index);
    state.fileReveals.remove(tab);
    if (!tab.startsWith('new:') && !isSideChatPanel(tab)) { state.closed..remove(tab)..insert(0, tab); }
    if (state.active == tab) state.active = state.tabs.isEmpty ? null : state.tabs[index.clamp(0, state.tabs.length - 1)];
    if (state.tabs.isEmpty) state.opened = false;
    _savePanels(target);
    if (isSideChatPanel(tab)) unawaited(_discardSideChat(target, sideChatID(tab)));
  }

  Future<DesktopTask> openSideChat(DesktopTask parent, {String prompt = '', List<Json> attachments = const []}) async {
    if (!connected || parent.archived || parent.archiving) throw StateError('Session is unavailable');
    if (parent.sideParentID != null) throw StateError('Start side chats from the main session');
    final store = parent.tracing ? await tracing : null;
    final inherited = currentTrace;
    final context = store == null ? null : inherited?.session == null && inherited != null ? inherited
      : TraceContext(sink: store.sink, service: 'desktop');
    return withTrace(context, () => traceAsync('desktop.side.open', () async {
      final key = 'opening:${newId()}';
      final count = sideChats.values.where((side) => side.sideParentID == parent.id).length + 1;
      final firstLine = prompt.trim().isEmpty ? 'Side chat $count' : prompt.trim().split('\n').first;
      final pending = DesktopTask(key, firstLine.length > 72 ? '${firstLine.substring(0, 72)}…' : firstLine,
        sideParentID: parent.id, sideDraftID: key, tracing: parent.tracing)
        ..sidePreparing = true
        ..sidePreparation = CancellationToken()
        ..provider = parent.provider
        ..model = parent.model
        ..reasoning = parent.nextReasoning ?? parent.reasoning
        ..reasoningUpdates = parent.reasoningUpdates
        ..contextLimit = parent.contextLimit;
      sideChats[key] = pending;
      openSessionPanel(parent, sideChatPanel(key));
      traceInstant('desktop.side.pane.opened');
      final trace = currentTrace;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_lifetime.isCancelled) withTrace(trace, () => traceInstant('desktop.side.pane.presented'));
      });
      try {
        final reply = await client.createSideChat(parent.id, prompt: prompt, attachments: attachments,
          cancellation: pending.sidePreparation!.merge(_lifetime));
        final id = requiredString(reply, 'sessionID');
        bindTraceSession(id);
        if (pending.archiving || sideChats[key] != pending) {
          await _request('session.side.close', {'sessionID': id});
          throw CancelledException();
        }
        final config = jsonObject(reply['configuration']);
        final side = DesktopTask(id, reply['title'] as String? ?? pending.title,
          sideParentID: parent.id, sideDraftID: key, tracing: config['tracing'] == true)
          ..running = reply['running'] == true
          ..provider = config['provider'] as String?
          ..model = config['model'] as String?
          ..reasoning = config['provider_settings']?['reasoning'] as String?
          ..nextReasoning = pending.nextReasoning
          ..reasoningUpdates = config['reasoning_updates'] == true
          ..contextLimit = config['provider_settings']?['context_limit'] as num?;
        if (side.tracing) client.traceSession(id);
        sideChats..remove(key)..[id] = side;
        pending.liveText.dispose();
        final panels = panelsFor(parent), oldTab = sideChatPanel(key), tab = sideChatPanel(id);
        final index = panels.tabs.indexOf(oldTab);
        if (index >= 0) panels.tabs[index] = tab;
        if (panels.active == oldTab) panels.active = tab;
        _savePanels(parent);
        await loadHistory(side);
        traceInstant('desktop.side.ready');
        return side;
      } catch (failure) {
        if (sideChats[key] == pending) {
          pending.sideError = failure.toString();
          if (!_lifetime.isCancelled) notifyListeners();
        }
        rethrow;
      } finally {
        pending.sidePreparation?.cancel();
        pending.sidePreparation = null;
      }
    }, attributes: {'parent.session_id': parent.id}));
  }

  Future<void> _discardSideChat(DesktopTask parent, String id) async {
    final side = sideChats[id];
    if (side == null) return;
    side.archiving = true;
    side.sideSubmission?.cancel();
    if (side.sidePreparing) {
      side.sidePreparation?.cancel();
      sideChats.remove(id);
      await _releaseSideDraft(side);
      return;
    }
    try {
      await _request('session.side.close', {'sessionID': id});
      if (sideChats.remove(id) != null) await _releaseSideDraft(side);
    } catch (failure) {
      side.archiving = false;
      side.sideError = failure.toString();
      if (!_lifetime.isCancelled) openSessionPanel(parent, sideChatPanel(id));
    }
    if (!_lifetime.isCancelled) notifyListeners();
  }

  Future<void> _releaseSideDraft(DesktopTask side) async {
    side.sideSubmission?.cancel();
    side.liveText.dispose();
    drafts.remove(side.draftKey);
    draftSelections.remove(side.draftKey);
    fileDrafts.remove(side.draftKey);
    final attachments = attachmentDrafts.remove(side.draftKey) ?? const <ComposerAttachment>[];
    for (final attachment in attachments) { await attachment.discard(); }
  }

  void resizeSessionPanel(DesktopTask target, double width) {
    if (!width.isFinite) return;
    panelsFor(target).sessionWidth = width.clamp(400, double.infinity);
    _savePanels(target);
  }

  Future<void> chooseOpenCodeLayout(OpenCodeLayout layout) async {
    if (layout == OpenCodeLayout.inbox && inboxSince == null) {
      inboxSince = DateTime.now().millisecondsSinceEpoch;
      _saveNavigation('inbox_since', inboxSince.toString());
    }
    openCodeLayout = layout;
    notifyListeners();
    await _setting('opencode_layout', layout.name);
    await loadNavigationTasks();
  }

  Future<void> loadNavigationTasks() async {
    if (task case final target?) _rememberTab(target);
    final targets = openCodeLayout == OpenCodeLayout.inbox
        ? projects.expand((project) => project.tasks).where((target) =>
            target == task || !target.projectionState.containsKey('summary')).toList()
        : openTasks.map((entry) => entry.$2).toList();
    for (var index = 0; index < targets.length; index += 4) {
      _lifetime.throwIfCancelled();
      await Future.wait([
        for (final target in targets.skip(index).take(4))
          if (!target.loaded && !target.loading) loadHistory(target),
      ]);
    }
  }

  Future<void> chooseInboxWorkingExpanded(bool expanded) async {
    inboxWorkingExpanded = expanded;
    notifyListeners();
    await _setting('inbox_working_expanded', expanded.toString());
  }

  List<String> get navigationTabIds => [
    ...openTabIds.where(pinnedTaskIds.contains),
    ...openTabIds.where((id) => !pinnedTaskIds.contains(id)),
  ];

  List<(Project, DesktopTask)> get pinnedTasks => [
    for (final id in pinnedTaskIds)
      for (final project in projects)
        if (!project.removing)
          for (final task in project.tasks)
            if (task.id == id && !task.archived) (project, task),
  ];

  List<(Project, DesktopTask)> get openTasks => [
    for (final id in navigationTabIds)
      for (final project in projects)
        if (!project.removing)
          for (final task in project.tasks)
            if (task.id == id && !task.archived) (project, task),
  ];

  void _rememberTab(DesktopTask target) {
    if (target.archived || openTabIds.contains(target.id)) { return; }
    openTabIds.add(target.id);
    _saveNavigation('open_tabs', jsonEncode(openTabIds));
  }

  void showHome() {
    viewingConversation = false;
    _saveNavigation('active_tab', 'home');
    notifyListeners();
  }

  void _removeArchivedTab(DesktopTask target) {
    final index = navigationTabIds.indexOf(target.id);
    if (index == -1) return;
    openTabIds.remove(target.id);
    _saveNavigation('open_tabs', jsonEncode(openTabIds));
    if (task != target || !viewingConversation) return;
    // OpenCode's removeSessions skips drafts, preferring the next session.
    final remaining = {for (final entry in openTasks) entry.$2.id: entry};
    final ids = navigationTabIds;
    final next = ids.skip(index).map((id) => remaining[id]).nonNulls.firstOrNull ??
      ids.take(index).map((id) => remaining[id]).nonNulls.lastOrNull;
    if (next == null) {
      showHome();
    } else {
      unawaited(select(next.$1, next.$2).catchError((Object failure) {
        if (failure is! CancelledException) showError(failure);
      }));
    }
  }

  void _saveNavigation(String key, String value) {
    if (key == 'open_tabs' || key == 'active_tab') saveDrafts();
    unawaited(_setting(key, value).catchError((Object failure) {
      if (failure is! CancelledException) showError(failure);
    }));
  }

  void _markViewed(DesktopTask target) {
    if (!viewingConversation) return;
    if ((viewedTasks[target.id] ?? -1) >= target.lastActivity) return;
    viewedTasks[target.id] = target.lastActivity;
    _saveNavigation('viewed_tasks', jsonEncode(viewedTasks));
  }

  Future<void> reorderTabs(List<String> ids) async {
    if (ids.length != openTabIds.length || ids.toSet().length != ids.length ||
        !ids.every(openTabIds.contains)) { return; }
    openTabIds..clear()..addAll(ids);
    notifyListeners();
    saveDrafts();
    await _setting('open_tabs', jsonEncode(openTabIds));
  }

  Future<void> closeTab(DesktopTask target) async {
    final index = navigationTabIds.indexOf(target.id);
    if (index == -1) return;
    openTabIds.remove(target.id);
    if (task == target) {
      await _selectTabNear(index);
    }
    notifyListeners();
    saveDrafts();
    await _setting('open_tabs', jsonEncode(openTabIds));
  }

  Future<void> chooseSidebarSection(String section, bool collapsed) async {
    if (!{'pinned', 'projects', 'recents'}.contains(section)) throw ArgumentError('Invalid sidebar section');
    if (collapsed) {
      collapsedSidebarSections.add(section);
    } else {
      collapsedSidebarSections.remove(section);
    }
    notifyListeners();
    await _setting('sidebar_collapsed', jsonEncode(collapsedSidebarSections.toList()));
  }

  Future<void> pinTask(DesktopTask target, bool pinned) async {
    if (target.archived || target.archiving || !projects.any((project) => !project.removing && project.tasks.contains(target))) return;
    await _pin('sidebar_pinned_tasks', pinnedTaskIds, target.id, pinned);
  }

  Future<void> pinProject(Project target, bool pinned) async {
    if (target.removing || !projects.contains(target)) return;
    await _pin('sidebar_pinned_projects', pinnedProjectKeys, target.checkoutKey, pinned);
  }

  Future<void> _pin(String setting, List<String> ids, String id, bool pinned) async {
    if (ids.contains(id) == pinned) return;
    final previous = ids.toList();
    final next = ids.where((value) => value != id).toList();
    if (pinned) next.add(id);
    ids..clear()..addAll(next);
    notifyListeners();
    try {
      await _setting(setting, jsonEncode(next));
    } catch (_) {
      if (listEquals(ids, next)) {
        ids..clear()..addAll(previous);
        notifyListeners();
      }
      rethrow;
    }
  }

  List<(Project, DesktopTask)> get recentTasks {
    final tasks = [
      for (final project in projects)
        for (final task in project.tasks)
          if (!task.archived && !pinnedTaskIds.contains(task.id)) (project, task),
    ];
    // Retain project/task order for equal timestamps, including unsaved rows.
    final order = {for (var index = 0; index < tasks.length; index++) tasks[index].$2: index};
    return tasks..sort((a, b) {
      final recency = b.$2.lastActivity.compareTo(a.$2.lastActivity);
      return recency != 0 ? recency : order[a.$2]!.compareTo(order[b.$2]!);
    });
  }

  Future<bool> signIn(String provider, Future<void> Function(String) openBrowser) async {
    if (signingIn || !connected) return false;
    if (provider == 'openai') await _dictation?.cancel();
    final id = _loginId = newId();
    signingIn = true;
    loginProvider = provider;
    loginSucceeded = false;
    _loginCancelled = false;
    _openLogin = openBrowser;
    loginError = null;
    loginUrl = null;
    loginCode = null;
    loginMessage = 'Opening sign-in…';
    notifyListeners();
    try {
      await _request('auth.login', {'provider': provider, 'login_id': id});
      await refreshProviders();
      loginSucceeded = true;
      return true;
    } on CancelledException {
      // The desktop lifetime owns the connection and server-side cancellation.
    } catch (failure) {
      if (!_loginCancelled) loginError = failure.toString();
    } finally {
      if (_loginId == id) {
        _loginId = null;
        _openLogin = null;
        signingIn = false;
        loginUrl = null;
        loginMessage = null;
        loginCode = null;
      }
      if (!_lifetime.isCancelled) notifyListeners();
    }
    return false;
  }

  void dismissLoginResult() {
    loginSucceeded = false;
    if (!_lifetime.isCancelled) notifyListeners();
  }

  Future<void> signOut(String provider) async {
    if (signingOut != null || signingIn) return;
    if (provider == 'openai') await _dictation?.cancel();
    signingOut = provider;
    loginError = null;
    loginProvider = provider;
    loginSucceeded = false;
    notifyListeners();
    try {
      await _request('auth.logout', {'provider': provider});
      await refreshProviders();
    } on CancelledException {
      // Application exit owns cancellation.
    } catch (failure) {
      loginError = failure.toString();
    } finally {
      signingOut = null;
      if (!_lifetime.isCancelled) notifyListeners();
    }
  }

  Future<void> openLoginBrowser() async {
    final id = _loginId, url = loginUrl, open = _openLogin;
    if (id == null || url == null || open == null || _loginCancelled) return;
    try {
      await open(url);
    } catch (_) {
      if (_loginId == id && !_lifetime.isCancelled) {
        loginError = 'Could not open the browser. Try Open browser again.';
        notifyListeners();
      }
    }
  }

  Future<void> cancelLogin() async {
    final id = _loginId;
    if (id == null) return;
    _loginCancelled = true;
    await _request('auth.cancel', {'login_id': id});
  }

  void chooseModel(String id) {
    if (task != null) return;
    final model = models.where((m) => m['id'] == id).firstOrNull;
    if (model == null) throw ArgumentError('Unknown model');
    _rememberModel(model['provider'] as String, id, model['default_reasoning'] as String?);
    notifyListeners();
  }

  void chooseTracing(bool enabled) {
    if (task != null || submitting) return;
    currentDraft.tracing = enabled;
    saveDrafts();
    notifyListeners();
  }

  void chooseReasoning(String value, {DesktopTask? target}) {
    final selected = target ?? task;
    final provider = selected?.provider ?? providerId, model = selected?.model ?? modelId;
    if (selected != null) {
      if (!selected.reasoningUpdates) return;
      selected.nextReasoning = value;
    }
    if (target == null) _rememberModel(provider, model, value);
    notifyListeners();
  }

  void _rememberModel(String? provider, String? model, String? reasoning) {
    if (task == null) {
      currentDraft..provider = provider..model = model..reasoning = reasoning;
    }
    _provider = provider;
    _model = model;
    _reasoning = reasoning;
    saveDrafts();
  }

  void saveDrafts() {
    _draftSave?.cancel();
    _draftSave = Timer(const Duration(milliseconds: 250), () {
      unawaited(_persistDrafts().catchError((Object failure) {
        if (failure is! CancelledException) showError(failure);
      }));
    });
  }

  Future<void> _persistDrafts() => _setting('session_drafts', jsonEncode({
    'recent': {'provider': _provider, 'model': _model, 'reasoning': _reasoning},
    'active': viewingConversation ? task?.id ?? _activeDraftId : 'home',
    'tabs': openTabIds,
    'drafts': [for (final draft in sessionDrafts) {
      'id': draft.id, 'project': draft.checkoutKey,
      'provider': draft.provider, 'model': draft.model, 'reasoning': draft.reasoning,
      'tracing': draft.tracing,
      'text': drafts[draft.id] ?? '',
      if (draftSelections[draft.id] case final selection?)
        'selection': [selection.baseOffset, selection.extentOffset],
      'files': [for (final file in fileDrafts[draft.id] ?? const <ComposerFileReference>[])
        {'offset': file.offset, 'path': file.path, 'skill': file.skillName, 'title': file.title, 'prompt': file.prompt}],
      'attachments': [for (final attachment in attachmentDrafts[draft.id] ?? const <ComposerAttachment>[])
        {...attachment.toJson(), 'owned_directory': attachment.ownedDirectory}],
    }],
  }));

  void openDraft(SessionDraft draft) {
    if (!sessionDrafts.contains(draft)) return;
    viewingConversation = true;
    _activeDraftId = draft.id;
    project = projects.where((project) => project.checkoutKey == draft.checkoutKey && !project.removing).firstOrNull;
    task = null;
    error = null;
    _saveNavigation('active_tab', draft.id);
    saveDrafts();
    notifyListeners();
  }

  void newSession([Project? owner]) {
    final draft = SessionDraft('draft:${newId()}', (owner ?? project)?.checkoutKey,
      provider: _provider, model: _model, reasoning: _reasoning);
    sessionDrafts.add(draft);
    openTabIds.add(draft.id);
    openDraft(draft);
  }

  Future<void> closeDraft(SessionDraft draft) async {
    if (submitting || !sessionDrafts.remove(draft)) return;
    final index = navigationTabIds.indexOf(draft.id);
    openTabIds.remove(draft.id);
    drafts.remove(draft.id);
    fileDrafts.remove(draft.id);
    draftSelections.remove(draft.id);
    final attachments = attachmentDrafts.remove(draft.id) ?? const <ComposerAttachment>[];
    if (_activeDraftId == draft.id) {
      _activeDraftId = null;
      if (task == null) {
        await _selectTabNear(index);
      }
    }
    _saveNavigation('open_tabs', jsonEncode(openTabIds));
    saveDrafts();
    notifyListeners();
    await terminals.removeTask(draft.id);
    for (final attachment in attachments) { await attachment.discard(); }
  }

  Future<void> _selectTabNear(int index) async {
    final ids = navigationTabIds;
    final next = ids.isEmpty ? null : ids[index.clamp(0, ids.length - 1)];
    final draft = sessionDrafts.where((draft) => draft.id == next).firstOrNull;
    final existing = openTasks.where((entry) => entry.$2.id == next).firstOrNull;
    if (draft != null) { openDraft(draft); }
    else if (existing != null) { await select(existing.$1, existing.$2); }
    else { newSession(); }
  }

  Future<Object?> _request(String method, [Json params = const {}]) {
    _lifetime.throwIfCancelled();
    method = const {
      'task.start': 'session.create', 'task.send': 'session.prompt',
      'task.cancel': 'session.interrupt', 'task.compact': 'session.compact',
      'task.retry': 'session.retry',
      'task.archive': 'session.archive', 'task.unarchive': 'session.unarchive',
      'task.fork': 'session.fork',
    }[method] ?? method;
    if (method.startsWith('session.') && params['task_id'] != null) {
      params = {...params, 'sessionID': params['task_id']}..remove('task_id');
    }
    if ({'session.list', 'session.message.list', 'session.context', 'session.event.list'}.contains(method)) {
      return client.sessionRead(method, params, cancellation: _lifetime);
    }
    return client.request(method, params).asCancellable(_lifetime);
  }

  Future<void> load() async {
    await _request('client.capabilities', {'questions': true});
    final saved = jsonObject(
      await callIsolate(database.port, 'load', {}, cancellation: _lifetime),
    );
    final settings = jsonObject(saved['settings'] ?? {});
    deliveryMode = settings['delivery_mode'] == 'queue' ? 'queue' : 'steer';
    dictationMode = settings['dictation_mode'] == 'on_stop' ? 'on_stop' : 'live';
    projectAvatarStyle = settings['project_avatar_style'] == 'generated' ? 'generated' : 'letters';
    openCodeLayout = OpenCodeLayout.values.where((layout) => layout.name == settings['opencode_layout']).firstOrNull ?? OpenCodeLayout.top;
    sidebarOpen = settings['sidebar_open'] != 'false';
    inboxWorkingExpanded = settings['inbox_working_expanded'] != 'false';
    inboxSince = int.tryParse(settings['inbox_since'] as String? ?? '');
    try {
      final viewed = jsonDecode(settings['viewed_tasks'] as String? ?? '{}');
      if (viewed is Map) {
        viewedTasks.addAll({for (final entry in viewed.entries)
          if (entry.key is String && entry.value is int) entry.key as String: entry.value as int});
      }
    } on FormatException {
      // Read markers are optional presentation state.
    }
    final savedSidebarWidth = double.tryParse(settings['sidebar_width'] as String? ?? '');
    sidebarWidth = savedSidebarWidth != null && savedSidebarWidth.isFinite && savedSidebarWidth > 0 ? savedSidebarWidth : 248;
    final savedOpenCodeWidth = double.tryParse(settings['opencode_sidebar_width'] as String? ?? '');
    openCodeSidebarWidth = savedOpenCodeWidth != null && savedOpenCodeWidth.isFinite && savedOpenCodeWidth > 0 ? savedOpenCodeWidth : 276;
    List<String> savedIds(String key) {
      final value = settings[key];
      if (value is! String) return const [];
      try {
        final decoded = jsonDecode(value);
        return decoded is List ? decoded.whereType<String>().toSet().toList() : const [];
      } on FormatException {
        return const [];
      }
    }
    collapsedSidebarSections..clear()..addAll(savedIds('sidebar_collapsed'));
    pinnedTaskIds..clear()..addAll(savedIds('sidebar_pinned_tasks'));
    pinnedProjectKeys..clear()..addAll(savedIds('sidebar_pinned_projects'));
    for (final raw in saved['projects'] as List) {
      final value = jsonObject(raw);
      final key = requiredString(value, 'checkout_key');
      projects.add(
        Project(
          key,
          requiredString(value, 'identity'),
          requiredString(value, 'path'),
          [
            for (final t in (saved['tasks'] as List).map(jsonObject))
              if (t['checkout_key'] == key)
                DesktopTask(
                  requiredString(t, 'id'),
                  requiredString(t, 'title'),
                )..archived = t['archived'] == 1
                  ..lastActivity = t['last_activity'] as int? ?? 0,
          ],
        )..avatarColor = opencodeProjectColors.containsKey(settings['project_avatar_color:$key'])
          ? settings['project_avatar_color:$key'] as String : null
          ..displayName = (settings['project_name:$key'] as String?)?.trim().isNotEmpty == true
            ? settings['project_name:$key'] as String : null,
      );
      final image = settings['project_avatar_image:$key'] as String?;
      if (image != null && image.isNotEmpty) {
        try { projects.last.avatarImage = base64Decode(image); } on FormatException { /* Use the default icon. */ }
      }
    }
    await _checkProjectAvailability();
    await refreshProjects();
    project = projects.firstOrNull;
    Json restored = {};
    try {
      restored = jsonObject(jsonDecode(settings['session_drafts'] as String? ?? '{}'));
    } on FormatException { /* Optional composer state. */ }
    final recent = jsonObject(restored['recent'] ?? {});
    _provider = recent['provider'] as String?;
    _model = recent['model'] as String?;
    _reasoning = recent['reasoning'] as String?;
    for (final raw in restored['drafts'] as List? ?? const []) {
      final value = jsonObject(raw);
      final id = requiredString(value, 'id');
      sessionDrafts.add(SessionDraft(id, value['project'] as String?, provider: value['provider'] as String?,
        model: value['model'] as String?, reasoning: value['reasoning'] as String?, tracing: value['tracing'] == true));
      drafts[id] = value['text'] as String? ?? '';
      if (value['selection'] case [final int base, final int extent]) {
        draftSelections[id] = TextSelection(baseOffset: base, extentOffset: extent);
      }
      fileDrafts[id] = [for (final file in (value['files'] as List? ?? const []).map(jsonObject))
        ComposerFileReference(file['offset'] as int, file['path'] as String, skillName: file['skill'] as String?,
          title: file['title'] as String?, prompt: file['prompt'] as String?)];
      attachmentDrafts[id] = [for (final attachment in (value['attachments'] as List? ?? const []).map(jsonObject))
        ComposerAttachment(name: attachment['name'] as String, path: attachment['path'] as String,
          image: attachment['type'] == 'image', ownedDirectory: attachment['owned_directory'] as String?)];
    }
    final visible = {...projects.expand((project) => project.tasks).where((task) => !task.archived).map((task) => task.id),
      ...sessionDrafts.map((draft) => draft.id)};
    openTabIds.addAll(((restored['tabs'] as List?)?.cast<String>() ?? savedIds('open_tabs')).where(visible.contains));
    final active = restored['active'] ?? settings['active_tab'];
    viewingConversation = active != 'home';
    final draft = sessionDrafts.where((draft) => draft.id == active).firstOrNull;
    _activeDraftId = (draft ?? sessionDrafts.lastOrNull)?.id;
    if (draft != null) {
      _activeDraftId = draft.id;
      project = projects.where((project) => project.checkoutKey == draft.checkoutKey).firstOrNull;
    }
    for (final (owner, target) in openTasks) {
      if (target.id != active) continue;
      project = owner;
      task = target;
      break;
    }
    await refreshProviders();
    if (task == null && viewingConversation) currentDraft;
    if (openCodeLayout == OpenCodeLayout.inbox && inboxSince == null) {
      inboxSince = DateTime.now().millisecondsSinceEpoch;
      await _setting('inbox_since', inboxSince.toString());
    }
    await loadNavigationTasks();
    notifyListeners();
  }

  Future<void> addProject(String path) async {
    final folder = Directory(path);
    if (!await folder.exists()) {
      throw const FileSystemException('Choose an existing project folder');
    }
    final canonical = await folder.resolveSymbolicLinks();
    _lifetime.throwIfCancelled();
    project = projects.where((p) => p.path == canonical).firstOrNull;
    if (project == null) {
      final key = newId();
      final id = await projectIdentity(canonical, _lifetime);
      await callIsolate(database.port, 'project.add', {
        'checkout_key': key,
        'identity': id,
        'path': canonical,
      }, cancellation: _lifetime);
      project = Project(key, id, canonical);
      projects.add(project!);
    } else {
      if (project!.removing) throw StateError('Project is being removed');
      project!.available = true;
      await _refreshIdentity(project!);
    }
    await refreshSessions(owner: project);
    task = null;
    currentDraft.checkoutKey = project!.checkoutKey;
    _saveNavigation('open_tabs', jsonEncode(openTabIds));
    notifyListeners();
  }

  Future<void> _refreshIdentity(Project target) async {
    // An unavailable checkout must not silently erase its last known remote.
    if (!await Directory(target.path).exists()) return;
    final identity = await Future.wait<String?>([
      projectIdentity(target.path, _lifetime), projectBranch(target.path, _lifetime),
    ]);
    if (target.branch != identity[1]) {
      target.branch = identity[1];
      if (!_lifetime.isCancelled) notifyListeners();
    }
    final id = identity[0]!;
    if (id == target.id) return;
    await callIsolate(database.port, 'project.identify', {
      'checkout_key': target.checkoutKey,
      'identity': id,
    }, cancellation: _lifetime);
    target.id = id;
  }

  Future<void> refreshProjects() async {
    for (final owner in List.of(projects)) {
      if (!owner.available || owner.removing) continue;
      await _refreshIdentity(owner);
    }
    await refreshSessions();
    if (!_lifetime.isCancelled) notifyListeners();
  }

  Future<void> _checkProjectAvailability() async {
    var changed = false;
    for (final owner in List.of(projects)) {
      final available = await Directory(owner.path).exists();
      _lifetime.throwIfCancelled();
      if (owner.available == available) continue;
      owner.available = available;
      changed = true;
    }
    if (changed && !_lifetime.isCancelled) notifyListeners();
  }

  Future<void> removeProject(Project target) async {
    if (!projects.contains(target) || target.removing) return;
    if (submitting || target.tasks.any((task) => task.archiving)) {
      throw StateError('Wait for the current action to finish before removing this project');
    }
    target.removing = true;
    final closingTerminals = terminals.removeProject(target.checkoutKey);
    notifyListeners();
    try {
      await closingTerminals;
      if (project == target) await _dictation?.cancel();
      for (final task in target.tasks.where((task) => task.running).toList()) {
        await _request('task.cancel', {'task_id': task.id});
      }
      await callIsolate(database.port, 'project.remove', {
        'checkout_key': target.checkoutKey,
      }, cancellation: _lifetime);
      projects.remove(target);
      final removedIds = target.tasks.map((task) => task.id).toSet();
      if (openTabIds.any(removedIds.contains)) {
        openTabIds.removeWhere(removedIds.contains);
        _saveNavigation('open_tabs', jsonEncode(openTabIds));
      }
      if (project == target) {
        project = projects.where((project) => project.available && !project.removing).firstOrNull ?? projects.firstOrNull;
        task = null;
        error = null;
      }
      for (final draft in sessionDrafts.where((draft) => draft.checkoutKey == target.checkoutKey)) {
        draft.checkoutKey = project?.checkoutKey;
      }
      saveDrafts();
      final attachments = <ComposerAttachment>[];
      for (final key in [target.checkoutKey, ...target.tasks.map((task) => task.id)]) {
        drafts.remove(key);
        fileDrafts.remove(key);
        attachments.addAll(attachmentDrafts.remove(key) ?? const []);
      }
      if (!_lifetime.isCancelled) notifyListeners();
      for (final attachment in attachments) { await attachment.discard(); }
    } finally {
      target.removing = false;
      if (!_lifetime.isCancelled) notifyListeners();
    }
  }

  Future<void> select(Project nextProject, [DesktopTask? nextTask]) async {
    if (nextProject.removing || !projects.contains(nextProject)) return;
    viewingConversation = true;
    project = nextProject;
    task = nextTask;
    if (nextTask == null) currentDraft.checkoutKey = nextProject.checkoutKey;
    error = null;
    if (nextTask != null) {
      _rememberTab(nextTask);
      _markViewed(nextTask);
      conversation(nextTask);
    }
    _saveNavigation('active_tab', nextTask?.id ?? '');
    saveDrafts();
    notifyListeners();
    // Live events can leave a cached task without its initial configuration.
    // History and checkout identity are independent reads.
    await Future.wait([
      if (nextTask != null && !nextTask.loading &&
          (!nextTask.loaded || nextTask.events.isNotEmpty && nextTask.provider == null))
        loadHistory(nextTask),
      _refreshIdentity(nextProject),
    ]);
  }

  Future<void> loadHistory(DesktopTask target, {CancellationToken? cancellation}) async {
    if (target.loading) return;
    final read = cancellation?.merge(_lifetime) ?? _lifetime;
    read.throwIfCancelled();
    target.loading = true;
    target.loadError = null;
    notifyListeners();
    try {
      target.liveEvents.clear();
      final page = await client.sessionRead('session.message.list', {'sessionID': target.id, 'limit': 100},
        cancellation: read);
      read.throwIfCancelled();
      target.running = page['running'] == true;
      target.retryStatus = target.running && page['status']?['type'] == 'retry'
        ? page['status']['message'] as String? : null;
      if (!target.running) target.runStartedAt = null;
      target.pending
        ..clear()
        ..addEntries((page['pending'] as List? ?? []).map((raw) {
          final item = jsonObject(raw);
          return MapEntry('msg_${item['id']}', item);
        }));
      target.questions
        ..clear()
        ..addEntries((page['questions'] as List? ?? []).map((raw) {
          final question = jsonObject(raw);
          return MapEntry(question['id'] as String, question);
        }));
      final config = jsonObject(page['configuration'] ?? {});
      await _restoreTracing(target, config['tracing'] == true);
      target.provider = config['provider'] as String?;
      target.model = config['model'] as String?;
      target.reasoning = page['reasoning'] as String? ?? config['provider_settings']?['reasoning'] as String?;
      target.reasoningUpdates = config['reasoning_updates'] == true;
      target.contextLimit = config['provider_settings']?['context_limit'] as num?;
      target.archived = page['archived'] == true;
      if (target.archived) await terminals.removeTask(target.id);
      target.through = page['through'] as int;
      target.messages.clear();
      target.events.clear();
      target.projectionState
        ..clear()
        ..addAll(jsonObject(page['state'] ?? {}));
      _mergeHistory(target, page);
      final live = target.liveEvents.toList();
      target.liveEvents.clear();
      target.streamingText = '';
      for (final event in live) {
        if (event['durable'] == null || (event['durable']['seq'] as int) > target.through) {
          _applySessionEvent(target, event);
        }
      }
      target.questionDrafts.removeWhere((id, _) => !target.questions.containsKey(id));
      target.loaded = true;
      if (task == target) _markViewed(target);
    } on CancelledException {
      rethrow;
    } catch (failure) {
      target.loadError = failure.toString();
    } finally {
      target.loading = false;
      if (!_lifetime.isCancelled) notifyListeners();
    }
  }

  void _mergeHistory(DesktopTask target, Json page) {
    for (final raw in page['data'] as List) {
      final message = jsonObject(raw);
      target.messages.putIfAbsent(message['id'] as String, () => message);
    }
    target.historyBefore = page['cursor']?['next'] as String?;
  }

  Future<void> loadEarlier(DesktopTask target, {CancellationToken? cancellation}) async {
    final before = target.historyBefore;
    if (before == null || target.loadingEarlier || target.loading) return;
    final read = cancellation?.merge(_lifetime) ?? _lifetime;
    read.throwIfCancelled();
    target.loadingEarlier = true;
    target.loadError = null;
    notifyListeners();
    try {
      final page = await client.sessionRead('session.message.list', {
        'sessionID': target.id, 'cursor': before, 'limit': 100,
      }, cancellation: read);
      read.throwIfCancelled();
      _mergeHistory(target, page);
    } on CancelledException {
      rethrow;
    } catch (failure) {
      target.loadError = failure.toString();
    } finally {
      target.loadingEarlier = false;
      if (!_lifetime.isCancelled) notifyListeners();
    }
  }

  Future<bool> send(String prompt, {List<ComposerAttachment> attachments = const [], DesktopTask? target}) async {
    final enabled = (target ?? task)?.tracing ?? currentDraft.tracing;
    final store = enabled ? await tracing : null;
    final sideCommand = target == null && RegExp(r'^\s*/side(?:\s|$)').hasMatch(prompt);
    final context = store == null ? null : TraceContext(sink: store.sink, service: 'desktop',
      session: sideCommand ? null : (target ?? task)?.id);
    return withTrace(context, () => traceAsync('desktop.submit',
      () => _send(prompt, attachments: attachments, target: target, tracing: enabled)));
  }

  Future<bool> _send(String prompt, {List<ComposerAttachment> attachments = const [], DesktopTask? target,
      required bool tracing}) async {
    final owner = target == null ? project : projects.where((project) =>
      project.tasks.any((task) => task.id == target.sideParentID)).firstOrNull;
    final existing = target ?? task;
    final draft = existing == null ? currentDraft : null;
    final wasRunning = existing?.running == true;
    final sideCommand = target == null ? RegExp(r'^\s*/side(?:\s|$)').firstMatch(prompt) : null;
    if (sideCommand != null && existing == null) {
      showError('Send a message in the main session before starting a side chat.');
      return false;
    }
    if (owner == null ||
        !owner.available ||
        owner.removing ||
        (prompt.trim().isEmpty && attachments.isEmpty) ||
        (target?.sideSubmitting ?? submitting) ||
        target?.sidePreparing == true ||
        target != null && sideChats[target.id] != target ||
        !connected ||
        existing?.archived == true ||
        existing?.archiving == true ||
        !authenticatedFor(target)) {
      return false;
    }
    if (target == null) {
      submitting = true;
      error = null;
      _earlyEvents.clear();
    } else {
      target.sideSubmitting = true;
      target.sideError = null;
    }
    final provider = target?.provider ?? providerId, model = target?.model ?? modelId;
    final effort = effortFor(target), info = modelFor(target);
    final cancellation = CancellationToken();
    if (target == null) { _submission = cancellation; }
    else { target.sideSubmission = cancellation; }
    void progress(String? status) {
      if (target == null) { attachmentStatus = status; }
      else { target.sideAttachmentStatus = status; }
      if (!_lifetime.isCancelled) notifyListeners();
    }
    final uploaded = <String>[];
    var admitted = false;
    notifyListeners();
    try {
      final input = <Json>[];
      final images = attachments.where((attachment) => attachment.image).toList();
      final remoteImages = <Json>[];
      if (images.isNotEmpty && !client.sharedFilesystem) {
        progress('Preparing images…');
        remoteImages.addAll(await prepareRemoteImages(images.map((image) => image.toJson()).toList(),
          cancellation: cancellation.merge(_lifetime)));
        progress(null);
      }
      var imageIndex = 0;
      for (final attachment in attachments) {
        cancellation.throwIfCancelled();
        _lifetime.throwIfCancelled();
        if (!client.sharedFilesystem && attachment.image) {
          input.add(remoteImages[imageIndex++]);
        } else if (!client.sharedFilesystem) {
          if (await FileSystemEntity.isDirectory(attachment.path)) {
            throw StateError('Folders must be on the server; upload individual files instead');
          }
          progress('Uploading ${attachment.name}…');
          final part = await client.uploadAttachment(attachment.path,
            name: attachment.name, type: attachment.image ? 'image' : 'file',
            cancellation: cancellation.merge(_lifetime),
            onProgress: (sent, total) {
              progress('Uploading ${attachment.name} · ${total == 0 ? 100 : (sent * 100 ~/ total)}%');
            });
          uploaded.add(part['upload_id'] as String);
          input.add(part);
        } else {
          input.add(attachment.toJson());
        }
      }
      cancellation.throwIfCancelled();
      _lifetime.throwIfCancelled();
      progress(null);
      if (existing == null) {
        final reply = jsonObject(
          await _request('task.start', {
            'cwd': owner.path,
            'prompt': prompt,
            if (input.isNotEmpty) 'attachments': input,
            'provider': provider,
            'model': model,
            'reasoning': effort,
            'tracing': tracing,
          }),
        );
        final title = prompt.trim().isEmpty ? attachments.first.name : prompt.trim().split('\n').first;
        final created = DesktopTask(
          requiredString(reply, 'sessionID'),
          title.length > 72 ? '${title.substring(0, 72)}…' : title,
          tracing: tracing,
        )..running = true
          ..lastActivity = DateTime.now().millisecondsSinceEpoch;
        bindTraceSession(created.id);
        if (tracing) client.traceSession(created.id);
        created.loaded = true;
        created.provider = provider;
        created.model = model;
        created.reasoning = effort;
        created.reasoningUpdates = info?['reasoning_updates'] == true;
        owner.tasks.insert(0, created);
        _rememberTab(created);
        terminals.adoptDraft(owner.checkoutKey, created.id, draft: draft?.id);
        if (draft != null) {
          final index = openTabIds.indexOf(draft.id);
          openTabIds.remove(created.id);
          if (index >= 0) { openTabIds[index] = created.id; }
          else { openTabIds.add(created.id); }
          sessionDrafts.remove(draft);
        }
        if (project == owner && task == null && _activeDraftId == draft?.id) {
          task = created;
          _saveNavigation('active_tab', created.id);
        }
        if (_activeDraftId == draft?.id) _activeDraftId = null;
        _saveNavigation('open_tabs', jsonEncode(openTabIds));
        for (final event in _earlyEvents) {
          if ((event['data']?['sessionID'] ?? event['task_id']) == created.id) _applyEvent(created, event);
        }
        if (created.archived) {
          await terminals.removeTask(created.id);
          if (task == created) task = null;
        }
        try {
          await callIsolate(database.port, 'task.add', {
            'id': created.id,
            'checkout_key': owner.checkoutKey,
            'title': created.title,
            'last_activity': created.lastActivity,
          }, cancellation: _lifetime);
        } on CancelledException {
          rethrow;
        } catch (failure) {
          // The server already admitted this turn. Do not offer to resend it.
          error =
              'Task started, but its sidebar reference could not be saved: $failure';
        }
      } else if (sideCommand != null) {
        await openSideChat(existing, prompt: prompt.substring(sideCommand.end).trimLeft(), attachments: input);
      } else {
        // Mark admission before awaiting: a very short turn can finish before
        // the caller resumes from the WebSocket acknowledgement.
        existing.running = true;
        await _request('task.send', {
          'task_id': existing.id,
          'prompt': prompt,
          if (input.isNotEmpty) 'attachments': input,
          'delivery': deliveryMode,
          if (!wasRunning || existing.reasoningUpdates) 'reasoning': effort,
        });
      }
      admitted = true;
      return true;
    } on CancelledException {
      rethrow;
    } catch (failure) {
      existing?.running = wasRunning;
      if (target == null) { error = failure.toString(); }
      else { target.sideError = failure.toString(); }
      return false;
    } finally {
      if (!admitted) for (final id in uploaded) { await client.discardAttachment(id); }
      cancellation.cancel();
      if (target == null) {
        if (identical(_submission, cancellation)) _submission = null;
        attachmentStatus = null;
        _earlyEvents.clear();
        submitting = false;
      } else {
        target.sideSubmission = null;
        target.sideAttachmentStatus = null;
        target.sideSubmitting = false;
      }
      if (!_lifetime.isCancelled) notifyListeners();
    }
  }

  Future<void> retry(DesktopTask target) async {
    if (target.running || target.archived || target.archiving || !connected) return;
    final terminals = target.messages.values.where((message) => message['type'] == 'idle').toList()
      ..sort((a, b) => (a['metadata']['seq'] as int).compareTo(b['metadata']['seq'] as int));
    final failure = terminals.lastOrNull;
    if (failure?['outcome'] != 'failed') return;
    target.running = true;
    target.retryStatus = 'Reconnecting…';
    error = null;
    notifyListeners();
    try {
      await _request('task.retry', {'task_id': target.id, 'failureID': failure!['id']});
    } catch (_) {
      target.running = false;
      target.retryStatus = null;
      rethrow;
    } finally {
      if (!_lifetime.isCancelled) notifyListeners();
    }
  }

  Future<void> stop({DesktopTask? target}) async {
    final selected = target ?? task;
    if (selected == null || !selected.running) return;
    await _request('task.cancel', {'task_id': selected.id});
  }

  Future<void> changePending(DesktopTask target, String inboxID, String action) async {
    if (!connected || target.archived || target.archiving) throw StateError('Session is unavailable');
    if (!target.pending.containsKey(inboxID)) throw StateError('Message is no longer pending');
    if (!{'steer', 'queue', 'delete'}.contains(action)) throw ArgumentError('Unknown pending message action');
    await _request(action == 'delete' ? 'session.inbox.cancel' : 'session.inbox.update', {
      'sessionID': target.id, 'inboxID': inboxID,
      if (action != 'delete') 'delivery': action,
    });
  }

  Future<void> answerQuestion(DesktopTask target, String requestID, List<List<String>>? answers, {
    required CancellationToken cancellation,
  }) async {
    await client.answerQuestion(target.id, requestID, answers,
      cancellation: cancellation.merge(_lifetime));
    target.questions.remove(requestID);
    target.questionDrafts.remove(requestID);
    if (!_lifetime.isCancelled) notifyListeners();
  }

  Future<void> setArchived(DesktopTask target, bool archived) async {
    final owner = projects.where((project) => project.tasks.contains(target)).firstOrNull;
    if (target.archiving || owner == null || owner.removing) return;
    target.archiving = true;
    final closingTerminals = archived ? terminals.removeTask(target.id) : Future<void>.value();
    notifyListeners();
    try {
      await closingTerminals;
      await _request(archived ? 'task.archive' : 'task.unarchive', {'task_id': target.id});
      target.archived = archived;
      if (archived) _removeArchivedTab(target);
      await _saveArchived(target);
    } finally {
      target.archiving = false;
      if (!_lifetime.isCancelled) notifyListeners();
    }
  }

  Future<void> _saveArchived(DesktopTask target) async {
    await callIsolate(database.port, 'task.archive', {
      'task_id': target.id, 'archived': target.archived,
    }, cancellation: _lifetime);
  }

  void showError(Object failure, {DesktopTask? target}) {
    if (_lifetime.isCancelled) return;
    if (target == null) { error = failure.toString(); }
    else { target.sideError = failure.toString(); }
    notifyListeners();
  }

  void _onEvent(Json event) {
    final trace = event['_trace'] == null ? null : client.eventTrace(event);
    withTrace(trace, () => traceSync('desktop.event.apply', () => _applyIncomingEvent(event),
      attributes: {'event.type': event['type']}));
    final side = sideChats[trace?.session];
    final panels = task == null ? null : panelLayouts[task!.id];
    final visible = trace?.session == task?.id || side?.sideParentID == task?.id &&
      panels?.opened == true && panels?.active == sideChatPanel(side!.id);
    if (trace == null || !visible || !_traceFrames.add(trace.trace)) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _traceFrames.remove(trace.trace);
      withTrace(trace, () => traceInstant('desktop.frame.presented',
        attributes: {'event.type': event['type']}));
    });
  }

  void attachExportToNewSession(File file, {Project? owner, String? ownedDirectory}) {
    newSession(owner);
    attachmentDrafts[currentDraft.id] = [ComposerAttachment(name: file.uri.pathSegments.last,
      path: file.path, image: false, ownedDirectory: ownedDirectory)];
    saveDrafts();
    notifyListeners();
  }

  void _applyIncomingEvent(Json event) {
    if (event['type'] == 'session.side.closed') {
      final id = event['data']?['sessionID'] as String?;
      final side = sideChats.remove(id);
      if (side == null) return;
      unawaited(_releaseSideDraft(side).catchError((Object failure) {
        if (!_lifetime.isCancelled) showError(failure);
      }));
      final parent = projects.expand((project) => project.tasks)
        .where((task) => task.id == side.sideParentID).firstOrNull;
      if (parent != null) {
        final panels = panelsFor(parent), tab = sideChatPanel(side.id);
        final index = panels.tabs.indexOf(tab);
        panels.tabs.remove(tab);
        if (panels.active == tab) panels.active = panels.tabs.isEmpty ? null
          : panels.tabs[index.clamp(0, panels.tabs.length - 1)];
        if (panels.tabs.isEmpty) panels.opened = false;
        _savePanels(parent);
      } else {
        notifyListeners();
      }
      return;
    }
    if (event['type'] == 'session.archived' || event['type'] == 'task.archived') {
      final id = event['data']?['sessionID'] ?? event['task_id'];
      if (id is String) unawaited(terminals.removeTask(id));
    }
    if (event['type'] == 'auth.changed' && event['provider'] == 'openai') {
      unawaited(_dictation?.cancel());
      return;
    }
    if (event['type'] == 'auth.login') {
      if (event['login_id'] == _loginId && !_loginCancelled) {
        loginUrl = event['url'] as String;
        loginMessage = event['message'] as String;
        loginCode = event['code'] as String?;
        notifyListeners();
        unawaited(openLoginBrowser());
      }
      return;
    }
    final sessionID = event['data']?['sessionID'] ?? event['task_id'];
    final target = sideChats[sessionID] ?? projects
        .expand((p) => p.tasks)
        .where((t) => t.id == sessionID)
        .firstOrNull;
    if (target == null) {
      if (submitting && _earlyEvents.length < 256) _earlyEvents.add(event);
      return;
    }
    final appendingText = event['type'] == 'session.text.delta' && target.streamingText.isNotEmpty;
    _applyEvent(target, event);
    _observeActivity(target, [event]);
    if (task == target) _markViewed(target);
    if ({'session.archived', 'session.unarchived', 'task.archived', 'task.unarchived'}.contains(event['type'])) {
      if (target.archived) _removeArchivedTab(target);
      unawaited(_saveArchived(target).catchError((Object failure) {
        if (failure is! CancelledException) showError(failure);
      }));
    }
    if (!appendingText) notifyListeners();
  }

  void _observeActivity(DesktopTask target, Iterable<Json> events) {
    var latest = target.lastActivity;
    for (final event in events) {
      if (!{'input.pending', 'input.committed', 'turn.started', 'turn.completed', 'turn.failed', 'turn.cancelled'}.contains(event['type'])) continue;
      var timestamp = event['created_at'];
      if (event['type'] == 'input.pending') timestamp ??= event['data']?['created_at'];
      final time = timestamp is String ? DateTime.tryParse(timestamp)?.millisecondsSinceEpoch : null;
      if (time != null && time > latest) latest = time;
    }
    if (latest <= target.lastActivity) return;
    target.lastActivity = latest;
    unawaited(_saveActivity(target).catchError((Object failure) {
      if (failure is! CancelledException) showError(failure);
    }));
  }

  Future<void> _saveActivity(DesktopTask target) async {
    if (target.sideParentID != null) return;
    await callIsolate(database.port, 'task.activity', {
      'task_id': target.id, 'last_activity': target.lastActivity,
    }, cancellation: _lifetime);
  }

  void _applyEvent(DesktopTask target, Json event) {
    if (event['type'].toString().startsWith('session.')) {
      if (target.loading) target.liveEvents.add(event);
      _applySessionEvent(target, event);
      return;
    }
    final state = jsonObject(target.projectionState['execution'] ?? {});
    for (final native in sessionEvents(target.id, event, state)) { _applySessionEvent(target, native); }
    target.projectionState['execution'] = state;
  }

  void _applySessionEvent(DesktopTask target, Json event) {
    final data = jsonObject(event['data'] ?? {});
    final sequence = event['durable']?['seq'] as int?;
    if (sequence != null && sequence <= target.through) return;
    if (sequence != null) target.through = sequence;
    applySessionEvent(target.messages, event, target.projectionState);
    switch (event['type']) {
      case 'session.created':
        target.provider = data['model']?['providerID'] as String?;
        target.model = data['model']?['id'] as String?;
        target.contextLimit = data['metadata']?['providerSettings']?['context_limit'] as num?;
        target.reasoning = data['metadata']?['providerSettings']?['reasoning'] as String?;
        target.reasoningUpdates = data['metadata']?['reasoningUpdates'] == true;
      case 'session.execution.started':
      case 'session.step.started':
        if (event['type'] == 'session.execution.started') target.runStartedAt = event['created'] as int?;
        target.running = true;
        target.streamingText = '';
        target.retryStatus = null;
      case 'session.text.delta':
        final message = target.messages[data['assistantMessageID']];
        if (message?['time']?['streamed'] != null || message?['time']?['completed'] != null) break;
        final parts = message?['content'] as List? ?? [];
        final ordinal = data['ordinal'] as int;
        target.streamingText = ordinal < parts.length ? parts[ordinal]['text'] as String? ?? '' : '';
        target.retryStatus = null;
      case 'session.reasoning.delta':
        target.retryStatus = null;
      case 'session.text.ended':
      case 'session.step.streamed':
        target.streamingText = '';
        target.retryStatus = null;
      case 'session.status':
        target.running = data['status']['type'] != 'idle';
        if (!target.running) target.runStartedAt = null;
        target.retryStatus = data['status']['type'] == 'retry' ? data['status']['message'] as String? : null;
        if (target.retryStatus != null) target.streamingText = '';
      case 'session.question.asked':
        final request = jsonObject(data['request']);
        target.questions[request['id'] as String] = request;
      case 'session.question.replied':
      case 'session.question.rejected':
        target.questions.remove(data['requestID']);
        target.questionDrafts.remove(data['requestID']);
      case 'session.model.selected':
        target.reasoning = data['model']['variant'] as String?;
        if (target.nextReasoning == target.reasoning) target.nextReasoning = null;
      case 'session.inbox.enqueued':
        final item = jsonObject(data['item']);
        target.pending[data['inboxID'] as String] = {
          'prompt': item['text'] ?? '', 'delivery': item['delivery'], 'attachments': item['files'] ?? [],
          'created_at': DateTime.fromMillisecondsSinceEpoch(event['created'] as int).toIso8601String(),
        };
      case 'session.inbox.delivered':
        target.pending.remove(data['inboxID']);
        target.streamingText = '';
      case 'session.inbox.delivery.changed':
        final id = data['inboxID'] as String;
        if (target.pending[id] case final item?) target.pending[id] = {...item, 'delivery': data['delivery']};
      case 'session.inbox.cancelled':
        for (final id in data['ids'] as List? ?? [data['inboxID']]) { target.pending.remove(id); }
      case 'session.archived':
        target.archived = true;
      case 'session.unarchived':
        target.archived = false;
      case 'session.execution.succeeded':
      case 'session.execution.failed':
      case 'session.execution.interrupted':
        target.running = false;
        target.runStartedAt = null;
        target.streamingText = '';
        target.retryStatus = null;
        target.questions.clear();
        target.questionDrafts.clear();
    }
    target.liveText.value = target.streamingText;
    final activity = event['created'] as int?;
    if (activity != null && activity > target.lastActivity &&
        {'session.inbox.delivered', 'session.execution.succeeded', 'session.execution.failed', 'session.execution.interrupted'}.contains(event['type'])) {
      target.lastActivity = activity;
      unawaited(_saveActivity(target).catchError((Object failure) { if (failure is! CancelledException) showError(failure); }));
    }
  }

  Future<void> close() async {
    _draftSave?.cancel();
    if (_draftSave != null || sessionDrafts.isNotEmpty) await _persistDrafts();
    await terminals.close();
    terminals.dispose();
    _submission?.cancel();
    for (final side in sideChats.values) {
      side.sidePreparation?.cancel();
      side.sideSubmission?.cancel();
    }
    await _dictation?.cancel();
    _dictation?.dispose();
    _dictation = null;
    _lifetime.cancel();
    _disconnect.dispose();
    await _events.cancel();
    await client.close();
    await database.close();
    for (final side in sideChats.values) { side.liveText.dispose(); }
    sideChats.clear();
    for (final entry in attachmentDrafts.entries) {
      if (sessionDrafts.any((draft) => draft.id == entry.key)) continue;
      for (final attachment in entry.value) { await attachment.discard(); }
    }
    attachmentDrafts.clear();
    dispose();
  }
}

class ToolActivity {
  ToolActivity(this.id, this.name, Object? input, {this.startedAt, this.preview, bool formatInput = false})
    : _rawInput = input, _input = formatInput || input is! String ? null : input;
  final String id, name;
  final String? preview;
  final Object? _rawInput;
  String? _input, _output;
  Object? _rawOutput;
  bool _hasOutput = false;
  // Collapsed tools should not parse and re-encode their potentially large JSON.
  String get input => _input ??= _pretty(_rawInput);
  Object? get rawInput => _rawInput;
  String? get output => _hasOutput ? _output ??= _pretty(_rawOutput) : null;
  Object? get rawOutput => _rawOutput;
  set output(Object? value) {
    _hasOutput = true;
    _rawOutput = value;
    _output = null;
  }
  final DateTime? startedAt;
  DateTime? endedAt;
  final children = <ToolActivity>[];
  String status = 'running';
}

/// A visible transcript row. Provider replay state never enters this projection.
typedef ChatResponse = ({String? provider, String? model, String? reasoning, Duration? duration, bool interrupted});

class ChatEntry {
  const ChatEntry(this.id, this.role, this.text, {
    this.tool, this.compaction, this.timestamp, this.startedAt, this.streaming = false, this.attachments = const [],
    this.response,
  });
  final String id, role, text;
  final ToolActivity? tool;
  final CompactionActivity? compaction;
  final DateTime? timestamp, startedAt;
  final bool streaming;
  final List<Json> attachments;
  final ChatResponse? response;
}

class CompactionActivity {
  CompactionActivity({this.startedAt});
  final DateTime? startedAt;
  DateTime? endedAt;
  String status = 'running', summary = '';
}

bool _sameRecords(Iterable<Json> records, List<Json>? previous) {
  if (previous == null) return false;
  var index = 0;
  for (final record in records) {
    if (index >= previous.length || !identical(record, previous[index++])) return false;
  }
  return index == previous.length;
}

List<ChatEntry> conversation(DesktopTask task) {
  if (task.events.isNotEmpty && !_sameRecords(task.events.values, task._legacyRecords)) {
    task._legacyRecords = task.events.values.toList(growable: false);
    task.messages.clear();
    final state = <String, dynamic>{}, inbox = <String, dynamic>{};
    final records = task.events.values.toList()..sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));
    for (final record in records) {
      for (final event in sessionEvents(task.id, record, state)) { applySessionEvent(task.messages, event, inbox); }
    }
  }
  final state = (task.running, task.streamingText);
  if (task._conversation != null && task._conversationState == state &&
      _sameRecords(task.messages.values, task._conversationEvents) &&
      _sameRecords(task.pending.values, task._conversationPending)) return task._conversation!;
  final result = <ChatEntry>[];
  final messages = task.messages.values.toList()..sort((a, b) =>
    (a['metadata']?['seq'] as int? ?? 0).compareTo(b['metadata']?['seq'] as int? ?? 0));
  final activeMessage = messages.where((message) => {'user', 'assistant', 'idle'}.contains(message['type'])).lastOrNull;
  DateTime? at(Object? value) => value is int ? DateTime.fromMillisecondsSinceEpoch(value) : null;
  final tools = <String, ToolActivity>{};
  DateTime? started;
  String? activeAssistant;
  var turnFirstRow = 0;
  final responseImageRows = <ChatEntry>[];
  void finishImages() {
    if (responseImageRows.isEmpty) return;
    final index = result.lastIndexWhere((entry) => entry.role == 'Happen' && entry.text.isNotEmpty);
    if (index > result.indexOf(responseImageRows.last)) {
      final entry = result[index], seen = <Object>{};
      final images = [for (final image in [...entry.attachments, ...responseImageRows.expand((row) => row.attachments)])
        if (seen.add(image[r'$part'] ?? image['data'] ?? image['path'] ?? image)) image];
      result[index] = ChatEntry(entry.id, entry.role, entry.text, timestamp: entry.timestamp,
        startedAt: entry.startedAt, streaming: entry.streaming, response: entry.response, attachments: images);
      final sources = responseImageRows.toSet();
      result.removeWhere(sources.contains);
    }
    responseImageRows.clear();
  }
  for (final message in messages) {
    final id = message['id'] as String, created = at(message['time']['created']);
    switch (message['type']) {
      case 'user':
        // An intervening user message keeps earlier media with its source reply.
        responseImageRows.clear();
        started ??= created;
        result.add(ChatEntry(id, 'You', message['text'] as String? ?? '',
          attachments: (message['files'] as List? ?? []).map(jsonObject).toList(), timestamp: created));
      case 'assistant':
        started ??= created;
        activeAssistant = id;
        final imageOwners = <String, String>{};
        final imageRows = <String, List<Json>>{};
        final content = (message['content'] as List? ?? []).map(jsonObject).toList();
        var ordinal = 0;
        for (final part in content) {
          final partID = '$id:${ordinal++}';
          if (part['type'] == 'tool') {
            final status = jsonObject(part['state']);
            final tool = ToolActivity(part['id'] as String, part['name'] as String,
              status['input'], formatInput: true, startedAt: at(part['time']?['created']));
            tool.status = switch (status['status']) {'completed' => 'done', 'error' => 'failed',
              _ => task.running && identical(message, activeMessage) ? 'running' : 'interrupted'};
            tool.endedAt = at(part['time']?['completed']);
            final outputImages = <Json>[];
            if (status['content'] is List) {
              final content = status['content'] as List;
              outputImages.addAll(content.where((part) => part['type'] == 'image').map(jsonObject));
              final text = content.where((part) => part['type'] != 'image').toList();
              if (text.isNotEmpty) tool.output = text.length == 1 && text.first['type'] == 'text' ? text.first['text'] : {'content': text};
            } else if (status['error'] != null) { tool.output = status['error']; }
            tools[tool.id] = tool;
            final parent = tools[part['native']?['parentCallID']];
            if (parent != null) { parent.children.add(tool); }
            else { result.add(ChatEntry(partID, 'Tool', tool.name, tool: tool, timestamp: created)); }
            final owner = imageOwners[tool.id] = imageOwners[parent?.id] ?? tool.id;
            if (outputImages.isNotEmpty) {
              // A nested call and its enclosing cell share one image row.
              final images = imageRows.putIfAbsent(owner, () {
                final images = <Json>[];
                final row = ChatEntry('$id:$owner:images', 'Happen', '', timestamp: created, attachments: images);
                result.add(row);
                responseImageRows.add(row);
                return images;
              });
              final seen = {for (final image in images) image[r'$part'] ?? image['data'] ?? image['path'] ?? image};
              for (final image in outputImages) {
                if (seen.add(image[r'$part'] ?? image['data'] ?? image['path'] ?? image)) images.add(image);
              }
            }
          } else if (part['type'] == 'text' || part['type'] == 'reasoning') {
            if ((part['text'] as String? ?? '').isEmpty) continue;
            final reasoning = part['type'] == 'reasoning';
            final streaming = task.running && identical(message, activeMessage) && ordinal == content.length &&
              message['time']?['streamed'] == null && message['time']?['completed'] == null && part['time']?['completed'] == null;
            result.add(ChatEntry(partID, part['type'] == 'text' ? 'Happen' : 'Reasoning', part['text'] as String,
              timestamp: reasoning ? at(part['time']?['completed']) ?? created : created,
              startedAt: reasoning ? at(part['time']?['created']) ?? created : null, streaming: streaming));
          }
        }
      case 'compaction':
        final activity = CompactionActivity(startedAt: created)
          ..status = switch (message['status']) {'completed' => 'done',
            'failed' => switch (message['outcome']) {'interrupted' => 'stopped', 'succeeded' => 'interrupted', _ => 'failed'},
            _ => task.running ? 'running' : 'interrupted'}
          ..endedAt = at(message['time']?['completed'])
          ..summary = message['summary'] as String? ?? '';
        result.add(ChatEntry(id, 'Compaction', '', compaction: activity));
      case 'idle':
        finishImages();
        final interrupted = message['outcome'] == 'interrupted';
        final index = result.lastIndexWhere((entry) => entry.role == 'Happen');
        if (index >= turnFirstRow) {
          final entry = result[index];
          final model = messages.where((m) => m['type'] == 'assistant' && m['id'] == activeAssistant).firstOrNull?['model'];
          result[index] = ChatEntry(entry.id, entry.role, entry.text, timestamp: entry.timestamp,
            attachments: entry.attachments,
            response: (provider: model?['providerID'] as String?, model: model?['id'] as String?,
              reasoning: model?['variant'] as String?, duration: created != null && started != null ? created.difference(started) : null,
              interrupted: interrupted));
        }
        // A resumed turn supersedes its failure notice; keep the stored event
        // for history without presenting a recovered failure as a current error.
        if (message['outcome'] != 'failed' || identical(message, activeMessage) && !task.running) {
          result.add(ChatEntry(id, message['outcome'] == 'failed' ? 'Error' : 'Status',
            message['outcome'] == 'failed' ? (message['error']?['message'] as String? ?? 'Task failed') : interrupted ? 'Stopped' : 'Completed',
            timestamp: created, startedAt: started));
        }
        started = null;
        turnFirstRow = result.length;
        activeAssistant = null;
    }
  }
  finishImages();
  for (final entry in task.pending.entries) {
    final item = entry.value;
    result.add(ChatEntry('pending:${entry.key}', item['delivery'] == 'steer' ? 'Steer pending' : 'Queued', item['prompt'] as String? ?? '',
      attachments: (item['attachments'] as List? ?? []).map(jsonObject).toList(),
      timestamp: DateTime.tryParse(item['created_at'] as String? ?? '')));
  }
  task._conversationState = state;
  task._conversationEvents = task.messages.values.toList(growable: false);
  task._conversationPending = task.pending.values.toList(growable: false);
  return task._conversation = result;
}

/// Binary media is presented by the response's image widgets.
String conversationDataText(Object? value) {
  final imageData = RegExp(r'data:image/[^,\s"]+,[^"\s]+');
  if (value is String) {
    final text = value;
    try { value = jsonDecode(text); } on FormatException { return text.replaceAll(imageData, '[Image]'); }
  }
  if (value is List && value.isNotEmpty && value.every((part) =>
      part is Map && {'input_text', 'input_image'}.contains(part['type']))) {
    return value.where((part) => part['type'] == 'input_text')
      .map((part) => conversationDataText(part['text'])).join('\n');
  }
  Object? display(Object? value) {
    if (value is String) return value.replaceAll(imageData, '[Image]');
    if (value is List) return value.map(display).toList();
    if (value is Map) return {
      for (final entry in value.entries) entry.key:
        entry.key == 'data' && (value['mime_type'] ?? value['mimeType'] ?? '').toString().startsWith('image/')
          ? '[Image]' : display(entry.value),
    };
    return value;
  }
  return const JsonEncoder.withIndent('  ').convert(display(value));
}

String _pretty(Object? value) {
  if (value is String) {
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(value));
    } on FormatException {
      return value;
    }
  }
  return const JsonEncoder.withIndent('  ').convert(value);
}
