import '../core/cancellation.dart';
import '../core/message.dart';
import '../governance/permissions.dart';
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
///
/// With [background], the call returns at once with a task id and the
/// subagent works alongside the parent; its answer reaches the parent as a
/// message at a later turn (the parent waits for outstanding tasks before
/// it finishes). A background subagent can't ask the user questions.
/// Nesting is capped by `RunConfig.maxSubagentDepth`, concurrent
/// background tasks by `RunConfig.maxBackgroundTasks`, and the parent's
/// cost budget covers every subagent.
class SubagentTool extends HarnessTool {
  final AgentSpec agent;
  final RunConfig config;
  @override
  final String name;
  final String _description;
  final bool background;

  SubagentTool({
    required this.agent,
    required this.name,
    required String description,
    this.config = const RunConfig(maxTurns: 15),
    this.background = false,
  }) : _description = description;

  @override
  String get description =>
      background
          ? '$_description Runs in the background: the call returns a task '
              'id at once, and the answer arrives later as a message, so '
              'carry on with other work meanwhile.'
          : _description;

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
      background
          ? 'Starting ${agent.name} in the background…'
          : 'Delegating to ${agent.name}…';

  @override
  Duration? get timeout => const Duration(minutes: 15);

  @override
  bool get startsRuns => true;

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final task = '${input['task'] ?? ''}'.trim();
    if (task.isEmpty) return ToolOutput.error('task must not be empty');
    final telemetry = context.telemetry;
    if (telemetry != null && telemetry.depth + 1 > telemetry.maxDepth) {
      return ToolOutput.error(
        'Subagents are nested too deeply (at most ${telemetry.maxDepth} '
        'levels). Do this part yourself.',
      );
    }

    final start = telemetry?.startBackground;
    if (background && start != null) {
      final label = '${agent.name}: ${_short(task)}';
      try {
        final taskId = start(label, (cancel) async {
          final output = await _run(task, context, cancel, interactive: false);
          if (output.isError) throw BackgroundTaskFailure(output.text);
          return output.text;
        });
        return ToolOutput.text(
          'Started background task $taskId with ${agent.name}. Its answer '
          'will arrive as a message when it finishes; carry on meanwhile.',
          structured: {'taskId': taskId},
        );
      } on StateError catch (e) {
        return ToolOutput.error(e.message);
      }
    }
    return _run(task, context, context.cancel, interactive: true);
  }

  Future<ToolOutput> _run(
    String task,
    ToolContext context,
    CancelToken cancel, {
    required bool interactive,
  }) async {
    // Nobody can answer a background subagent's approval prompts, so they
    // are declined (its policy's "ask" becomes "deny").
    final spec =
        interactive
            ? agent
            : agent.copyWith(
              permissions: PermissionPolicy(
                mode: agent.permissions.mode,
                rules: agent.permissions.rules,
              ),
            );
    final run = const Runner().run(
      spec,
      input: AgentMessage.user(task),
      config: config,
      cancel: cancel,
      telemetry: context.telemetry,
    );
    await for (final event in run.events) {
      switch (event) {
        case ToolCallStarted(:final displayLabel) when interactive:
          context.progress('${agent.name}: $displayLabel');
        case UserInputRequested(
          :final requestId,
          :final prompt,
          :final inputType,
          :final choices,
          :final fields,
        ):
          final answer =
              interactive
                  ? await context.requestUserInput(
                    prompt,
                    inputType: inputType,
                    choices: choices,
                    fields: fields,
                  )
                  : '(No answer: the user can\'t be asked from a background '
                      'task. Continue with your best judgement.)';
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

  static String _short(String text) {
    final line = text.split('\n').first.trim();
    return line.length <= 60 ? line : '${line.substring(0, 57)}…';
  }
}
