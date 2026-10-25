import 'dart:io';

import 'package:agentic_harness/agentic_harness.dart';
import 'package:agentic_harness/testing.dart';

/// A small console agent with one read-only tool and one destructive tool
/// that needs permission.
///
/// Run with `dart run example/main.dart`. With `ANTHROPIC_API_KEY` or
/// `OPENAI_API_KEY` set it talks to that provider (override the model with
/// `MODEL`); otherwise a scripted [FakeModelClient] plays the model, so the
/// example runs offline.
Future<void> main() async {
  final notes = <String, String>{'groceries': 'eggs, milk', 'todo': 'call Sam'};

  final listNotes = FunctionTool(
    name: 'list_notes',
    description: 'Lists the titles of all saved notes.',
    inputSchema: const {'type': 'object', 'properties': {}},
    annotations: ToolAnnotations.readOnlyLocal,
    label: (_) => 'Listing notes',
    run: (input, context) async => ToolOutput.text(notes.keys.join(', ')),
  );

  final deleteNote = FunctionTool(
    name: 'delete_note',
    description: 'Deletes a note by title.',
    inputSchema: const {
      'type': 'object',
      'properties': {
        'title': {'type': 'string', 'description': 'Exact note title.'},
      },
      'required': ['title'],
    },
    // Destructive by default, so the permission policy asks first.
    label: (input) => 'Deleting "${input['title']}"',
    run: (input, context) async {
      final title = input['title'] as String;
      return notes.remove(title) == null
          ? ToolOutput.error('No note called "$title".')
          : ToolOutput.text('Deleted "$title".');
    },
  );

  final agent = AgentSpec(
    name: 'notes',
    instructions: 'You manage the user\'s notes. Use the tools; be brief.',
    model: _modelFromEnvironment(),
    tools: [listNotes, deleteNote],
    permissions: PermissionPolicy(
      canUseTool: (call) async {
        stdout.write('\nAllow ${call.displayLabel}? [y/N] ');
        final answer = _readLine() ?? 'y';
        stdout.writeln(answer);
        return answer.trim().toLowerCase() == 'y'
            ? const Allow()
            : const Deny();
      },
    ),
  );

  final run = const Runner().run(
    agent,
    input: AgentMessage.user('Delete my todo note, then tell me what is left.'),
    config: const RunConfig(maxTurns: 6),
  );

  await for (final event in run.events) {
    switch (event) {
      case TextDelta(:final text):
        stdout.write(text);
      case ToolCallStarted(:final displayLabel):
        stdout.writeln('[$displayLabel]');
      case ToolResultEvent(:final name, :final content, :final isError):
        stdout.writeln('[$name ${isError ? 'failed' : 'returned'}: $content]');
      default:
        break;
    }
  }

  final result = await run.result;
  stdout.writeln('\n\nStopped: ${result.stopReason.name}, ${result.usage}');
  if (result.error case final error?) stdout.writeln('Error: $error');
  await agent.model.close();
}

/// A line from the terminal, or null when there is no interactive stdin
/// (the example then approves automatically).
String? _readLine() {
  try {
    return stdin.hasTerminal ? stdin.readLineSync() : null;
  } on StdinException {
    return null;
  }
}

ModelClient _modelFromEnvironment() {
  final env = Platform.environment;
  final model = env['MODEL'];
  if (env['ANTHROPIC_API_KEY'] case final key? when key.isNotEmpty) {
    return AnthropicClient(
      AnthropicConfig(model: model ?? 'claude-sonnet-5-5', apiKey: key),
    );
  }
  if (env['OPENAI_API_KEY'] case final key? when key.isNotEmpty) {
    return OpenAiChatClient(
      OpenAiChatConfig(model: model ?? 'gpt-5-mini', apiKey: key),
    );
  }
  return FakeModelClient([
    FakeTurn.tools([const FakeToolCall('c1', 'list_notes', {})]),
    FakeTurn.tools([
      const FakeToolCall('c2', 'delete_note', {'title': 'todo'}),
    ]),
    FakeTurn.text('Deleted "todo". You still have: groceries.'),
  ]);
}
