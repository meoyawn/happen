import 'main_native.dart' if (dart.library.js_interop) 'main_web.dart' as platform;
export 'main_native.dart' if (dart.library.js_interop) 'main_web.dart';

void main() => platform.main();
