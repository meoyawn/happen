import 'dart:isolate';

typedef TraceSink = SendPort;
int get traceThread => Isolate.current.hashCode;
