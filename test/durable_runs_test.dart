import 'dart:convert';

import 'package:agentic_harness/agentic_harness.dart';
import 'package:agentic_harness/testing.dart';
import 'package:test/test.dart';

/// Records calls; destructive unless [readOnly].
class RecordingTool extends HarnessTool {
  RecordingTool(this.name, {this.readOnly = true});
  @override
  final String name;
  final bool readOnly;
  final List<Map<String, Object?>> calls = [];

  @override
  String get description => 'Records its input';
  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'text': {'type': 'string'},
    },
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
    calls.add(input);
    return ToolOutput.text('$name:${input['text']}');
  }
}

/// Asks two questions before answering.
class TwoQuestionTool extends HarnessTool {
  int runs = 0;
  @override
  String get name => 'survey';
  @override
  String get description => 'Asks two questions';
  @override
  Map<String, Object?> get inputSchema => const {'type': 'object'};
  @override
  ToolAnnotations get annotations => ToolAnnotations.readOnlyLocal;
  @override
  bool get replayable => true;

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    runs++;
    final name = await context.requestUserInput('Name?');
    final colour = await context.requestUserInput(
      'Colour?',
      inputType: 'choice',
      choices: ['red', 'blue'],
    );
    return ToolOutput.text('$name likes $colour');
  }
}

/// A [TwoQuestionTool] that writes, so it needs approval first.
class ApprovedSurveyTool extends TwoQuestionTool {
  @override
  ToolAnnotations get annotations => const ToolAnnotations(destructive: true);
}

/// Asks a question whose wording changes between runs.
class ChangingQuestionTool extends HarnessTool {
  ChangingQuestionTool(this.prompt);
  String prompt;
  @override
  String get name => 'confirm';
  @override
  String get description => 'Asks one question';
  @override
  Map<String, Object?> get inputSchema => const {'type': 'object'};
  @override
  ToolAnnotations get annotations => ToolAnnotations.readOnlyLocal;
  @override
  bool get replayable => true;

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async => ToolOutput.text(await context.requestUserInput(prompt));
}

AgentSpec agent(
  ModelClient model,
  List<HarnessTool> tools, {
  List<PermissionRule> rules = const [],
}) => AgentSpec(
  name: 'durable',
  instructions: 'sys',
  model: model,
  tools: tools,
  permissions: PermissionPolicy(rules: rules),
);

const interruptible = RunConfig(interruptible: true);

/// Serializes [state] the way a host would persist it.
RunState roundTrip(RunState state) => RunState.fromJson(
  jsonDecode(jsonEncode(state.toJson())) as Map<String, Object?>,
);

Future<RunResult> finish(AgentRun run) async {
  await run.events.drain<void>();
  return run.result;
}

void main() {
  test('an approval interrupts, survives JSON and resumes', () async {
    final read = RecordingTool('read');
    final write = RecordingTool('write', readOnly: false);
    final turns = [
      FakeTurn.tools([
        const FakeToolCall('a', 'read', {'text': '1'}),
        const FakeToolCall('b', 'write', {'text': '2'}),
        const FakeToolCall('c', 'read', {'text': '3'}),
      ]),
      FakeTurn.text('done'),
    ];
    final first = FakeModelClient(turns.sublist(0, 1));
    final run = const Runner().run(
      agent(first, [read, write]),
      input: AgentMessage.user('go'),
      config: interruptible,
    );
    final events = await run.events.toList();
    final result = await run.result;

    expect(result.stopReason, StopReason.interrupted);
    expect(events.whereType<ApprovalRequested>().single.toolUseId, 'b');
    final interruption = result.interruption as ApprovalInterruption;
    expect(interruption.toolName, 'write');
    expect(interruption.input, {'text': '2'});
    expect(read.calls, hasLength(1));
    expect(write.calls, isEmpty);

    // A fresh process: new model client, state from JSON.
    final saved = roundTrip(result.state!);
    expect(saved.isReady, isFalse);
    final second = FakeModelClient(turns.sublist(1));
    final resumed = const Runner().resume(
      agent(second, [read, write]),
      saved.approve(),
      config: interruptible,
    );
    final done = await finish(resumed);

    expect(done.stopReason, StopReason.endTurn);
    expect(done.finalText, 'done');
    expect(resumed.id, run.id);
    expect(done.turns, 2);
    expect(read.calls.map((c) => c['text']), ['1', '3']);
    expect(write.calls.single['text'], '2');
    expect(second.lastToolResults(0).map((r) => r.text), [
      'read:1',
      'write:2',
      'read:3',
    ]);
    // newMessages covers the whole run: call turn, results, answer.
    expect(done.newMessages, hasLength(3));
    expect(done.newMessages[1].toolResults, hasLength(3));
  });

  test('a rejected call reports the message to the model', () async {
    final write = RecordingTool('write', readOnly: false);
    final model = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('w', 'write', {'text': 'x'}),
      ]),
      FakeTurn.text('ok'),
    ]);
    final spec = agent(model, [write]);
    final first = await finish(
      const Runner().run(
        spec,
        input: AgentMessage.user('go'),
        config: interruptible,
      ),
    );
    final done = await finish(
      const Runner().resume(
        spec,
        first.state!.reject('Not today'),
        config: interruptible,
      ),
    );
    expect(write.calls, isEmpty);
    final result = model.lastToolResults(1).single;
    expect(result.isError, isTrue);
    expect(result.text, 'Not today');
    expect(done.finalText, 'ok');
  });

  test('deny rules are checked again on resume', () async {
    final write = RecordingTool('write', readOnly: false);
    final model = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('w', 'write', {'text': 'x'}),
      ]),
      FakeTurn.text('ok'),
    ]);
    final first = await finish(
      const Runner().run(
        agent(model, [write]),
        input: AgentMessage.user('go'),
        config: interruptible,
      ),
    );
    await finish(
      const Runner().resume(
        agent(
          model,
          [write],
          rules: [
            const PermissionRule(
              'write',
              PermissionBehavior.deny,
              reason: 'Writes are off',
            ),
          ],
        ),
        first.state!.approve(),
        config: interruptible,
      ),
    );
    expect(write.calls, isEmpty);
    expect(model.lastToolResults(1).single.text, 'Writes are off');
  });

  test('edited input from the approval is used', () async {
    final write = RecordingTool('write', readOnly: false);
    final model = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('w', 'write', {'text': 'x'}),
      ]),
      FakeTurn.text('ok'),
    ]);
    final spec = agent(model, [write]);
    final first = await finish(
      const Runner().run(
        spec,
        input: AgentMessage.user('go'),
        config: interruptible,
      ),
    );
    final approved = roundTrip(
      first.state!.approve(updatedInput: {'text': 'edited'}),
    );
    await finish(const Runner().resume(spec, approved, config: interruptible));
    expect(write.calls.single['text'], 'edited');
  });

  test('ask_user interrupts and the answer becomes the result', () async {
    final model = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('q', 'ask_user', {
          'question': 'Which?',
          'choices': ['A', 'B'],
        }),
      ]),
      FakeTurn.text('You chose B'),
    ]);
    final spec = agent(model, [const AskUserTool()]);
    final run = const Runner().run(
      spec,
      input: AgentMessage.user('go'),
      config: interruptible,
    );
    final events = await run.events.toList();
    final first = await run.result;
    expect(first.stopReason, StopReason.interrupted);
    expect(run.pendingUserInput, isNull);
    final question = first.interruption as InputInterruption;
    expect(question.prompt, 'Which?');
    expect(question.choices, ['A', 'B']);
    expect(
      events.whereType<UserInputRequested>().single.requestId,
      question.requestId,
    );
    expect(() => first.state!.approve(), throwsStateError);

    final done = await finish(
      const Runner().resume(
        spec,
        roundTrip(roundTrip(first.state!).answer('B')),
        config: interruptible,
      ),
    );
    expect(done.finalText, 'You chose B');
    expect(model.lastToolResults(1).single.text, 'B');
  });

  test('a replayable tool asks each question once, in order', () async {
    final survey = TwoQuestionTool();
    final model = FakeModelClient([
      FakeTurn.tools([const FakeToolCall('s', 'survey', {})]),
      FakeTurn.text('thanks'),
    ]);
    final spec = agent(model, [survey]);
    var result = await finish(
      const Runner().run(
        spec,
        input: AgentMessage.user('go'),
        config: interruptible,
      ),
    );
    expect((result.interruption as InputInterruption).prompt, 'Name?');
    result = await finish(
      const Runner().resume(
        spec,
        roundTrip(result.state!.answer('Ada')),
        config: interruptible,
      ),
    );
    final second = result.interruption as InputInterruption;
    expect(second.prompt, 'Colour?');
    expect(second.choices, ['red', 'blue']);
    result = await finish(
      const Runner().resume(
        spec,
        roundTrip(result.state!.answer('blue')),
        config: interruptible,
      ),
    );
    expect(result.finalText, 'thanks');
    expect(model.lastToolResults(1).single.text, 'Ada likes blue');
    expect(survey.runs, 3);
  });

  test('resume refuses an unanswered state or another agent', () async {
    final model = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('w', 'write', {'text': 'x'}),
      ]),
    ]);
    final write = RecordingTool('write', readOnly: false);
    final first = await finish(
      const Runner().run(
        agent(model, [write]),
        input: AgentMessage.user('go'),
        config: interruptible,
      ),
    );
    expect(
      () => const Runner().resume(agent(model, [write]), first.state!),
      throwsArgumentError,
    );
    expect(
      () => const Runner().resume(
        AgentSpec(name: 'other', instructions: '', model: model),
        first.state!.approve(),
      ),
      throwsArgumentError,
    );
  });

  test('checkpoints resume a run after a crash', () async {
    final read = RecordingTool('read');
    final checkpoints = <RunState>[];
    final model = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('a', 'read', {'text': '1'}),
      ]),
      const FakeTurn(error: NetworkError('connection lost')),
    ]);
    final crashed = await finish(
      const Runner().run(
        agent(model, [read]),
        input: AgentMessage.user('go'),
        config: RunConfig(onCheckpoint: checkpoints.add),
      ),
    );
    expect(crashed.stopReason, StopReason.error);
    expect(checkpoints, hasLength(2));
    final latest = roundTrip(checkpoints.last);
    expect(latest.interruption, isNull);
    expect(latest.isReady, isTrue);
    expect(latest.turns, 1);

    final retry = FakeModelClient([FakeTurn.text('recovered')]);
    final done = await finish(
      const Runner().resume(agent(retry, [read]), latest),
    );
    expect(done.finalText, 'recovered');
    expect(done.turns, 2);
    expect(read.calls, hasLength(1));
    // The model sees the earlier tool result.
    expect(retry.lastToolResults(0).single.text, 'read:1');
  });

  test('todos and budgets carry over', () async {
    final model = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('t', 'todo_write', {
          'todos': [
            {'content': 'Step', 'status': 'in_progress'},
          ],
        }),
        const FakeToolCall('w', 'write', {'text': 'x'}),
      ]),
      FakeTurn.text('ok'),
    ]);
    final spec = agent(model, [
      const TodoWriteTool(),
      RecordingTool('write', readOnly: false),
    ]);
    final first = await finish(
      const Runner().run(
        spec,
        input: AgentMessage.user('go'),
        config: interruptible,
      ),
    );
    final state = roundTrip(first.state!);
    expect(state.todos.single.status, TodoStatus.inProgress);
    final done = await finish(
      const Runner().resume(
        spec,
        state.approve(),
        config: const RunConfig(interruptible: true, maxTurns: 1),
      ),
    );
    // The tool turn finishes, then the turn limit (already used) applies.
    expect(done.stopReason, StopReason.maxTurns);
    expect(done.todos.single.content, 'Step');
  });

  test('malformed state is rejected', () {
    expect(() => RunState.fromJson({'version': 99}), throwsFormatException);
    expect(
      () => RunState.fromJson({'version': RunState.formatVersion}),
      throwsFormatException,
    );
  });

  test('a pending turn that does not line up is rejected', () async {
    final model = FakeModelClient([
      FakeTurn.tools([
        const FakeToolCall('w', 'write', {'text': 'x'}),
      ]),
    ]);
    final first = await finish(
      const Runner().run(
        agent(model, [RecordingTool('write', readOnly: false)]),
        input: AgentMessage.user('go'),
        config: interruptible,
      ),
    );
    final json =
        jsonDecode(jsonEncode(first.state!.toJson())) as Map<String, Object?>;
    (json['pending'] as Map)['index'] = 5;
    expect(() => RunState.fromJson(json), throwsFormatException);
  });

  group('review regressions', () {
    Future<RunResult> start(
      AgentSpec spec, {
      RunConfig config = interruptible,
    }) => finish(
      const Runner().run(spec, input: AgentMessage.user('go'), config: config),
    );

    test('answers replay even when resumed without interruptible', () async {
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('q', 'ask_user', {'question': 'Which?'}),
        ]),
        FakeTurn.text('ok'),
      ]);
      final spec = agent(model, [const AskUserTool()]);
      final first = await start(spec);
      final done = await finish(
        const Runner().resume(spec, first.state!.answer('B')),
      );
      expect(done.stopReason, StopReason.endTurn);
      expect(model.lastToolResults(1).single.text, 'B');
    });

    test('dry run applies to a resumed call', () async {
      final write = RecordingTool('write', readOnly: false);
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('w', 'write', {'text': 'x'}),
        ]),
        FakeTurn.text('ok'),
      ]);
      final spec = agent(model, [write]);
      final first = await start(spec);
      await finish(
        const Runner().resume(
          spec,
          first.state!.approve(),
          config: const RunConfig(interruptible: true, dryRun: true),
        ),
      );
      expect(write.calls, isEmpty);
      expect(model.lastToolResults(1).single.text, contains('dry-run'));
    });

    test('edited input is validated against the schema', () async {
      final write = RecordingTool('write', readOnly: false);
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('w', 'write', {'text': 'x'}),
        ]),
        FakeTurn.text('ok'),
      ]);
      final spec = agent(model, [write]);
      final first = await start(spec);
      await finish(
        const Runner().resume(
          spec,
          first.state!.approve(updatedInput: {'text': 42, 'extra': true}),
          config: interruptible,
        ),
      );
      // 42 is coerced to "42"; a non-coercible value would be rejected.
      expect(write.calls.single['text'], '42');
    });

    test('an approved call that then asks a question stays approved', () async {
      final survey = ApprovedSurveyTool();
      final model = FakeModelClient([
        FakeTurn.tools([const FakeToolCall('s', 'survey', {})]),
        FakeTurn.text('thanks'),
      ]);
      final spec = agent(model, [survey]);
      var result = await start(spec);
      expect(result.interruption, isA<ApprovalInterruption>());
      result = await finish(
        const Runner().resume(
          spec,
          roundTrip(result.state!.approve()),
          config: interruptible,
        ),
      );
      expect((result.interruption as InputInterruption).prompt, 'Name?');
      for (final answer in ['Ada', 'red']) {
        result = await finish(
          const Runner().resume(
            spec,
            roundTrip(result.state!.answer(answer)),
            config: interruptible,
          ),
        );
      }
      expect(result.finalText, 'thanks');
      expect(model.lastToolResults(1).single.text, 'Ada likes red');
    });

    test('a question cannot stand in for an approval', () async {
      final write = RecordingTool('write', readOnly: false);
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('w', 'write', {'text': 'x'}),
        ]),
        FakeTurn.text('ok'),
      ]);
      final spec = agent(model, [write]);
      final first = await start(spec);
      final json =
          jsonDecode(jsonEncode(first.state!.toJson())) as Map<String, Object?>;
      final pending = json['pending'] as Map<String, Object?>;
      pending['interruption'] = {
        ...(pending['interruption'] as Map<String, Object?>),
        'kind': 'input',
        'requestId': 'r',
        'prompt': 'p',
        'inputType': 'text',
      };
      pending['answers'] = [
        {'prompt': 'p', 'answer': 'yes'},
      ];
      pending['answered'] = true;
      await finish(
        const Runner().resume(
          spec,
          RunState.fromJson(json),
          config: interruptible,
        ),
      );
      expect(write.calls, isEmpty);
      expect(model.lastToolResults(1).single.isError, isTrue);
    });

    test('an answer is not replayed to a different question', () async {
      final tool = ChangingQuestionTool('Delete the draft?');
      final model = FakeModelClient([
        FakeTurn.tools([const FakeToolCall('c', 'confirm', {})]),
        FakeTurn.text('ok'),
      ]);
      final spec = agent(model, [tool]);
      final first = await start(spec);
      final answered = first.state!.answer('yes');
      tool.prompt = 'Delete everything?';
      final second = await finish(
        const Runner().resume(spec, answered, config: interruptible),
      );
      expect(second.stopReason, StopReason.interrupted);
      expect(
        (second.interruption as InputInterruption).prompt,
        'Delete everything?',
      );
    });

    test('a pending turn must match the transcript', () async {
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('w', 'write', {'text': 'x'}),
        ]),
      ]);
      final first = await start(
        agent(model, [RecordingTool('write', readOnly: false)]),
      );
      final json =
          jsonDecode(jsonEncode(first.state!.toJson())) as Map<String, Object?>;
      (json['messages'] as List).removeLast();
      expect(() => RunState.fromJson(json), throwsFormatException);
    });
  });
}
