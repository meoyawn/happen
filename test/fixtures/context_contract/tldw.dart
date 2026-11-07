// Derived from the supplied ebILGCoN4UU TL;DW context export and adapted for
// isolated cached-transcript replay. All shell work is real.
const tldwYoutubeCase = <String, dynamic>{
  'id': 'tldw-youtube', 'workflow': 'tldw',
  'prompt': 'Use fixture-youtube-transcript and fixture-tldw for tldw https://www.youtube.com/watch?v=ebILGCoN4UU. '
    'Read both SKILL.md files before inspecting the transcript.',
  'global_skills': {
    'fixture-youtube-transcript/SKILL.md': '---\nname: fixture-youtube-transcript\n'
      'description: Use to locate and read the isolated YouTube transcript.\n---\n'
      'TLDW_TRANSCRIPT_SKILL_START\nRead transcript.txt in the current working directory.\n'
      'If the shell truncates it, reread the timestamp range before summarizing.\nTLDW_TRANSCRIPT_SKILL_END\n',
    'fixture-tldw/SKILL.md': '---\nname: fixture-tldw\n'
      'description: Use to summarize the isolated transcript as a TL;DW.\n---\n'
      'TLDW_SUMMARY_SKILL_START\nSummarize the central claim and key supporting points.\n'
      'Use the original language of the transcript. Do not translate unless explicitly asked.\nTLDW_SUMMARY_SKILL_END\n',
  },
  'catalog_skills': ['fixture-tldw', 'fixture-youtube-transcript'],
  'files': {'AGENTS.md': 'Print the TLDW in the original language. Do not mention the language. Do not translate unless explicitly asked.\n'},
  'binary_sources': {'transcript.txt': 'transcripts/ebILGCoN4UU.txt'},
  'contains': ['Print the TLDW in the original language.', 'fixture-tldw', 'fixture-youtube-transcript'],
  'absent': ['[14:01]', 'TLDW_TRANSCRIPT_SKILL_START', 'TLDW_TRANSCRIPT_SKILL_END', 'TLDW_SUMMARY_SKILL_START', 'TLDW_SUMMARY_SKILL_END'],
  'continue_after': [0, 6], 'indexless_stream': true, 'retain_model_items': true,
  'responses': [
    [
      {'type': 'message', 'role': 'assistant', 'phase': 'commentary',
        'content': [{'type': 'output_text', 'text': 'I’ll get the transcript and summarize the main points.'}]},
    ],
    [
      {'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'tldw_read_skills',
        'input': 'const results = await Promise.allSettled(['
          'tools.exec_command({cmd:"cat \\"{{SKILLS_ROOT}}/fixture-youtube-transcript/SKILL.md\\"",max_output_tokens:2000}),'
          'tools.exec_command({cmd:"cat \\"{{SKILLS_ROOT}}/fixture-tldw/SKILL.md\\"",max_output_tokens:2000})'
          ']); for (let i=0;i<results.length;i++) text({i,...results[i]});'},
    ],
    [
      {'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'tldw_discover',
        'input': 'const results = await Promise.allSettled(['
          'tools.exec_command({cmd:"pwd",max_output_tokens:1000}),'
          'tools.exec_command({cmd:"rg --files -g AGENTS.md -g \'*transcript*\' | sort",max_output_tokens:4000})'
          ']); for (let i=0;i<results.length;i++) text({i,...results[i]}); '
          'text(ALL_TOOLS.filter(x=>/web|browse|fetch|youtube/i.test(x.name+" "+x.description))'
          '.map(x=>({name:x.name,description:x.description.slice(0,250)})).slice(0,30));'},
    ],
    [
      {'type': 'reasoning', 'encrypted_content': 'tldw-awaiting-page-details',
        'summary': [{'type': 'summary_text', 'text': '**Awaiting page details**'}]},
      {'type': 'web_search_call', 'action': {'type': 'open_page', 'url': 'https://www.youtube.com/watch?v=ebILGCoN4UU'}},
      {'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'tldw_cached_transcript',
        'input': 'text(await tools.exec_command({cmd:"rg --files -g transcript.txt",max_output_tokens:4000})); '
          'text(await tools.exec_command({cmd:"cat AGENTS.md",max_output_tokens:3000}));'},
    ],
    [
      {'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'tldw_read_transcript',
        'input': 'text(await tools.exec_command({cmd:"cat transcript.txt",max_output_tokens:4000}));'},
    ],
    [
      {'type': 'reasoning', 'encrypted_content': 'tldw-reading-missing-lines',
        'summary': [{'type': 'summary_text', 'text': '**Reading missing lines**'}]},
      {'type': 'web_search_call', 'action': {'type': 'search', 'queries': ['"ebILGCoN4UU"'], 'query': '"ebILGCoN4UU"'}},
      {'type': 'custom_tool_call', 'namespace': 'functions', 'name': 'exec', 'call_id': 'tldw_recover_transcript',
        'input': '// @exec: {"max_output_tokens": 18000}\n'
          r'''text(await tools.exec_command({cmd:"rg '^\\[(1[4-9]|2[0-9]|3[0-4]):' transcript.txt",max_output_tokens:15000}));'''},
    ],
    [
      {'type': 'reasoning', 'encrypted_content': 'tldw-checking-source-availability',
        'summary': [{'type': 'summary_text', 'text': '**Checking source availability**'}]},
      {'type': 'reasoning', 'encrypted_content': 'tldw-structuring-six-key-roles',
        'summary': [{'type': 'summary_text', 'text': '**Structuring six key roles**'}]},
    ],
    [
      {'type': 'message', 'role': 'assistant', 'phase': 'final_answer', 'content': [{'type': 'output_text',
        'text': '**TL;DW:** Theo argues that developers should spend less time debating AI coding harnesses and more time building products.'}]},
    ],
  ],
};
