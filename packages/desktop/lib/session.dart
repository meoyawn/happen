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

class Project {
  Project(this.checkoutKey, this.id, this.path, [List<DesktopTask>? tasks])
    : tasks = tasks ?? [];
  final String checkoutKey, path;
  String id;
  final List<DesktopTask> tasks;
  bool available = true, removing = false;
  String get name => path.split(Platform.pathSeparator).last;
}

class DesktopTask {
  DesktopTask(this.id, this.title);
  final String id, title;
  final events = <int, Json>{};
  final pending = <String, Json>{};
  bool running = false, loaded = false, loading = false, archived = false, archiving = false;
  String streamingText = '';
  String? retryStatus;
  Json? transientTerminal;
  String? loadError;
  String? provider, model, reasoning, nextReasoning;
  bool reasoningUpdates = false;
  List<ChatEntry>? _conversation;
  List<Json>? _conversationEvents, _conversationPending;
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
  String? _provider, _model, _reasoning;
  String deliveryMode = 'steer';
  String dictationMode = 'live';
  double sidebarWidth = 248;
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
    final selected = task?.provider ?? _provider;
    return selected == 'gpt' ? 'openai' : selected;
  }
  String? get modelId => task?.model ?? _model;
  String? get reasoning => task?.nextReasoning ?? task?.reasoning ?? _reasoning;
  Json? get providerInfo =>
      providers.where((p) => p['id'] == providerId).firstOrNull;
  List<Json> get models => [
    for (final provider in providers)
      for (final model in provider['models'] as List? ?? [])
        {...jsonObject(model), 'provider': provider['id']},
  ];
  Json? get modelInfo => models.where((m) => m['provider'] == providerId && m['id'] == modelId).firstOrNull;
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
    sidebarWidth = width;
    notifyListeners();
    await _setting('sidebar_width', width.toString());
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
    _provider = model['provider'] as String;
    _model = id;
    _reasoning = model['default_reasoning'] as String?;
    notifyListeners();
  }

  void chooseReasoning(String value) {
    if (task case final target?) {
      if (!target.reasoningUpdates) return;
      target.nextReasoning = value;
    } else {
      _reasoning = value;
    }
    notifyListeners();
  }

  Future<Object?> _request(String method, [Json params = const {}]) {
    _lifetime.throwIfCancelled();
    return client.request(method, params).asCancellable(_lifetime);
  }

  Future<void> load() async {
    final saved = jsonObject(
      await callIsolate(database.port, 'load', {}, cancellation: _lifetime),
    );
    final settings = jsonObject(saved['settings'] ?? {});
    deliveryMode = settings['delivery_mode'] == 'queue' ? 'queue' : 'steer';
    dictationMode = settings['dictation_mode'] == 'on_stop' ? 'on_stop' : 'live';
    final savedSidebarWidth = double.tryParse(settings['sidebar_width'] as String? ?? '');
    sidebarWidth = savedSidebarWidth != null && savedSidebarWidth.isFinite && savedSidebarWidth > 0 ? savedSidebarWidth : 248;
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
                )..archived = t['archived'] == 1,
          ],
        ),
      );
    }
    project = projects.firstOrNull;
    await refreshProviders();
    await _checkProjectAvailability();
    await refreshProjects();
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
    final id = await projectIdentity(target.path, _lifetime);
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
    notifyListeners();
    try {
      if (project == target) await _dictation?.cancel();
      for (final task in target.tasks.where((task) => task.running).toList()) {
        await _request('task.cancel', {'task_id': task.id});
      }
      await callIsolate(database.port, 'project.remove', {
        'checkout_key': target.checkoutKey,
      }, cancellation: _lifetime);
      projects.remove(target);
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
    if (nextTask != null) conversation(nextTask);
    notifyListeners();
    await _refreshIdentity(nextProject);
    // Live events can leave a cached task without its initial configuration.
    // Recover that prefix before treating the transcript as fully loaded.
    if (nextTask != null && !nextTask.loading &&
        (!nextTask.loaded || nextTask.events.isNotEmpty && !nextTask.events.containsKey(1))) {
      await loadHistory(nextTask);
    }
  }

  Future<void> loadHistory(DesktopTask target) async {
    target.loading = true;
    target.loadError = null;
    notifyListeners();
    try {
      // Subscribe before paging, then merge by durable sequence number. A live
      // event may also be in a page; it must appear only once in the transcript.
      final status = jsonObject(
        await _request('task.subscribe', {'task_id': target.id}),
      );
      target.running = status['running'] == true;
      target.pending
        ..clear()
        ..addEntries(
          (status['pending'] as List? ?? []).map((raw) {
            final message = jsonObject(raw);
            return MapEntry(message['id'] as String, message);
          }),
        );
      var after = 0;
      while (true) {
        final page = (await _request('history.page', {
          'task_id': target.id,
          'after': after,
          'limit': 100,
        }) as List).map(jsonObject).toList();
        for (final event in page) {
          target.events[event['seq'] as int] = event;
        }
        if (page.isEmpty) break;
        after = page.last['seq'] as int;
      }
      target.loaded = true;
      final ordered = target.events.values.toList()
        ..sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));
      for (final event in ordered) {
        _settings(target, event);
      }
    } on CancelledException {
      rethrow;
    } catch (failure) {
      target.loadError = failure.toString();
    } finally {
      target.loading = false;
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
          requiredString(reply, 'task_id'),
          title.length > 72 ? '${title.substring(0, 72)}…' : title,
        )..running = true;
        created.loaded = true;
        created.provider = provider;
        created.model = model;
        created.reasoning = effort;
        created.reasoningUpdates = modelInfo?['reasoning_updates'] == true;
        owner.tasks.insert(0, created);
        if (project == owner && task == null) task = created;
        for (final event in _earlyEvents) {
          if (event['task_id'] == created.id) _applyEvent(created, event);
        }
        try {
          await callIsolate(database.port, 'task.add', {
            'id': created.id,
            'checkout_key': owner.checkoutKey,
            'title': created.title,
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
    notifyListeners();
    try {
      await _request(archived ? 'task.archive' : 'task.unarchive', {'task_id': target.id});
      target.archived = archived;
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
        .where((t) => t.id == event['task_id'])
        .firstOrNull;
    if (target == null) {
      if (submitting && _earlyEvents.length < 256) _earlyEvents.add(event);
      return;
    }
    _applyEvent(target, event);
    if (event['type'] == 'task.archived' || event['type'] == 'task.unarchived') {
      if (target.archived && task == target) task = null;
      unawaited(_saveArchived(target).catchError((Object failure) {
        if (failure is! CancelledException) showError(failure);
      }));
    }
    notifyListeners();
  }

  void _applyEvent(DesktopTask target, Json event) {
    _settings(target, event);
    final sequence = event['seq'] as int?;
    if (sequence != null) target.events[sequence] = event;
    if ({'turn.completed', 'turn.failed', 'turn.cancelled'}.contains(event['type'])) {
      target.transientTerminal = sequence == null ? event : null;
    }
    switch (event['type']) {
      case 'input.pending':
        final message = jsonObject(event['data']);
        target.pending[message['id'] as String] = message;
      case 'input.committed':
        target.pending.remove(event['data']?['message_id']);
        if (event['data']?['delivery'] == 'steer') {
          target.streamingText = '';
          target.retryStatus = null;
        }
      case 'input.discarded':
        for (final id in event['data']['ids'] as List) {
          target.pending.remove(id);
        }
      case 'turn.started':
        target.running = true;
        target.transientTerminal = null;
        target.retryStatus = null;
      case 'model.retrying':
        target.streamingText = '';
        target.retryStatus = 'Reconnecting… ${event['attempt']}/${event['max_retries']}';
      case 'text.delta':
        target.streamingText += event['delta'] as String;
        target.retryStatus = null;
      case 'compaction.started':
      case 'context.compacted':
      case 'model.completed':
        target.streamingText = '';
        target.retryStatus = null;
      case 'turn.completed':
      case 'turn.cancelled':
      case 'turn.failed':
        target.running = false;
        target.streamingText = '';
        target.retryStatus = null;
        if (sequence == null && event['type'] == 'turn.failed') {
          error = event['data']?['error'] as String? ?? 'Task failed to start';
        }
    }
  }

  void _settings(DesktopTask target, Json event) {
    final data = jsonObject(event['data'] ?? {});
    if (event['type'] == 'task.archived') target.archived = true;
    if ({'task.unarchived', 'task.imported', 'task.forked'}.contains(event['type'])) target.archived = false;
    if (event['type'] == 'task.created' ||
        event['type'] == 'task.configuration_migrated') {
      target.provider = data['provider'] as String? ?? 'openai';
      target.model = data['model'] as String?;
      target.reasoning =
          data['provider_settings']?['reasoning'] as String? ??
          data['reasoning'] as String?;
      target.reasoningUpdates = data['reasoning_updates'] == true;
    } else if (event['type'] == 'configuration.updated') {
      target.reasoning =
          data['effort'] as String? ??
          data['item']?['settings']?['reasoning'] as String?;
      if (target.nextReasoning == target.reasoning) target.nextReasoning = null;
    }
  }

  Future<void> close() async {
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
  ToolActivity(this.id, this.name, Object? input, {this.startedAt, bool formatInput = false})
    : _rawInput = input, _input = formatInput ? null : input as String;
  final String id, name;
  final Object? _rawInput;
  String? _input, _output;
  Object? _rawOutput;
  bool _hasOutput = false;
  // Collapsed tools should not parse and re-encode their potentially large JSON.
  String get input => _input ??= _pretty(_rawInput);
  String? get output => _hasOutput ? _output ??= _pretty(_rawOutput) : null;
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
class ChatEntry {
  const ChatEntry(this.id, this.role, this.text, {
    this.tool, this.compaction, this.timestamp, this.startedAt, this.streaming = false, this.attachments = const [],
  });
  final String id, role, text;
  final ToolActivity? tool;
  final CompactionActivity? compaction;
  final DateTime? timestamp, startedAt;
  final bool streaming;
  final List<Json> attachments;
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
  final state = (task.running, task.streamingText, task.transientTerminal);
  // Durable records are immutable. Compare identities so replay/replacement of
  // an existing sequence invalidates the cache as well as newly appended events.
  if (task._conversation != null && task._conversationState == state &&
      _sameRecords(task.events.values, task._conversationEvents) &&
      _sameRecords(task.pending.values, task._conversationPending)) return task._conversation!;
  final result = <ChatEntry>[];
  final events = task.events.values.toList()
    ..sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));
  if (task.transientTerminal case final terminal?) events.add(terminal);
  final tools = <String, ToolActivity>{};
  ToolActivity? activeCell;
  CompactionActivity? activeCompaction;
  DateTime? turnStartedAt;
  String turnId = task.id;
  void finishTools(String status, [DateTime? at]) {
    for (final tool in tools.values) {
      if (tool.status == 'running') {
        tool.status = status;
        tool.endedAt = at;
      }
    }
  }
  void finishCompaction(String status, [DateTime? at]) {
    final compaction = activeCompaction;
    if (compaction == null) return;
    compaction.status = status;
    compaction.endedAt = at;
    activeCompaction = null;
  }

  for (final event in events) {
    final data = jsonObject(event['data']);
    final at = DateTime.tryParse(event['created_at'] as String? ?? '');
    final id = event['id'] as String? ?? '${task.id}:${event['seq']}';
    switch (event['type']) {
      case 'turn.started':
        finishCompaction('interrupted', at);
        turnStartedAt = at;
        turnId = id;
      case 'input.committed':
        final item = jsonObject(data['item']);
        if (item['role'] == 'user') {
          result.add(ChatEntry(id, 'You', _text(item),
            attachments: (item['content'] as List? ?? []).where((part) => part['type'] == 'image' || part['type'] == 'file').map(jsonObject).toList(),
            timestamp: DateTime.tryParse(data['sent_at'] as String? ?? '') ?? at));
        }
      case 'model.completed':
        var index = 0;
        for (final raw in data['output'] as List? ?? []) {
          final item = jsonObject(raw);
          // Group adjacent text parts, preserving reasoning/text order. Never
          // expose opaque native reasoning or tool-call serialization as prose.
          String? role;
          final text = StringBuffer();
          void flush() {
            if (text.isEmpty) return;
            result.add(ChatEntry('$id:${index++}', role!, text.toString(), timestamp: at));
            text.clear();
          }
          for (final part in (item['content'] as List? ?? []).map(jsonObject)) {
            final nextRole = switch (part['type']) {
              'text' => 'Happen',
              'reasoning' => 'Reasoning',
              _ => null,
            };
            if (nextRole == null || part['text'] is! String || (part['text'] as String).isEmpty) continue;
            if (role != nextRole) flush();
            role = nextRole;
            if (text.isNotEmpty) text.writeln();
            text.write(part['text']);
          }
          flush();
        }
      case 'tool.started':
        final name = data['name'] as String;
        final namespace = data['namespace'] as String?;
        final tool = ToolActivity(
          data['call_id'] as String,
          namespace == null ? name : '$namespace.$name',
          data['input'] as String,
          startedAt: at,
        );
        tools[tool.id] = tool;
        activeCell =
            name == 'exec' && (namespace == null || namespace == 'functions')
            ? tool
            : null;
        result.add(ChatEntry(id, 'Tool', tool.name, tool: tool, timestamp: at));
      case 'host_tool.started':
        final tool = ToolActivity(
          data['id'] as String,
          data['name'] as String,
          data['arguments'],
          formatInput: true,
          startedAt: at,
        );
        tools[tool.id] = tool;
        // Old history predates parent_call_id. Cells execute sequentially, so
        // its active code-mode call is unambiguous; new events carry the ID.
        final parent = data['parent_call_id'] == null
            ? activeCell
            : tools[data['parent_call_id']];
        if (parent != null) {
          parent.children.add(tool);
        } else {
          result.add(ChatEntry(id, 'Tool', tool.name, tool: tool, timestamp: at));
        }
      case 'host_tool.completed':
        final tool = tools[data['id']];
        if (tool == null) continue;
        tool.status = data['cancelled'] == true
            ? 'stopped'
            : data.containsKey('error')
            ? 'failed'
            : 'done';
        tool.output = data['error'] ?? data['output'];
        tool.endedAt = at;
      case 'tool.completed':
        final item = jsonObject(data['item']);
        for (final raw in item['content'] as List? ?? []) {
          final part = jsonObject(raw);
          final tool = tools[part['call_id']];
          if (tool == null) continue;
          tool.status = part['is_error'] == true ? 'failed' : 'done';
          tool.output = part['output'];
          tool.endedAt = at;
          if (tool == activeCell) activeCell = null;
        }
      case 'turn.failed':
        finishTools('failed', at);
        finishCompaction('failed', at);
        result.add(ChatEntry(id, 'Error', '${data['error']}', timestamp: at, startedAt: turnStartedAt));
        turnStartedAt = null;
      case 'turn.cancelled':
        finishTools('stopped', at);
        finishCompaction('stopped', at);
        result.add(ChatEntry(id, 'Status', 'Stopped', timestamp: at, startedAt: turnStartedAt));
        turnStartedAt = null;
      case 'turn.completed':
        finishTools('interrupted', at);
        finishCompaction('interrupted', at);
        result.add(ChatEntry(id, 'Status', 'Completed', timestamp: at, startedAt: turnStartedAt));
        turnStartedAt = null;
      case 'compaction.started':
        finishCompaction('interrupted', at);
        final compaction = activeCompaction = CompactionActivity(startedAt: at);
        result.add(ChatEntry(id, 'Compaction', '', compaction: compaction));
      case 'context.compacted':
        final compaction = activeCompaction ?? CompactionActivity();
        if (activeCompaction == null) {
          result.add(ChatEntry(id, 'Compaction', '', compaction: compaction));
        }
        compaction
          ..status = 'done'
          ..endedAt = at
          ..summary = data['summary'] as String? ?? '';
        activeCompaction = null;
    }
  }
  if (task.streamingText.isNotEmpty && activeCompaction == null) {
    result.add(ChatEntry('$turnId:streaming', 'Happen', task.streamingText, streaming: true));
  }
  for (final message in task.pending.values) {
    result.add(ChatEntry('pending:${message['id']}',
      message['delivery'] == 'steer' ? 'Steer pending' : 'Queued',
      message['prompt'] as String,
      attachments: (message['attachments'] as List? ?? []).map(jsonObject).toList(),
      timestamp: DateTime.tryParse(message['created_at'] as String? ?? ''),
    ));
  }
  if (!task.running) finishTools('interrupted');
  if (!task.running) finishCompaction('interrupted');
  task._conversationState = state;
  task._conversationEvents = task.events.values.toList(growable: false);
  task._conversationPending = task.pending.values.toList(growable: false);
  return task._conversation = result;
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

String _text(Json item) => (item['content'] as List? ?? [])
    .map(jsonObject)
    .where((part) => part['type'] == 'text')
    .map((part) => part['text'] as String)
    .join('\n');
