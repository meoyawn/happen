import 'package:flutter/foundation.dart';

enum DesktopToastType { success, error, info, warning }

typedef DesktopNotice = ({
  String title,
  String? description,
  DesktopToastType type,
  Object? tag,
  String? actionLabel,
  VoidCallback? onAction,
});
