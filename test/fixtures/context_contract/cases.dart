import 'fermented_beetroot.dart';
import 'tldw.dart';

const contextCases = <Map<String, dynamic>>[
  {'id': 'empty', 'prompt': 'Reply READY.', 'files': <String, Object?>{}, 'contains': <Object?>[], 'absent': <Object?>[]},
  {'id': 'interactive-user-input', 'prompt': 'Reply READY.', 'request_user_input': true,
    'files': <String, Object?>{}, 'contains': <Object?>[], 'absent': <Object?>[],
    'responses': [
      [{'type': 'function_call', 'name': 'request_user_input_async', 'call_id': 'async_question',
        'arguments': '{"questions":[{"title":"Which approach should we use?","options":["Safe","Fast"]},{"title":"Any constraints?"}]}'}],
      [_ready],
    ],
    'result': 'accepted',
  },
  {
    'id': 'streamed-continuation', 'workflow': 'continuation',
    'prompt': 'Read receipt.txt using a tool after the introductory commentary, then reply READY.',
    'files': {'receipt.txt': 'STREAMED_TOOL_RECEIPT=mango-47\n'},
    'contains': <Object?>[], 'absent': ['STREAMED_TOOL_RECEIPT'], 'continue_after': [0], 'indexless_stream': true,
    'responses': [
      [{'type': 'message', 'role': 'assistant', 'phase': 'commentary',
        'content': [{'type': 'output_text', 'text': "I'll check the requested tools."}]}],
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'streamed_receipt',
        'input': 'text(await tools.exec_command({cmd:"cat receipt.txt",login:false}));'}],
      [_ready],
    ],
    'result': 'STREAMED_TOOL_RECEIPT',
  },
  {
    'id': 'web-search', 'workflow': 'web',
    'prompt': 'google youtube to podcast tools',
    'files': <String, Object?>{}, 'contains': <Object?>[], 'absent': <Object?>[],
    'search': {
      'commands': {'search_query': [{'q': 'youtube to podcast tools'}], 'response_length': 'short'},
      'output': 'YOUTUBE_PODCAST_SEARCH_RECEIPT\nListenbox converts YouTube videos into podcast feeds.\nSource: https://listenbox.app/',
    },
    'responses': [
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'youtube_podcast_search',
        'input': 'text(await tools.web__run({search_query:[{q:"youtube to podcast tools"}],response_length:"short"}));'}],
      [
        {'type': 'message', 'role': 'assistant', 'phase': 'commentary', 'content': [{
          'type': 'output_text', 'text': 'Listenbox converts YouTube videos into podcast feeds.',
          'annotations': [{'type': 'url_citation', 'start_index': 0, 'end_index': 28,
            'url': 'https://listenbox.app/', 'title': 'Listenbox'}],
        }]},
        {'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'web_receipt',
          'input': 'text("WEB_CONTEXT_RECEIPT");'},
      ],
      [_ready],
    ],
    'result': 'YOUTUBE_PODCAST_SEARCH_RECEIPT',
  },
  fermentedBeetrootCase,
  tldwYoutubeCase,
  {
    'id': 'clock-sleep', 'workflow': 'sleep', 'prompt': 'Pause briefly using clock.sleep, then reply READY.',
    'files': <String, Object?>{}, 'contains': <Object?>[], 'absent': <Object?>[],
    'responses': [
      [{'type': 'function_call', 'namespace': 'clock', 'name': 'sleep', 'call_id': 'invalid_sleep', 'arguments': '{"duration_ms":0}'}],
      [{'type': 'function_call', 'namespace': 'clock', 'name': 'sleep', 'call_id': 'clock_sleep', 'arguments': '{"duration_ms":1}'}],
      [_ready],
    ],
    'result': 'Sleep completed.',
  },
  {
    'id': 'goal-lifecycle', 'workflow': 'goal',
    'prompt': 'Explicitly create a goal named GOAL_CONTEXT_RECEIPT with a 1000-token budget. Inspect it, mark it complete, then inspect the completed goal.',
    'messages': [
      'Explicitly create a goal named GOAL_CONTEXT_RECEIPT with a 1000-token budget. Inspect it, mark it complete, then inspect the completed goal.',
      'Read the saved completed goal without creating another goal, then reply READY.',
    ],
    'files': <String, Object?>{}, 'contains': <Object?>[], 'absent': <Object?>[],
    'responses': [
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'goal_lifecycle',
        'input': 'text(await tools.get_goal({})); '
          'text(await tools.create_goal({objective:"GOAL_CONTEXT_RECEIPT",token_budget:1000})); '
          'text(await tools.get_goal({}));'}],
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'goal_complete',
        'input': 'text(await tools.get_goal({})); text(await tools.update_goal({status:"complete"})); text(await tools.get_goal({}));'}],
      [_ready],
    ],
    'resume_responses': [
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'goal_restore', 'input': 'text(await tools.get_goal({}));'}],
      [_ready],
    ],
    'result': 'GOAL_CONTEXT_RECEIPT',
  },
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
    'contains': <Object?>[], 'absent': ['EVAL_SUPPRESSED_RULE'],
  },
  {
    'id': 'global-skills', 'prompt': 'Reply READY without selecting a skill.', 'files': <String, Object?>{},
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
    'mixed_responses': [
      [{'type': 'tool_search_call', 'execution': 'client', 'call_id': 'search_dart',
        'arguments': {'query': 'dart roots manage project roots', 'limit': 1}}],
      [{'type': 'function_call', 'namespace': 'mcp__dart', 'name': 'roots', 'call_id': 'register_root',
        'arguments': '{"command":"add","uris":["{{WORK_URI}}"]}'}],
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'search_package',
        'input': 'text(await tools.tool_search({query:"dart read_package_uris",limit:1}));'}],
      [{'type': 'function_call', 'namespace': 'mcp__dart', 'name': 'read_package_uris', 'call_id': 'read_package',
        'arguments': '{"root":"{{WORK_URI}}","uris":["package:context_contract/fixture.dart"]}'}],
      [_ready],
    ],
    'files': _dartProject,
    'contains': <Object?>[], 'absent': ['REAL_DART_MCP_RECEIPT'], 'result': 'REAL_DART_MCP_RECEIPT',
  },
  {
    'id': 'dart-evaluation-discovery', 'workflow': 'search', 'mcp': true,
    'prompt': 'Discover Dart MCP tools for evaluating an expression, Flutter driver commands, and runtime errors. '
      'Print their declarations, then reply READY. Do not connect to an app or execute any discovered runtime tool.',
    'discovery_calls': {
      'search_dart_evaluation': {'limit': 8},
      'search_vm_service': {'limit': 1, 'names': ['mcp__dart__vm_service']},
    },
    'responses': [
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'search_dart_evaluation',
        'input': '// @exec: {"max_output_tokens": 20000}\n'
          'text(await tools.tool_search({query:"+mcp__dart evaluate expression flutter driver runtime errors",limit:8}));'}],
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'search_vm_service',
        'input': 'text(await tools.tool_search({query:"dart vm_service evaluate expression",limit:1}));'}],
      [_ready],
    ],
    'mixed_responses': [
      [{'type': 'tool_search_call', 'execution': 'client', 'call_id': 'search_dart_evaluation',
        'arguments': {'query': '+mcp__dart evaluate expression flutter driver runtime errors', 'limit': 8}}],
      [{'type': 'tool_search_call', 'execution': 'client', 'call_id': 'search_vm_service',
        'arguments': {'query': 'dart vm_service evaluate expression', 'limit': 1}}],
      [_ready],
    ],
    'files': _dartProject,
    'contains': <Object?>[], 'absent': ['REAL_DART_MCP_RECEIPT'], 'result': 'vm_service',
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
    'contains': ['EVAL_RESUME_RULE'], 'absent': <Object?>[],
  },
  {
    'id': 'multi-user-compaction', 'workflow': 'compaction',
    'prompt': 'USER_ONE: retain mango-47 and reply READY.',
    'messages': [
      'USER_ONE: retain mango-47 and reply READY.',
      'USER_TWO: preserve the first instruction and reply READY.',
      'USER_THREE: retain the user-message order and reply READY.',
      'USER_FOUR: read receipt.txt using the shell, then complete the task.',
    ],
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
    'id': 'patch-and-shell', 'workflow': 'shell',
    'prompt': 'Write receipt.txt using apply_patch, read it using the shell, then reply READY.',
    'files': <String, Object?>{}, 'contains': <Object?>[], 'absent': ['PATCH_CONTEXT_RECEIPT'],
    'responses': [
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'patch_receipt',
        'input': 'text(await tools.apply_patch("*** Begin Patch\\n*** Add File: receipt.txt\\n+PATCH_CONTEXT_RECEIPT\\n*** End Patch"));'}],
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'read_patched_receipt',
        'input': 'text(await tools.exec_command({cmd:"cat receipt.txt",login:false}));'}],
      [_ready],
    ],
    'mixed_responses': [
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'apply_patch', 'call_id': 'patch_receipt',
        'input': '*** Begin Patch\n*** Add File: receipt.txt\n+PATCH_CONTEXT_RECEIPT\n*** End Patch'}],
      [{'type': 'function_call', 'namespace': 'functions', 'name': 'exec_command', 'call_id': 'read_patched_receipt',
        'arguments': '{"cmd":"cat receipt.txt","login":false}'}],
      [_ready],
    ],
    'result': 'PATCH_CONTEXT_RECEIPT',
  },
  {
    'id': 'shell-unicode-output', 'workflow': 'shell', 'prompt': 'Run the Unicode shell-output fixture.',
    'files': <String, Object?>{}, 'contains': <Object?>[], 'absent': <Object?>[],
    'responses': [
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'unicode_output',
        'input': 'text(await tools.exec_command({cmd:"printf \'AB😀CD😀EF\'",login:false,max_output_tokens:2}));'}],
      [_ready],
    ],
    'result': 'AB…2 tokens truncated…EF',
  },
  {
    'id': 'pty-output', 'workflow': 'shell', 'prompt': 'Run the shell command in a real terminal.',
    'files': <String, Object?>{}, 'contains': <Object?>[], 'absent': <Object?>[],
    'responses': [
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'pty_output',
        'input': 'text(await tools.exec_command({cmd:"test -t 0 && test -t 1 && test -t 2 && printf PTY-CONTEXT",login:false,tty:true}));'}],
      [_ready],
    ],
    'result': 'PTY-CONTEXT',
  },
  {
    'id': 'generated-image-output', 'workflow': 'image', 'prompt': 'Inspect the image and return its generated-image result.',
    'files': <String, Object?>{}, 'binary_files': {'sample.png': _png}, 'contains': <Object?>[], 'absent': <Object?>[],
    'responses': [
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'image_result',
        'input': 'const result = await tools.view_image({path:"sample.png"}); '
          'text("image-before"); generatedImage({...result,output_hint:"image-output-hint"}); text("image-after");'}],
      [_ready],
    ],
    'result': 'image-output-hint',
  },
  {
    'id': 'recorded-audio-output', 'workflow': 'audio', 'prompt': 'Forward the recorded audio as an audio result. Do not play it.',
    'files': <String, Object?>{}, 'binary_sources': {'recording.wav': 'media/jfk-excerpt.wav'}, 'contains': <Object?>[], 'absent': <Object?>[],
    'responses': [
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'audio_result',
        'input': 'const clip = await tools.exec_command({cmd:"base64 < recording.wav",login:false,max_output_tokens:20000}); '
          r'text("audio-before"); audio("data:audio/wav;base64," + clip.output.replace(/\s/g,"")); text("audio-after");'}],
      [_ready],
    ],
    'result': 'audio-after',
  },
  {
    'id': 'resumable-cells', 'workflow': 'cells', 'prompt': 'Yield, resume, and terminate real JavaScript cells.',
    'files': <String, Object?>{}, 'contains': <Object?>[], 'absent': <Object?>[],
    'responses': [
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'yield_cell',
        'input': 'export const moduleValue = 7; text({moduleValue,moduleThis:this === undefined,console:typeof console,missingTool:typeof tools.not_registered}); '
          r'text({clock:/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} UTC$/.test((await tools.clock__curr_time({})).current_time)}); '
          'text("BEFORE_WAIT"); notify("CELL_NOTICE"); yield_control(); '
          'await new Promise(resolve => setTimeout(resolve, 500)); text("AFTER_WAIT");'}],
      [{'type': 'function_call', 'name': 'wait', 'call_id': 'resume_cell',
        'arguments': '{"cell_id":"1","yield_time_ms":1000}'}],
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'terminate_cell',
        'input': 'text("BEFORE_TERMINATE"); yield_control(); '
          'await new Promise(resolve => setTimeout(resolve, 60000)); text("UNEXPECTED_AFTER_TERMINATE");'}],
      [{'type': 'function_call', 'name': 'wait', 'call_id': 'stop_cell',
        'arguments': '{"cell_id":"2","terminate":true}'}],
      [{'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'exit_cell',
        'input': 'text("BEFORE_EXIT"); try { exit(); } finally { while (true) {} } text("UNEXPECTED_AFTER_EXIT");'}],
      [{'type': 'function_call', 'name': 'wait', 'call_id': 'missing_cell', 'arguments': '{"cell_id":"3"}'}],
      [_ready],
    ],
    'result': 'AFTER_WAIT',
  },
];

const _globalSkill = '---\nname: fixture-global\ndescription: Use for the isolated global-skill fixture.\n---\nGLOBAL_FIXTURE_BODY_MUST_STAY_ON_DISK\n';
const _png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==';
const _dartProject = {
  'pubspec.yaml': "name: context_contract\nenvironment:\n  sdk: '>=3.13.0 <4.0.0'\n",
  'lib/fixture.dart': "const contextContractReceipt = 'REAL_DART_MCP_RECEIPT';\n",
};
const _ready = {'type': 'message', 'role': 'assistant', 'content': [{'type': 'output_text', 'text': 'READY', 'annotations': <Object?>[]}]};
