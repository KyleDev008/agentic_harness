import 'dart:convert';

import 'package:agentic_harness/agentic_harness.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

/// Scripted responses (SSE event lists, or a JSON body); records requests.
class ScriptedResponses {
  final List<Object> responses;
  final List<Map<String, Object?>> bodies = [];
  ScriptedResponses(this.responses);

  http.Client get client => MockClient.streaming((request, body) async {
    bodies.add(
      jsonDecode(await utf8.decodeStream(body)) as Map<String, Object?>,
    );
    final next = responses.removeAt(0);
    if (next is Map) {
      return http.StreamedResponse(
        Stream.value(utf8.encode(jsonEncode(next))),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    return http.StreamedResponse(
      Stream.fromIterable([
        for (final e in next as List)
          utf8.encode(
            'event: ${(e as Map)['type']}\ndata: ${jsonEncode(e)}\n\n',
          ),
      ]),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  });
}

Map<String, Object?> completed(String id, {String status = 'completed'}) => {
  'type': 'response.$status',
  'response': {
    'id': id,
    'status': status,
    if (status == 'incomplete')
      'incomplete_details': {'reason': 'max_output_tokens'},
    'usage': {
      'input_tokens': 100,
      'output_tokens': 20,
      'input_tokens_details': {'cached_tokens': 40},
    },
  },
};

/// Reasoning, then a function call streamed in pieces.
List<Map<String, Object?>> reasoningThenCall() => [
  {
    'type': 'response.created',
    'response': {'id': 'resp_1'},
  },
  {
    'type': 'response.output_item.added',
    'output_index': 0,
    'item': {'type': 'reasoning', 'id': 'rs_1', 'summary': []},
  },
  {
    'type': 'response.reasoning_summary_text.delta',
    'output_index': 0,
    'delta': 'Need the weather.',
  },
  {
    'type': 'response.output_item.done',
    'output_index': 0,
    'item': {
      'type': 'reasoning',
      'id': 'rs_1',
      'summary': [
        {'type': 'summary_text', 'text': 'Need the weather.'},
      ],
      'encrypted_content': 'ENC',
    },
  },
  {
    'type': 'response.output_item.added',
    'output_index': 1,
    'item': {
      'type': 'function_call',
      'id': 'fc_1',
      'call_id': 'call_1',
      'name': 'echo',
      'arguments': '',
    },
  },
  {
    'type': 'response.function_call_arguments.delta',
    'output_index': 1,
    'delta': '{"text":',
  },
  {
    'type': 'response.function_call_arguments.delta',
    'output_index': 1,
    'delta': '"Paris"}',
  },
  {
    'type': 'response.output_item.done',
    'output_index': 1,
    'item': {
      'type': 'function_call',
      'id': 'fc_1',
      'call_id': 'call_1',
      'name': 'echo',
      'arguments': '{"text":"Paris"}',
    },
  },
  completed('resp_1'),
];

List<Map<String, Object?>> textAnswer(String text, {String id = 'resp_2'}) => [
  {
    'type': 'response.output_item.added',
    'output_index': 0,
    'item': {'type': 'message', 'role': 'assistant', 'content': []},
  },
  {'type': 'response.output_text.delta', 'output_index': 0, 'delta': text},
  {
    'type': 'response.output_item.done',
    'output_index': 0,
    'item': {
      'type': 'message',
      'role': 'assistant',
      'content': [
        {'type': 'output_text', 'text': text},
      ],
    },
  },
  completed(id),
];

final echo = FunctionTool(
  name: 'echo',
  description: 'Echo',
  inputSchema: const {
    'type': 'object',
    'properties': {
      'text': {'type': 'string'},
    },
  },
  annotations: ToolAnnotations.readOnlyLocal,
  run: (input, _) async => ToolOutput.text('echo:${input['text']}'),
);

OpenAiResponsesClient client(
  ScriptedResponses api, {
  OpenAiResponsesConfig config = const OpenAiResponsesConfig(
    model: 'gpt-5.5',
    apiKey: 'k',
  ),
}) =>
    OpenAiResponsesClient(config, transport: HttpTransport(client: api.client));

void main() {
  test('streams reasoning, calls and usage', () async {
    final api = ScriptedResponses([reasoningThenCall()]);
    final events =
        await client(api)
            .stream(
              ModelRequest(
                messages: [AgentMessage.user('weather?')],
                tools: const [
                  ToolDefinition(
                    name: 'echo',
                    description: 'Echo',
                    inputSchema: {'type': 'object'},
                  ),
                ],
                thinking: const ThinkingConfig(),
              ),
            )
            .toList();
    expect(
      events.whereType<ThinkingDeltaEvent>().single.text,
      'Need the weather.',
    );
    expect(
      events.whereType<ThinkingCompleteEvent>().single.text,
      'Need the weather.',
    );
    final call = events.whereType<ToolUseEndEvent>().single;
    expect(call.id, 'call_1');
    expect(call.input, {'text': 'Paris'});
    final usage = events.whereType<UsageReport>().single.usage;
    expect(usage.inputTokens, 100);
    expect(usage.cacheReadTokens, 40);
    expect((events.last as MessageStop).reason, ModelStopReason.toolUse);
    final meta =
        events
                .whereType<MessageMetadataEvent>()
                .single
                .metadata[OpenAiResponsesClient.metadataKey]
            as Map;
    expect(meta['id'], 'resp_1');
    expect(
      (meta['items'] as List).map((i) => (i as Map)['type'] ?? i.keys.first),
      ['reasoning', 'call'],
    );

    final body = api.bodies.single;
    expect(body['store'], false);
    expect(body['include'], ['reasoning.encrypted_content']);
    expect(body['reasoning'], {'summary': 'auto'});
    expect(body.containsKey('temperature'), isFalse);
    expect((body['tools'] as List).single, {
      'type': 'function',
      'name': 'echo',
      'description': 'Echo',
      'parameters': {'type': 'object'},
      'strict': false,
    });
  });

  test('reasoning is replayed before its call on the next turn', () async {
    final api = ScriptedResponses([reasoningThenCall(), textAnswer('Sunny')]);
    final result =
        await const Runner()
            .run(
              AgentSpec(
                name: 'a',
                instructions: 'Be brief.',
                model: client(api),
                tools: [echo],
              ),
              input: AgentMessage.user('weather?'),
            )
            .result;
    expect(result.finalText, 'Sunny');
    final second = api.bodies[1];
    expect(second['instructions'], 'Be brief.');
    final input = second['input'] as List;
    expect(input.map((i) => (i as Map)['type'] ?? i['role']), [
      'user',
      'reasoning',
      'function_call',
      'function_call_output',
    ]);
    expect(input[1], {
      'type': 'reasoning',
      'id': 'rs_1',
      'summary': [
        {'type': 'summary_text', 'text': 'Need the weather.'},
      ],
      'encrypted_content': 'ENC',
    });
    expect(input[2], {
      'type': 'function_call',
      'call_id': 'call_1',
      'name': 'echo',
      'arguments': '{"text":"Paris"}',
    });
    expect(input[3], {
      'type': 'function_call_output',
      'call_id': 'call_1',
      'output': 'echo:Paris',
    });
  });

  test(
    'chained responses send previous_response_id and only new turns',
    () async {
      final api = ScriptedResponses([reasoningThenCall(), textAnswer('Sunny')]);
      await const Runner()
          .run(
            AgentSpec(
              name: 'a',
              instructions: 'sys',
              model: client(
                api,
                config: const OpenAiResponsesConfig(
                  model: 'gpt-5.5',
                  store: true,
                  chainResponses: true,
                ),
              ),
              tools: [echo],
            ),
            input: AgentMessage.user('weather?'),
          )
          .result;
      expect(api.bodies.first.containsKey('include'), isFalse);
      final second = api.bodies[1];
      expect(second['previous_response_id'], 'resp_1');
      expect((second['input'] as List).single, {
        'type': 'function_call_output',
        'call_id': 'call_1',
        'output': 'echo:Paris',
      });
    },
  );

  test('a buffered JSON response is understood', () async {
    final api = ScriptedResponses([
      {
        'id': 'resp_9',
        'status': 'completed',
        'output': [
          {
            'type': 'function_call',
            'call_id': 'c9',
            'name': 'echo',
            'arguments': '{"text":"x"}',
          },
          {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {'type': 'output_text', 'text': 'calling'},
            ],
          },
        ],
        'usage': {'input_tokens': 5, 'output_tokens': 2},
      },
    ]);
    final events =
        await client(
          api,
        ).stream(ModelRequest(messages: [AgentMessage.user('go')])).toList();
    expect(events.whereType<TextDeltaEvent>().single.text, 'calling');
    expect(events.whereType<ToolUseEndEvent>().single.input, {'text': 'x'});
    expect((events.last as MessageStop).reason, ModelStopReason.toolUse);
  });

  test('an incomplete response stops for max tokens', () async {
    final api = ScriptedResponses([
      [
        {
          'type': 'response.output_text.delta',
          'output_index': 0,
          'delta': 'Hal',
        },
        completed('r', status: 'incomplete'),
      ],
    ]);
    final events =
        await client(
          api,
        ).stream(ModelRequest(messages: [AgentMessage.user('go')])).toList();
    expect((events.last as MessageStop).reason, ModelStopReason.maxTokens);
  });

  test('failures map to typed errors', () async {
    Future<Object?> failure(Map<String, Object?> error) async {
      final api = ScriptedResponses([
        [
          {
            'type': 'response.failed',
            'response': {'id': 'r', 'error': error},
          },
        ],
      ]);
      try {
        await client(api)
            .stream(ModelRequest(messages: [AgentMessage.user('go')]))
            .drain<void>();
      } catch (e) {
        return e;
      }
      return null;
    }

    expect(
      await failure({'code': 'rate_limit_exceeded', 'message': 'slow down'}),
      isA<RateLimitError>(),
    );
    expect(
      await failure({'code': 'context_length_exceeded', 'message': 'big'}),
      isA<ContextOverflowError>(),
    );
    expect(
      await failure({'code': 'invalid_prompt', 'message': 'no'}),
      isA<ProviderError>(),
    );
  });

  test('request body for non-reasoning models and structured output', () {
    final body = OpenAiResponsesClient(
      const OpenAiResponsesConfig(model: 'gpt-4.1'),
    ).buildBody(
      ModelRequest(
        system: 'sys',
        messages: [AgentMessage.user('hi')],
        temperature: 0.3,
        maxOutputTokens: 500,
        outputSchema: const {'type': 'object'},
        cacheKey: 'conv-1',
      ),
    );
    expect(body['temperature'], 0.3);
    expect(body['max_output_tokens'], 500);
    expect(body.containsKey('include'), isFalse);
    expect(body.containsKey('reasoning'), isFalse);
    expect((body['text'] as Map)['format'], {
      'type': 'json_schema',
      'name': 'final_answer',
      'schema': {'type': 'object'},
      'strict': false,
    });
    expect(body['prompt_cache_key'], 'conv-1');
  });

  test('tool results with images and user images are converted', () {
    final input = OpenAiResponsesClient.toResponsesInput([
      AgentMessage.user(
        'look',
        images: [ImageBlock(url: Uri.parse('https://x.test/a.png'))],
      ),
      const AgentMessage(
        role: Role.assistant,
        content: [ToolUseBlock(id: 'c1', name: 'shot', input: {})],
      ),
      AgentMessage(
        role: Role.user,
        content: [
          ToolResultBlock(
            toolUseId: 'c1',
            isError: true,
            content: [
              const TextBlock('blurry'),
              ImageBlock(url: Uri.parse('https://x.test/b.png')),
            ],
          ),
        ],
      ),
    ]);
    expect(input[0], {
      'role': 'user',
      'content': [
        {'type': 'input_text', 'text': 'look'},
        {'type': 'input_image', 'image_url': 'https://x.test/a.png'},
      ],
    });
    // An assistant turn from another client still gets its calls.
    expect(input[1]['type'], 'function_call');
    expect(input[2]['output'], [
      {'type': 'input_text', 'text': 'Error: blurry'},
      {'type': 'input_image', 'image_url': 'https://x.test/b.png'},
    ]);
  });

  group('review regressions', () {
    Future<Object?> errorOf(ScriptedResponses api) async {
      try {
        await client(api)
            .stream(ModelRequest(messages: [AgentMessage.user('go')]))
            .drain<void>();
      } catch (e) {
        return e;
      }
      return null;
    }

    test('a failed buffered response is an error', () async {
      expect(
        await errorOf(
          ScriptedResponses([
            {
              'id': 'r',
              'status': 'failed',
              'error': {'code': 'rate_limit_exceeded', 'message': 'slow'},
              'output': [],
            },
          ]),
        ),
        isA<RateLimitError>(),
      );
      expect(
        await errorOf(
          ScriptedResponses([
            {'id': 'r', 'status': 'cancelled', 'output': []},
          ]),
        ),
        isA<ProviderError>(),
      );
    });

    test('a stream cut off before completion is an error', () async {
      expect(
        await errorOf(
          ScriptedResponses([
            [
              {
                'type': 'response.output_text.delta',
                'output_index': 0,
                'delta': 'Hal',
              },
            ],
          ]),
        ),
        isA<NetworkError>(),
      );
    });

    test('a top-level error event and a refusal are handled', () async {
      expect(
        await errorOf(
          ScriptedResponses([
            [
              {'type': 'error', 'code': 'server_error', 'message': 'try later'},
            ],
          ]),
        ),
        isA<OverloadedError>(),
      );
      final events =
          await client(
            ScriptedResponses([
              [
                {
                  'type': 'response.refusal.delta',
                  'output_index': 0,
                  'delta': "I can't help with that.",
                },
                completed('r'),
              ],
            ]),
          ).stream(ModelRequest(messages: [AgentMessage.user('go')])).toList();
      expect((events.last as MessageStop).reason, ModelStopReason.refusal);
    });

    test('messages keep their order around reasoning', () async {
      final api = ScriptedResponses([
        [
          {
            'type': 'response.output_text.delta',
            'output_index': 0,
            'delta': 'First. ',
          },
          {
            'type': 'response.output_item.done',
            'output_index': 1,
            'item': {
              'type': 'reasoning',
              'id': 'rs_1',
              'summary': [],
              'encrypted_content': 'E',
            },
          },
          {
            'type': 'response.output_text.delta',
            'output_index': 2,
            'delta': 'Second.',
          },
          completed('r1'),
        ],
        textAnswer('ok'),
      ]);
      final spec = AgentSpec(name: 'a', instructions: '', model: client(api));
      final first =
          await const Runner().run(spec, input: AgentMessage.user('go')).result;
      await const Runner()
          .run(
            spec,
            history: [AgentMessage.user('go'), ...first.newMessages],
            input: AgentMessage.user('again'),
          )
          .result;
      final input = api.bodies[1]['input'] as List;
      expect(
        [
          for (final i in input.skip(1).take(3))
            (i as Map)['type'] == 'message'
                ? ((i['content'] as List).single as Map)['text']
                : i['type'],
        ],
        ['First. ', 'reasoning', 'Second.'],
      );
    });

    test('unresolvable reasoning is not replayed', () {
      AgentMessage turn(Map<String, Object?> reasoning) => AgentMessage(
        role: Role.assistant,
        content: const [ToolUseBlock(id: 'c', name: 'echo', input: {})],
        providerMetadata: {
          OpenAiResponsesClient.metadataKey: {
            'items': [
              reasoning,
              {'call': 'c'},
            ],
          },
        },
      );
      final noContent = turn({'type': 'reasoning', 'id': 'rs', 'summary': []});
      expect(
        OpenAiResponsesClient.toResponsesInput([
          noContent,
        ]).map((i) => i['type']),
        ['function_call'],
      );
      // With store on, the id alone resolves.
      expect(
        OpenAiResponsesClient.toResponsesInput([
          noContent,
        ], store: true).map((i) => i['type']),
        ['reasoning', 'function_call'],
      );
      // Unknown fields from a tampered transcript are not forwarded.
      final tampered = OpenAiResponsesClient.toResponsesInput([
        turn({
          'type': 'reasoning',
          'encrypted_content': 'E',
          'summary': [
            {'type': 'evil', 'text': 'x', 'extra': 1},
            42,
          ],
          'other': 'field',
        }),
      ]);
      expect(tampered.first, {
        'type': 'reasoning',
        'summary': [
          {'type': 'summary_text', 'text': 'x'},
        ],
        'encrypted_content': 'E',
      });
      // A reasoning-only turn sends nothing.
      expect(
        OpenAiResponsesClient.toResponsesInput([
          const AgentMessage(
            role: Role.assistant,
            content: [],
            providerMetadata: {
              OpenAiResponsesClient.metadataKey: {
                'items': [
                  {
                    'type': 'reasoning',
                    'encrypted_content': 'E',
                    'summary': [],
                  },
                ],
              },
            },
          ),
        ]),
        isEmpty,
      );
    });

    test('a call named only when done is not lost', () async {
      final events =
          await client(
            ScriptedResponses([
              [
                {
                  'type': 'response.output_item.added',
                  'output_index': 0,
                  'item': {'type': 'function_call', 'call_id': 'c1'},
                },
                {
                  'type': 'response.output_item.done',
                  'output_index': 0,
                  'item': {
                    'type': 'function_call',
                    'call_id': 'c1',
                    'name': 'echo',
                    'arguments': '{}',
                  },
                },
                completed('r'),
              ],
            ]),
          ).stream(ModelRequest(messages: [AgentMessage.user('go')])).toList();
      expect(events.whereType<ToolUseEndEvent>().single.name, 'echo');
    });

    test('chaining falls back to a full resend when history changed', () async {
      const config = OpenAiResponsesConfig(
        model: 'gpt-5.5',
        store: true,
        chainResponses: true,
      );
      final api = ScriptedResponses([textAnswer('one', id: 'r1')]);
      final spec = AgentSpec(
        name: 'a',
        instructions: 'sys',
        model: client(api, config: config),
      );
      final first =
          await const Runner().run(spec, input: AgentMessage.user('hi')).result;
      final body = OpenAiResponsesClient(config);
      // Unchanged history chains.
      final chained = body.buildBody(
        ModelRequest(
          system: 'sys',
          messages: [
            AgentMessage.user('hi'),
            ...first.newMessages,
            AgentMessage.user('next'),
          ],
        ),
      );
      expect(chained['previous_response_id'], 'r1');
      expect((chained['input'] as List), hasLength(1));
      // Edited (or compacted) history does not.
      final edited = body.buildBody(
        ModelRequest(
          system: 'sys',
          messages: [
            AgentMessage.user('hi (edited)'),
            ...first.newMessages,
            AgentMessage.user('next'),
          ],
        ),
      );
      expect(edited.containsKey('previous_response_id'), isFalse);
      expect((edited['input'] as List), hasLength(3));
      // Nor does a different model, or a response made without store.
      final otherModel = OpenAiResponsesClient(
        const OpenAiResponsesConfig(
          model: 'gpt-6',
          store: true,
          chainResponses: true,
        ),
      ).buildBody(
        ModelRequest(
          system: 'sys',
          messages: [
            AgentMessage.user('hi'),
            ...first.newMessages,
            AgentMessage.user('next'),
          ],
        ),
      );
      expect(otherModel.containsKey('previous_response_id'), isFalse);
    });

    test('reasoning effort and no summary', () {
      final body = OpenAiResponsesClient(
        const OpenAiResponsesConfig(
          model: 'o4-mini',
          reasoningEffort: 'high',
          reasoningSummary: null,
        ),
      ).buildBody(
        ModelRequest(
          messages: [AgentMessage.user('hi')],
          thinking: const ThinkingConfig(),
        ),
      );
      expect(body['reasoning'], {'effort': 'high'});
    });
  });

  group('expired stored responses', () {
    const config = OpenAiResponsesConfig(
      model: 'gpt-5.5',
      store: true,
      chainResponses: true,
    );

    /// History whose last assistant turn was stored as `r1`.
    Future<List<AgentMessage>> storedHistory() async {
      final api = ScriptedResponses([textAnswer('one', id: 'r1')]);
      final first =
          await const Runner()
              .run(
                AgentSpec(
                  name: 'a',
                  instructions: 'sys',
                  model: client(api, config: config),
                ),
                input: AgentMessage.user('hi'),
              )
              .result;
      return [
        AgentMessage.user('hi'),
        ...first.newMessages,
        AgentMessage.user('next'),
      ];
    }

    Future<(List<Map<String, Object?>>, List<ModelStreamEvent>)> run(
      http.StreamedResponse Function() firstReply,
    ) async {
      final history = await storedHistory();
      final bodies = <Map<String, Object?>>[];
      final mock = MockClient.streaming((request, body) async {
        bodies.add(
          jsonDecode(await utf8.decodeStream(body)) as Map<String, Object?>,
        );
        if (bodies.length == 1) return firstReply();
        return http.StreamedResponse(
          Stream.fromIterable([
            for (final e in textAnswer('two', id: 'r2'))
              utf8.encode('data: ${jsonEncode(e)}\n\n'),
          ]),
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final events =
          await OpenAiResponsesClient(
            config,
            transport: HttpTransport(client: mock),
          ).stream(ModelRequest(system: 'sys', messages: history)).toList();
      return (bodies, events);
    }

    void expectResent(List<Map<String, Object?>> bodies) {
      expect(bodies, hasLength(2));
      expect(bodies[0]['previous_response_id'], 'r1');
      expect(bodies[1].containsKey('previous_response_id'), isFalse);
      expect(bodies[1]['input'] as List, hasLength(3));
    }

    test('a rejected previous_response_id is resent in full', () async {
      final (bodies, events) = await run(
        () => http.StreamedResponse(
          Stream.value(
            utf8.encode(
              jsonEncode({
                'error': {
                  'code': 'previous_response_not_found',
                  'message': "Previous response with id 'r1' not found.",
                },
              }),
            ),
          ),
          400,
          headers: {'content-type': 'application/json'},
        ),
      );
      expectResent(bodies);
      expect(events.whereType<TextDeltaEvent>().single.text, 'two');
    });

    test('a 404 and an in-stream failure are resent too', () async {
      final (notFound, _) = await run(
        () => http.StreamedResponse(
          Stream.value(
            utf8.encode(
              '{"error":{"message":"Response with id r1 not found"}}',
            ),
          ),
          404,
        ),
      );
      expectResent(notFound);
      final (failed, _) = await run(
        () => http.StreamedResponse(
          Stream.value(
            utf8.encode(
              'data: ${jsonEncode({
                'type': 'response.failed',
                'response': {
                  'error': {'code': 'previous_response_not_found', 'message': 'gone'},
                },
              })}\n\n',
            ),
          ),
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      );
      expectResent(failed);
    });

    test('other errors are not retried', () async {
      final history = await storedHistory();
      var calls = 0;
      final mock = MockClient.streaming((request, body) async {
        calls++;
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"error":{"message":"bad"}}')),
          400,
        );
      });
      await expectLater(
        OpenAiResponsesClient(
          config,
          transport: HttpTransport(client: mock),
        ).stream(ModelRequest(system: 'sys', messages: history)).drain<void>(),
        throwsA(isA<ProviderError>()),
      );
      expect(calls, 1);
    });
  });
}
