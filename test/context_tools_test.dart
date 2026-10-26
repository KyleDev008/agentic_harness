import 'dart:convert';
import 'dart:io';

import 'package:agentic_harness/agentic_harness.dart';
import 'package:agentic_harness/io_tools.dart';
import 'package:agentic_harness/testing.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

ToolContext ctx() => ToolContext(
  cancel: CancelToken(),
  runId: 'r',
  toolUseId: 't',
  progress: (_) {},
  requestUserInput: (prompt, {inputType = 'text', choices, fields}) async => '',
  runState: {},
);

/// Scripted SSE responses, one list of events per request; records the
/// decoded request bodies and headers.
class ScriptedAnthropic {
  final List<List<Map<String, Object?>>> responses;
  final List<Map<String, Object?>> bodies = [];
  final List<Map<String, String>> headers = [];
  ScriptedAnthropic(this.responses);

  http.Client get client => MockClient.streaming((request, body) async {
    bodies.add(
      jsonDecode(await utf8.decodeStream(body)) as Map<String, Object?>,
    );
    headers.add(request.headers);
    final events = responses.removeAt(0);
    return http.StreamedResponse(
      Stream.fromIterable([
        for (final e in events) utf8.encode('data: ${jsonEncode(e)}\n\n'),
      ]),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  });
}

List<Map<String, Object?>> textReply(String text, {int input = 10}) => [
  {
    'type': 'message_start',
    'message': {
      'usage': {'input_tokens': input, 'output_tokens': 1},
    },
  },
  {
    'type': 'content_block_start',
    'index': 0,
    'content_block': {'type': 'text', 'text': ''},
  },
  {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'text_delta', 'text': text},
  },
  {'type': 'content_block_stop', 'index': 0},
  {
    'type': 'message_delta',
    'delta': {'stop_reason': 'end_turn'},
    'usage': {'output_tokens': 4},
  },
];

/// A compaction block followed by a tool call.
List<Map<String, Object?>> compactedToolCall() => [
  {
    'type': 'message_start',
    'message': {
      'usage': {'input_tokens': 900, 'output_tokens': 1},
    },
  },
  {
    'type': 'content_block_start',
    'index': 0,
    'content_block': {'type': 'compaction'},
  },
  {
    'type': 'content_block_delta',
    'index': 0,
    'delta': {'type': 'compaction_delta', 'content': 'User wants notes.'},
  },
  {'type': 'content_block_stop', 'index': 0},
  {
    'type': 'content_block_start',
    'index': 1,
    'content_block': {
      'type': 'tool_use',
      'id': 'toolu_1',
      'name': 'memory',
      'input': {},
    },
  },
  {
    'type': 'content_block_delta',
    'index': 1,
    'delta': {
      'type': 'input_json_delta',
      'partial_json': '{"command":"view","path":"/memories"}',
    },
  },
  {'type': 'content_block_stop', 'index': 1},
  {
    'type': 'message_delta',
    'delta': {'stop_reason': 'tool_use'},
    'usage': {
      'output_tokens': 30,
      'iterations': [
        {'type': 'compaction', 'input_tokens': 180000, 'output_tokens': 3500},
        {'type': 'message', 'input_tokens': 900, 'output_tokens': 30},
      ],
    },
    'context_management': {
      'applied_edits': [
        {'type': 'clear_tool_uses_20250919', 'cleared_tool_uses': 2},
      ],
    },
  },
];

const fullConfig = AnthropicContextManagement(
  compaction: AnthropicCompaction(triggerTokens: 60000),
  clearToolResults: AnthropicToolResultClearing(
    keepToolUses: 5,
    clearAtLeastTokens: 5000,
    excludeTools: ['memory'],
  ),
  clearThinking: AnthropicThinkingClearing(keepTurns: 2),
);

void main() {
  group('Anthropic context management', () {
    test('edits are sent in order with the right betas', () async {
      final api = ScriptedAnthropic([textReply('ok')]);
      final client = AnthropicClient(
        const AnthropicConfig(
          model: 'claude-opus-5-5',
          apiKey: 'k',
          contextManagement: fullConfig,
        ),
        transport: HttpTransport(client: api.client),
      );
      expect(client.capabilities.serverCompaction, isTrue);
      await client
          .stream(
            ModelRequest(
              messages: [AgentMessage.user('hi')],
              tools: [
                ToolDefinition(
                  name: 'memory',
                  description: 'd',
                  inputSchema: MemoryTool(InMemoryMemoryStore()).inputSchema,
                  anthropicType: 'memory_20250818',
                ),
              ],
            ),
          )
          .drain<void>();
      final edits =
          (api.bodies.single['context_management'] as Map)['edits'] as List;
      expect(edits.map((e) => (e as Map)['type']), [
        'clear_thinking_20251015',
        'clear_tool_uses_20250919',
        'compact_20260112',
      ]);
      expect(edits[0], {
        'type': 'clear_thinking_20251015',
        'keep': {'type': 'thinking_turns', 'value': 2},
      });
      expect((edits[1] as Map)['exclude_tools'], ['memory']);
      expect((edits[2] as Map)['trigger'], {
        'type': 'input_tokens',
        'value': 60000,
      });
      // With tools, the summary prompt forbids tool calls.
      expect(
        (edits[2] as Map)['instructions'],
        AnthropicCompaction.textOnlyInstructions,
      );
      final betas = api.headers.single['anthropic-beta']!.split(',');
      expect(
        betas,
        containsAll([
          'compact-2026-01-12',
          'context-management-2025-06-27',
          'server-side-fallback-2026-07-01',
        ]),
      );
      // The memory tool is declared natively, with no schema.
      final tool = (api.bodies.single['tools'] as List).single as Map;
      expect(tool['type'], 'memory_20250818');
      expect(tool['name'], 'memory');
      expect(tool.containsKey('input_schema'), isFalse);
    });

    test('clearing alone sends only the context-management beta', () {
      const config = AnthropicConfig(
        model: 'claude-haiku-5-5',
        apiKey: 'k',
        contextManagement: AnthropicContextManagement(
          clearThinking: AnthropicThinkingClearing(),
        ),
      );
      expect(config.betas, ['context-management-2025-06-27']);
      final edits =
          (AnthropicClient(config).buildBody(
                    ModelRequest(messages: [AgentMessage.user('hi')]),
                  )['context_management']
                  as Map)['edits']
              as List;
      expect(edits.single, {'type': 'clear_thinking_20251015', 'keep': 'all'});
      expect(AnthropicClient(config).capabilities.serverCompaction, isFalse);
    });

    test('native tool types can be turned off', () {
      final body = AnthropicClient(
        const AnthropicConfig(
          model: 'claude-opus-5-5',
          apiKey: 'k',
          nativeToolTypes: false,
        ),
      ).buildBody(
        ModelRequest(
          messages: [AgentMessage.user('hi')],
          tools: const [
            ToolDefinition(
              name: 'memory',
              description: 'd',
              inputSchema: {'type': 'object'},
              anthropicType: 'memory_20250818',
            ),
          ],
        ),
      );
      final tool = (body['tools'] as List).single as Map;
      expect(tool.containsKey('type'), isFalse);
      expect(tool['input_schema'], {'type': 'object'});
    });

    test('a compaction is parsed, counted and replayed first', () async {
      final api = ScriptedAnthropic([compactedToolCall(), textReply('done')]);
      final client = AnthropicClient(
        const AnthropicConfig(
          model: 'claude-opus-5-5',
          apiKey: 'k',
          contextManagement: AnthropicContextManagement(
            compaction: AnthropicCompaction(),
          ),
        ),
        transport: HttpTransport(client: api.client),
      );
      final run = const Runner().run(
        AgentSpec(
          name: 'a',
          instructions: 'sys',
          model: client,
          tools: [MemoryTool(InMemoryMemoryStore())],
          permissions: PermissionPolicy.allowAll,
        ),
        history: [
          AgentMessage.user('old question'),
          AgentMessage.assistant('old answer'),
        ],
        input: AgentMessage.user('take notes'),
        config: const RunConfig(contextWindow: 1000),
      );
      final events = await run.events.toList();
      final result = await run.result;
      expect(result.finalText, 'done');

      final compacted = events.whereType<ContextCompacted>().single;
      expect(compacted.stage, 'server');
      expect(compacted.tokensBefore, 180000);
      expect(compacted.tokensAfter, 900);
      // Compaction tokens count toward the run's usage.
      expect(result.usage.inputTokens, 180000 + 900 + 10);
      expect(result.usage.outputTokens, 3500 + 30 + 4);

      // The second request starts at the compaction; older turns are gone.
      final second = api.bodies[1]['messages'] as List;
      final first = second.first as Map;
      expect(first['role'], 'assistant');
      expect((first['content'] as List).first, {
        'type': 'compaction',
        'content': 'User wants notes.',
      });
      expect(jsonEncode(second), isNot(contains('old question')));
      // The summary survives in the transcript for later runs.
      expect(
        result.newMessages.first.providerMetadata[compactionMetadataKey],
        isA<Map>(),
      );
    });

    test('the runner leaves compaction to the server', () async {
      final model = FakeModelClient(
        [FakeTurn.text('ok')],
        capabilities: const ModelCapabilities(
          contextWindow: 2000,
          serverCompaction: true,
        ),
      );
      final run = const Runner().run(
        AgentSpec(name: 'a', instructions: 'sys', model: model),
        history: [for (var i = 0; i < 20; i++) AgentMessage.user('x' * 2000)],
        input: AgentMessage.user('hi'),
      );
      final events = await run.events.toList();
      expect(events.whereType<ContextCompacted>(), isEmpty);
      expect(model.requests.single.messages, hasLength(21));
    });
  });

  group('MemoryTool', () {
    late InMemoryMemoryStore store;
    late MemoryTool tool;
    Future<ToolOutput> run(Map<String, Object?> input) =>
        tool.call(input, ctx());

    setUp(() {
      store = InMemoryMemoryStore();
      tool = MemoryTool(
        store,
        maxFiles: 3,
        maxFileChars: 200,
        maxViewChars: 40,
      );
    });

    test('create, view, edit, insert, rename and delete', () async {
      expect(
        (await run({'command': 'view', 'path': '/memories'})).text,
        startsWith("Here're the files"),
      );
      expect(
        (await run({
          'command': 'create',
          'path': '/memories/notes/todo.md',
          'file_text': 'one\ntwo\nthree',
        })).text,
        'File created successfully at: /memories/notes/todo.md',
      );
      final listing =
          (await run({'command': 'view', 'path': '/memories'})).text;
      expect(listing, contains('\t/memories/notes\n'));
      expect(listing, contains('\t/memories/notes/todo.md'));

      final file = await run({
        'command': 'view',
        'path': '/memories/notes/todo.md',
      });
      expect(
        file.text,
        "Here's the content of /memories/notes/todo.md with line numbers:\n"
        '     1\tone\n     2\ttwo\n     3\tthree',
      );
      final ranged = await run({
        'command': 'view',
        'path': '/memories/notes/todo.md',
        'view_range': [2, -1],
      });
      expect(ranged.text, endsWith('     2\ttwo\n     3\tthree'));

      final replaced = await run({
        'command': 'str_replace',
        'path': '/memories/notes/todo.md',
        'old_str': 'two',
        'new_str': 'TWO',
      });
      expect(replaced.text, startsWith('The memory file has been edited.'));
      expect(replaced.text, contains('     2\tTWO'));

      await run({
        'command': 'insert',
        'path': '/memories/notes/todo.md',
        'insert_line': 0,
        'insert_text': 'zero\n',
      });
      expect(store.files['notes/todo.md'], 'zero\none\nTWO\nthree');

      expect(
        (await run({
          'command': 'rename',
          'old_path': '/memories/notes',
          'new_path': '/memories/archive',
        })).text,
        'Successfully renamed /memories/notes to /memories/archive',
      );
      expect(store.files.keys, ['archive/todo.md']);
      expect(
        (await run({'command': 'delete', 'path': '/memories/archive'})).text,
        'Successfully deleted /memories/archive',
      );
      expect(store.files, isEmpty);
    });

    test('errors use the documented messages', () async {
      await run({
        'command': 'create',
        'path': '/memories/a.txt',
        'file_text': 'x x',
      });
      final missing = await run({'command': 'view', 'path': '/memories/b'});
      expect(missing.isError, isTrue);
      expect(
        missing.text,
        'The path /memories/b does not exist. Please provide a valid path.',
      );
      expect(
        (await run({
          'command': 'str_replace',
          'path': '/memories/a.txt',
          'old_str': 'x',
          'new_str': 'y',
        })).text,
        contains('Multiple occurrences of old_str `x` in lines: 1, 1'),
      );
      expect(
        (await run({
          'command': 'str_replace',
          'path': '/memories/a.txt',
          'old_str': 'z',
        })).text,
        contains('did not appear verbatim'),
      );
      expect(
        (await run({
          'command': 'insert',
          'path': '/memories/a.txt',
          'insert_line': 5,
          'insert_text': 'q',
        })).text,
        contains('[0, 1]'),
      );
      expect(
        (await run({'command': 'delete', 'path': '/memories'})).isError,
        isTrue,
      );
      await run({
        'command': 'create',
        'path': '/memories/b.txt',
        'file_text': '',
      });
      expect(
        (await run({
          'command': 'rename',
          'old_path': '/memories/a.txt',
          'new_path': '/memories/b.txt',
        })).text,
        'Error: The destination /memories/b.txt already exists',
      );
    });

    test('paths are confined to /memories', () async {
      for (final path in [
        '/etc/passwd',
        '/memories/../secrets.env',
        '/memories/./a',
        '/memories/.hidden',
        '/memories/%2e%2e/x',
        r'/memories/a\..\b',
        '/memoriesX/a',
        '/memories//a',
        '/memories/a:b',
        '/memories/${'a/' * 9}b',
      ]) {
        final output = await run({
          'command': 'create',
          'path': path,
          'file_text': 'x',
        });
        expect(output.isError, isTrue, reason: path);
      }
      expect(store.files, isEmpty);
    });

    test('size, count and view limits apply', () async {
      expect(
        (await run({
          'command': 'create',
          'path': '/memories/big',
          'file_text': 'x' * 201,
        })).isError,
        isTrue,
      );
      for (var i = 0; i < 3; i++) {
        await run({
          'command': 'create',
          'path': '/memories/f$i',
          'file_text': '',
        });
      }
      expect(
        (await run({
          'command': 'create',
          'path': '/memories/f3',
          'file_text': '',
        })).text,
        contains('maximum of 3 files'),
      );
      // Overwriting an existing file is allowed at the limit.
      await run({
        'command': 'create',
        'path': '/memories/f0',
        'file_text': List.generate(10, (i) => 'line $i').join('\n'),
      });
      final view = await run({'command': 'view', 'path': '/memories/f0'});
      expect(view.text, contains('[Truncated at line'));
      expect(view.text, isNot(contains('line 9')));
    });

    test('a file cannot be used as a directory', () async {
      await run({'command': 'create', 'path': '/memories/a', 'file_text': ''});
      final output = await run({
        'command': 'create',
        'path': '/memories/a/b',
        'file_text': '',
      });
      expect(output.isError, isTrue);
    });

    test('views are read-only; writes and deletes are classified', () {
      expect(tool.annotationsFor({'command': 'view'}).readOnly, isTrue);
      expect(tool.annotationsFor({'command': 'create'}).needsApproval, isFalse);
      expect(tool.annotationsFor({'command': 'delete'}).needsApproval, isTrue);
      expect(tool.anthropicType, 'memory_20250818');
    });
  });

  group('FileMemoryStore', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('memory_test'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('backs the memory tool on disk', () async {
      final tool = MemoryTool(FileMemoryStore(dir.path));
      Future<ToolOutput> run(Map<String, Object?> input) =>
          tool.call(input, ctx());
      await run({
        'command': 'create',
        'path': '/memories/p/notes.md',
        'file_text': 'hello',
      });
      expect(File('${dir.path}/p/notes.md').readAsStringSync(), 'hello');
      final listing =
          (await run({'command': 'view', 'path': '/memories'})).text;
      expect(listing, contains('/memories/p/notes.md'));
      await run({
        'command': 'str_replace',
        'path': '/memories/p/notes.md',
        'old_str': 'hello',
        'new_str': 'bye',
      });
      expect(File('${dir.path}/p/notes.md').readAsStringSync(), 'bye');
      await run({
        'command': 'rename',
        'old_path': '/memories/p',
        'new_path': '/memories/q',
      });
      expect(File('${dir.path}/q/notes.md').existsSync(), isTrue);
      await run({'command': 'delete', 'path': '/memories/q'});
      expect(dir.listSync(), isEmpty);
    });
  });

  group('review regressions', () {
    List<Map<String, Object?>> compactionOnly() => [
      {
        'type': 'message_start',
        'message': {
          'usage': {'input_tokens': 50, 'output_tokens': 1},
        },
      },
      {
        'type': 'content_block_start',
        'index': 0,
        'content_block': {'type': 'compaction', 'content': 'Short summary.'},
      },
      {'type': 'content_block_stop', 'index': 0},
      {
        'type': 'message_delta',
        'delta': {'stop_reason': 'end_turn'},
        'usage': {'output_tokens': 1},
      },
    ];

    test('a compaction-only reply is kept, not retried', () async {
      final api = ScriptedAnthropic([compactionOnly(), textReply('next')]);
      final client = AnthropicClient(
        const AnthropicConfig(
          model: 'claude-opus-5-5',
          apiKey: 'k',
          contextManagement: AnthropicContextManagement(
            compaction: AnthropicCompaction(),
          ),
        ),
        transport: HttpTransport(client: api.client),
      );
      final spec = AgentSpec(
        name: 'a',
        instructions: 'sys',
        model: client,
        tools: [MemoryTool(InMemoryMemoryStore())],
      );
      final first =
          await const Runner().run(spec, input: AgentMessage.user('go')).result;
      expect(api.bodies, hasLength(1));
      expect(first.newMessages.single.content, isEmpty);
      final second =
          await const Runner()
              .run(
                spec,
                history: [AgentMessage.user('go'), ...first.newMessages],
                input: AgentMessage.user('more'),
              )
              .result;
      expect(second.finalText, 'next');
      final sent = api.bodies[1]['messages'] as List;
      expect(((sent.first as Map)['content'] as List).single, {
        'type': 'compaction',
        'content': 'Short summary.',
      });
    });

    test('summaries are not replayed once compaction is off', () {
      final history = [
        AgentMessage.user('old'),
        const AgentMessage(
          role: Role.assistant,
          content: [TextBlock('answer')],
          providerMetadata: {
            compactionMetadataKey: {'summary': 'S', 'tokensBefore': 1},
          },
        ),
        AgentMessage.user('new'),
      ];
      final off = AnthropicClient(
        const AnthropicConfig(model: 'claude-opus-5-5', apiKey: 'k'),
      ).buildBody(ModelRequest(messages: history));
      expect(jsonEncode(off['messages']), isNot(contains('compaction')));
      expect(off['messages'] as List, hasLength(3));

      // An oversized summary is never trusted.
      final huge = AnthropicClient.toAnthropicMessages([
        AgentMessage.user('old'),
        AgentMessage(
          role: Role.assistant,
          content: const [TextBlock('answer')],
          providerMetadata: {
            compactionMetadataKey: {
              'summary': 'x' * (AnthropicClient.maxSummaryChars + 1),
            },
          },
        ),
      ], serverCompaction: true);
      expect(jsonEncode(huge), isNot(contains('"compaction"')));
    });

    test(
      'Windows device names, trailing dots and invisible characters are refused',
      () async {
        final tool = MemoryTool(InMemoryMemoryStore());
        for (final path in [
          '/memories/nul',
          '/memories/NUL.md',
          '/memories/con.txt',
          '/memories/com1',
          '/memories/notes.',
          '/memories/a\u202eb',
          '/memories/a\u200bb',
        ]) {
          final output = await tool.call({
            'command': 'create',
            'path': path,
            'file_text': 'x',
          }, ctx());
          expect(output.isError, isTrue, reason: path);
        }
      },
    );

    test('str_replace counts non-overlapping matches', () async {
      final store = InMemoryMemoryStore()..files['a'] = 'aaa';
      final output = await MemoryTool(store).call({
        'command': 'str_replace',
        'path': '/memories/a',
        'old_str': 'aa',
        'new_str': 'b',
      }, ctx());
      expect(output.isError, isFalse);
      expect(store.files['a'], 'ba');
    });

    test('commands run one at a time', () async {
      final tool = MemoryTool(InMemoryMemoryStore(), maxFiles: 1);
      final outputs = await Future.wait([
        for (var i = 0; i < 2; i++)
          tool.call({
            'command': 'create',
            'path': '/memories/f$i',
            'file_text': '',
          }, ctx()),
      ]);
      expect(outputs.where((o) => o.isError), hasLength(1));
    });

    test('askBeforeWrites makes every write need approval', () {
      final tool = MemoryTool(InMemoryMemoryStore(), askBeforeWrites: true);
      expect(tool.annotationsFor({'command': 'create'}).needsApproval, isTrue);
      expect(tool.annotationsFor({'command': 'view'}).needsApproval, isFalse);
    });

    test('a rename cannot exceed the nesting limit', () async {
      final store = InMemoryMemoryStore()..files['a/b/c/d/e'] = '';
      final output = await MemoryTool(store).call({
        'command': 'rename',
        'old_path': '/memories/a',
        'new_path': '/memories/x/y/z/w/v',
      }, ctx());
      expect(output.isError, isTrue);
      expect(store.files.keys, ['a/b/c/d/e']);
    });

    test('the file store prunes empty directories and refuses links', () async {
      final dir = Directory.systemTemp.createTempSync('memory_links');
      final outside = Directory.systemTemp.createTempSync('memory_outside');
      addTearDown(() {
        dir.deleteSync(recursive: true);
        outside.deleteSync(recursive: true);
      });
      final tool = MemoryTool(FileMemoryStore(dir.path));
      await tool.call({
        'command': 'create',
        'path': '/memories/a/b/c.md',
        'file_text': 'x',
      }, ctx());
      await tool.call({
        'command': 'delete',
        'path': '/memories/a/b/c.md',
      }, ctx());
      expect(dir.listSync(), isEmpty);

      try {
        Link('${dir.path}/link').createSync(outside.path);
      } on FileSystemException {
        markTestSkipped('cannot create links here');
        return;
      }
      final output = await tool.call({
        'command': 'create',
        'path': '/memories/link/x.md',
        'file_text': 'escaped',
      }, ctx());
      expect(output.isError, isTrue);
      expect(outside.listSync(), isEmpty);
    });
  });
}
