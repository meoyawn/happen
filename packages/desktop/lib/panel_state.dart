import 'package:protocol/protocol.dart';

const contextPanel = 'context:main';

String filePanelPath(String tab) => tab.substring('file:'.length);
bool isFilePanel(String tab) => tab.startsWith('file:/') && !tab.contains('\x00');
bool isBrowserPanel(String tab) => tab.startsWith('browser:');
String sideChatPanel(String sessionID) => 'side:$sessionID';
bool isSideChatPanel(String tab) => tab.startsWith('side:');
String sideChatID(String tab) => tab.substring('side:'.length);
bool _knownPanel(String tab) => tab == contextPanel || isFilePanel(tab) || isBrowserPanel(tab);

/// OpenCode's per-session side region: stored tabs, selection and chat width.
/// New tabs are launchers and disappear when the application closes.
class SessionPanelState {
  bool opened = false;
  double? sessionWidth;
  final tabs = <String>[];
  final closed = <String>[];
  final fileReveals = <String, ({int? line, int revision})>{};
  final browserPages = <String, ({String url, String title})>{};
  String? active;
}

SessionPanelState readSessionPanels(Json value) {
  final state = SessionPanelState();
  state.opened = value['opened'] == true;
  final width = value['sessionWidth'];
  if (width is num && width.isFinite) state.sessionWidth = width.toDouble().clamp(400, double.infinity);
  final tabs = value['tabs'], closed = value['closed'];
  state.tabs.addAll((tabs is List ? tabs : const <Object?>[]).whereType<String>().where(_knownPanel).toSet());
  state.closed.addAll((closed is List ? closed : const <Object?>[]).whereType<String>()
    .where((tab) => _knownPanel(tab) && !state.tabs.contains(tab)).toSet());
  final pages = value['browserPages'];
  if (pages is Map) {
    for (final tab in [...state.tabs, ...state.closed].where(isBrowserPanel)) {
      final page = pages[tab];
      if (page is Map) state.browserPages[tab] = (
        url: page['url'] is String ? page['url'] as String : '',
        title: page['title'] is String ? page['title'] as String : '',
      );
    }
  }
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
  'tabs': state.tabs.where(_knownPanel).toList(),
  'active': state.active != null && _knownPanel(state.active!) ? state.active : null,
  'closed': state.closed.where(_knownPanel).toList(),
  'browserPages': {
    for (final tab in [...state.tabs, ...state.closed].where(isBrowserPanel))
      if (state.browserPages[tab] case final page?)
        tab: {'url': page.url, 'title': page.title},
  },
};
