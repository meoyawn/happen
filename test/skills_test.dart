import 'dart:convert';
import 'dart:io';

import 'package:agent/src/skills.dart';
import 'package:ai/ai.dart';
import 'package:opencode/opencode.dart';
import 'package:opencode/src/skills.dart';
import 'package:protocol/protocol.dart';
import 'package:server/src/skills.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  late FilesystemSkills skills;
  late CancellationToken cancellation;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('filesystem-skills-');
    skills = FilesystemSkills(homeDirectory: root.path + '/home');
    cancellation = CancellationToken();
  });
  tearDown(() async {
    cancellation.cancel();
    await root.delete(recursive: true);
  });
  Future<File> skill(String path, String name, {String description = 'Useful workflow', String body = 'BODY_ONLY'}) async {
    final file = File(root.path + '/' + path + '/SKILL.md');
    await file.parent.create(recursive: true);
    await file.writeAsString('---\nname: $name\ndescription: $description\n---\n$body\n');
    return file;
  }

  test('only .agents skills roots, canonical deduplication, hidden entries and nearest repository', () async {
    final cwd = root.path + '/repo/sub';
    await Directory(cwd).create(recursive: true);
    await File(root.path + '/repo/.git').writeAsString('gitdir: elsewhere');
    final repo = await skill('repo/.agents/skills/a', 'same-name');
    await skill('repo/sub/.agents/skills/b', 'same-name');
    await skill('home/.agents/skills/global', 'home');
    final excluded = [
      await skill('repo/.codex/skills/compat', 'project-config'),
      await skill('repo/sub/.codex/skills/compat', 'nested-config'),
      await skill('home/.codex/skills/legacy', 'legacy'),
      await skill('repo/.claude/skills/compat', 'project-claude'),
      await skill('home/.claude/skills/compat', 'global-claude'),
      await skill('data/skills/happen', 'happen'),
    ];
    await skill('.agents/skills/outside', 'outside-repository');
    await skill('repo/sub/deeper/.agents/skills/unvisited', 'descendant');
    await skill('repo/.agents/skills/.hidden', 'hidden');
    await Link(root.path + '/repo/.agents/skills/alias').create(repo.parent.path);
    await Link(repo.parent.path + '/cycle').create(root.path + '/repo/.agents/skills');
    final catalog = await skills.catalog(cwd, cancellation);
    final entries = (catalog['skills'] as List).cast<Json>();
    expect(entries.map((s) => s['name']), unorderedEquals(['same-name', 'same-name', 'home']));
    expect(entries.map((s) => s['path']).toSet(), hasLength(entries.length));
    expect(jsonEncode(catalog), isNot(contains('BODY_ONLY')));
    for (final file in excluded) {
      await expectLater(skills.read(cwd, await file.resolveSymbolicLinks(), cancellation), throwsStateError);
    }
    final single = await skills.catalog(root.path + '/repo/sub/deeper', cancellation);
    expect((single['skills'] as List).any((s) => s['name'] == 'descendant'), isTrue);
    final nonRepo = await Directory(root.path + '/elsewhere').create();
    expect((await skills.catalog(nonRepo.path, cancellation))['skills'],
      everyElement(isNot(containsPair('scope', 'repo'))));
  });

  test('metadata parsing follows Codex fallback, normalization, repair and validation', () {
    final parsed = parseSkillDocument('---\ndescription: Build for AWS: ECS\nmetadata:\n  short-description: Deploy things\n---\n  body stays intact\n', '/skills/deploy/SKILL.md');
    expect(parsed, {'name': 'deploy', 'description': 'Build for AWS: ECS',
      'short_description': 'Deploy things', 'content': '  body stays intact\n'});
    expect(parseSkillDocument('---\nname: ""\ndescription: >\n  Multi line\n  description\n---\r\nbody', '/skills/default/SKILL.md')['description'], 'Multi line description');
    expect(() => parseSkillDocument('No header', '/skills/a/SKILL.md'), throwsFormatException);
    expect(() => parseSkillDocument('---\nname: x\n---\nbody', '/skills/a/SKILL.md'), throwsFormatException);
    expect(() => parseSkillDocument('---\nname: ' + 'x' * 65 + '\ndescription: valid\n---\n', '/skills/a/SKILL.md'), throwsFormatException);
    expect(parseSkillDocument('---\nname: ' + '界' * 64 + '\ndescription: valid\n---\n', '/skills/a/SKILL.md')['name'], '界' * 64);
    expect(() => parseSkillDocument('---\nname: [invalid]\ndescription: valid\n---\n', '/skills/a/SKILL.md'), throwsFormatException);
  });

  test('invalid files do not hide siblings and implicit opt-out remains explicitly readable', () async {
    final cwd = await Directory(root.path + '/repo').create();
    final hidden = await skill('repo/.agents/skills/manual', 'manual');
    await Directory(hidden.parent.path + '/agents').create();
    await File(hidden.parent.path + '/agents/openai.yaml').writeAsString('policy:\n  allow_implicit_invocation: false\n');
    final bad = await skill('repo/.agents/skills/bad', 'bad');
    await bad.writeAsString('broken');
    final catalog = await skills.catalog(cwd.path, cancellation);
    expect(catalog['error_count'], 1);
    expect((catalog['skills'] as List).single['implicit'], false);
    expect(skillContext(catalog, contextWindow: 100000).text, isNot(contains('- manual')));
    final body = await skills.read(cwd.path, 'manual', cancellation);
    expect(body['content'], 'BODY_ONLY\n');
    await hidden.delete();
    await expectLater(skills.read(cwd.path, 'manual', cancellation), throwsStateError);
  });

  test('resource loading is complete, sorted, bounded, and resolves duplicate names by path', () async {
    final file = await skill('.agents/skills/a', 'duplicate', body: 'first\n' + 'line\n' * 1000 + 'last');
    await skill('home/.agents/skills/b', 'duplicate');
    for (var i = 0; i < 15; i++) {
      await File(file.parent.path + '/resource-' + i.toString().padLeft(2, '0')).writeAsString('reference');
    }
    await Directory(file.parent.path + '/node_modules').create();
    await File(file.parent.path + '/node_modules/ignored').writeAsString('ignored');
    await expectLater(skills.read(root.path, 'duplicate', cancellation), throwsStateError);
    final result = await skills.read(root.path, await file.resolveSymbolicLinks(), cancellation);
    expect(result['content'], startsWith('first\n'));
    expect(result['content'], endsWith('last\n'));
    expect(result['files'], hasLength(10));
    expect((result['files'] as List).first, endsWith('resource-00'));
    expect((result['files'] as List).last, endsWith('resource-09'));
  });

  test('cancelled discovery does not publish a partial catalog', () async {
    cancellation.cancel();
    await expectLater(skills.catalog(root.path, cancellation), throwsA(isA<CancelledException>()));
  });

  Json catalog(int count, {String description = 'A useful description', int generation = 0}) => {
    'skills': [for (var i = 0; i < count; i++) {
      'name': 'skill-' + i.toString().padLeft(3, '0'), 'description': '$description $generation',
      'path': '/home/example/.agents/skills/skill-$i/SKILL.md',
      'root': '/home/example/.agents/skills', 'scope': 'user', 'implicit': true,
    }],
    'error_count': 0,
  };

  test('hundreds of Unicode skill descriptions fit one budget, with metadata kept off the wire', () {
    final current = catalog(500, description: '界🙂 descriptions ' * 100);
    final update = skillContext(current, contextWindow: 300000);
    expect(update.text, isNotNull);
    expect((utf8.encode(update.text!).length + 3) ~/ 4, lessThanOrEqualTo(6000));
    expect(update.text, contains('### Skill roots'));
    expect(update.text, contains('r0/skill-'));
    expect(update.text, isNot(contains('\uFFFD')));
    expect(update.item!.native, {'harness': {'context': 'skills'}});
    expect(update.snapshot['entries'], hasLength(500));
    final again = skillContext(current, previous: update.snapshot, contextWindow: 300000);
    expect(again.text, isNull);
    expect(again.snapshot, update.snapshot);
    final fallback = skillContext(current);
    expect(fallback.text!.runes.length, lessThanOrEqualTo(8000));
    expect(skillContext(current, maxTokens: 1).text, isNull);
  });

  test('changing implicit invocation policy updates an already-initialized catalog', () {
    final current = catalog(2);
    final entry = (current['skills'] as List)[1] as Json;
    entry['implicit'] = false;
    final initial = skillContext(current, maxTokens: 1000);
    expect(initial.text, contains('skill-000'));
    expect(initial.text, isNot(contains('skill-001')));
    entry['implicit'] = true;
    final enabled = skillContext(current, previous: initial.snapshot, maxTokens: 1000);
    expect(enabled.text, contains('skill-001'));
    expect(enabled.text, isNot(contains('skill-000')));
    entry['implicit'] = false;
    final disabled = skillContext(current, previous: enabled.snapshot, maxTokens: 1000);
    expect(disabled.text, contains('Removed skill file:'));
    expect(disabled.text, contains('skill-1/SKILL.md'));
  });

  test('updates share a cumulative budget across serialization and reset only on compaction', () {
    Json? state;
    var emitted = 0;
    final messages = <String>[];
    for (var generation = 0; generation < 40; generation++) {
      final update = skillContext(catalog(4 + generation, generation: generation),
        previous: state, maxTokens: 1000);
      if (update.text != null) {
        messages.add(update.text!);
        emitted += (utf8.encode(update.text!).length + 3) ~/ 4;
      }
      state = jsonObject(jsonDecode(jsonEncode(update.snapshot)));
      expect(emitted, lessThanOrEqualTo(1000));
    }
    expect(messages, hasLength(greaterThan(1)));
    expect(state!['tokens'], emitted);
    final fresh = skillContext(catalog(43, generation: 39), maxTokens: 1000);
    expect(fresh.text, isNotNull);
    expect((utf8.encode(fresh.text!).length + 3) ~/ 4, lessThanOrEqualTo(1000));
    expect(skillContext(catalog(43, generation: 39), previous: fresh.snapshot, maxTokens: 1000).text, isNull);
  });

  test('OpenCode native skill output matches executed upstream and remains outside code mode', () async {
    final fixture = jsonObject(jsonDecode(await File('test/fixtures/skills/opencode.json').readAsString()));
    final interface = const OpenCodeToolInterface();
    final runtime = interface.createRuntime(root.path, cancellation);
    addTearDown(runtime.close);
    expect(interface.definitions.where((tool) => tool.name == 'skill'), hasLength(1));
    expect(interface.hostCatalog.where((tool) => tool['name'] == 'skill'), isEmpty);
    for (final raw in fixture['cases'] as List) {
      final entry = jsonObject(raw), input = jsonObject(raw['skill']);
      var calls = 0;
      final result = await runtime.execute(ToolCall(id: 'load', name: 'skill',
        input: jsonEncode({'id': input['path']}), format: 'json'), ToolExecution(
        call: (name, arguments, {required cancellation}) async {
          calls++;
          expect(name, 'skill');
          expect(arguments, {'id': input['path']});
          return {'name': input['name'], 'content': input['content'],
            'directory': (input['path'] as String).replaceFirst('/SKILL.md', ''), 'files': entry['files']};
        }, catalog: (_) async => [], values: {}, cancellation: cancellation,
      ));
      expect(result['output'], entry['expected']);
      expect(calls, 1);
    }
    expect(skillDefinition.parameters['required'], ['id']);
  });
}
