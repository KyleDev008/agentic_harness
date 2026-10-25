import 'dart:convert';

import 'package:agentic_harness/agentic_harness.dart';
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A mock HTTP client returning [chunks] as a streamed body.
http.Client streaming(
  List<String> chunks, {
  int status = 200,
  String contentType = 'text/event-stream',
  void Function(http.BaseRequest request, String body)? onRequest,
  Map<String, String> headers = const {},
}) => MockClient.streaming((request, bodyStream) async {
  final body = await utf8.decodeStream(bodyStream);
  onRequest?.call(request, body);
  return http.StreamedResponse(
    Stream.fromIterable(chunks.map(utf8.encode)),
    status,
    headers: {'content-type': contentType, ...headers},
  );
});

Future<List<ModelStreamEvent>> collect(
  ModelClient client,
  ModelRequest request,
) => client.stream(request).toList();

const req = ModelRequest(
  system: 'sys',
  messages: [
    AgentMessage(role: Role.user, content: [TextBlock('hi')]),
  ],
  tools: [
    ToolDefinition(
      name: 'echo',
      description: 'Echo',
      inputSchema: {
        'type': 'object',
        'properties': {
          'text': {'type': 'string'},
        },
      },
    ),
  ],
  temperature: 0.2,
);

void main() {
  group('OpenAiChatClient', () {
    test('streams text, merges split tool-call fragments, reports usage', () async {
      Map<String, Object?>? sent;
      final client = OpenAiChatClient(
        const OpenAiChatConfig(model: 'gpt-4.1', apiKey: 'k'),
        transport: HttpTransport(
          client: streaming([
            'data: {"choices":[{"delta":{"content":"Hel"}}]}\n\n',
            'data: {"choices":[{"delta":{"content":"lo"}}]}\n',
            '\ndata: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"echo","arguments":"{\\"te"}}]}}]}\n\n',
            'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"xt\\":\\"a\\"}"}}]}}]}\n\n',
            'data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"call_2","function":{"name":"echo","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}\n\n',
            'data: {"choices":[],"usage":{"prompt_tokens":12,"completion_tokens":3,"prompt_tokens_details":{"cached_tokens":4}}}\n\n',
            'data: [DONE]\n\n',
          ], onRequest: (r, body) => sent = jsonDecode(body) as Map<String, Object?>),
        ),
      );
      final events = await collect(client, req);
      expect(
        events.whereType<TextDeltaEvent>().map((e) => e.text).join(),
        'Hello',
      );
      final ends = events.whereType<ToolUseEndEvent>().toList();
      expect(ends.map((e) => e.id), ['call_1', 'call_2']);
      expect(ends.first.input, {'text': 'a'});
      expect(events.whereType<UsageReport>().single.usage.cacheReadTokens, 4);
      expect((events.last as MessageStop).reason, ModelStopReason.toolUse);
      expect(sent!['stream_options'], {'include_usage': true});
      expect(sent!['temperature'], 0.2);
      expect((sent!['messages'] as List).first, {
        'role': 'system',
        'content': 'sys',
      });
    });

    test('reasoning models get max_completion_tokens and no temperature', () {
      final body = OpenAiChatClient(
        const OpenAiChatConfig(model: 'o4-mini'),
      ).buildBody(req.copyWith(maxOutputTokens: 100));
      expect(body.containsKey('temperature'), isFalse);
      expect(body['max_completion_tokens'], 100);
      expect(body.containsKey('max_tokens'), isFalse);
    });

    test('tool results become role:tool messages with tool_call_id', () {
      final messages = OpenAiChatClient.toOpenAiMessages(null, [
        AgentMessage.user('q'),
        const AgentMessage(
          role: Role.assistant,
          content: [
            ToolUseBlock(id: 'c1', name: 'echo', input: {'text': 'a'}),
          ],
        ),
        const AgentMessage(
          role: Role.user,
          content: [
            ToolResultBlock(toolUseId: 'c1', content: [TextBlock('out')]),
          ],
        ),
      ]);
      expect(messages[1]['tool_calls'], isNotNull);
      expect(messages[1]['content'], isNull);
      expect(messages[2], {
        'role': 'tool',
        'tool_call_id': 'c1',
        'content': 'out',
      });
    });
  });

  group('AnthropicClient', () {
    test('parses thinking (with signature), text and tool input deltas', () async {
      final client = AnthropicClient(
        const AnthropicConfig(model: 'claude-opus-5-5', apiKey: 'k'),
        transport: HttpTransport(
          client: streaming([
            'event: message_start\ndata: {"type":"message_start","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":100,"output_tokens":1}}}\n\n',
            'data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}\n',
            'data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}\n',
            'data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"SIG"}}\n',
            'data: {"type":"content_block_stop","index":0}\n',
            'data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}\n',
            'data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hi"}}\n',
            'data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_1","name":"echo","input":{}}}\n',
            'data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"text\\""}}\n',
            'data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":":\\"x\\"}"}}\n',
            'data: {"type":"content_block_stop","index":2}\n',
            'data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":20}}\n',
            'data: {"type":"message_stop"}\n',
          ]),
        ),
      );
      final events = await collect(client, req);
      final thinking = events.whereType<ThinkingCompleteEvent>().single;
      expect(thinking.text, 'hmm');
      expect(thinking.signature, 'SIG');
      expect(events.whereType<ToolUseEndEvent>().single.input, {'text': 'x'});
      final usage = events.whereType<UsageReport>().single.usage;
      expect(usage.inputTokens, 105);
      expect(usage.outputTokens, 20);
      expect(usage.cacheReadTokens, 100);
      expect((events.last as MessageStop).reason, ModelStopReason.toolUse);
    });

    test(
      'current models: no sampling params, adaptive thinking, caching, fallback',
      () {
        final body = AnthropicClient(
          const AnthropicConfig(model: 'claude-opus-5-5', apiKey: 'k'),
        ).buildBody(
          const ModelRequest(
            system: 's',
            messages: [
              AgentMessage(role: Role.user, content: [TextBlock('hi')]),
            ],
            temperature: 0.5,
            topP: 0.9,
            thinking: ThinkingConfig(),
            tools: [
              ToolDefinition(
                name: 'a',
                description: 'd',
                inputSchema: {'type': 'object'},
              ),
            ],
          ),
        );
        expect(body.containsKey('temperature'), isFalse);
        expect(body.containsKey('top_p'), isFalse);
        expect(body['thinking'], {'type': 'adaptive', 'display': 'summarized'});
        expect((body['tools'] as List).last['cache_control'], {
          'type': 'ephemeral',
        });
        expect(body['fallbacks'], 'default');
      },
    );

    test(
      'tool_choice none keeps tool definitions; redacted thinking is replayed',
      () {
        final client = AnthropicClient(
          const AnthropicConfig(model: 'claude-opus-5-5', apiKey: 'k'),
        );
        final body = client.buildBody(
          req.copyWith(toolChoice: ToolChoice.none),
        );
        expect(body['tools'], isNotEmpty);
        expect(body['tool_choice'], {'type': 'none'});
        final out = AnthropicClient.toAnthropicMessages([
          AgentMessage.user('q'),
          const AgentMessage(
            role: Role.assistant,
            content: [
              ThinkingBlock('', redactedData: 'ENC'),
              ToolUseBlock(id: 't', name: 'echo', input: {}),
            ],
          ),
          const AgentMessage(
            role: Role.user,
            content: [
              ToolResultBlock(toolUseId: 't', content: [TextBlock('r')]),
            ],
          ),
        ]);
        expect((out[1]['content'] as List).first, {
          'type': 'redacted_thinking',
          'data': 'ENC',
        });
      },
    );

    test(
      'older models get temperature but never both temperature and top_p',
      () {
        final body = AnthropicClient(
          const AnthropicConfig(model: 'claude-haiku-4-5', apiKey: 'k'),
        ).buildBody(req.copyWith());
        expect(body['temperature'], 0.2);
        expect(body.containsKey('top_p'), isFalse);
        expect(body.containsKey('fallbacks'), isFalse);
      },
    );

    test('messages: merged roles, no empty text, never ends on assistant', () {
      final out = AnthropicClient.toAnthropicMessages([
        const AgentMessage(
          role: Role.assistant,
          content: [TextBlock('orphan')],
        ),
        AgentMessage.user('a'),
        AgentMessage.user('b'),
        const AgentMessage(role: Role.assistant, content: [TextBlock('  ')]),
        const AgentMessage(role: Role.assistant, content: [TextBlock('reply')]),
      ]);
      expect(out.first['role'], 'user');
      expect((out.first['content'] as List), hasLength(2));
      expect(out.last['role'], 'user');
      expect(out[1]['content'], [
        {'type': 'text', 'text': 'reply'},
      ]);
    });
  });

  group('OllamaClient', () {
    test(
      'two tool calls in separate chunks stay distinct; think only when supported',
      () async {
        final requests = <String>[];
        final mock = MockClient.streaming((request, bodyStream) async {
          final body = await utf8.decodeStream(bodyStream);
          requests.add('${request.url.path} $body');
          if (request.url.path.endsWith('/api/show')) {
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  '{"capabilities":["completion","tools","thinking"]}',
                ),
              ),
              200,
            );
          }
          return http.StreamedResponse(
            Stream.fromIterable(
              [
                '{"message":{"thinking":"t"},"done":false}\n',
                '{"message":{"tool_calls":[{"function":{"name":"echo","arguments":{"text":"a"}}}]},"done":false}\n',
                '{"message":{"tool_calls":[{"function":{"name":"echo","arguments":{"text":"b"}}}]},"done":false}\n',
                '{"message":{"content":""},"done":true,"done_reason":"stop","prompt_eval_count":9,"eval_count":4}\n',
              ].map(utf8.encode),
            ),
            200,
            headers: {'content-type': 'application/x-ndjson'},
          );
        });
        final client = OllamaClient(
          const OllamaConfig(
            model: 'qwen3-test',
            baseUrl: 'http://h:11434/v1/',
            numCtx: 8192,
          ),
          transport: HttpTransport(client: mock),
          probeClient: mock,
        );
        final events = await collect(client, req.copyWith().copyWith());
        final ends = events.whereType<ToolUseEndEvent>().toList();
        expect(ends.map((e) => e.input), [
          {'text': 'a'},
          {'text': 'b'},
        ]);
        expect(ends[0].id, isNot(ends[1].id));
        expect(events.whereType<ThinkingDeltaEvent>().single.text, 't');
        final chat = requests.last;
        expect(chat, startsWith('/api/chat'));
        expect(chat, contains('"num_ctx":8192'));
        expect(chat, isNot(contains('"think"'))); // not requested
      },
    );

    test('normalizes base URLs', () {
      expect(
        OllamaClient.normalizeBaseUrl('https://api.ollama.com/v1/'),
        'https://ollama.com',
      );
      expect(
        OllamaClient.normalizeBaseUrl('http://h:11434/api/v1?x=1'),
        'http://h:11434',
      );
    });
  });

  group('GeminiClient', () {
    test('parses function calls and sanitizes schemas', () async {
      final client = GeminiClient(
        const GeminiConfig(model: 'gemini-x', apiKey: 'k'),
        transport: HttpTransport(
          client: streaming([
            'data: {"candidates":[{"content":{"parts":[{"text":"ok "},{"functionCall":{"name":"echo","args":{"text":"z"}}}]}}],"usageMetadata":{"promptTokenCount":3,"candidatesTokenCount":2}}\n\n',
          ]),
        ),
      );
      final events = await collect(client, req);
      expect(events.whereType<ToolUseEndEvent>().single.input, {'text': 'z'});
      expect(
        GeminiClient.sanitizeSchema({
          'type': 'object',
          'additionalProperties': false,
          'properties': {
            'tags': {'type': 'array'},
            'n': {
              'type': ['integer', 'null'],
            },
          },
        }),
        {
          'type': 'object',
          'properties': {
            'tags': {
              'type': 'array',
              'items': {'type': 'string'},
            },
            'n': {'type': 'integer', 'nullable': true},
          },
        },
      );
    });

    test('records thought signatures and provider call ids', () async {
      final client = GeminiClient(
        const GeminiConfig(model: 'gemini-x', apiKey: 'k'),
        transport: HttpTransport(
          client: streaming([
            'data: {"candidates":[{"content":{"parts":[{"functionCall":{"id":"fc1","name":"echo","args":{"text":"a"}},"thoughtSignature":"SIG_A"},{"functionCall":{"name":"echo","args":{"text":"b"}}}]}}]}\n\n',
          ]),
        ),
      );
      final events = await collect(client, req);
      final ends = events.whereType<ToolUseEndEvent>().toList();
      expect(ends.first.id, 'fc1');
      final meta =
          events.whereType<MessageMetadataEvent>().single.metadata['gemini']
              as Map;
      expect(meta['signatures'], {'fc1': 'SIG_A'});
      expect(meta['callIds'], ['fc1']);
      expect(events.last, isA<MessageStop>());
    });

    test('replays signatures exactly and bypasses calls it did not make', () {
      final client = GeminiClient(
        const GeminiConfig(model: 'gemini-x', apiKey: 'k'),
      );
      final body = client.buildBody(
        const ModelRequest(
          messages: [
            AgentMessage(role: Role.user, content: [TextBlock('go')]),
            AgentMessage(
              role: Role.assistant,
              content: [ToolUseBlock(id: 'h1', name: 'echo', input: {})],
              providerMetadata: {'hostInitiated': true},
            ),
            AgentMessage(
              role: Role.user,
              content: [
                ToolResultBlock(toolUseId: 'h1', content: [TextBlock('ok')]),
              ],
            ),
            AgentMessage(
              role: Role.assistant,
              content: [
                ToolUseBlock(id: 'fc1', name: 'echo', input: {'text': 'a'}),
                ToolUseBlock(id: 'call_x', name: 'echo', input: {'text': 'b'}),
              ],
              providerMetadata: {
                'gemini': {
                  'signatures': {'fc1': 'SIG_A'},
                  'callIds': ['fc1'],
                },
              },
            ),
            AgentMessage(
              role: Role.user,
              content: [
                ToolResultBlock(toolUseId: 'fc1', content: [TextBlock('a')]),
                ToolResultBlock(toolUseId: 'call_x', content: [TextBlock('b')]),
              ],
            ),
            AgentMessage(
              role: Role.assistant,
              content: [TextBlock('done')],
              providerMetadata: {
                'gemini': {'textSignature': 'SIG_T'},
              },
            ),
          ],
        ),
      );
      final contents = body['contents'] as List;
      List parts(int i) => (contents[i] as Map)['parts'] as List;
      expect(parts(1).single, {
        'functionCall': {'name': 'echo', 'args': {}},
        'thoughtSignature': GeminiClient.bypassSignature,
      });
      expect(parts(3), [
        {
          'functionCall': {
            'id': 'fc1',
            'name': 'echo',
            'args': {'text': 'a'},
          },
          'thoughtSignature': 'SIG_A',
        },
        {
          'functionCall': {
            'name': 'echo',
            'args': {'text': 'b'},
          },
        },
      ]);
      expect(
        (parts(4).first as Map)['functionResponse'],
        containsPair('id', 'fc1'),
      );
      expect((parts(4).last as Map)['functionResponse'], isNot(contains('id')));
      expect(parts(5).single, {'text': 'done', 'thoughtSignature': 'SIG_T'});
    });

    test('bypasses a missing or oversized signature on the first call', () {
      final client = GeminiClient(
        const GeminiConfig(model: 'gemini-x', apiKey: 'k'),
      );
      final body = client.buildBody(
        ModelRequest(
          messages: [
            const AgentMessage(role: Role.user, content: [TextBlock('go')]),
            AgentMessage(
              role: Role.assistant,
              content: const [
                ToolUseBlock(id: 'a', name: 'echo', input: {}),
                ToolUseBlock(id: 'b', name: 'echo', input: {}),
              ],
              providerMetadata: {
                'gemini': {
                  'signatures': {'b': 'x' * 70000},
                },
              },
            ),
          ],
        ),
      );
      final parts = ((body['contents'] as List)[1] as Map)['parts'] as List;
      expect(
        (parts.first as Map)['thoughtSignature'],
        GeminiClient.bypassSignature,
      );
      expect(parts.last as Map, isNot(contains('thoughtSignature')));
    });

    test('maps thinking to thinkingLevel or thinkingBudget, never both', () {
      const thinking = ModelRequest(
        messages: [
          AgentMessage(role: Role.user, content: [TextBlock('q')]),
        ],
        thinking: ThinkingConfig(budgetTokens: 2048),
      );
      Map gen(GeminiConfig config) =>
          GeminiClient(config).buildBody(thinking)['generationConfig'] as Map;
      expect(
        gen(
          const GeminiConfig(model: 'gemini-2.5-flash', apiKey: 'k'),
        )['thinkingConfig'],
        {'includeThoughts': true, 'thinkingBudget': 2048},
      );
      expect(
        gen(
          const GeminiConfig(
            model: 'gemini-3-pro',
            apiKey: 'k',
            thinkingLevel: 'low',
          ),
        )['thinkingConfig'],
        {'includeThoughts': true, 'thinkingLevel': 'low'},
      );
      expect(
        GeminiClient(
          const GeminiConfig(model: 'g', apiKey: 'k'),
        ).capabilities.structuredOutput,
        isTrue,
      );
    });
  });

  group('HttpTransport', () {
    test('retries 429 honouring retry-after, then succeeds', () async {
      var attempts = 0;
      final retries = <int>[];
      final mock = MockClient.streaming((request, body) async {
        attempts++;
        if (attempts == 1) {
          return http.StreamedResponse(
            Stream.value(utf8.encode('slow down')),
            429,
            headers: {'retry-after-ms': '10'},
          );
        }
        return http.StreamedResponse(
          Stream.value(
            utf8.encode('data: {"choices":[{"delta":{"content":"x"}}]}\n\n'),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final client = OpenAiChatClient(
        const OpenAiChatConfig(model: 'm'),
        transport: HttpTransport(client: mock),
        onRetry: (attempt, delay, error) => retries.add(delay.inMilliseconds),
      );
      final events = await collect(client, req);
      expect(attempts, 2);
      expect(retries, [10]);
      expect(events.whereType<TextDeltaEvent>().single.text, 'x');
    });

    test('auth errors are typed and not retried', () async {
      var attempts = 0;
      final mock = MockClient.streaming((request, body) async {
        attempts++;
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"error":"bad key"}')),
          401,
        );
      });
      final client = OpenAiChatClient(
        const OpenAiChatConfig(model: 'm'),
        transport: HttpTransport(client: mock),
      );
      await expectLater(collect(client, req), throwsA(isA<AuthError>()));
      expect(attempts, 1);
    });

    test('maps context overflow and overloaded statuses', () {
      expect(
        errorFromStatus(
          400,
          'This model\'s maximum context length is 8192 tokens',
          {},
        ),
        isA<ContextOverflowError>(),
      );
      expect(errorFromStatus(529, 'overloaded', {}), isA<OverloadedError>());
      expect(errorFromStatus(500, 'oops', {}), isA<ProviderError>());
      expect(errorFromStatus(500, 'oops', {}).isRetryable, isFalse);
    });
  });
}
