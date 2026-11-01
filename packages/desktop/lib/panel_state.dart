import 'package:protocol/protocol.dart';

const contextPanel = 'context:main';

/// OpenCode's per-session side region: stored tabs, selection and chat width.
/// New tabs are launchers and disappear when the application closes.
class SessionPanelState {
  bool opened = false;
  double? sessionWidth;
  final tabs = <String>[];
  final closed = <String>[];
  String? active;
}

SessionPanelState readSessionPanels(Json value) {
  final state = SessionPanelState();
  state.opened = value['opened'] == true;
  final width = value['sessionWidth'];
  if (width is num && width.isFinite) state.sessionWidth = width.toDouble().clamp(400, double.infinity);
  final tabs = value['tabs'], closed = value['closed'];
  state.tabs.addAll((tabs is List ? tabs : const []).whereType<String>().where((tab) => tab == contextPanel).toSet());
  state.closed.addAll((closed is List ? closed : const []).whereType<String>()
    .where((tab) => tab == contextPanel && !state.tabs.contains(tab)).toSet());
  final active = value['active'];
  state.active = state.tabs.contains(active) ? active as String : state.tabs.firstOrNull;
  if (state.opened && state.tabs.isEmpty) {
    state.tabs.add('new:${newId()}');
    state.active = state.tabs.single;
  }
  return state;
}

Json writeSessionPanels(SessionPanelState state) => {
  'opened': state.opened,
  'sessionWidth': state.sessionWidth,
  'tabs': state.tabs.where((tab) => !tab.startsWith('new:')).toList(),
  'active': state.active?.startsWith('new:') == true ? null : state.active,
  'closed': state.closed,
};
