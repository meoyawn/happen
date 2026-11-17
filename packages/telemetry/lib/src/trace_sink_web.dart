class TraceSink {
  TraceSink(this.send);
  final void Function(Object?) send;
}

int get traceThread => 0;
