import 'dart:math';
import 'dart:convert';

import 'package:agentic_harness/agentic_harness.dart';
import 'package:agentic_harness/testing.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';

final lookup = FunctionTool(
  name: 'lookup',
  description: 'Looks something up',
  inputSchema: const {'type': 'object'},
  annotations: ToolAnnotations.readOnlyLocal,
  run: (input, _) async => ToolOutput.text('found'),
);

/// $1 per million input tokens, $2 per million output tokens.
const cheap = ModelPricing(inputPerMillion: 1, outputPerMillion: 2);

AgentSpec agent(FakeModelClient model, {List<HarnessTool> tools = const []}) =>
    AgentSpec(
      name: 'main',
      instructions: 'sys',
      model: model,
      tools: tools,
      permissions: PermissionPolicy.allowAll,
    );

void main() {
  group('pricing', () {
    test('cache tokens are priced separately', () {
      const pricing = ModelPricing(
        inputPerMillion: 4,
        outputPerMillion: 20,
        cacheReadPerMillion: 0.2,
        cacheWritePerMillion: 5,
      );
      final cost = pricing.cost(
        const Usage(
          inputTokens: 1000000,
          outputTokens: 100000,
          cacheReadTokens: 500000,
          cacheWriteTokens: 100000,
        ),
      );
      // 400k plain × $4 + 500k × $0.20 + 100k × $5 + 100k out × $20.
      expect(cost, closeTo(1.6 + 0.1 + 0.5 + 2.0, 1e-9));
    });

    test('lookup by client id, model name and longest prefix', () {
      const table = PricingTable({
        'anthropic:claude-opus-5-5': ModelPricing(
          inputPerMillion: 1,
          outputPerMillion: 1,
        ),
        'gpt-5.5': ModelPricing(inputPerMillion: 2, outputPerMillion: 2),
        'claude-*': ModelPricing(inputPerMillion: 3, outputPerMillion: 3),
        'claude-sonnet-*': ModelPricing(
          inputPerMillion: 4,
          outputPerMillion: 4,
        ),
      });
      expect(table.forModel('anthropic:claude-opus-5-5')!.inputPerMillion, 1);
      expect(table.forModel('openai-responses:gpt-5.5')!.inputPerMillion, 2);
      expect(table.forModel('anthropic:claude-haiku-5-5')!.inputPerMillion, 3);
      expect(table.forModel('anthropic:claude-sonnet-5-5')!.inputPerMillion, 4);
      expect(table.forModel('ollama:llama4'), isNull);
    });
  });

  group('tracing', () {
    test('a run traces its model and tool calls', () async {
      final spans = InMemorySpanExporter();
      final model = FakeModelClient([
        FakeTurn.tools([const FakeToolCall('t1', 'lookup', {})]),
        FakeTurn.text('done'),
      ]);
      final run = const Runner().run(
        agent(model, tools: [lookup]),
        input: AgentMessage.user('go'),
        config: const RunConfig(
          pricing: PricingTable({'fake': cheap}),
        ).copyWithTracer(spans),
      );
      final events = await run.events.toList();
      final result = await run.result;

      final kinds = spans.spans.map((s) => s.kind).toList();
      expect(kinds, [
        SpanKind.model,
        SpanKind.tool,
        SpanKind.model,
        SpanKind.run,
      ]);
      final root = spans.spans.last;
      expect(root.parentSpanId, isNull);
      expect(root.attributes['gen_ai.agent.name'], 'main');
      expect(root.attributes['agentic_harness.run.stop_reason'], 'endTurn');
      for (final s in spans.spans.take(3)) {
        expect(s.traceId, root.traceId);
        expect(s.parentSpanId, root.spanId);
      }
      final tool = spans.spans[1];
      expect(tool.name, 'execute_tool lookup');
      expect(tool.attributes['gen_ai.tool.call.id'], 't1');
      final chat = spans.spans.first;
      expect(chat.attributes['gen_ai.operation.name'], 'chat');
      expect(chat.attributes['gen_ai.usage.input_tokens'], 10);
      expect(chat.attributes['gen_ai.response.finish_reasons'], ['toolUse']);

      // Two calls of 10 in / 5 out at $1 / $2 per million.
      expect(result.cost, closeTo(2 * (10 * 1 + 5 * 2) / 1e6, 1e-12));
      expect(events.whereType<UsageUpdated>().last.cost, result.cost);
      expect(root.attributes['agentic_harness.cost_usd'], result.cost);
    });

    test('a failed model call marks its spans', () async {
      final spans = InMemorySpanExporter();
      final model = FakeModelClient([
        const FakeTurn(error: ProviderError('boom')),
      ]);
      final result =
          await const Runner()
              .run(
                agent(model),
                input: AgentMessage.user('go'),
                config: const RunConfig().copyWithTracer(spans),
              )
              .result;
      expect(result.stopReason, StopReason.error);
      expect(result.cost, isNull);
      // Only the error class by default: provider text can echo content.
      expect(spans.spans.map((s) => s.error), ['provider', 'provider']);

      final detailed = InMemorySpanExporter();
      await const Runner()
          .run(
            agent(
              FakeModelClient([const FakeTurn(error: ProviderError('boom'))]),
            ),
            input: AgentMessage.user('go'),
            config: RunConfig(tracer: detailed, traceErrorMessages: true),
          )
          .result;
      expect(detailed.spans.first.error, 'boom');
    });

    test('only tools that start runs get telemetry', () async {
      RunTelemetry? seen;
      final spy = FunctionTool(
        name: 'spy',
        description: 'Looks at its context',
        inputSchema: const {'type': 'object'},
        annotations: ToolAnnotations.readOnlyLocal,
        run: (input, context) async {
          seen = context.telemetry;
          return ToolOutput.text('ok');
        },
      );
      await const Runner()
          .run(
            agent(
              FakeModelClient([
                FakeTurn.tools([const FakeToolCall('s', 'spy', {})]),
                FakeTurn.text('done'),
              ]),
              tools: [spy],
            ),
            input: AgentMessage.user('go'),
            config: RunConfig(tracer: InMemorySpanExporter()),
          )
          .result;
      expect(seen, isNull);
    });

    test('an approval pause is not a failed tool span', () async {
      final spans = InMemorySpanExporter();
      final survey = FunctionTool(
        name: 'write',
        description: 'Writes',
        inputSchema: const {'type': 'object'},
        run: (input, _) async => ToolOutput.text('ok'),
      );
      final result =
          await const Runner()
              .run(
                AgentSpec(
                  name: 'main',
                  instructions: '',
                  model: FakeModelClient([
                    FakeTurn.tools([const FakeToolCall('w', 'write', {})]),
                  ]),
                  tools: [survey],
                ),
                input: AgentMessage.user('go'),
                config: RunConfig(tracer: spans, interruptible: true),
              )
              .result;
      expect(result.stopReason, StopReason.interrupted);
      // The approval stops the run before the tool runs: no failed spans.
      expect(spans.spans.where((s) => s.error != null), isEmpty);
    });

    test('subagents nest under the call and add to the cost', () async {
      final spans = InMemorySpanExporter();
      final child = AgentSpec(
        name: 'helper',
        instructions: 'help',
        model: FakeModelClient([FakeTurn.text('helped')]),
      );
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('s1', 'ask_helper', {'task': 'do it'}),
        ]),
        FakeTurn.text('done'),
      ]);
      final result =
          await const Runner()
              .run(
                agent(
                  model,
                  tools: [
                    SubagentTool(
                      agent: child,
                      name: 'ask_helper',
                      description: 'Delegates',
                    ),
                  ],
                ),
                input: AgentMessage.user('go'),
                config: const RunConfig(
                  pricing: PricingTable({'fake': cheap}),
                ).copyWithTracer(spans),
              )
              .result;
      final callSpan = spans.spans.firstWhere((s) => s.kind == SpanKind.tool);
      final childRun = spans.spans.firstWhere(
        (s) => s.attributes['gen_ai.agent.name'] == 'helper',
      );
      expect(childRun.parentSpanId, callSpan.spanId);
      expect(childRun.traceId, callSpan.traceId);
      final childChat = spans.spans.firstWhere(
        (s) => s.kind == SpanKind.model && s.parentSpanId == childRun.spanId,
      );
      expect(childChat.traceId, callSpan.traceId);
      // Three model calls in all, each 10 in / 5 out.
      expect(result.cost, closeTo(3 * 20 / 1e6, 1e-12));
    });

    test('the cost budget stops the run', () async {
      final model = FakeModelClient([
        FakeTurn.tools([const FakeToolCall('t1', 'lookup', {})]),
        FakeTurn.text('never'),
      ]);
      final result =
          await const Runner()
              .run(
                agent(model, tools: [lookup]),
                input: AgentMessage.user('go'),
                config: const RunConfig(
                  pricing: PricingTable({'fake': cheap}),
                  maxCost: 1e-6,
                ),
              )
              .result;
      // Not even the first call fits, so nothing is spent.
      expect(result.stopReason, StopReason.budget);
      expect(model.requests, isEmpty);
      expect(result.cost, isNull);
    });

    test('each call is capped to what the budget can pay for', () async {
      // $1 / $2 per million: a $0.0021 budget leaves ~1000 output tokens
      // after a small prompt.
      final model = FakeModelClient([
        FakeTurn.tools([const FakeToolCall('t1', 'lookup', {})]),
        FakeTurn.text('done'),
      ]);
      final result =
          await const Runner()
              .run(
                agent(model, tools: [lookup]),
                input: AgentMessage.user('go'),
                config: const RunConfig(
                  pricing: PricingTable({'fake': cheap}),
                  maxCost: 0.0021,
                ),
              )
              .result;
      expect(result.stopReason, StopReason.endTurn);
      final first = model.requests[0].maxOutputTokens!;
      final second = model.requests[1].maxOutputTokens!;
      expect(first, inInclusiveRange(900, 1050));
      // The second call has less left: the first one's cost is deducted.
      expect(second, lessThan(first));
      expect(result.cost!, lessThanOrEqualTo(0.0021));
    });

    test('the agent\'s own output limit is kept when lower', () async {
      final model = FakeModelClient([FakeTurn.text('ok')]);
      await const Runner()
          .run(
            AgentSpec(
              name: 'main',
              instructions: '',
              model: model,
              settings: const ModelSettings(maxOutputTokens: 300),
            ),
            input: AgentMessage.user('go'),
            config: const RunConfig(
              pricing: PricingTable({'fake': cheap}),
              maxCost: 1,
            ),
          )
          .result;
      expect(model.requests.single.maxOutputTokens, 300);
    });

    test('a budget without a price refuses to run', () async {
      final model = FakeModelClient([FakeTurn.text('never')]);
      final result =
          await const Runner()
              .run(
                agent(model),
                input: AgentMessage.user('go'),
                config: const RunConfig(maxCost: 1),
              )
              .result;
      expect(result.stopReason, StopReason.budget);
      expect(result.error, isA<StateError>());
      expect(model.requests, isEmpty);
    });

    test('a subagent works within the parent\'s remaining budget', () async {
      final childModel = FakeModelClient([FakeTurn.text('helped')]);
      final child = AgentSpec(
        name: 'helper',
        instructions: 'help',
        model: childModel,
      );
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('s1', 'ask_helper', {'task': 'do it'}),
        ]),
        FakeTurn.text('done'),
      ]);
      final result =
          await const Runner()
              .run(
                agent(
                  model,
                  tools: [
                    SubagentTool(
                      agent: child,
                      name: 'ask_helper',
                      description: 'Delegates',
                    ),
                  ],
                ),
                input: AgentMessage.user('go'),
                config: const RunConfig(
                  pricing: PricingTable({'fake': cheap}),
                  maxCost: 0.0031,
                ),
              )
              .result;
      // The child's call is capped by what the parent had left after its
      // first call ($20e-6), at $2 per million output tokens.
      final childCap = childModel.requests.single.maxOutputTokens!;
      expect(childCap, lessThanOrEqualTo(((0.0031 - 20e-6) * 1e6 / 2).floor()));
      expect(result.cost!, lessThanOrEqualTo(0.0031));
    });

    test('a resumed run keeps its trace and cost', () async {
      final spans = InMemorySpanExporter();
      final write = FunctionTool(
        name: 'write',
        description: 'Writes',
        inputSchema: const {'type': 'object'},
        run: (input, _) async => ToolOutput.text('ok'),
      );
      final spec = AgentSpec(
        name: 'main',
        instructions: 'sys',
        model: FakeModelClient([
          FakeTurn.tools([const FakeToolCall('w', 'write', {})]),
          FakeTurn.text('done'),
        ]),
        tools: [write],
      );
      final config = const RunConfig(
        interruptible: true,
        pricing: PricingTable({'fake': cheap}),
      ).copyWithTracer(spans);
      final first =
          await const Runner()
              .run(spec, input: AgentMessage.user('go'), config: config)
              .result;
      final saved = RunState.fromJson(
        jsonDecode(jsonEncode(first.state!.toJson())) as Map<String, Object?>,
      );
      expect(saved.cost, closeTo(20 / 1e6, 1e-12));
      final done =
          await const Runner()
              .resume(spec, saved.approve(), config: config)
              .result;
      expect(done.cost, closeTo(40 / 1e6, 1e-12));
      expect(spans.spans.map((s) => s.traceId).toSet(), hasLength(1));
    });
  });

  group('OTLP export', () {
    test('remote collectors must use https', () {
      expect(
        () => OtlpHttpExporter(Uri.parse('http://collector.example/v1/traces')),
        throwsArgumentError,
      );
      OtlpHttpExporter(Uri.parse('http://localhost:4318/v1/traces'));
      OtlpHttpExporter(
        Uri.parse('http://collector.example/v1/traces'),
        allowInsecureHttp: true,
      );
    });

    test(
      'redirects are not followed and closed exporters drop spans',
      () async {
        final requests = <http.BaseRequest>[];
        final exporter = OtlpHttpExporter(
          Uri.parse('https://collector.example/v1/traces'),
          client: MockClient.streaming((request, body) async {
            requests.add(request);
            await body.drain<void>();
            return http.StreamedResponse(const Stream.empty(), 200);
          }),
        );
        TraceSpan span() => TraceSpan(
          traceId: newTraceId(),
          spanId: newSpanId(),
          name: 's',
          kind: SpanKind.tool,
          start: DateTime.now(),
          end: DateTime.now(),
        );
        exporter.export(span());
        await exporter.close();
        exporter.export(span());
        await exporter.flush();
        expect(requests, hasLength(1));
        expect((requests.single as http.Request).followRedirects, isFalse);
      },
    );

    test('spans are converted to OTLP JSON', () {
      final span = TraceSpan(
        traceId: newTraceId(),
        spanId: newSpanId(),
        name: 'chat x',
        kind: SpanKind.model,
        start: DateTime.utc(2026),
        end: DateTime.utc(2026, 1, 1, 0, 0, 1),
        attributes: const {
          'gen_ai.usage.input_tokens': 3,
          'agentic_harness.cost_usd': 0.5,
          'gen_ai.response.finish_reasons': ['endTurn'],
          'flag': true,
        },
        error: 'bad',
      );
      final json = toOtlpJson([span], serviceName: 'svc');
      final scope =
          ((json['resourceSpans'] as List).single as Map)['scopeSpans'] as List;
      final out = ((scope.single as Map)['spans'] as List).single as Map;
      expect(out['traceId'], hasLength(32));
      expect(out['spanId'], hasLength(16));
      expect(out['kind'], 3);
      expect(out['startTimeUnixNano'], '1767225600000000000');
      expect(out['status'], {'code': 2, 'message': 'bad'});
      expect(
        out['attributes'],
        contains(
          equals({
            'key': 'gen_ai.usage.input_tokens',
            'value': {'intValue': '3'},
          }),
        ),
      );
      expect(
        out['attributes'],
        contains(
          equals({
            'key': 'flag',
            'value': {'boolValue': true},
          }),
        ),
      );
    });

    test('the exporter batches and posts', () async {
      final posted = <Map<String, Object?>>[];
      final exporter = OtlpHttpExporter(
        Uri.parse('http://localhost:4318/v1/traces'),
        batchSize: 2,
        client: MockClient((request) async {
          posted.add(jsonDecode(request.body) as Map<String, Object?>);
          return http.Response('', 200);
        }),
      );
      TraceSpan span() => TraceSpan(
        traceId: newTraceId(),
        spanId: newSpanId(),
        name: 's',
        kind: SpanKind.tool,
        start: DateTime.now(),
        end: DateTime.now(),
      );
      exporter
        ..export(span())
        ..export(span())
        ..export(span());
      await exporter.close();
      expect(posted, hasLength(2));
      int count(Map<String, Object?> body) =>
          ((((body['resourceSpans'] as List).single as Map)['scopeSpans']
                              as List)
                          .single
                      as Map)['spans']
                  .length
              as int;
      expect(posted.map(count), [2, 1]);
    });
  });

  group('built-in prices', () {
    test('cover the main providers and id shapes', () {
      final table = PricingTable.builtIn;
      expect(table.forModel('anthropic:claude-opus-5-5')!.outputPerMillion, 20);
      expect(table.forModel('openai-responses:gpt-5.5')!.inputPerMillion, 5);
      // OpenRouter-style vendor paths and dated snapshots.
      expect(
        table.forModel('openai:anthropic/claude-sonnet-4-5')!.inputPerMillion,
        3,
      );
      expect(table.forModel('openai:gpt-4.1-2025-04-14')!.inputPerMillion, 2);
      expect(
        table.forModel('gemini:models/gemini-2.5-pro')!.inputPerMillion,
        1.25,
      );
      expect(
        table
            .forModel('gemini:gemini-3.1-pro-preview-customtools')!
            .outputPerMillion,
        12,
      );
      // Local models are free, also behind the prompted wrapper.
      expect(table.forModel('prompted(ollama:llama4)')!.outputPerMillion, 0);
      expect(table.forModel('openai:some-local-model'), isNull);
    });

    test('long prompts and announced changes are priced', () {
      final haiku = PricingTable.builtIn.forModel('claude-haiku-5-5')!;
      expect(
        haiku.cost(const Usage(inputTokens: 100000, outputTokens: 0)),
        closeTo(0.01, 1e-12),
      );
      expect(
        haiku.cost(const Usage(inputTokens: 100001, outputTokens: 0)),
        closeTo(100001 * 0.5 / 1e6, 1e-12),
      );
      final flash = PricingTable.builtIn.forModel('gemini-3.6-flash')!;
      expect(
        flash.resolve(1, at: DateTime.utc(2026, 12, 31)).inputPerMillion,
        0.75,
      );
      expect(
        flash.resolve(1, at: DateTime.utc(2027, 1, 1)).inputPerMillion,
        1.5,
      );
    });

    test('tables load from JSON and layer over the built-in one', () {
      final remote = PricingTable.fromJson(
        jsonDecode(
              jsonEncode({
                'models': {
                  'claude-opus-5-5': {'input': 3, 'output': 15},
                  'my-model': {
                    'input': 1,
                    'output': 1,
                    'longContextThreshold': 10,
                    'longContext': {'input': 2, 'output': 2},
                  },
                },
                'fallback': {'input': 50, 'output': 100},
              }),
            )
            as Map<String, Object?>,
      );
      final table = PricingTable.builtIn.withOverrides(remote);
      expect(table.forModel('claude-opus-5-5')!.inputPerMillion, 3);
      expect(table.forModel('gpt-5.5')!.inputPerMillion, 5);
      expect(table.forModel('unknown')!.inputPerMillion, 50);
      expect(table.forModel('my-model')!.resolve(11).inputPerMillion, 2);
      expect(PricingTable.fromJson(remote.toJson()).toJson(), remote.toJson());
      expect(
        () => PricingTable.fromJson({
          'models': {
            'x': {'input': -1, 'output': 1},
          },
        }),
        throwsFormatException,
      );
    });
  });

  group('budget review regressions', () {
    test('local models named like hosted ones stay free', () {
      final table = PricingTable.builtIn;
      expect(table.forModel('ollama:o3')!.outputPerMillion, 0);
      expect(table.forModel('ollama:gpt-5')!.outputPerMillion, 0);
      expect(table.forModel('openai:o3')!.outputPerMillion, 8);
      expect(table.forModel('anthropic:claude-3-5-haiku-latest'), isNotNull);
      expect(table.forModel('anthropic:claude-sonnet-4-0'), isNotNull);
    });

    test('price JSON is strict', () {
      Map<String, Object?> one(Map<String, Object?> pricing) => {
        'models': {'m': pricing},
      };
      expect(
        PricingTable.fromJson(
          one({
            'input': 1,
            'output': 1,
            'longContextThreshold': 100000.0,
            'longContext': {'input': 2, 'output': 2},
          }),
        ).forModel('m')!.longContextThreshold,
        100000,
      );
      for (final bad in [
        {'input': 1, 'output': 1, 'longContextThreshold': 10},
        {
          'input': 1,
          'output': 1,
          'nextFrom': 'soon',
          'next': {'input': 2, 'output': 2},
        },
        {'input': 1, 'output': 1, 'nextFrom': '2027-01-01'},
      ]) {
        expect(() => PricingTable.fromJson(one(bad)), throwsFormatException);
      }
      expect(
        () => PricingTable.fromJson({
          'models': {'m': 3},
        }),
        throwsFormatException,
      );
    });

    test('the prompt is priced at the dearer cache-write rate', () async {
      Future<int> cap(ModelPricing pricing) async {
        final model = FakeModelClient([FakeTurn.text('ok')]);
        await const Runner()
            .run(
              agent(model),
              input: AgentMessage.user('x' * 4000),
              config: RunConfig(
                pricing: PricingTable({'fake': pricing}),
                maxCost: 0.1,
              ),
            )
            .result;
        return model.requests.single.maxOutputTokens!;
      }

      final plain = await cap(
        const ModelPricing(inputPerMillion: 10, outputPerMillion: 10),
      );
      final cached = await cap(
        const ModelPricing(
          inputPerMillion: 10,
          outputPerMillion: 10,
          cacheWritePerMillion: 12.5,
        ),
      );
      expect(cached, lessThan(plain));
    });

    test('tools that start runs go one at a time', () async {
      var running = 0;
      var most = 0;
      final runs = <HarnessTool>[
        for (final name in ['a', 'b'])
          _RunStarter(name, () async {
            running++;
            most = max(most, running);
            await Future<void>.delayed(const Duration(milliseconds: 20));
            running--;
          }),
      ];
      await const Runner()
          .run(
            agent(
              FakeModelClient([
                FakeTurn.tools([
                  const FakeToolCall('1', 'a', {}),
                  const FakeToolCall('2', 'b', {}),
                ]),
                FakeTurn.text('done'),
              ]),
              tools: runs,
            ),
            input: AgentMessage.user('go'),
          )
          .result;
      expect(most, 1);
    });
  });

  test('the runner counts its summarizing compaction', () async {
    final model = FakeModelClient([
      FakeTurn.text('summary'),
      FakeTurn.text('answer'),
    ], capabilities: const ModelCapabilities(contextWindow: 3000));
    final result =
        await const Runner()
            .run(
              AgentSpec(name: 'main', instructions: 'sys', model: model),
              history: [
                for (var i = 0; i < 12; i++)
                  AgentMessage.user('${'word ' * 300}$i'),
              ],
              input: AgentMessage.user('hi'),
              config: const RunConfig(
                context: ContextPolicy(summarize: true, keepRecentMessages: 2),
                pricing: PricingTable({'fake': cheap}),
              ),
            )
            .result;
    expect(model.requests, hasLength(2));
    // Both the summary call and the answer are counted.
    expect(result.usage.inputTokens, 20);
    expect(result.cost, closeTo(2 * 20 / 1e6, 1e-12));
  });
}

extension on RunConfig {
  /// The same config with [tracer]; keeps the tests' configs const-friendly.
  RunConfig copyWithTracer(SpanExporter tracer) => RunConfig(
    maxTurns: maxTurns,
    interruptible: interruptible,
    pricing: pricing,
    maxCost: maxCost,
    tracer: tracer,
  );
}

/// A read-only tool that starts runs (so it would otherwise run in
/// parallel).
class _RunStarter extends HarnessTool {
  _RunStarter(this.name, this.work);
  @override
  final String name;
  final Future<void> Function() work;
  @override
  String get description => 'Starts a run';
  @override
  Map<String, Object?> get inputSchema => const {'type': 'object'};
  @override
  ToolAnnotations get annotations => ToolAnnotations.readOnlyLocal;
  @override
  bool get startsRuns => true;
  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    await work();
    return ToolOutput.text('ok');
  }
}
