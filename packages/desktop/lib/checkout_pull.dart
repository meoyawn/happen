import 'dart:async';

import 'package:flutter/material.dart';

import 'appearance.dart';
import 'git_actions_state.dart';
import 'session.dart';

// T3's ghost Pull control, progress, error toast and ten-second inline success.
class CheckoutPullControl extends StatefulWidget {
  const CheckoutPullControl({super.key, required this.session, this.enabled = true});
  final DesktopSession session;
  final bool enabled;
  @override
  State<CheckoutPullControl> createState() => _CheckoutPullControlState();
}

class _CheckoutPullControlState extends State<CheckoutPullControl> {
  GitActionsController? _controller;
  String? _draftId;
  GitCompleted? _success;
  Timer? _successExpiry;

  @override
  void initState() { super.initState(); _bind(); }
  @override
  void didUpdateWidget(CheckoutPullControl oldWidget) { super.didUpdateWidget(oldWidget); _bind(); }

  void _bind() {
    final session = widget.session, project = session.project;
    final controller = project == null ? null : session.gitForProject(project);
    final draftId = session.task == null ? session.currentDraft.id : null;
    if (identical(_controller, controller) && _draftId == draftId) return;
    _controller = controller; _draftId = draftId; _success = null; _successExpiry?.cancel();
    if (controller != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && identical(_controller, controller)) { unawaited(controller.refresh()); }
      });
    }
  }

  @override
  void dispose() { _successExpiry?.cancel(); super.dispose(); }

  Future<void> _pull() async {
    final controller = _controller, session = widget.session, draftId = _draftId;
    if (controller == null || controller.busy || !widget.enabled) return;
    _successExpiry?.cancel();
    setState(() => _success = null);
    await session.pullCheckout();
    if (!mounted || !identical(_controller, controller) || _draftId != draftId ||
        !identical(widget.session, session)) { return; }
    final state = controller.state;
    if (state is GitFailed) { session.showError(state.message, title: 'Pull failed'); }
    if (state is GitCompleted && state.operation.action == GitAction.pull) {
      setState(() => _success = state);
      _successExpiry = Timer(const Duration(seconds: 10), () { if (mounted) setState(() => _success = null); });
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    return ListenableBuilder(listenable: controller, builder: (context, _) {
      final state = controller.state, repo = state.repository;
      if (repo != null && !repo.isRepo) return const SizedBox.shrink();
      final pulling = controller.pulling;
      final success = !controller.busy && state is GitCompleted && state.operation.id == _success?.operation.id ? _success : null;
      final retry = repo == null && state is GitFailed;
      final reason = !widget.session.connected ? 'Machine is disconnected'
        : widget.session.submitting || widget.session.task != null ? 'Start a new thread to update its checkout'
        : !widget.enabled ? 'Wait for the workspace to finish changing'
        : repo == null ? state is GitFailed ? state.message : 'Checking Git status…'
        : repo.branch == null || repo.head == null ? 'Check out a branch before pulling'
        : repo.pullRemote == null ? 'Configure a Git remote before pulling' : null;
      final tooltip = success?.result.detail ?? (pulling ? state is GitRunning ? state.output ?? state.label
        : 'Pulling latest changes…' : reason ??
          'Update ${repo?.branch} from ${repo?.pullRemote}/${repo?.pullBranch ?? 'main or master'} (fast-forward only)');
      final label = pulling ? 'Pulling latest changes…' : success?.message ?? (retry ? 'Retry Git status' : 'Pull');
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Flexible(child: Tooltip(message: tooltip, child: TextButton(
          onPressed: retry && widget.enabled && widget.session.connected && !widget.session.submitting
            ? () => unawaited(controller.refresh(force: true))
            : reason == null && !controller.busy && success == null ? () => unawaited(_pull()) : null,
          style: TextButton.styleFrom(foregroundColor: desktopSecondary,
            disabledForegroundColor: pulling || success != null ? desktopSecondary : desktopTertiary,
            minimumSize: const Size(0, 24), tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
            textStyle: const TextStyle(fontFamily: desktopFontFamily, fontSize: 12, fontWeight: FontWeight.w400),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6))),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (pulling) const SizedBox.square(dimension: 13,
              child: CircularProgressIndicator(strokeWidth: 1.5, color: desktopSecondary))
            else Icon(success != null ? Icons.check_rounded : Icons.cloud_download_outlined, size: 14),
            const SizedBox(width: 6), Flexible(child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)),
          ])))),
        if (pulling) SizedBox.square(dimension: 24, child: IconButton(tooltip: 'Cancel pull',
          padding: EdgeInsets.zero, onPressed: state is GitCancelling || state is GitRefreshing ? null : controller.cancel,
          icon: const Icon(Icons.close_rounded, size: 13, color: desktopSecondary))),
      ]);
    });
  }
}
