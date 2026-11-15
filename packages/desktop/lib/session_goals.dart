part of 'session.dart';

extension SessionGoals on DesktopSession {
  ComposerMode composerMode(String id) => _composerModes[id] ?? const MessageComposer();

  void chooseComposerMode(String id, ComposerMode next) {
    final mode = transitionComposerMode(composerMode(id), next);
    if (mode is MessageComposer) { _composerModes.remove(id); }
    else { _composerModes[id] = mode; }
    saveDrafts();
    if (!_lifetime.isCancelled) _notifyDraftChanges();
  }

  Future<bool> changeGoal(DesktopTask target, {String? objective, String? status,
      bool clear = false, CancellationToken? cancellation}) async {
    if (!connected || target.archived || target.archiving || target.sideParentID != null ||
        target.goalWrite is GoalWritePending) { return false; }
    final mutation = (objective: objective, status: status, clear: clear);
    final write = GoalWritePending(mutation);
    target._goalWrite = transitionGoalWrite(target._goalWrite, write);
    final operation = target._goalOperation = CancellationToken();
    final token = operation.merge(cancellation?.merge(_lifetime) ?? _lifetime);
    _taskChanged(target, sidebar: false);
    try {
      if (!clear && status == 'active' && !target.running) {
        // Reading a transcript only watches it. Resume the runtime before
        // asking it to pursue a goal in a previously unloaded conversation.
        await client.sessionRead('thread/resume', {'threadId': target.id, 'excludeTurns': true}, cancellation: token);
        token.throwIfCancelled();
      }
      final revision = target._goalRevision;
      final response = await client.goalRequest(clear ? 'thread/goal/clear' : 'thread/goal/set', {
        'threadId': target.id, 'origin': 'user',
        if (!clear) ...{'objective': ?objective, 'status': ?status},
      }, cancellation: token);
      token.throwIfCancelled();
      if (!identical(target._goalOperation, operation)) return false;
      // A notification can beat its acknowledgement. Keep the newer server state.
      if (target._goalRevision == revision) {
        target._goal = clear ? null : savedGoal(response['goal']);
        target._goalRevision++;
      }
      target._goalWrite = transitionGoalWrite(target._goalWrite, const GoalWriteIdle());
      return true;
    } catch (failure) {
      if (identical(target._goalOperation, operation)) {
        target._goalWrite = transitionGoalWrite(target._goalWrite, GoalWriteFailed(write, failure));
      }
      if (failure is CancelledException) rethrow;
      showError(failure, title: clear ? 'Could not clear goal' : 'Could not save goal');
      return false;
    } finally {
      if (identical(target._goalOperation, operation)) target._goalOperation = null;
      operation.cancel();
      _taskChanged(target, sidebar: false);
    }
  }
}
