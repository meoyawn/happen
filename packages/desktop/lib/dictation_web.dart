import 'package:flutter/foundation.dart';
import 'connection_web.dart';
import 'dictation_state.dart';

enum DictationAction { insert, send }
typedef DictationConversation = ({Object scope, String draftKey});
class DictationResult { const DictationResult(this.text, this.action); final String text; final DictationAction action; }

/// Native dictation uses the macOS microphone bridge. Browser composers expose
/// keyboard input; no provider credential is ever transferred to the browser.
class DictationService extends ChangeNotifier {
  DictationService(AgentClient client);
  DictationState _state = const DictationIdle();
  DictationState get state => _state;
  String? get error => switch (_state) { DictationFailed(:final error) => error, _ => null };
  final amplitude = ValueNotifier<double>(0);
  String transcript = '';
  bool liveTranscription = false;
  String? get liveTranscriptionHint => null;
  Object? owner;
  DictationConversation? conversation;
  bool get microphonePermissionDenied => false;
  bool get active => false;
  bool get canRetry => false;
  Future<void> start({required Object owner, required DictationConversation conversation,
    required VoidCallback onRecordingLimit, bool liveTranscription = false}) async {
    _state = transitionDictation(_state, const DictationStarting());
    _state = transitionDictation(_state, const DictationFailed('Dictation is available in the macOS app'));
    notifyListeners();
  }
  Future<DictationResult?> stop(DictationAction action) async => null;
  Future<DictationResult?> retry(DictationAction action) async => null;
  Future<void> cancel() async { _state = transitionDictation(_state, const DictationIdle()); notifyListeners(); }
  Future<void> openMicrophoneSettings() async {}
  @override
  void dispose() { amplitude.dispose(); _state = transitionDictation(_state, const DictationDisposed()); super.dispose(); }
}
