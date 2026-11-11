@TestOn('mac-os')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:protocol/protocol.dart';
import 'package:test/test.dart';

void main() {
  late _Fixture fixture;
  late Directory native;
  late File appExecutable;
  setUpAll(() async {
    native = await Directory.systemTemp.createTemp('happen-launch-native-');
    appExecutable = File('${native.path}/app');
    final compilation = await Process.run(Platform.resolvedExecutable,
      ['compile', 'exe', '${Directory.current.path}/test/fixtures/desktop_flutter.dart', '-o', appExecutable.path],
      workingDirectory: native.path);
    expect(compilation.exitCode, 0, reason: '${compilation.stdout}\n${compilation.stderr}');
  });
  tearDownAll(() => native.delete(recursive: true));
  setUp(() async { fixture = await _Fixture.create(); });
  tearDown(() => fixture.dispose());

  test('moon dev strips its context and preserves SDK settings and input', () async {
    final (owner, first) = await fixture.launch(moon: true);
    await fixture.waitFor(() => fixture.starts.isNotEmpty);
    final started = fixture.starts.single;
    expect(started['moon'], isEmpty);
    expect(started['sentinel'], 'preserved');
    expect(started['FLUTTER_ROOT'], '${fixture.root.path}/third_party/flutter');
    expect(started['PATH'], startsWith('${fixture.root.path}/third_party/flutter/bin:'));
    expect(started['pid'], first['pid']);
    for (final command in ['r', 'R']) {
      await owner.send(command);
      expect(await owner.line(), 'received:$command');
    }
    await owner.send('q');
    expect(await owner.process.exitCode, 0);
    expect((await fixture.status())['flutter_pids'], isEmpty);
  });

  test('Flutter failure exit status is preserved', () async {
    final (owner, _) = await fixture.launch();
    await fixture.waitFor(() => fixture.starts.isNotEmpty);
    await owner.send('x');
    expect(await owner.process.exitCode, 42);
    expect((await fixture.status())['flutter_pids'], isEmpty);
  });

  test('dev ignores an inherited SDK and repairs its package resolution', () async {
    final foreignSdk = Directory('${fixture.temporary.path}/homebrew flutter');
    final foreignFlutter = File('${foreignSdk.path}/bin/flutter');
    await foreignFlutter.parent.create(recursive: true);
    await foreignFlutter.writeAsString('#!${Platform.resolvedExecutable} --disable-dart-dev\n'
      "import 'dart:io';\nvoid main() { exit(23); }\n");
    expect((await Process.run('/bin/chmod', ['700', foreignFlutter.path])).exitCode, 0);
    fixture.environment['PATH'] = '${foreignFlutter.parent.path}:${Platform.environment['PATH']}';
    fixture.environment['FLUTTER_ROOT'] = foreignSdk.path;
    final packageFile = File('${fixture.root.path}/.dart_tool/package_config.json');
    final packages = jsonDecode(await packageFile.readAsString()) as Map<String, dynamic>;
    (packages['packages'] as List).cast<Map<String, dynamic>>()
      .singleWhere((package) => package['name'] == 'flutter')['rootUri'] =
        Uri.directory('${foreignSdk.path}/packages/flutter').toString();
    await packageFile.writeAsString(jsonEncode(packages));

    final (owner, _) = await fixture.launch();
    await fixture.waitFor(() => fixture.starts.isNotEmpty);
    expect(fixture.starts.single['FLUTTER_ROOT'], '${fixture.root.path}/third_party/flutter');
    expect(fixture.starts.single['frameworkRoot'],
      await Directory('${fixture.root.path}/third_party/flutter/packages/flutter').resolveSymbolicLinks());
    await owner.send('q');
    expect(await owner.process.exitCode, 0);
  });

  test('concurrent launches share one process and relaunch after it exits', () async {
    expect((await fixture.status())['flutter_pids'], isEmpty);
    final results = await Future.wait(List.generate(8, (_) => fixture.launch()));
    final (owner, first) = results.singleWhere((result) => result.$2['reused'] != true);
    await fixture.waitFor(() => fixture.starts.isNotEmpty);
    expect(fixture.starts.map((value) => value['pid']), [owner.process.pid]);
    expect(first['pid'], owner.process.pid);
    expect(results.map((result) => result.$2['pid']), everyElement(first['pid']));
    expect((await fixture.status())['flutter_pids'], [owner.process.pid]);
    await owner.send('q');
    expect(await Future.wait(results.map((result) => result.$1.process.exitCode)), everyElement(0));
    final (relaunched, second) = await fixture.launch();
    expect(second['pid'], isNot(first['pid']));
    await fixture.waitFor(() => fixture.starts.length == 2);
    await relaunched.send('q');
    expect(await relaunched.process.exitCode, 0);
  });

  test('checkouts serialize startup through the shared app lock', () async {
    final other = Directory('${fixture.temporary.path}/other checkout/packages/desktop');
    await fixture.copyLauncher(other);
    final results = await Future.wait([fixture.launch(), fixture.launch(desktop: other)]);
    final (owner, first) = results.singleWhere((result) => result.$2['reused'] != true);
    await fixture.waitFor(() => fixture.starts.isNotEmpty);
    expect(fixture.starts.map((value) => value['pid']), [first['pid']]);
    expect(results.singleWhere((result) => result.$2['reused'] == true).$2['flutter_pids'], [owner.process.pid]);
    await owner.send('q');
    expect(await Future.wait(results.map((result) => result.$1.process.exitCode)), everyElement(0));
  });

  test('cancelling reuse leaves the original session running; terminating its owner stops Flutter', () async {
    final (owner, _) = await fixture.launch();
    await fixture.waitFor(() => fixture.starts.isNotEmpty);
    final (reused, report) = await fixture.launch();
    expect(report['reused'], isTrue);
    reused.process.kill(ProcessSignal.sigint);
    expect(await reused.process.exitCode, 130);
    await owner.send('r');
    expect(await owner.line(), 'received:r');
    owner.process.kill(ProcessSignal.sigterm);
    expect(await owner.process.exitCode, -ProcessSignal.sigterm.signalNumber);
    expect((await fixture.status())['flutter_pids'], isEmpty);
  });

  test('duplicate supervisors are refused without starting another', () async {
    final children = [await fixture.startFlutter(), await fixture.startFlutter()];
    await fixture.waitFor(() => fixture.starts.length == 2);
    final (refused, report) = await fixture.launch();
    expect(await refused.process.exitCode, 2);
    expect(report['flutter_pids'], unorderedEquals(children.map((child) => child.process.pid)));
    expect(fixture.starts, hasLength(2));
  });

  for (final mode in ['release', 'profile']) {
    test('reuses a $mode Flutter supervisor before the app starts', () async {
      final existing = await fixture.startFlutter(mode: mode);
      await fixture.waitFor(() => fixture.starts.isNotEmpty);
      final (reused, report) = await fixture.launch();
      expect(report['reused'], isTrue, reason: jsonEncode(report));
      expect(report['flutter_pids'], [existing.process.pid]);
      expect(fixture.starts, hasLength(1));
      await existing.send('q');
      expect(await existing.process.exitCode, 0);
      expect(await reused.process.exitCode, 0);
    });
  }

  for (final configuration in ['Debug', 'Profile', 'Release', 'Applications']) {
    test('reuses an existing app from $configuration', () async {
      final existing = await fixture.startApp(configuration, appExecutable);
      final (reused, report) = await fixture.launch();
      expect(report['reused'], isTrue, reason: jsonEncode(report));
      expect(report['app_pids'], [existing.process.pid]);
      expect(fixture.starts, isEmpty);
      existing.process.kill();
      await existing.process.exitCode;
      expect(await reused.process.exitCode, 0);
    });
  }

  test('apps from different builds refuse another launch', () async {
    final apps = [await fixture.startApp('Debug', appExecutable), await fixture.startApp('Applications', appExecutable)];
    final (refused, report) = await fixture.launch();
    expect(await refused.process.exitCode, 2);
    expect(report['app_pids'], unorderedEquals(apps.map((child) => child.process.pid)));
    expect(fixture.starts, isEmpty);
  });

  test('vendored SDK symlinks with spaces and apostrophes still reuse the supervisor', () async {
    final sdk = fixture.flutter.parent.parent;
    final directory = await Directory('${fixture.root.path}/owner\'s tools').create();
    final moved = await sdk.rename('${directory.path}/flutter');
    await Link(sdk.path).create(moved.path);
    fixture.flutter = File('${moved.path}/bin/flutter');
    final (owner, first) = await fixture.launch();
    await fixture.waitFor(() => fixture.starts.isNotEmpty);
    final (reused, report) = await fixture.launch();
    expect(report['reused'], isTrue);
    expect(report['flutter_pids'], [first['pid']]);
    expect(fixture.starts, hasLength(1));
    await owner.send('q');
    expect(await owner.process.exitCode, 0);
    expect(await reused.process.exitCode, 0);
  });
}

class _Child {
  _Child(this.process, this.cancellation)
    : output = StreamIterator(process.stdout.transform(utf8.decoder).transform(const LineSplitter())),
      errors = process.stderr.transform(utf8.decoder).join();
  final Process process;
  final CancellationToken cancellation;
  final StreamIterator<String> output;
  final Future<String> errors;

  Future<String> line() async {
    if (!await output.moveNext().timeout(const Duration(seconds: 30)).asCancellable(cancellation)) {
      fail('Launcher exited: ${await errors}');
    }
    return output.current;
  }

  Future<void> send(String command) async {
    process.stdin.write(command);
    await process.stdin.flush();
  }
}

class _Fixture {
  _Fixture(this.temporary);
  final Directory temporary;
  final source = Directory.current;
  final children = <_Child>[];
  final cancellation = CancellationToken();
  late final root = Directory('${temporary.path}/checkout with spaces');
  late final desktop = Directory('${root.path}/packages/desktop');
  late File flutter = File('${root.path}/third_party/flutter/bin/flutter');
  late final name = 'Happen-${temporary.uri.pathSegments.where((part) => part.isNotEmpty).last}';
  late final environment = Map<String, String>.of(Platform.environment);

  static Future<_Fixture> create() async {
    final temporary = await Directory.systemTemp.createTemp('happen-launch-');
    final fixture = _Fixture(Directory(await temporary.resolveSymbolicLinks()));
    await fixture.copyLauncher(fixture.desktop);
    await fixture.flutter.parent.create(recursive: true);
    await Directory('${fixture.root.path}/third_party/flutter/packages/flutter').create(recursive: true);
    await fixture.flutter.writeAsString('#!${Platform.resolvedExecutable} --disable-dart-dev\n'
      '${await File('${fixture.source.path}/test/fixtures/desktop_flutter.dart').readAsString()}');
    await Link('${fixture.flutter.parent.path}/dart').create(Platform.resolvedExecutable);
    final chmod = await Process.run('/bin/chmod', ['700', fixture.flutter.path]);
    expect(chmod.exitCode, 0);
    fixture.environment
      ..removeWhere((key, _) => key.startsWith('MOON_'))
      ..addAll({'PATH': '${fixture.flutter.parent.path}:${Platform.environment['PATH']}', 'TMPDIR': fixture.temporary.path,
        'MOON_LAUNCH_SENTINEL': 'must not reach Flutter', 'HAPPEN_LAUNCH_SENTINEL': 'preserved'});
    await Directory('${fixture.root.path}/.moon').create();
    await File('${fixture.source.path}/.moon/workspace.yml').copy('${fixture.root.path}/.moon/workspace.yml');
    await File('${fixture.source.path}/moon.yml').copy('${fixture.root.path}/moon.yml');
    // Dart subprocesses in the fixture use the existing dependency graph only.
    await Directory('${fixture.root.path}/.dart_tool').create();
    final packageFile = File('${fixture.source.path}/.dart_tool/package_config.json');
    final packages = jsonDecode(await packageFile.readAsString()) as Map<String, dynamic>;
    for (final package in packages['packages'] as List<dynamic>) {
      final entry = package as Map<String, dynamic>;
      entry['rootUri'] = entry['name'] == 'flutter'
        ? Uri.directory('${fixture.root.path}/third_party/flutter/packages/flutter').toString()
        : packageFile.uri.resolve(entry['rootUri'] as String).toString();
    }
    await File('${fixture.root.path}/.dart_tool/package_config.json').writeAsString(jsonEncode(packages));
    return fixture;
  }

  Future<void> copyLauncher(Directory destination) async {
    await Directory('${destination.path}/tool').create(recursive: true);
    await File('${source.path}/packages/desktop/tool/run_flutter.dart').copy('${destination.path}/tool/run_flutter.dart');
    final config = File('${destination.path}/macos/Runner/Configs/AppInfo.xcconfig');
    await config.parent.create(recursive: true);
    await config.writeAsString('PRODUCT_NAME = $name\nPRODUCT_BUNDLE_IDENTIFIER = com.adelnz.$name\n');
    final checkout = destination.parent.parent;
    if (checkout.path != root.path) {
      await Directory('${checkout.path}/third_party').create(recursive: true);
      await Link('${checkout.path}/third_party/flutter').create('${root.path}/third_party/flutter');
      await Directory('${checkout.path}/.dart_tool').create();
      await File('${root.path}/.dart_tool/package_config.json').copy('${checkout.path}/.dart_tool/package_config.json');
    }
  }

  List<Map<String, dynamic>> get starts {
    final trace = Directory('${flutter.parent.path}/starts');
    return trace.existsSync() ? [
      for (final file in trace.listSync().whereType<File>().where((file) => file.path.endsWith('.json')))
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
    ] : [];
  }

  Future<_Child> start(String executable, List<String> arguments, String directory) async {
    cancellation.throwIfCancelled();
    final process = await Process.start(executable, arguments, workingDirectory: directory,
      environment: environment, includeParentEnvironment: false);
    final child = _Child(process, cancellation);
    children.add(child);
    return child;
  }

  Future<(_Child, Map<String, dynamic>)> launch({bool moon = false, Directory? desktop, List<String> arguments = const []}) async {
    final child = await start(moon ? 'moon' : Platform.resolvedExecutable,
      moon ? ['run', 'dev', '--', ...arguments] : ['--disable-dart-dev', '--packages=${source.path}/.dart_tool/package_config.json',
        '${(desktop ?? this.desktop).path}/tool/run_flutter.dart', ...arguments], root.path);
    while (true) {
      final line = await child.line();
      if (line.startsWith('{')) return (child, jsonDecode(line) as Map<String, dynamic>);
    }
  }

  Future<Map<String, dynamic>> status() async {
    final (child, report) = await launch(arguments: ['--status']);
    expect(await child.process.exitCode.timeout(const Duration(seconds: 10)), 0, reason: await child.errors);
    return report;
  }

  Future<_Child> startFlutter({String mode = 'debug'}) => start(flutter.path, ['run', '-d', 'macos', '--$mode'], desktop.path);

  Future<_Child> startApp(String configuration, File appExecutable) async {
    final executable = File('${temporary.path}/$configuration/$name.app/Contents/MacOS/$name');
    await executable.parent.create(recursive: true);
    await appExecutable.copy(executable.path);
    final child = await start(executable.path, [], desktop.path);
    await waitFor(() {
      final result = Process.runSync('/bin/ps', ['-p', '${child.process.pid}', '-o', 'comm=']);
      return (result.stdout as String).contains('/$name.app/Contents/MacOS/$name');
    });
    return child;
  }

  Future<void> waitFor(bool Function() predicate) async {
    final elapsed = Stopwatch()..start();
    while (!predicate()) {
      if (elapsed.elapsed > const Duration(seconds: 15)) fail('Timed out waiting for launcher process');
      await Future<void>.delayed(const Duration(milliseconds: 20)).asCancellable(cancellation);
    }
  }

  Future<void> dispose() async {
    cancellation.cancel();
    for (final child in children) { child.process.kill(ProcessSignal.sigterm); }
    for (final value in starts) { Process.killPid(value['pid'] as int, ProcessSignal.sigterm); }
    for (final child in children) {
      await child.process.exitCode.timeout(const Duration(seconds: 10));
      await child.output.cancel();
      await child.process.stdin.close();
      await child.errors;
    }
    await temporary.delete(recursive: true);
  }
}
