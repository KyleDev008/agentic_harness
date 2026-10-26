import '../core/errors.dart';
import '../core/usage.dart';
import '../tools/tool.dart' show UserInputField;

/// Every event a run emits, in order, on `AgentRun.events`.
///
/// Events are plain data with a `toJson` form (for logs, traces and
/// isolate transport). `structured` tool payloads are included verbatim
/// and must themselves be JSON-encodable for `toJson` to be.
sealed class RunEvent {
  final String runId;
  final DateTime at;
  RunEvent(this.runId) : at = DateTime.now();

  String get type;

  Map<String, Object?> toJson() => {
    'type': type,
    'runId': runId,
    'at': at.toIso8601String(),
    ..._fields(),
  };

  Map<String, Object?> _fields();
}

final class RunStarted extends RunEvent {
  final String agentName;
  final String model;
  RunStarted(super.runId, {required this.agentName, required this.model});
  @override
  String get type => 'run_started';
  @override
  Map<String, Object?> _fields() => {'agentName': agentName, 'model': model};
}

/// A model call is starting. [turn] is 1-based.
final class TurnStarted extends RunEvent {
  final int turn;
  TurnStarted(super.runId, this.turn);
  @override
  String get type => 'turn_started';
  @override
  Map<String, Object?> _fields() => {'turn': turn};
}

final class TextDelta extends RunEvent {
  final String text;
  TextDelta(super.runId, this.text);
  @override
  String get type => 'text_delta';
  @override
  Map<String, Object?> _fields() => {'text': text};
}

final class ThinkingDelta extends RunEvent {
  final String text;
  ThinkingDelta(super.runId, this.text);
  @override
  String get type => 'thinking_delta';
  @override
  Map<String, Object?> _fields() => {'text': text};
}

/// The model began a tool call. [input] is complete (tool calls are
/// emitted once their arguments are parsed).
final class ToolCallStarted extends RunEvent {
  final String toolUseId;
  final String name;
  final Map<String, Object?> input;
  final String displayLabel;
  ToolCallStarted(
    super.runId, {
    required this.toolUseId,
    required this.name,
    required this.input,
    required this.displayLabel,
  });
  @override
  String get type => 'tool_call_started';
  @override
  Map<String, Object?> _fields() => {
    'toolUseId': toolUseId,
    'name': name,
    'input': input,
    'displayLabel': displayLabel,
  };
}

/// Raw argument JSON fragment while the model is still writing a call.
final class ToolInputDelta extends RunEvent {
  final String toolUseId;
  final String jsonFragment;

  /// The tool being called, when the provider announced it before the
  /// arguments (every streaming provider does) — lets hosts preview
  /// specific tools' input while it is written.
  final String? name;
  ToolInputDelta(super.runId, this.toolUseId, this.jsonFragment, {this.name});
  @override
  String get type => 'tool_input_delta';
  @override
  Map<String, Object?> _fields() => {
    'toolUseId': toolUseId,
    'jsonFragment': jsonFragment,
    if (name != null) 'name': name,
  };
}

final class ToolProgress extends RunEvent {
  final String toolUseId;
  final String message;
  ToolProgress(super.runId, this.toolUseId, this.message);
  @override
  String get type => 'tool_progress';
  @override
  Map<String, Object?> _fields() => {
    'toolUseId': toolUseId,
    'message': message,
  };
}

/// A tool call finished (successfully, with an error, denied or skipped).
final class ToolResultEvent extends RunEvent {
  final String toolUseId;
  final String name;
  final Map<String, Object?> input;

  /// What the model sees (after truncation).
  final String content;

  /// Host-facing payload from `ToolOutput.structured`.
  final Object? structured;
  final bool isError;
  final Duration duration;

  ToolResultEvent(
    super.runId, {
    required this.toolUseId,
    required this.name,
    required this.input,
    required this.content,
    required this.structured,
    required this.isError,
    required this.duration,
  });
  @override
  String get type => 'tool_result';
  @override
  Map<String, Object?> _fields() => {
    'toolUseId': toolUseId,
    'name': name,
    'input': input,
    'content': content,
    if (structured != null) 'structured': structured,
    'isError': isError,
    'durationMs': duration.inMilliseconds,
  };
}

/// A call is waiting on `PermissionPolicy.canUseTool`.
final class ApprovalRequested extends RunEvent {
  final String toolUseId;
  final String name;
  final Map<String, Object?> input;
  final String displayLabel;
  ApprovalRequested(
    super.runId, {
    required this.toolUseId,
    required this.name,
    required this.input,
    required this.displayLabel,
  });
  @override
  String get type => 'approval_requested';
  @override
  Map<String, Object?> _fields() => {
    'toolUseId': toolUseId,
    'name': name,
    'input': input,
    'displayLabel': displayLabel,
  };
}

/// The run waits for `AgentRun.respond(requestId, answer)`.
final class UserInputRequested extends RunEvent {
  final String requestId;
  final String prompt;
  final String inputType;
  final List<String>? choices;

  /// Fields of a multi-field question (`inputType == 'form'`); answer
  /// with a JSON object keyed by field id.
  final List<UserInputField>? fields;
  UserInputRequested(
    super.runId, {
    required this.requestId,
    required this.prompt,
    required this.inputType,
    this.choices,
    this.fields,
  });
  @override
  String get type => 'user_input_requested';
  @override
  Map<String, Object?> _fields() => {
    'requestId': requestId,
    'prompt': prompt,
    'inputType': inputType,
    if (choices != null) 'choices': choices,
    if (fields != null) 'fields': [for (final f in fields!) f.toJson()],
  };
}

final class UsageUpdated extends RunEvent {
  final Usage call;
  final Usage total;

  /// The run's cost so far in US dollars, when priced.
  final double? cost;
  UsageUpdated(
    super.runId, {
    required this.call,
    required this.total,
    this.cost,
  });
  @override
  String get type => 'usage';
  @override
  Map<String, Object?> _fields() => {
    'call': call.toJson(),
    'total': total.toJson(),
    if (cost != null) 'cost': cost,
  };
}

/// The working context was reduced to fit the model's window.
final class ContextCompacted extends RunEvent {
  final String stage;
  final int tokensBefore;
  final int tokensAfter;
  ContextCompacted(
    super.runId, {
    required this.stage,
    required this.tokensBefore,
    required this.tokensAfter,
  });
  @override
  String get type => 'context_compacted';
  @override
  Map<String, Object?> _fields() => {
    'stage': stage,
    'tokensBefore': tokensBefore,
    'tokensAfter': tokensAfter,
  };
}

final class Retrying extends RunEvent {
  final int attempt;
  final Duration delay;
  final ErrorClass errorClass;
  Retrying(
    super.runId, {
    required this.attempt,
    required this.delay,
    required this.errorClass,
  });
  @override
  String get type => 'retrying';
  @override
  Map<String, Object?> _fields() => {
    'attempt': attempt,
    'delayMs': delay.inMilliseconds,
    'errorClass': errorClass.name,
  };
}

/// A fatal error; always followed by `RunCompleted(error)`.
final class RunError extends RunEvent {
  final ErrorClass errorClass;
  final String message;
  final Object error;
  RunError(
    super.runId, {
    required this.errorClass,
    required this.message,
    required this.error,
  });
  @override
  String get type => 'error';
  @override
  Map<String, Object?> _fields() => {
    'errorClass': errorClass.name,
    'message': message,
  };
}

/// The conversation passed to another agent (`Handoff`).
final class HandoffOccurred extends RunEvent {
  final String from;
  final String to;
  HandoffOccurred(super.runId, {required this.from, required this.to});
  @override
  String get type => 'handoff';
  @override
  Map<String, Object?> _fields() => {'from': from, 'to': to};
}

/// A background task (for example a background subagent) started.
final class BackgroundTaskStarted extends RunEvent {
  final String taskId;
  final String label;
  BackgroundTaskStarted(
    super.runId, {
    required this.taskId,
    required this.label,
  });
  @override
  String get type => 'background_task_started';
  @override
  Map<String, Object?> _fields() => {'taskId': taskId, 'label': label};
}

/// A background task finished; its result reaches the model as a message.
final class BackgroundTaskFinished extends RunEvent {
  final String taskId;
  final String label;
  final bool failed;
  BackgroundTaskFinished(
    super.runId, {
    required this.taskId,
    required this.label,
    this.failed = false,
  });
  @override
  String get type => 'background_task_finished';
  @override
  Map<String, Object?> _fields() => {
    'taskId': taskId,
    'label': label,
    if (failed) 'failed': true,
  };
}

/// Why a run ended.
enum StopReason {
  /// The model finished its answer.
  endTurn,
  maxTurns,

  /// Token budget (`RunConfig.maxTotalTokens`) exhausted.
  budget,

  /// Wall-clock budget exhausted.
  timeout,
  cancelled,

  /// The model declined (safety refusal).
  refusal,
  error,

  /// An interruptible run stopped for an approval or a question; resume it
  /// from `RunResult.state`.
  interrupted,
}

/// Always the last event.
final class RunCompleted extends RunEvent {
  final StopReason stopReason;
  RunCompleted(super.runId, this.stopReason);
  @override
  String get type => 'run_completed';
  @override
  Map<String, Object?> _fields() => {'stopReason': stopReason.name};
}
