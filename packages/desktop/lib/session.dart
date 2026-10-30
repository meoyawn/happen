import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

import 'project_identity.dart';

class Project {
  Project(this.checkoutKey, this.id, this.path, [List<DesktopTask>? tasks])
    : tasks = tasks ?? [];
  final String checkoutKey, path;
  String id;
  final List<DesktopTask> tasks;
  String get name => path.split(Platform.pathSeparator).last;
}

class DesktopTask {
  DesktopTask(this.id, this.title);
  final String id, title;
  final events = <int, Json>{};
  bool running = false, loaded = false, loading = false;
  String streamingText = '';
  String? loadError;
  String? provider, model, reasoning, nextReasoning;
  bool reasoningUpdates = false;
}

/// UI state only. Task execution and durable history stay behind the WebSocket.
class DesktopSession extends ChangeNotifier {
  DesktopSession(this.client, this.database) {
    _events = client.events.stream.listen(
      _onEvent,
      onDone: () {
        if (_lifetime.isCancelled) return;
        connected = false;
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
  final _lifetime = CancellationToken();
  late final StreamSubscription<Json> _events;
  late final CancellationHook _disconnect;
  final _earlyEvents = <Json>[];
  List<Json> providers = [];
  String? _provider, _model, _reasoning;
  String deliveryMode = 'steer';
  Project? project;
  DesktopTask? task;
  String? error;
  bool connected = true, submitting = false;

  String get draftKey => task?.id ?? project?.checkoutKey ?? '';
  String? get providerId => task?.provider ?? _provider;
  String? get defaultProviderId => _provider;
  String? get modelId => task?.model ?? _model;
  String? get reasoning => task?.nextReasoning ?? task?.reasoning ?? _reasoning;
  Json? get providerInfo =>
      providers.where((p) => p['id'] == providerId).firstOrNull;
  List<Json> get models =>
      (providerInfo?['models'] as List? ?? []).map(jsonObject).toList();
  Json? get modelInfo => models.where((m) => m['id'] == modelId).firstOrNull;
  bool get authenticated => {
    'signed_in',
    'refresh_required',
    'api_key',
  }.contains(providerInfo?['status']);

  Future<void> refreshProviders() async {
    final result = jsonObject(await _request('providers.list'));
    providers = (result['providers'] as List).map(jsonObject).toList();
    if (_model == null) _selectProvider(_provider ?? result['default_provider'] as String);
    notifyListeners();
  }

  void _selectProvider(String id) {
    _provider = id;
    final provider = providers.firstWhere((p) => p['id'] == id);
    _model = provider['default_model'] as String;
    _reasoning = (provider['models'] as List).map(jsonObject)
        .firstWhere((m) => m['id'] == _model)['default_reasoning'] as String;
    notifyListeners();
  }

  Future<void> chooseProvider(String id) async {
    await _setting('provider', id);
    _selectProvider(id);
  }

  Future<void> chooseDeliveryMode(String mode) async {
    if (!{'steer', 'queue'}.contains(mode)) throw ArgumentError('Invalid delivery mode');
    await _setting('delivery_mode', mode);
    deliveryMode = mode;
    notifyListeners();
  }

  Future<void> _setting(String key, String value) async {
    await callIsolate(database.port, 'settings.set', {'key': key, 'value': value},
        cancellation: _lifetime);
  }

  void chooseModel(String id) {
    if (task != null) return;
    _model = id;
    _reasoning = modelInfo?['default_reasoning'] as String?;
    notifyListeners();
  }

  void chooseReasoning(String value) {
    if (task case final target?) {
      if (!target.reasoningUpdates || target.running) return;
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
    _provider = settings['provider'] as String?;
    deliveryMode = settings['delivery_mode'] as String? ?? 'steer';
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
                ),
          ],
        ),
      );
    }
    project = projects.firstOrNull;
    await refreshProviders();
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
    for (final owner in projects) {
      await _refreshIdentity(owner);
    }
    if (!_lifetime.isCancelled) notifyListeners();
  }

  Future<void> select(Project nextProject, [DesktopTask? nextTask]) async {
    project = nextProject;
    task = nextTask;
    error = null;
    notifyListeners();
    await _refreshIdentity(nextProject);
    if (nextTask != null && !nextTask.loaded && !nextTask.loading) {
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
      await _request('task.subscribe', {'task_id': target.id});
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
        if (page.length < 100) break;
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

  Future<bool> send(String prompt) async {
    final owner = project;
    final existing = task;
    if (owner == null ||
        prompt.trim().isEmpty ||
        submitting ||
        !connected ||
        !authenticated ||
        existing?.running == true) {
      return false;
    }
    submitting = true;
    error = null;
    _earlyEvents.clear();
    final provider = providerId, model = modelId, effort = reasoning;
    notifyListeners();
    try {
      if (existing == null) {
        final reply = jsonObject(
          await _request('task.start', {
            'cwd': owner.path,
            'prompt': prompt,
            'provider': provider,
            'model': model,
            'reasoning': effort,
          }),
        );
        final title = prompt.trim().split('\n').first;
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
          'reasoning': effort,
        });
      }
      return true;
    } on CancelledException {
      rethrow;
    } catch (failure) {
      existing?.running = false;
      error = failure.toString();
      return false;
    } finally {
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

  void showError(Object failure) {
    if (_lifetime.isCancelled) return;
    error = failure.toString();
    notifyListeners();
  }

  void _onEvent(Json event) {
    final target = projects
        .expand((p) => p.tasks)
        .where((t) => t.id == event['task_id'])
        .firstOrNull;
    if (target == null) {
      if (submitting && _earlyEvents.length < 256) _earlyEvents.add(event);
      return;
    }
    _applyEvent(target, event);
    notifyListeners();
  }

  void _applyEvent(DesktopTask target, Json event) {
    _settings(target, event);
    final sequence = event['seq'] as int?;
    if (sequence != null) target.events[sequence] = event;
    switch (event['type']) {
      case 'turn.started':
        target.running = true;
      case 'text.delta':
        target.streamingText += event['delta'] as String;
      case 'model.completed':
        target.streamingText = '';
      case 'turn.completed':
      case 'turn.cancelled':
      case 'turn.failed':
        target.running = false;
        target.streamingText = '';
        if (sequence == null && event['type'] == 'turn.failed') {
          error = event['data']?['error'] as String? ?? 'Task failed to start';
        }
    }
  }

  void _settings(DesktopTask target, Json event) {
    final data = jsonObject(event['data'] ?? {});
    if (event['type'] == 'task.created' ||
        event['type'] == 'task.configuration_migrated') {
      target.provider = data['provider'] as String? ?? 'gpt';
      target.model = data['model'] as String?;
      target.reasoning =
          data['provider_settings']?['reasoning'] as String? ??
          data['reasoning'] as String?;
      target.reasoningUpdates = data['reasoning_updates'] == true;
    } else if (event['type'] == 'configuration.updated') {
      target.reasoning =
          data['effort'] as String? ??
          data['item']?['settings']?['reasoning'] as String?;
      target.nextReasoning = null;
    }
  }

  Future<void> close() async {
    _lifetime.cancel();
    _disconnect.dispose();
    await _events.cancel();
    await client.close();
    await database.close();
    dispose();
  }
}

class ToolActivity {
  ToolActivity(this.id, this.name, this.input);
  final String id, name, input;
  final children = <ToolActivity>[];
  String status = 'running';
  String? output;
}

typedef ChatEntry = ({String role, String text, ToolActivity? tool});

List<ChatEntry> conversation(DesktopTask task) {
  final result = <ChatEntry>[];
  final events = task.events.values.toList()
    ..sort((a, b) => (a['seq'] as int).compareTo(b['seq'] as int));
  final tools = <String, ToolActivity>{};
  ToolActivity? activeCell;
  void finishTools(String status) {
    for (final tool in tools.values) {
      if (tool.status == 'running') tool.status = status;
    }
  }

  for (final event in events) {
    final data = jsonObject(event['data']);
    switch (event['type']) {
      case 'input.committed':
        final item = jsonObject(data['item']);
        if (item['role'] == 'user') {
          result.add((role: 'You', text: _text(item), tool: null));
        }
      case 'model.completed':
        for (final raw in data['output'] as List? ?? []) {
          final text = _text(jsonObject(raw));
          if (text.isNotEmpty) {
            result.add((role: 'Happen', text: text, tool: null));
          }
        }
      case 'tool.started':
        final name = data['name'] as String;
        final namespace = data['namespace'] as String?;
        final tool = ToolActivity(
          data['call_id'] as String,
          namespace == null ? name : '$namespace.$name',
          data['input'] as String,
        );
        tools[tool.id] = tool;
        activeCell =
            name == 'exec' && (namespace == null || namespace == 'functions')
            ? tool
            : null;
        result.add((role: 'Tool', text: tool.name, tool: tool));
      case 'host_tool.started':
        final tool = ToolActivity(
          data['id'] as String,
          data['name'] as String,
          _pretty(data['arguments']),
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
          result.add((role: 'Tool', text: tool.name, tool: tool));
        }
      case 'host_tool.completed':
        final tool = tools[data['id']];
        if (tool == null) continue;
        tool.status = data['cancelled'] == true
            ? 'stopped'
            : data.containsKey('error')
            ? 'failed'
            : 'done';
        tool.output = _pretty(data['error'] ?? data['output']);
      case 'tool.completed':
        final item = jsonObject(data['item']);
        for (final raw in item['content'] as List? ?? []) {
          final part = jsonObject(raw);
          final tool = tools[part['call_id']];
          if (tool == null) continue;
          tool.status = part['is_error'] == true ? 'failed' : 'done';
          tool.output = _pretty(part['output']);
          if (tool == activeCell) activeCell = null;
        }
      case 'turn.failed':
        finishTools('failed');
        result.add((role: 'Error', text: '${data['error']}', tool: null));
      case 'turn.cancelled':
        finishTools('stopped');
        result.add((role: 'Status', text: 'Stopped', tool: null));
      case 'turn.completed':
        finishTools('interrupted');
      case 'context.compacted':
        result.add((role: 'Status', text: 'Context compacted', tool: null));
    }
  }
  if (task.streamingText.isNotEmpty) {
    result.add((role: 'Happen', text: task.streamingText, tool: null));
  }
  if (!task.running) finishTools('interrupted');
  return result;
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
