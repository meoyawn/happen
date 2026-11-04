import 'package:flutter/material.dart';

/// T3Code's compact work-log spinner. Offscreen tickers are owned by Flutter.
class ConversationActivityIndicator extends StatelessWidget {
  const ConversationActivityIndicator({super.key, this.color});
  final Color? color;

  @override
  Widget build(BuildContext context) => SizedBox.square(dimension: 14, child: MediaQuery.disableAnimationsOf(context)
    ? Icon(Icons.more_horiz, size: 14, color: color)
    : CircularProgressIndicator(strokeWidth: 1.5, color: color ?? Theme.of(context).colorScheme.onSurfaceVariant));
}
