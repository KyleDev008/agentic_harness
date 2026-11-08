// Checks the Anthropic and OpenAI Responses clients against the real APIs.
// Skipped by default (see dart_test.yaml); run with:
//
//   ANTHROPIC_API_KEY=... OPENAI_API_KEY=... \
//     dart test -t live --run-skipped test/live/providers_live_test.dart
//
// Each provider's tests skip when its key is missing. Request formats are
// validated through the free token-counting endpoints, which accept the
// same body as a real request and reject what it would reject. Only the
// "streams" tests make a real (16-token) request.
//
// Optional: ANTHROPIC_LIVE_MODEL (default claude-haiku-5-5) and
// OPENAI_LIVE_MODEL (default gpt-5.5).
@Tags(['live'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:agentic_harness/agentic_harness.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

final _env = Platform.environment;

const _tool = ToolDefinition(
  name: 'lookup',
  description: 'Looks up a word.',
  inputSchema: {
    'type': 'object',
    'properties': {
      'word': {'type': 'string'},
    },
    'required': ['word'],
  },
);

/// Keeps only [keys] of [body]: the counting endpoints take the request's
/// content, not streaming or output settings.
Map<String, Object?> _only(Map<String, Object?> body, Set<String> keys) => {
  for (final e in body.entries)
    if (keys.contains(e.key)) e.key: e.value,
};

Future<Map<String, Object?>> _post(
  Uri uri,
  Map<String, String> headers,
  Map<String, Object?> body,
) async {
  final response = await http
      .post(
        uri,
        headers: {'content-type': 'application/json', ...headers},
        body: jsonEncode(body),
      )
      .timeout(const Duration(seconds: 60));
  expect(
    response.statusCode,
    200,
    reason: 'HTTP ${response.statusCode}: ${response.body}',
  );
  return jsonDecode(response.body) as Map<String, Object?>;
}

/// A test that needs an API key. `--run-skipped` ignores `skip:`, so the
/// missing key is checked when the test runs.
void _live(String? missing, String name, Future<void> Function() body) =>
    test(name, () async {
      if (missing != null) {
        markTestSkipped(missing);
        return;
      }
      await body();
    });

void main() {
  group('Anthropic', () {
    final key = _env['ANTHROPIC_API_KEY'];
    final model = _env['ANTHROPIC_LIVE_MODEL'] ?? 'claude-haiku-5-5';
    final skip =
        key == null || key.isEmpty ? 'ANTHROPIC_API_KEY not set' : null;

    Future<Map<String, Object?>> countTokens(AnthropicConfig config) {
      final body = AnthropicClient(config).buildBody(
        ModelRequest(
          system: 'You are terse.',
          messages: [
            AgentMessage.user('Define "harness".'),
            AgentMessage.assistant('A set of straps.'),
            AgentMessage.user('Look it up.'),
          ],
          tools: const [_tool],
          thinking: const ThinkingConfig(),
        ),
      );
      return _post(
        Uri.parse('https://api.anthropic.com/v1/messages/count_tokens'),
        {
          'x-api-key': key!,
          'anthropic-version': config.apiVersion,
          if (config.betas.isNotEmpty) 'anthropic-beta': config.betas.join(','),
        },
        _only(body, const {
          'model',
          'system',
          'messages',
          'tools',
          'tool_choice',
          'thinking',
          'context_management',
          'output_config',
        }),
      );
    }

    _live(skip, 'the request format is accepted (free)', () async {
      final out = await countTokens(
        AnthropicConfig(model: model, apiKey: key!),
      );
      expect(out['input_tokens'], isA<int>());
    });

    _live(
      skip,
      'compaction and both clearing edits share one edits array (free)',
      () async {
        final config = AnthropicConfig(
          model: model,
          apiKey: key!,
          contextManagement: const AnthropicContextManagement(
            compaction: AnthropicCompaction(),
            clearToolResults: AnthropicToolResultClearing(),
            clearThinking: AnthropicThinkingClearing(keepTurns: 1),
          ),
        );
        expect(config.betas, containsAll(['compact-2026-01-12']));
        final out = await countTokens(config);
        expect(out['input_tokens'], isA<int>());
      },
    );

    _live(skip, 'streams an answer (paid, 16 tokens)', () async {
      final client = AnthropicClient(
        AnthropicConfig(model: model, apiKey: key!),
      );
      final events =
          await client
              .stream(
                ModelRequest(
                  messages: [AgentMessage.user('Reply with the word OK.')],
                  maxOutputTokens: 16,
                ),
              )
              .toList();
      await client.close();
      expect(events.last, isA<MessageStop>());
      expect(events.whereType<UsageReport>(), isNotEmpty);
    });
  });

  group('OpenAI Responses', () {
    final key = _env['OPENAI_API_KEY'];
    final model = _env['OPENAI_LIVE_MODEL'] ?? 'gpt-5.5';
    final skip = key == null || key.isEmpty ? 'OPENAI_API_KEY not set' : null;

    _live(skip, 'the request format is accepted (free)', () async {
      final body = OpenAiResponsesClient(
        OpenAiResponsesConfig(model: model, apiKey: key!),
      ).buildBody(
        ModelRequest(
          system: 'You are terse.',
          messages: [
            AgentMessage.user('Define "harness".'),
            AgentMessage.assistant('A set of straps.'),
            AgentMessage.user('Look it up.'),
          ],
          tools: const [_tool],
          thinking: const ThinkingConfig(),
        ),
      );
      final out = await _post(
        Uri.parse('https://api.openai.com/v1/responses/input_tokens'),
        {'Authorization': 'Bearer $key'},
        _only(body, const {
          'model',
          'instructions',
          'input',
          'tools',
          'tool_choice',
          'reasoning',
          'text',
          'parallel_tool_calls',
        }),
      );
      expect(out['input_tokens'], isA<int>());
    });

    _live(skip, 'streams an answer (paid, 16 tokens)', () async {
      final client = OpenAiResponsesClient(
        OpenAiResponsesConfig(model: model, apiKey: key!),
      );
      final events =
          await client
              .stream(
                ModelRequest(
                  messages: [AgentMessage.user('Reply with the word OK.')],
                  maxOutputTokens: 16,
                ),
              )
              .toList();
      await client.close();
      expect(events.last, isA<MessageStop>());
      expect(events.whereType<UsageReport>(), isNotEmpty);
    });
  });
}
