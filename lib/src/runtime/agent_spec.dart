import '../context/context_manager.dart';
import '../governance/permissions.dart';
import '../model/model_client.dart';
import '../tools/builtin_tools.dart';
import '../tools/tool.dart';

/// Sampling and output settings for an agent's model calls.
final class ModelSettings {
  final int? maxOutputTokens;
  final double? temperature;
  final double? topP;

  /// Request reasoning/extended thinking where the model supports it.
  final ThinkingConfig? thinking;

  /// When set, the final answer must be JSON matching this schema; it is
  /// validated and returned on `RunResult.structuredOutput`.
  final Map<String, Object?>? outputSchema;

  const ModelSettings({
    this.maxOutputTokens,
    this.temperature,
    this.topP,
    this.thinking,
    this.outputSchema,
  });
}

/// An agent: instructions + model + tools + permissions. Immutable and
/// reusable across runs.
final class AgentSpec {
  final String name;

  /// System prompt.
  final String instructions;
  final ModelClient model;
  final ModelSettings settings;
  final List<HarnessTool> tools;

  /// Dynamic tool sources resolved at the start of every run.
  final List<ToolProvider> toolProviders;
  final PermissionPolicy permissions;
  final Hooks hooks;

  const AgentSpec({
    required this.name,
    required this.instructions,
    required this.model,
    this.settings = const ModelSettings(),
    this.tools = const [],
    this.toolProviders = const [],
    this.permissions = const PermissionPolicy(),
    this.hooks = const Hooks(),
  });

  AgentSpec copyWith({
    String? instructions,
    ModelClient? model,
    List<HarnessTool>? tools,
    PermissionPolicy? permissions,
  }) => AgentSpec(
    name: name,
    instructions: instructions ?? this.instructions,
    model: model ?? this.model,
    settings: settings,
    tools: tools ?? this.tools,
    toolProviders: toolProviders,
    permissions: permissions ?? this.permissions,
    hooks: hooks,
  );
}

/// Limits and behaviour for one run.
final class RunConfig {
  /// Maximum model calls in the run.
  final int maxTurns;

  /// Active wall-clock limit (time spent waiting for the user is excluded).
  final Duration? wallClockBudget;

  /// Total input+output token budget across the run's model calls.
  final int? maxTotalTokens;

  /// Read-only tool calls run concurrently up to this limit.
  final int maxParallelTools;

  /// Per-call tool timeout. Starts after permission is granted and pauses
  /// while the tool waits for user input.
  final Duration toolTimeout;

  /// Identical calls (same tool, same input) allowed before further
  /// repeats are answered with an error (loop protection).
  final int maxRepeatedCalls;

  /// Non-read-only calls are not executed; the model is told so.
  final bool dryRun;

  /// Context window used for compaction. When the client also knows its
  /// window (`ModelCapabilities.contextWindow`, e.g. Ollama `num_ctx` or a
  /// loaded on-device model) the smaller of the two applies — a run can
  /// lower a hard limit but never raise it.
  final int? contextWindow;
  final ContextPolicy context;

  /// Seeds the `todo_write` list.
  final List<Todo> initialTodos;

  /// Conversation id passed to model clients (KV/prompt-cache routing).
  final String? cacheKey;

  /// Treat the run as already holding private data (history, memories,
  /// attachments), so open-world calls ask for approval from the start in
  /// the standard permission mode. Hosts whose prompts carry user data
  /// should set this.
  final bool assumePrivateContext;

  const RunConfig({
    this.maxTurns = 25,
    this.wallClockBudget,
    this.maxTotalTokens,
    this.maxParallelTools = 4,
    this.toolTimeout = const Duration(seconds: 60),
    this.maxRepeatedCalls = 3,
    this.dryRun = false,
    this.contextWindow,
    this.context = const ContextPolicy(),
    this.initialTodos = const [],
    this.cacheKey,
    this.assumePrivateContext = false,
  });
}
