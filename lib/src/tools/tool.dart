import 'dart:async';
import 'dart:convert';

import '../core/cancellation.dart';
import '../core/message.dart';

/// Behavioural hints about a tool call (aligned with MCP tool annotations).
///
/// They drive scheduling and permissions: read-only calls may run in
/// parallel and are allowed by default; destructive calls run one at a
/// time and ask for permission under the standard policy; only idempotent
/// calls are retried.
final class ToolAnnotations {
  /// The call does not modify any state.
  final bool readOnly;

  /// The call may delete or irreversibly change data. Ignored when
  /// [readOnly].
  final bool destructive;

  /// Repeating the call with the same input has no additional effect.
  final bool idempotent;

  /// The call reaches outside the app/workspace (network, third parties).
  final bool openWorld;

  const ToolAnnotations({
    this.readOnly = false,
    this.destructive = true,
    this.idempotent = false,
    this.openWorld = false,
  });

  static const readOnlyLocal = ToolAnnotations(
    readOnly: true,
    destructive: false,
    idempotent: true,
  );

  static const readOnlyRemote = ToolAnnotations(
    readOnly: true,
    destructive: false,
    idempotent: true,
    openWorld: true,
  );

  /// Writes that only add or update (no deletes).
  static const additiveWrite = ToolAnnotations(destructive: false);

  bool get needsApproval => !readOnly && destructive;
}

/// What a tool returns.
final class ToolOutput {
  /// Model-facing content (capped by the runner to the tool's
  /// `maxOutputChars`).
  final List<ContentBlock> content;

  /// Host-facing structured data (e.g. records for UI chips). Never sent to
  /// the model and never truncated.
  final Object? structured;
  final bool isError;

  const ToolOutput({
    required this.content,
    this.structured,
    this.isError = false,
  });

  factory ToolOutput.text(String text, {Object? structured}) =>
      ToolOutput(content: [TextBlock(text)], structured: structured);

  /// JSON-encodes [value] for the model and keeps it as [structured].
  factory ToolOutput.json(Object? value) =>
      ToolOutput(content: [TextBlock(jsonEncode(value))], structured: value);

  factory ToolOutput.error(String message, {Object? structured}) => ToolOutput(
    content: [TextBlock(message)],
    structured: structured,
    isError: true,
  );

  String get text =>
      content.whereType<TextBlock>().map((b) => b.text).join('\n');
}

/// One field of a multi-field `ask_user` question (`inputType: 'form'`).
///
/// The host shows all fields together and answers with a JSON object that
/// maps each field [id] to its value (strings; `true`/`false` for
/// `boolean`; omitted when left empty).
final class UserInputField {
  /// Kinds a host should support.
  static const types = {'text', 'number', 'choice', 'date', 'boolean'};

  final String id;
  final String label;

  /// One of [types]; `text` when unknown.
  final String type;

  /// Options for `choice` fields.
  final List<String>? choices;

  /// The user must fill the field before submitting.
  final bool required;

  final String? placeholder;

  const UserInputField({
    required this.id,
    required this.label,
    this.type = 'text',
    this.choices,
    this.required = false,
    this.placeholder,
  });

  /// Parses one model-supplied field, or `null` when it is unusable.
  static UserInputField? tryParse(Object? json) {
    if (json is! Map) return null;
    final id = '${json['id'] ?? ''}'.trim();
    final label = '${json['label'] ?? ''}'.trim();
    if (id.isEmpty || label.isEmpty || id.length > 64 || label.length > 200) {
      return null;
    }
    final rawType = '${json['type'] ?? 'text'}'.trim().toLowerCase();
    final rawChoices = json['choices'];
    final choices =
        rawChoices is List
            ? rawChoices
                .map((c) => '$c'.trim())
                .where((c) => c.isNotEmpty)
                .take(20)
                .toList()
            : null;
    var type = types.contains(rawType) ? rawType : 'text';
    if (type == 'choice' && (choices == null || choices.isEmpty)) type = 'text';
    final placeholder = json['placeholder'];
    return UserInputField(
      id: id,
      label: label,
      type: type,
      choices: type == 'choice' ? choices : null,
      required: json['required'] == true,
      placeholder:
          placeholder is String && placeholder.trim().isNotEmpty
              ? placeholder.trim()
              : null,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'type': type,
    if (choices != null) 'choices': choices,
    if (required) 'required': true,
    if (placeholder != null) 'placeholder': placeholder,
  };
}

/// Request the host to answer a question mid-run (see `ask_user`).
///
/// With [fields] (`inputType: 'form'`) the answer is a JSON object keyed
/// by field id.
typedef UserInputRequester =
    Future<String> Function(
      String prompt, {
      String inputType,
      List<String>? choices,
      List<UserInputField>? fields,
    });

/// Per-call context passed to [HarnessTool.call].
final class ToolContext {
  final CancelToken cancel;
  final String runId;
  final String toolUseId;

  /// Reports progress; surfaced as `ToolProgress` events.
  final void Function(String message) progress;

  /// Asks the host a question and waits for the answer. Waiting time does
  /// not count toward the run's wall-clock budget or the tool timeout.
  final UserInputRequester requestUserInput;

  /// Mutable state shared by every tool in the run (e.g. the todo list).
  final Map<String, Object?> runState;

  const ToolContext({
    required this.cancel,
    required this.runId,
    required this.toolUseId,
    required this.progress,
    required this.requestUserInput,
    required this.runState,
  });
}

/// A tool the model can call.
///
/// Implementations must honour [ToolContext.cancel] for long work and
/// should return [ToolOutput.error] (not throw) for expected failures —
/// thrown exceptions are caught and reported to the model with a generic
/// message.
abstract class HarnessTool {
  const HarnessTool();

  /// Function name shown to the model (`^[a-zA-Z0-9_-]{1,64}$`).
  String get name;
  String get description;

  /// JSON Schema (`type: object`) for the input.
  Map<String, Object?> get inputSchema;

  /// Static annotations; see [annotationsFor] for per-call classification.
  ToolAnnotations get annotations;

  /// Classification of one specific call. Override for tools that read or
  /// write depending on their arguments.
  ToolAnnotations annotationsFor(Map<String, Object?> input) => annotations;

  /// Short UI label for a call, e.g. `Reading notes…`.
  String displayLabel(Map<String, Object?> input) {
    final spaced = name.replaceAll(RegExp('[_-]+'), ' ').trim();
    if (spaced.isEmpty) return 'Running tool…';
    return '${spaced[0].toUpperCase()}${spaced.substring(1)}…';
  }

  /// Overrides `RunConfig.toolTimeout` for this tool.
  Duration? get timeout => null;

  /// Model-facing output cap (characters); longer output keeps its head and
  /// tail with a truncation note.
  int get maxOutputChars => 24000;

  Future<ToolOutput> call(Map<String, Object?> input, ToolContext context);
}

/// A [HarnessTool] defined inline from a function.
class FunctionTool extends HarnessTool {
  @override
  final String name;
  @override
  final String description;
  @override
  final Map<String, Object?> inputSchema;
  @override
  final ToolAnnotations annotations;
  final Future<ToolOutput> Function(
    Map<String, Object?> input,
    ToolContext context,
  )
  _run;
  final String Function(Map<String, Object?> input)? _label;

  FunctionTool({
    required this.name,
    required this.description,
    required this.inputSchema,
    required Future<ToolOutput> Function(Map<String, Object?>, ToolContext) run,
    this.annotations = const ToolAnnotations(),
    String Function(Map<String, Object?>)? label,
  }) : _run = run,
       _label = label;

  @override
  String displayLabel(Map<String, Object?> input) =>
      _label?.call(input) ?? super.displayLabel(input);

  @override
  Future<ToolOutput> call(Map<String, Object?> input, ToolContext context) =>
      _run(input, context);
}

/// A dynamic set of tools (e.g. an MCP server). Resolved once at run start.
abstract interface class ToolProvider {
  Future<List<HarnessTool>> listTools();
}
