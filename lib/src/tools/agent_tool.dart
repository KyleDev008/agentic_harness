import '../core/message.dart';
import '../events/run_event.dart';
import '../runtime/agent_spec.dart';
import '../runtime/runner.dart';
import 'tool.dart';

/// Exposes an [AgentSpec] as a tool (a subagent).
///
/// The subagent runs with its own fresh context (only the task text the
/// parent writes), its own model, tools and permissions, and returns its
/// final answer as the tool result. Its tool activity is reported as
/// progress on the parent call; its `ask_user` questions reach the host
/// through the parent run, and cancelling the parent cancels it.
class SubagentTool extends HarnessTool {
  final AgentSpec agent;
  final RunConfig config;
  @override
  final String name;
  @override
  final String description;

  SubagentTool({
    required this.agent,
    required this.name,
    required this.description,
    this.config = const RunConfig(maxTurns: 15),
  });

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'task': {
        'type': 'string',
        'description':
            'A complete, self-contained description of the task, including '
            'all context the subagent needs — it cannot see this conversation.',
      },
    },
    'required': ['task'],
  };

  @override
  ToolAnnotations get annotations =>
      const ToolAnnotations(destructive: false, openWorld: true);

  @override
  String displayLabel(Map<String, Object?> input) =>
      'Delegating to ${agent.name}…';

  @override
  Duration? get timeout => const Duration(minutes: 15);

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final task = '${input['task'] ?? ''}'.trim();
    if (task.isEmpty) return ToolOutput.error('task must not be empty');
    final run = const Runner().run(
      agent,
      input: AgentMessage.user(task),
      config: config,
      cancel: context.cancel,
    );
    await for (final event in run.events) {
      switch (event) {
        case ToolCallStarted(:final displayLabel):
          context.progress('${agent.name}: $displayLabel');
        case UserInputRequested(
          :final requestId,
          :final prompt,
          :final inputType,
          :final choices,
          :final fields,
        ):
          final answer = await context.requestUserInput(
            prompt,
            inputType: inputType,
            choices: choices,
            fields: fields,
          );
          run.respond(requestId, answer);
        default:
          break;
      }
    }
    final result = await run.result;
    return switch (result.stopReason) {
      StopReason.endTurn => ToolOutput.text(
        result.finalText.isEmpty
            ? '(the subagent returned no text)'
            : result.finalText,
        structured: result.structuredOutput,
      ),
      StopReason.cancelled => ToolOutput.error('The subagent was cancelled.'),
      _ => ToolOutput.error(
        'The subagent stopped (${result.stopReason.name}). Partial answer: '
        '${result.finalText.isEmpty ? '(none)' : result.finalText}',
      ),
    };
  }
}
