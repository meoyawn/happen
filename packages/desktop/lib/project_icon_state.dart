import 'dart:typed_data';

import 'package:config/config.dart';
import 'package:protocol/protocol.dart';

typedef ProjectIconSnapshot = ({ProjectIcon? icon, Uint8List? bytes, bool svg, String? revision, String? error});
const emptyProjectIcon = (icon: null, bytes: null, svg: false, revision: null, error: null);

ProjectIconSnapshot readProjectIconSnapshot(Json value) => (
  icon: parseProjectIcon(value['icon']),
  bytes: (value['icon_data'] as Uint8List?)?.asUnmodifiableView(),
  svg: value['icon_svg'] == true,
  revision: value['icon_revision'] as String?,
  error: value['icon_error'] as String?,
);

sealed class ProjectIconState {
  const ProjectIconState(this.value);
  final ProjectIconSnapshot value;
}
final class ProjectIconReady extends ProjectIconState { const ProjectIconReady(super.value); }
final class ProjectIconSaving extends ProjectIconState {
  const ProjectIconSaving(super.value, this.pending);
  final ProjectIcon? pending;
}
final class ProjectIconFailed extends ProjectIconState {
  const ProjectIconFailed(super.value, this.message);
  final String message;
}

ProjectIconState transitionProjectIcon(ProjectIconState current, ProjectIconState next) => switch ((current, next)) {
  (ProjectIconReady() || ProjectIconFailed(), ProjectIconReady() || ProjectIconSaving() || ProjectIconFailed()) => next,
  (ProjectIconSaving(), ProjectIconReady() || ProjectIconFailed()) => next,
  _ => throw StateError('Invalid project icon transition'),
};
