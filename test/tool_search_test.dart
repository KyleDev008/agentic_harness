import 'dart:convert';

import 'package:agentic_harness/agentic_harness.dart';
import 'package:agentic_harness/testing.dart';
import 'package:test/test.dart';

FunctionTool tool(
  String name,
  String description, {
  Map<String, Object?> properties = const {},
  ToolAnnotations annotations = ToolAnnotations.readOnlyLocal,
}) => FunctionTool(
  name: name,
  description: description,
  inputSchema: {'type': 'object', 'properties': properties},
  annotations: annotations,
  run: (input, _) async => ToolOutput.text('$name ran'),
);

final catalogue = [
  tool(
    'get_weather',
    'Current weather and forecast for a city.',
    properties: {
      'city': {'type': 'string'},
    },
  ),
  tool('createInvoice', 'Create an invoice for a customer.'),
  tool('list_invoices', 'List invoices, newest first.'),
  tool('send_email', 'Send an email message.'),
  for (var i = 0; i < 20; i++)
    tool('misc_tool_$i', 'Does miscellaneous job $i.'),
];

AgentSpec agent(
  FakeModelClient model, {
  List<HarnessTool> tools = const [],
  PermissionPolicy permissions = PermissionPolicy.allowAll,
}) => AgentSpec(
  name: 'a',
  instructions: '',
  model: model,
  tools: tools,
  toolProviders: [DeferredTools.of(catalogue)],
  permissions: permissions,
);

void main() {
  group('ToolSearchIndex', () {
    test('ranks by name, description and parameters', () {
      final index = ToolSearchIndex(catalogue);
      expect(index.search('weather forecast').first.name, 'get_weather');
      expect(index.search('city').first.name, 'get_weather');
      // camelCase names are split.
      expect(index.search('create invoice').first.name, 'createInvoice');
      expect(
        index.search('invoices').map((t) => t.name),
        contains('list_invoices'),
      );
      expect(index.search(''), isEmpty);
      expect(index.search('zzz'), isEmpty);
      expect(index.search('job', limit: 3), hasLength(3));
    });
  });

  group('deferred tools', () {
    test('only search_tools is offered until a search loads tools', () async {
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('s', 'search_tools', {
            'query': 'weather forecast',
          }),
        ]),
        FakeTurn.tools([
          const FakeToolCall('w', 'get_weather', {'city': 'Durban'}),
        ]),
        FakeTurn.text('Sunny.'),
      ]);
      final always = tool('clock', 'The time.');
      final result =
          await const Runner()
              .run(
                agent(model, tools: [always]),
                input: AgentMessage.user('Weather in Durban?'),
              )
              .result;
      expect(result.finalText, 'Sunny.');
      final first = model.requests[0].tools.map((t) => t.name).toList();
      expect(first, ['search_tools', 'clock']);
      final search = model.requests[0].tools.first;
      expect(search.description, contains('24 more tools'));
      expect(search.description, contains('get_weather'));
      final second = model.requests[1].tools.map((t) => t.name).toList();
      expect(second.first, 'search_tools');
      expect(second, contains('get_weather'));
      expect(second.length, lessThan(10));
      expect(model.lastToolResults(2).single.text, 'get_weather ran');
      expect(model.lastToolResults(1).single.text, contains('- get_weather:'));
    });

    test('select: loads exact names; unknown names are reported', () async {
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('s', 'search_tools', {
            'query': 'select:send_email,list_invoices',
          }),
          const FakeToolCall('x', 'search_tools', {'query': 'select:nope'}),
        ]),
        FakeTurn.text('ok'),
      ]);
      await const Runner()
          .run(agent(model), input: AgentMessage.user('go'))
          .result;
      final results = model.lastToolResults(1);
      expect(results[0].text, contains('send_email'));
      expect(results[1].isError, isTrue);
      expect(
        model.requests[1].tools.map((t) => t.name),
        containsAll(['send_email', 'list_invoices']),
      );
    });

    test('calling a deferred tool by name loads it', () async {
      final model = FakeModelClient([
        FakeTurn.tools([const FakeToolCall('e', 'send_email', {})]),
        FakeTurn.text('sent'),
      ]);
      await const Runner()
          .run(agent(model), input: AgentMessage.user('go'))
          .result;
      expect(model.lastToolResults(1).single.text, 'send_email ran');
      expect(
        model.requests[1].tools.map((t) => t.name),
        contains('send_email'),
      );
    });

    test('loaded tools are capped per run', () async {
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('s', 'search_tools', {'query': 'job'}),
        ]),
        FakeTurn.text('ok'),
      ]);
      await const Runner()
          .run(
            agent(model),
            input: AgentMessage.user('go'),
            config: const RunConfig(maxLoadedTools: 2),
          )
          .result;
      // As many as fit are loaded; the rest are named.
      final result = model.lastToolResults(1).single;
      expect(result.isError, isFalse);
      expect(result.text, contains('Not loaded (the limit'));
      final offered = model.requests[1].tools.map((t) => t.name).toList();
      expect(offered.where((n) => n.startsWith('misc_tool_')), hasLength(2));
    });

    test('a deferred destructive tool still asks for approval', () async {
      final model = FakeModelClient([
        FakeTurn.tools([const FakeToolCall('d', 'drop_table', {})]),
        FakeTurn.text('ok'),
      ]);
      await const Runner()
          .run(
            AgentSpec(
              name: 'a',
              instructions: '',
              model: model,
              toolProviders: [
                DeferredTools.of([
                  tool(
                    'drop_table',
                    'Drops a table.',
                    annotations: const ToolAnnotations(destructive: true),
                  ),
                ]),
              ],
            ),
            input: AgentMessage.user('go'),
          )
          .result;
      // Standard mode with no approval handler declines it.
      expect(model.lastToolResults(1).single.isError, isTrue);
    });

    test('loaded tools survive a pause', () async {
      final write = tool(
        'write_note',
        'Writes a note.',
        annotations: const ToolAnnotations(destructive: true),
      );
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('s', 'search_tools', {'query': 'weather'}),
          const FakeToolCall('n', 'write_note', {}),
        ]),
        FakeTurn.text('done'),
      ]);
      final spec = agent(
        model,
        tools: [write],
        permissions: const PermissionPolicy(),
      );
      const config = RunConfig(interruptible: true);
      final first =
          await const Runner()
              .run(spec, input: AgentMessage.user('go'), config: config)
              .result;
      expect(first.stopReason, StopReason.interrupted);
      final saved = RunState.fromJson(
        jsonDecode(jsonEncode(first.state!.toJson())) as Map<String, Object?>,
      );
      await const Runner().resume(spec, saved.approve(), config: config).result;
      expect(
        model.requests.last.tools.map((t) => t.name),
        contains('get_weather'),
      );
    });
  });

  group('review regressions', () {
    test('search handles stop words, acronyms and other scripts', () {
      final index = ToolSearchIndex([
        tool('HTTPServerStatus', 'Checks a server.'),
        tool('envoyer_courriel', 'Envoie un courriel à un client.'),
        tool('the_tool', 'Does the thing.'),
      ]);
      expect(index.search('http server').first.name, 'HTTPServerStatus');
      expect(index.search('courriel').first.name, 'envoyer_courriel');
      // "the" alone matches nothing.
      expect(index.search('the'), isEmpty);
    });

    test('a direct call beyond the cap is refused', () async {
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('a', 'send_email', {}),
          const FakeToolCall('b', 'list_invoices', {}),
        ]),
        FakeTurn.text('ok'),
      ]);
      await const Runner()
          .run(
            agent(model),
            input: AgentMessage.user('go'),
            config: const RunConfig(maxLoadedTools: 1),
          )
          .result;
      final results = model.lastToolResults(1);
      expect(results[0].text, 'send_email ran');
      expect(results[1].isError, isTrue);
      expect(results[1].text, contains('limit of 1 loaded tools'));
    });

    test('select: names unknown tools alongside the loaded ones', () async {
      final model = FakeModelClient([
        FakeTurn.tools([
          const FakeToolCall('s', 'search_tools', {
            'query': 'select:send_email,nope',
          }),
        ]),
        FakeTurn.text('ok'),
      ]);
      await const Runner()
          .run(agent(model), input: AgentMessage.user('go'))
          .result;
      expect(
        model.lastToolResults(1).single.text,
        contains('Not found: nope.'),
      );
    });
  });
}
