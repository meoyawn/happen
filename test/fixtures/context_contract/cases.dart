const contextCases = <Map<String, dynamic>>[
  {'id': 'empty', 'prompt': 'Reply READY.', 'files': {}, 'contains': [], 'absent': []},
  {
    'id': 'agents-precedence', 'cwd': 'nested', 'prompt': 'Reply READY.',
    'global_instructions': 'EVAL_GLOBAL_RULE: use the fixture only.\n',
    'files': {
      'AGENTS.md': 'EVAL_SUPPRESSED_ROOT: this file is overridden.\n',
      'AGENTS.override.md': 'EVAL_ROOT_RULE: preserve the root guidance.\n',
      'nested/AGENTS.md': 'EVAL_CHILD_RULE: preserve the child guidance.\n',
      'nested/deeper/AGENTS.md': 'EVAL_DESCENDANT_RULE: not visited yet.\n',
    },
    'contains': ['EVAL_GLOBAL_RULE', 'EVAL_ROOT_RULE', 'EVAL_CHILD_RULE'],
    'absent': ['EVAL_SUPPRESSED_ROOT', 'EVAL_DESCENDANT_RULE'],
  },
  {
    'id': 'empty-override', 'prompt': 'Reply READY.',
    'files': {'AGENTS.md': 'EVAL_SUPPRESSED_RULE: never inject this.\n', 'AGENTS.override.md': ''},
    'contains': [], 'absent': ['EVAL_SUPPRESSED_RULE'],
  },
  {
    'id': 'global-skills', 'prompt': 'Reply READY without selecting a skill.', 'files': {},
    'global_skills': {'fixture-global/SKILL.md': _globalSkill},
    'catalog_skills': ['fixture-global'],
    'contains': ['fixture-global', 'Use for the isolated global-skill fixture.'],
    'absent': ['GLOBAL_FIXTURE_BODY_MUST_STAY_ON_DISK'],
  },
  {
    'id': 'skill-reading', 'workflow': 'skill',
    'prompt': 'Use fixture-skill to inspect the fixture. Read its entire SKILL.md, then reply READY. Do not change any files.',
    'global_skills': {'fixture-global/SKILL.md': _globalSkill},
    'catalog_skills': ['fixture-global', 'fixture-skill'],
    'responses': [
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'read_skill',
        'input': 'text(await tools.exec_command({cmd:"cat .agents/skills/fixture-skill/SKILL.md",login:false}));'}],
      [_ready],
    ],
    'files': {
      '.agents/skills/fixture-skill/SKILL.md': '---\nname: fixture-skill\ndescription: Use to inspect the context fixture.\n---\n'
        'EVAL_SKILL_BODY_START\nRead the complete skill before acting. The fixture value is mango-47.\nEVAL_SKILL_BODY_END\n',
      '.agents/skills/explicit-only/SKILL.md': '---\nname: explicit-only\ndescription: Do not list implicitly.\n---\nEVAL_EXPLICIT_BODY\n',
      '.agents/skills/explicit-only/agents/openai.yaml': 'policy:\n  allow_implicit_invocation: false\n',
    },
    'contains': ['fixture-skill', 'Use to inspect the context fixture.'],
    'absent': ['EVAL_SKILL_BODY_START', 'EVAL_SKILL_BODY_END', 'EVAL_EXPLICIT_BODY', '- explicit-only:', 'GLOBAL_FIXTURE_BODY_MUST_STAY_ON_DISK'],
    'result': 'EVAL_SKILL_BODY_END',
  },
  {
    'id': 'tool-search', 'workflow': 'search', 'mcp': true,
    'prompt': 'Use Dart MCP to read package:context_contract/fixture.dart. Discover its package-reading and project-roots tools first. '
      'Register this project with the MCP server, read the package URI, then reply READY. Do not change project files.',
    'responses': [
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'search_dart',
        'input': 'text(await tools.tool_search({query:"dart read_package_uris",limit:1})); '
          'text(await tools.tool_search({query:"dart roots manage project roots",limit:1}));'}],
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'register_root',
        'input': 'text(await tools.mcp__dart__roots({command:"add",uris:["{{WORK_URI}}"]}));'}],
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'read_package',
        'input': 'text(await tools.mcp__dart__read_package_uris({root:"{{WORK_URI}}",uris:["package:context_contract/fixture.dart"]}));'}],
      [_ready],
    ],
    'files': {
      'pubspec.yaml': "name: context_contract\nenvironment:\n  sdk: '>=3.13.0 <4.0.0'\n",
      'lib/fixture.dart': "const contextContractReceipt = 'REAL_DART_MCP_RECEIPT';\n",
    },
    'contains': [], 'absent': ['REAL_DART_MCP_RECEIPT'], 'result': 'REAL_DART_MCP_RECEIPT',
  },
  {
    'id': 'compaction', 'workflow': 'compaction',
    'prompt': 'Read receipt.txt using the shell, then complete the task. Preserve the repository guidance.',
    'files': {
      'receipt.txt': 'COMPACTION_TOOL_RECEIPT=mango-47\n',
      'AGENTS.md': 'COMPACTION_REPOSITORY_RULE: retain this instruction across compaction.\n',
    },
    'global_skills': {'fixture-global/SKILL.md': _globalSkill},
    'catalog_skills': ['fixture-global'],
    'responses': [
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'read_receipt',
        'input': 'text(await tools.exec_command({cmd:"cat receipt.txt",login:false}));'}],
      [_ready],
    ],
    'contains': ['COMPACTION_REPOSITORY_RULE', 'fixture-global'],
    'absent': ['COMPACTION_TOOL_RECEIPT', 'GLOBAL_FIXTURE_BODY_MUST_STAY_ON_DISK'],
  },
  {
    'id': 'resume', 'workflow': 'resume',
    'prompt': 'Remember the fixture value mango-47 and reply READY. Do not use tools.',
    'files': {'AGENTS.md': 'EVAL_RESUME_RULE: keep this guidance across turns.\n'},
    'contains': ['EVAL_RESUME_RULE'], 'absent': [],
  },
];

const _globalSkill = '---\nname: fixture-global\ndescription: Use for the isolated global-skill fixture.\n---\nGLOBAL_FIXTURE_BODY_MUST_STAY_ON_DISK\n';
const _ready = {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'READY', 'annotations': []}]};
