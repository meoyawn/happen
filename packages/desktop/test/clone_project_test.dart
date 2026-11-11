import 'dart:io';

import 'package:desktop/add_project_state.dart';
import 'package:desktop/database.dart';
import 'package:desktop/session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:protocol/protocol.dart';
import 'package:server/server.dart';

void main() {
  test('cloning to a chosen destination saves the repository subfolder after commit', () async {
    final temporary = await Directory.systemTemp.createTemp('happen-clone-project-');
    final root = Directory(await temporary.resolveSymbolicLinks());
    addTearDown(() => root.delete(recursive: true));
    final source = '${root.path}/source';
    await Directory('$source/packages/app').create(recursive: true);
    await File('$source/packages/app/main.dart').writeAsString('cloned project\n');
    for (final arguments in [
      ['init'], ['add', '.'],
      ['-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'Initial'],
    ]) {
      final result = await Process.run('git', ['-c', 'core.hooksPath=/dev/null', ...arguments], workingDirectory: source);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }
    final server = await AgentServer.startLocal(directory: '${root.path}/server', skillsHome: root.path);
    addTearDown(server.close);
    final session = DesktopSession(AgentClient.local(server), await openDesktopDatabase('${root.path}/desktop'));
    addTearDown(session.close);
    final controller = AddProjectController(location: ProjectLocation(
      (alias: null, name: 'local', session: session), ProjectSource.git,
      remoteUrl: source, subdirectory: 'packages/app'));
    addTearDown(controller.dispose);
    expect(controller.state, isA<ProjectLocation>());
    final destination = '${root.path}/chosen folder λ/checkout';
    await controller.submit(destination);
    expect(controller.state, isA<ProjectSaved>(),
      reason: switch (controller.state) { ProjectSaveFailed(:final message) => message, _ => null });
    final saved = controller.state as ProjectSaved;
    expect(saved.project.path, '$destination/packages/app');
    expect(saved.project.workspace?['repositoryRoot'], destination);
    expect(saved.project.workspace?['subdirectory'], 'packages/app');
    expect(await File('$destination/packages/app/main.dart').readAsString(), 'cloned project\n');
    final persisted = jsonObject(await callIsolate(session.database.port, 'load', {}));
    expect((persisted['projects'] as List).single['path'], '$destination/packages/app');
  });
}
