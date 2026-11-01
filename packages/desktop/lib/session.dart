import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:ai/ai.dart';
import 'package:flutter/foundation.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

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
  String? branch;
  final List<DesktopTask> tasks;
  bool available = true, removing = false;
  String get name => path.split(Platform.pathSeparator).last;
}

class DesktopTask {
  DesktopTask(this.id, this.title);
  final String id, title;
  final events = <int, Json>{};
  final messages = <String, Json>{};
  final projectionState = <String, dynamic>{};
  final liveEvents = <Json>[];
  int through = 0;
  final pending = <String, Json>{};
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
  List<ChatEntry>? _conversation;
  List<Json>? _conversationEvents, _conversationPending, _legacyRecords;
  Object? _conversationState;
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
  final terminals = DesktopTerminals();
  final panelLayouts = <String, SessionPanelState>{};
  final _changedPanelLayouts = <String>{};
  bool _panelsLoaded = false;
  final drafts = <String, String>{};
  late final fileDrafts = <String, List<ComposerFileReference>>{};
  final String attachmentDirectory;
  final attachmentDrafts = <String, List<ComposerAttachment>>{};
  CancellationToken? _submission;
  String? attachmentStatus;
  void cancelUpload() => _submission?.cancel();
  DictationService? _dictation;
  DictationService get dictation => _dictation ??= DictationService(client);
  final _lifetime = CancellationToken();
  late final StreamSubscription<Json> _events;
  late final CancellationHook _disconnect;
  final _earlyEvents = <Json>[];
  List<Json> providers = [];
  final _projectModels = <String, Json>{};
  String? _provider, _model, _reasoning;
  String deliveryMode = 'steer';
  String dictationMode = 'live';
  OpenCodeLayout openCodeLayout = OpenCodeLayout.top;
  bool sidebarOpen = true, inboxWorkingExpanded = true;
  bool viewingConversation = true;
  int? inboxSince;
  final openTaskIds = <String>[];
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

  String get draftKey => task?.id ?? project?.checkoutKey ?? '';
  String? get providerId {
    final selected = task?.provider ?? (_projectModel?['provider'] as String?) ?? _provider;
    return selected == 'gpt' ? 'openai' : selected;
  }
  String? get modelId => task?.model ?? (_projectModel?['id'] as String?) ?? _model;
  String? get reasoning {
    final selected = task?.nextReasoning ?? task?.reasoning;
    if (selected != null) return selected;
    final model = _projectModel;
    if (model == null) return _reasoning;
    final saved = _projectModels[project?.checkoutKey]?['reasoning'];
    return (model['reasoning_levels'] as List? ?? const []).contains(saved)
        ? saved as String? : model['default_reasoning'] as String?;
  }
  Json? get providerInfo =>
      providers.where((p) => p['id'] == providerId).firstOrNull;
  List<Json> get models => [
    for (final provider in providers)
      for (final model in provider['models'] as List? ?? [])
        {...jsonObject(model), 'provider': provider['id']},
  ];
  Json? get modelInfo => models.where((m) => m['provider'] == providerId && m['id'] == modelId).firstOrNull;
  Json? get _projectModel {
    final saved = _projectModels[project?.checkoutKey];
    return models.where((m) => m['provider'] == saved?['provider'] && m['id'] == saved?['model']).firstOrNull;
  }
  bool get authenticated => {
    'signed_in',
    'refresh_required',
  }.contains(providerInfo?['status']);

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

  void openSessionPanel(DesktopTask target, String tab, {bool toggle = false}) {
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
    if (!tab.startsWith('new:')) { state.closed..remove(tab)..insert(0, tab); }
    if (state.active == tab) state.active = state.tabs.isEmpty ? null : state.tabs[index.clamp(0, state.tabs.length - 1)];
    if (state.tabs.isEmpty) state.opened = false;
    _savePanels(target);
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
        ? projects.expand((project) => project.tasks).toList()
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

  List<(Project, DesktopTask)> get openTasks => [
    for (final id in openTaskIds)
      for (final project in projects)
        if (!project.removing)
          for (final task in project.tasks)
            if (task.id == id && !task.archived) (project, task),
  ];

  void _rememberTab(DesktopTask target) {
    if (target.archived || openTaskIds.contains(target.id)) { return; }
    openTaskIds.add(target.id);
    _saveNavigation('open_tabs', jsonEncode(openTaskIds));
  }

  void _saveNavigation(String key, String value) {
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
    if (ids.length != openTaskIds.length || ids.toSet().length != ids.length ||
        !ids.every(openTaskIds.contains)) return;
    openTaskIds..clear()..addAll(ids);
    notifyListeners();
    await _setting('open_tabs', jsonEncode(openTaskIds));
  }

  Future<void> closeTab(DesktopTask target) async {
    final index = openTaskIds.indexOf(target.id);
    if (index == -1) return;
    openTaskIds.removeAt(index);
    final tabs = openTasks;
    if (task == target) {
      if (tabs.isNotEmpty) {
        final next = tabs[index.clamp(0, tabs.length - 1)];
        await select(next.$1, next.$2);
      } else if (project case final owner?) {
        await select(owner);
      }
    }
    notifyListeners();
    await _setting('open_tabs', jsonEncode(openTaskIds));
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
    final next = ids.where((value) => value != id).toList();
    if (pinned) next.add(id);
    await _setting(setting, jsonEncode(next));
    ids..clear()..addAll(next);
    notifyListeners();
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

  void chooseReasoning(String value) {
    final provider = providerId, model = modelId;
    if (task case final target?) {
      if (!target.reasoningUpdates) return;
      target.nextReasoning = value;
    }
    _rememberModel(provider, model, value);
    notifyListeners();
  }

  void _rememberModel(String? provider, String? model, String? reasoning) {
    final owner = project;
    if (owner == null) {
      _provider = provider;
      _model = model;
      _reasoning = reasoning;
      return;
    }
    if (owner.removing) return;
    _projectModels[owner.checkoutKey] = {'provider': provider, 'model': model, 'reasoning': reasoning};
    _saveProjectModels();
  }

  void _saveProjectModels() {
    unawaited(_setting('project_models', jsonEncode(_projectModels)).catchError((Object failure) {
      if (failure is! CancelledException) showError(failure);
    }));
  }

  Future<Object?> _request(String method, [Json params = const {}]) {
    _lifetime.throwIfCancelled();
    method = const {
      'task.start': 'session.create', 'task.send': 'session.prompt',
      'task.cancel': 'session.interrupt', 'task.compact': 'session.compact',
      'task.archive': 'session.archive', 'task.unarchive': 'session.unarchive',
      'task.fork': 'session.fork',
    }[method] ?? method;
    if (method.startsWith('session.') && params['task_id'] != null) {
      params = {...params, 'sessionID': params['task_id']}..remove('task_id');
    }
    if ({'session.message.list', 'session.context', 'session.event.list'}.contains(method)) {
      return client.sessionRead(method, params, cancellation: _lifetime);
    }
    return client.request(method, params).asCancellable(_lifetime);
  }

  Future<void> load() async {
    final saved = jsonObject(
      await callIsolate(database.port, 'load', {}, cancellation: _lifetime),
    );
    final settings = jsonObject(saved['settings'] ?? {});
    _projectModels.clear();
    try {
      final decoded = jsonDecode(settings['project_models'] as String? ?? '{}');
      if (decoded is Map) {
        for (final entry in jsonObject(decoded).entries) {
          if (entry.value is Map) _projectModels[entry.key] = jsonObject(entry.value);
        }
      }
    } on FormatException {
      // Ignore malformed UI preferences and use the catalog defaults.
    }
    deliveryMode = settings['delivery_mode'] == 'queue' ? 'queue' : 'steer';
    dictationMode = settings['dictation_mode'] == 'on_stop' ? 'on_stop' : 'live';
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
        ),
      );
    }
    project = projects.firstOrNull;
    final visible = projects.expand((project) => project.tasks).where((task) => !task.archived).map((task) => task.id).toSet();
    openTaskIds.addAll(savedIds('open_tabs').where(visible.contains));
    final active = settings['active_tab'];
    for (final (owner, target) in openTasks) {
      if (target.id != active) continue;
      project = owner;
      task = target;
      break;
    }
    await refreshProviders();
    await _checkProjectAvailability();
    await refreshProjects();
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
    task = null;
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
      if (openTaskIds.any(removedIds.contains)) {
        openTaskIds.removeWhere(removedIds.contains);
        _saveNavigation('open_tabs', jsonEncode(openTaskIds));
      }
      if (_projectModels.remove(target.checkoutKey) != null) _saveProjectModels();
      if (project == target) {
        project = projects.where((project) => project.available && !project.removing).firstOrNull ?? projects.firstOrNull;
        task = null;
        error = null;
      }
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
    project = nextProject;
    task = nextTask;
    error = null;
    if (nextTask != null) {
      _rememberTab(nextTask);
      _markViewed(nextTask);
      conversation(nextTask);
    }
    _saveNavigation('active_tab', nextTask?.id ?? '');
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

  Future<void> loadHistory(DesktopTask target) async {
    if (target.loading) return;
    target.loading = true;
    target.loadError = null;
    notifyListeners();
    try {
      target.liveEvents.clear();
      final page = jsonObject(await _request('session.message.list', {'sessionID': target.id, 'limit': 100}));
      target.running = page['running'] == true;
      target.pending
        ..clear()
        ..addEntries((page['pending'] as List? ?? []).map((raw) {
          final item = jsonObject(raw);
          return MapEntry('msg_${item['id']}', item);
        }));
      final config = jsonObject(page['configuration'] ?? {});
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

  Future<void> loadEarlier(DesktopTask target) async {
    final before = target.historyBefore;
    if (before == null || target.loadingEarlier || target.loading) return;
    target.loadingEarlier = true;
    target.loadError = null;
    notifyListeners();
    try {
      final page = jsonObject(await _request('session.message.list', {
        'sessionID': target.id, 'cursor': before, 'limit': 100,
      }));
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

  Future<bool> send(String prompt, {List<ComposerAttachment> attachments = const []}) async {
    final owner = project;
    final existing = task;
    final wasRunning = existing?.running == true;
    if (owner == null ||
        !owner.available ||
        owner.removing ||
        (prompt.trim().isEmpty && attachments.isEmpty) ||
        submitting ||
        !connected ||
        existing?.archived == true ||
        existing?.archiving == true ||
        !authenticated) {
      return false;
    }
    submitting = true;
    error = null;
    _earlyEvents.clear();
    final provider = providerId, model = modelId, effort = reasoning;
    final cancellation = _submission = CancellationToken();
    final uploaded = <String>[];
    var admitted = false;
    notifyListeners();
    try {
      final input = <Json>[];
      final images = attachments.where((attachment) => attachment.image).toList();
      final remoteImages = <Json>[];
      if (images.isNotEmpty && !client.sharedFilesystem) {
        attachmentStatus = 'Preparing images…';
        notifyListeners();
        remoteImages.addAll(await prepareRemoteImages(images.map((image) => image.toJson()).toList(),
          cancellation: cancellation.merge(_lifetime)));
        attachmentStatus = null;
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
          attachmentStatus = 'Uploading ${attachment.name}…';
          notifyListeners();
          final part = await client.uploadAttachment(attachment.path,
            name: attachment.name, type: attachment.image ? 'image' : 'file',
            cancellation: cancellation.merge(_lifetime),
            onProgress: (sent, total) {
              attachmentStatus = 'Uploading ${attachment.name} · ${total == 0 ? 100 : (sent * 100 ~/ total)}%';
              if (!_lifetime.isCancelled) notifyListeners();
            });
          uploaded.add(part['upload_id'] as String);
          input.add(part);
        } else {
          input.add(attachment.toJson());
        }
      }
      cancellation.throwIfCancelled();
      _lifetime.throwIfCancelled();
      attachmentStatus = null;
      notifyListeners();
      if (existing == null) {
        final reply = jsonObject(
          await _request('task.start', {
            'cwd': owner.path,
            'prompt': prompt,
            if (input.isNotEmpty) 'attachments': input,
            'provider': provider,
            'model': model,
            'reasoning': effort,
          }),
        );
        final title = prompt.trim().isEmpty ? attachments.first.name : prompt.trim().split('\n').first;
        final created = DesktopTask(
          requiredString(reply, 'sessionID'),
          title.length > 72 ? '${title.substring(0, 72)}…' : title,
        )..running = true
          ..lastActivity = DateTime.now().millisecondsSinceEpoch;
        created.loaded = true;
        created.provider = provider;
        created.model = model;
        created.reasoning = effort;
        created.reasoningUpdates = modelInfo?['reasoning_updates'] == true;
        owner.tasks.insert(0, created);
        _rememberTab(created);
        terminals.adoptDraft(owner.checkoutKey, created.id);
        if (project == owner && task == null) {
          task = created;
          _saveNavigation('active_tab', created.id);
        }
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
      error = failure.toString();
      return false;
    } finally {
      if (!admitted) for (final id in uploaded) { await client.discardAttachment(id); }
      cancellation.cancel();
      if (identical(_submission, cancellation)) _submission = null;
      attachmentStatus = null;
      _earlyEvents.clear();
      submitting = false;
      if (!_lifetime.isCancelled) notifyListeners();
    }
  }

  Future<void> stop() async {
    final target = task;
    if (target == null || !target.running) return;
    await _request('task.cancel', {'task_id': target.id});
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
      if (archived && openTaskIds.remove(target.id)) _saveNavigation('open_tabs', jsonEncode(openTaskIds));
      if (archived && task == target) task = null;
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

  void showError(Object failure) {
    if (_lifetime.isCancelled) return;
    error = failure.toString();
    notifyListeners();
  }

  void _onEvent(Json event) {
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
    final target = projects
        .expand((p) => p.tasks)
        .where((t) => t.id == (event['data']?['sessionID'] ?? event['task_id']))
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
      if (target.archived && openTaskIds.remove(target.id)) _saveNavigation('open_tabs', jsonEncode(openTaskIds));
      if (target.archived && task == target) task = null;
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
        target.running = true;
        target.streamingText = '';
        target.retryStatus = null;
      case 'session.text.delta':
        final message = target.messages[data['assistantMessageID']];
        if (message?['time']?['streamed'] != null) break;
        final parts = message?['content'] as List? ?? [];
        final ordinal = data['ordinal'] as int;
        target.streamingText = ordinal < parts.length ? parts[ordinal]['text'] as String? ?? '' : '';
        target.retryStatus = null;
      case 'session.text.ended':
      case 'session.step.streamed':
        target.streamingText = '';
        target.retryStatus = null;
      case 'session.status':
        target.running = data['status']['type'] != 'idle';
        target.retryStatus = data['status']['type'] == 'retry' ? data['status']['message'] as String? : null;
        if (target.retryStatus != null) target.streamingText = '';
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
        target.streamingText = '';
        target.retryStatus = null;
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
    await terminals.close();
    terminals.dispose();
    _submission?.cancel();
    await _dictation?.cancel();
    _dictation?.dispose();
    _dictation = null;
    _lifetime.cancel();
    _disconnect.dispose();
    await _events.cancel();
    await client.close();
    await database.close();
    for (final draft in attachmentDrafts.values) {
      for (final attachment in draft) { await attachment.discard(); }
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
  DateTime? at(Object? value) => value is int ? DateTime.fromMillisecondsSinceEpoch(value) : null;
  final tools = <String, ToolActivity>{};
  DateTime? started;
  String? activeAssistant;
  var turnFirstRow = 0;
  var liveTextPart = false;
  for (final message in messages) {
    final id = message['id'] as String, created = at(message['time']['created']);
    switch (message['type']) {
      case 'user':
        started ??= created;
        result.add(ChatEntry(id, 'You', message['text'] as String? ?? '',
          attachments: (message['files'] as List? ?? []).map(jsonObject).toList(), timestamp: created));
      case 'assistant':
        started ??= created;
        activeAssistant = id;
        var ordinal = 0;
        for (final part in (message['content'] as List? ?? []).map(jsonObject)) {
          final partID = '$id:${ordinal++}';
          if (part['type'] == 'tool') {
            final status = jsonObject(part['state']);
            final tool = ToolActivity(part['id'] as String, part['name'] as String,
              status['input'], formatInput: true, startedAt: at(part['time']?['created']));
            tool.status = switch (status['status']) {'completed' => 'done', 'error' => 'failed', _ => task.running ? 'running' : 'interrupted'};
            tool.endedAt = at(part['time']?['completed']);
            if (status['content'] is List) {
              final content = status['content'] as List;
              tool.output = content.length == 1 && content.first['type'] == 'text' ? content.first['text'] : {'content': content};
            } else if (status['error'] != null) { tool.output = status['error']; }
            tools[tool.id] = tool;
            final parent = tools[part['native']?['parentCallID']];
            if (parent != null) { parent.children.add(tool); }
            else { result.add(ChatEntry(partID, 'Tool', tool.name, tool: tool, timestamp: created)); }
            final images = (status['content'] as List? ?? []).where((part) => part['type'] == 'image').map(jsonObject).toList();
            if (images.isNotEmpty) result.add(ChatEntry('$partID:images', 'Image', '', attachments: images, timestamp: created));
          } else if (part['type'] == 'text' || part['type'] == 'reasoning') {
            if ((part['text'] as String? ?? '').isEmpty) continue;
            final streaming = task.running && part['type'] == 'text' && message['time']?['streamed'] == null;
            liveTextPart |= streaming;
            result.add(ChatEntry(partID, part['type'] == 'text' ? 'Happen' : 'Reasoning', part['text'] as String,
              timestamp: created, streaming: streaming));
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
        final interrupted = message['outcome'] == 'interrupted';
        final index = result.lastIndexWhere((entry) => entry.role == 'Happen');
        if (index >= turnFirstRow) {
          final entry = result[index];
          final model = messages.where((m) => m['type'] == 'assistant' && m['id'] == activeAssistant).firstOrNull?['model'];
          result[index] = ChatEntry(entry.id, entry.role, entry.text, timestamp: entry.timestamp,
            response: (provider: model?['providerID'] as String?, model: model?['id'] as String?,
              reasoning: model?['variant'] as String?, duration: created != null && started != null ? created.difference(started) : null,
              interrupted: interrupted));
        }
        result.add(ChatEntry(id, message['outcome'] == 'failed' ? 'Error' : 'Status',
          message['outcome'] == 'failed' ? (message['error']?['message'] as String? ?? 'Task failed') : interrupted ? 'Stopped' : 'Completed',
          timestamp: created, startedAt: started));
        started = null;
        turnFirstRow = result.length;
        activeAssistant = null;
    }
  }
  if (task.streamingText.isNotEmpty && !liveTextPart && !result.any((entry) => entry.compaction?.status == 'running')) {
    result.add(ChatEntry('${activeAssistant ?? task.id}:streaming', 'Happen', task.streamingText, streaming: true));
  }
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

String conversationDataText(Object? value) => _pretty(value);

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
