import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

import 'file_change.dart';

typedef GitFile = ({String path, String? previousPath, String status, bool conflicted, int additions, int deletions, bool binary});
typedef GitRepository = ({bool isRepo, String? root, String? branch, String? remote, String? upstream,
  String? head, String? host, int ahead, int behind, int additions, int deletions, List<GitFile> files});
typedef GitBranch = ({String ref, String name, bool remote});

GitRepository _repository(Json value) => (
  isRepo: value['isRepo'] == true, root: value['root'] as String?, branch: value['branch'] as String?,
  remote: value['remote'] as String?, upstream: value['upstream'] as String?, head: value['head'] as String?,
  host: value['host'] as String?,
  ahead: value['ahead'] as int? ?? 0, behind: value['behind'] as int? ?? 0,
  additions: value['additions'] as int? ?? 0, deletions: value['deletions'] as int? ?? 0,
  files: List.unmodifiable([for (final raw in value['files'] as List) (
    path: raw['path'] as String, previousPath: raw['previousPath'] as String?,
    status: raw['status'] as String, conflicted: raw['conflicted'] == true,
    additions: raw['additions'] as int? ?? 0, deletions: raw['deletions'] as int? ?? 0, binary: raw['binary'] == true,
  )]),
);

sealed class GitState {
  const GitState(this.repository);
  final GitRepository? repository;
}
final class GitLoading extends GitState { const GitLoading(super.repository); }
final class GitReady extends GitState { const GitReady(GitRepository super.repository); }
enum GitAction {
  commit('commit'), push('push'), commitPush('commit_push'), switchBranch('switch'), createBranch('create_branch');
  const GitAction(this.wire);
  final String wire;
}
typedef GitOperation = ({String id, GitAction action});
typedef GitCommit = ({String sha, String subject});
sealed class GitRunning extends GitState {
  const GitRunning(GitRepository super.repository, this.operation);
  final GitOperation operation;
  String get id => operation.id;
  String get label => switch (this) {
    GitStarting() => 'Starting…', GitGenerating() => 'Generating commit message…',
    GitCreatingBranch() => 'Creating branch…',
    GitCommitting() => 'Committing…', GitPushing() => 'Pushing…',
    GitSwitching() => operation.action == GitAction.createBranch ? 'Creating branch…' : 'Switching branch…',
  };
  String? get output => switch (this) {
    GitCommitting(:final progress) || GitPushing(:final progress) || GitSwitching(:final progress) => progress,
    _ => null,
  };
}
final class GitStarting extends GitRunning { const GitStarting(super.repository, super.operation); }
final class GitGenerating extends GitRunning { const GitGenerating(super.repository, super.operation); }
final class GitCreatingBranch extends GitRunning { const GitCreatingBranch(super.repository, super.operation); }
final class GitCommitting extends GitRunning {
  const GitCommitting(super.repository, super.operation, {this.progress});
  final String? progress;
}
final class GitPushing extends GitRunning {
  const GitPushing(super.repository, super.operation, {this.commit, this.progress});
  final GitCommit? commit;
  final String? progress;
}
final class GitSwitching extends GitRunning {
  const GitSwitching(super.repository, super.operation, {this.progress});
  final String? progress;
}
final class GitCancelling extends GitState {
  GitCancelling(this.operation) : super(operation.repository);
  final GitRunning operation;
}
sealed class GitOutcome { const GitOutcome(); }
final class GitSucceeded extends GitOutcome {
  const GitSucceeded(this.commit);
  final GitCommit? commit;
}
final class GitRejected extends GitOutcome {
  const GitRejected(this.message, this.commit);
  final String message;
  final GitCommit? commit;
}
final class GitStopped extends GitOutcome {
  const GitStopped(this.commit);
  final GitCommit? commit;
}
final class GitRefreshing extends GitState {
  const GitRefreshing(GitRepository super.repository, this.operation, this.outcome);
  final GitOperation operation;
  final GitOutcome outcome;
}
final class GitCompleted extends GitState {
  const GitCompleted(super.repository, this.operation, this.result);
  final GitOperation operation;
  final GitSucceeded result;
  String get message => switch (operation.action) {
    GitAction.commit => 'Changes committed', GitAction.push => 'Changes pushed',
    GitAction.switchBranch => 'Branch switched', GitAction.createBranch => 'Branch created',
    GitAction.commitPush => 'Changes committed and pushed',
  };
}
final class GitFailed extends GitState {
  const GitFailed(super.repository, this.message, {this.operation, this.commit});
  final String message;
  final GitOperation? operation;
  final GitCommit? commit;
}
final class GitCancelled extends GitState {
  const GitCancelled(super.repository, this.operation, this.commit);
  final GitOperation operation;
  final GitCommit? commit;
}

GitState _transition(GitState current, GitState next) => switch ((current, next)) {
  (GitLoading(), GitLoading() || GitReady() || GitFailed() || GitCompleted() || GitCancelled() || GitStarting()) => next,
  (GitReady() || GitCompleted() || GitFailed() || GitCancelled(), GitLoading() || GitStarting() || GitReady()) => next,
  (GitRunning(:final operation), GitRunning(operation: final nextOperation)) when operation != nextOperation =>
    throw StateError('A stale Git operation cannot transition the current operation'),
  (GitStarting(operation: (:final action, id: _)), GitGenerating() || GitCreatingBranch() || GitCommitting())
    when action == GitAction.commit || action == GitAction.commitPush => next,
  (GitStarting(operation: (action: GitAction.push, id: _)), GitPushing()) => next,
  (GitStarting(operation: (:final action, id: _)), GitSwitching())
    when action == GitAction.switchBranch || action == GitAction.createBranch => next,
  (GitGenerating(), GitCreatingBranch() || GitCommitting()) => next,
  (GitCreatingBranch(), GitCommitting()) => next,
  (GitCommitting(), GitCommitting()) => next,
  (GitCommitting(operation: (action: GitAction.commitPush, id: _)), GitPushing()) => next,
  (GitPushing(), GitPushing()) => next,
  (GitSwitching(), GitSwitching()) => next,
  (GitRunning(), GitCancelling() || GitRefreshing()) => next,
  (GitCancelling(), GitRefreshing()) => next,
  (GitRefreshing(), GitCompleted() || GitFailed() || GitCancelled()) => next,
  _ => throw StateError('Invalid Git transition: ${current.runtimeType} → ${next.runtimeType}'),
};

/// The session owns each checkout's operation, including navigation and cancellation.
class GitActionsController extends ChangeNotifier {
  GitActionsController(this.client, this.cwd) {
    _events = client.events.stream.listen((event) {
      if (event['method'] != 'git/progress' || _lifetime.isCancelled) return;
      final value = jsonObject(event['params']);
      final current = _state;
      if (current is! GitRunning || value['actionId'] != current.id || _operation?.id != current.id) return;
      final repo = current.repository!, operation = current.operation;
      final output = value['output'] as String?;
      final next = switch (value['phase']) {
        'generating' => GitGenerating(repo, operation),
        'creating_branch' => GitCreatingBranch(repo, operation),
        'committing' => GitCommitting(repo, operation, progress: output ?? (current is GitCommitting ? current.progress : null)),
        'pushing' => GitPushing(repo, operation, commit: _commit(value['commit']) ?? (current is GitPushing ? current.commit : null),
          progress: output ?? (current is GitPushing ? current.progress : null)),
        'switching' => GitSwitching(repo, operation, progress: output ?? (current is GitSwitching ? current.progress : null)),
        _ => null,
      };
      if (next != null) _set(next);
    });
  }
  final AgentClient client;
  final String cwd;
  String _commitMessage = '';
  bool _includeUnstaged = true;
  String get commitMessage => _commitMessage;
  bool get includeUnstaged => _includeUnstaged;
  void editCommitMessage(String value) { _commitMessage = value; }
  void chooseIncludeUnstaged(bool value) { _includeUnstaged = value; }
  final _lifetime = CancellationToken();
  late final StreamSubscription<Json> _events;
  CancellationToken? _read;
  ({String id, CancellationToken token})? _operation;
  GitState _state = const GitLoading(null);
  GitState get state => _state;
  bool get busy => _state is GitRunning || _state is GitCancelling || _state is GitRefreshing;
  DateTime? _refreshed;

  void _set(GitState next) {
    if (_lifetime.isCancelled) return;
    _state = _transition(_state, next);
    notifyListeners();
  }

  Future<void> refresh({bool force = false}) async {
    if (_lifetime.isCancelled || busy || _read != null) return;
    if (!force && _refreshed != null && DateTime.now().difference(_refreshed!) < const Duration(seconds: 5)) return;
    final token = CancellationToken();
    _read = token;
    final previous = _state, repository = _state.repository;
    _set(GitLoading(repository));
    try {
      final result = await client.gitRequest('git/status', {'cwd': cwd}, cancellation: token.merge(_lifetime));
      if (!identical(_read, token) || _lifetime.isCancelled) return;
      _refreshed = DateTime.now();
      final updated = _repository(result);
      _set(switch (previous) {
        GitCompleted(:final operation, :final result) => GitCompleted(updated, operation, result),
        GitFailed(:final message, :final operation, :final commit) when operation != null =>
          GitFailed(updated, message, operation: operation, commit: commit),
        GitCancelled(:final operation, :final commit) => GitCancelled(updated, operation, commit),
        _ => GitReady(updated),
      });
    } on CancelledException {
      // A new action or owner shutdown supersedes this read.
    } catch (error) {
      if (identical(_read, token)) {
        _set(previous is GitFailed && previous.operation != null ? previous : GitFailed(repository, error.toString()));
      }
    } finally {
      if (identical(_read, token)) _read = null;
      token.cancel();
    }
  }

  Future<List<GitBranch>> branches(CancellationToken cancellation) async {
    final result = await client.gitRequest('git/branches', {'cwd': cwd}, cancellation: cancellation.merge(_lifetime));
    return [for (final raw in result['branches'] as List)
      (ref: raw['ref'] as String, name: raw['name'] as String, remote: raw['remote'] == true)];
  }

  Future<({ChangedFile file, bool truncated})> diff(String path, CancellationToken cancellation) async {
    final result = await client.gitRequest('git/diff', {'cwd': cwd, 'path': path}, cancellation: cancellation.merge(_lifetime));
    return (file: (path: path, oldPath: result['previousPath'] as String?,
      kind: result['previousPath'] != null ? 'rename' : result['status'] == '??' ? 'add'
        : (result['status'] as String).contains('D') ? 'delete' : 'update',
      diff: result['diff'] as String, additions: result['additions'] as int, deletions: result['deletions'] as int),
      truncated: result['truncated'] == true);
  }

  Future<GitRepository> commitSelection(bool includeUnstaged, CancellationToken cancellation) async =>
    _repository(await client.gitRequest('git/status', {'cwd': cwd, 'includeUnstaged': includeUnstaged},
      cancellation: cancellation.merge(_lifetime)));

  Future<void> run(String action, {String message = '', List<String>? filePaths, String? provider, String? model,
    String? branch, bool includeUnstaged = true, String? newBranch}) async {
    if (busy || _lifetime.isCancelled) return;
    final repository = _state.repository;
    if (repository == null || !repository.isRepo) return;
    _read?.cancel(); _read = null;
    final token = CancellationToken(), id = newId();
    final operation = (id: id, action: GitAction.values.firstWhere((value) => value.wire == action));
    _operation = (id: id, token: token);
    _set(GitStarting(repository, operation));
    GitOutcome outcome;
    try {
      final result = await client.gitRequest('git/run', {'cwd': cwd, 'actionId': id, 'action': action,
        'commitMessage': message, 'filePaths': ?filePaths, 'provider': ?provider, 'model': ?model, 'branch': ?branch,
        'includeUnstaged': includeUnstaged, 'newBranch': ?newBranch},
        cancellation: token.merge(_lifetime));
      final commit = _commit(result['commit']);
      if (commit != null && _commitMessage.trim() == message.trim()) _commitMessage = '';
      outcome = result['status'] == 'failed' ? GitRejected(
        '${commit == null ? '' : 'Committed ${commit.sha.substring(0, 7)}. '}${result['message']}', commit) : GitSucceeded(commit);
    } on CancelledException {
      final active = _state is GitCancelling ? (_state as GitCancelling).operation : _state;
      outcome = GitStopped(active is GitPushing ? active.commit : null);
    } catch (error) {
      outcome = GitRejected(error.toString(), null);
    } finally {
      token.cancel();
    }
    if (_lifetime.isCancelled || _operation?.id != id) return;
    _operation = null;
    _set(GitRefreshing(repository, operation, outcome));
    var updated = repository;
    try {
      updated = _repository(await client.gitRequest('git/status', {'cwd': cwd}, cancellation: _lifetime));
    } catch (_) { /* Keep the last status; the action's result remains authoritative. */ }
    if (_lifetime.isCancelled) return;
    _refreshed = DateTime.now();
    _set(switch (outcome) {
      GitStopped(:final commit) => GitCancelled(updated, operation, commit),
      GitRejected(:final message, :final commit) => GitFailed(updated, message, operation: operation, commit: commit),
      GitSucceeded() => GitCompleted(updated, operation, outcome),
    });
  }

  void cancel() {
    if (_state case final GitRunning current) {
      if (_operation == null) return;
      _set(GitCancelling(current));
      _operation?.token.cancel();
    }
  }

  void acknowledge() {
    final repository = _state.repository;
    if (repository != null && (_state is GitCompleted || _state is GitFailed || _state is GitCancelled)) {
      _set(GitReady(repository));
    }
  }

  Future<void> close() async {
    _lifetime.cancel(); _read?.cancel(); _operation?.token.cancel();
    await _events.cancel();
    dispose();
  }
}

GitCommit? _commit(Object? value) => value is Map
  ? (sha: value['sha'] as String, subject: value['subject'] as String) : null;
