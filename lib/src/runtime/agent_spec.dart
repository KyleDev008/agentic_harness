import '../context/context_manager.dart';
import '../core/message.dart';
import '../governance/permissions.dart';
import '../model/model_client.dart';
import '../tools/builtin_tools.dart';
import '../tools/tool.dart';
import '../telemetry/pricing.dart';
import '../telemetry/telemetry.dart';
import 'runner.dart' show RunState;

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

/// Hands the conversation to another agent: the model sees a
/// `transfer_to_<agent>` tool, and calling it makes [agent] (its
/// instructions, model, tools and permissions) take over the rest of the
/// run, on the same transcript.
final class Handoff {
  final AgentSpec agent;

  /// Tool name; defaults to `transfer_to_<agent name>`.
  final String? toolName;

  /// Tells the model when to hand off; defaults to a generic sentence.
  final String? description;

  /// Rewrites the transcript the new agent continues from (for example
  /// [HandoffFilters.removeToolCalls]). The run's `newMessages` keep the
  /// full record.
  final List<AgentMessage> Function(List<AgentMessage> messages)? inputFilter;

  /// Whether calling the transfer tool needs approval. Null decides per
  /// call: it asks once the run has read private data and the target's
  /// permissions are in bypass mode while the current agent's aren't (a
  /// prompt-injected agent could otherwise pass the conversation to a more
  /// permissive one). True always asks; false never does.
  final bool? requiresApproval;

  const Handoff(
    this.agent, {
    this.toolName,
    this.description,
    this.inputFilter,
    this.requiresApproval,
  });

  String get name {
    if (toolName case final n?) return n;
    final slug = agent.name
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    final full = 'transfer_to_${slug.isEmpty ? 'agent' : slug}';
    return full.length <= 64 ? full : full.substring(0, 64);
  }
}

/// Ready-made [Handoff.inputFilter]s.
abstract final class HandoffFilters {
  /// Drops tool calls and results (and messages left empty), keeping the
  /// conversation's text: the new agent doesn't see the old agent's tools.
  ///
  /// It doesn't remove instructions injected as plain text; for handoffs to
  /// more privileged agents, prefer a filter that summarizes.
  static List<AgentMessage> removeToolCalls(List<AgentMessage> messages) {
    final out = <AgentMessage>[];
    for (final m in messages) {
      final kept =
          m.content
              .where((b) => b is! ToolUseBlock && b is! ToolResultBlock)
              .toList();
      if (kept.isEmpty) continue;
      // Merge what dropping tool turns left next to each other.
      if (out.isNotEmpty && out.last.role == m.role) {
        out[out.length - 1] = out.last.copyWith(
          content: [...out.last.content, ...kept],
        );
      } else {
        out.add(m.copyWith(content: kept, providerMetadata: const {}));
      }
    }
    return out;
  }
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

  /// Agents this one can hand the conversation to.
  final List<Handoff> handoffs;

  const AgentSpec({
    required this.name,
    required this.instructions,
    required this.model,
    this.settings = const ModelSettings(),
    this.tools = const [],
    this.toolProviders = const [],
    this.permissions = const PermissionPolicy(),
    this.hooks = const Hooks(),
    this.handoffs = const [],
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
    handoffs: handoffs,
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

  /// Stop the run instead of waiting when a tool call needs approval or a
  /// replayable tool (such as `ask_user`) asks a question. The run ends
  /// with `StopReason.interrupted` and a `RunResult.state` to persist;
  /// answer it (`RunState.approve`/`reject`/`answer`) and continue with
  /// `Runner.resume`. `PermissionPolicy.canUseTool` is not called.
  final bool interruptible;

  /// Called with a snapshot at the start of every turn, for resuming after
  /// a crash. Resuming one re-sends that turn's model call, so its tool
  /// calls may run again. Runs synchronously on the run's path: keep it
  /// cheap (for example, queue the save). Errors are logged and ignored.
  final void Function(RunState state)? onCheckpoint;

  /// Receives a span for the run, each model call and each tool call
  /// (subagents nest under their call). Subagents use it too unless their
  /// own config sets one.
  final SpanExporter? tracer;

  /// Model prices, for `RunResult.cost` and [maxCost]. Null uses the
  /// parent run's table, else `PricingTable.builtIn`; `PricingTable.none`
  /// turns cost tracking off.
  final PricingTable? pricing;

  /// The most the run may cost in US dollars, subagents included. Before
  /// each model call the runner prices the prompt conservatively and caps
  /// the call's output tokens to what the remaining budget can pay for
  /// (never above the agent's `maxOutputTokens`, the client's default, or
  /// 16,384); when even a short answer won't fit, the run stops with
  /// `StopReason.budget`. Subagents share the budget: open ones get equal
  /// shares, and a call that doesn't fit waits for others to finish. A run whose model has no price stops at once
  /// rather than run unmetered. A best-effort cap: see the guide for what
  /// can still slip past it.
  final double? maxCost;

  /// Put full error messages in span errors. Off by default: provider
  /// messages can echo request content, so spans get only the error class
  /// and HTTP status.
  final bool traceErrorMessages;

  /// Most handoffs in one run (a guard against agents passing the
  /// conversation back and forth).
  final int maxHandoffs;

  /// Most background subagent tasks running at once in this run.
  final int maxBackgroundTasks;

  /// Deepest subagent nesting below this run (a subagent's subagent is
  /// depth 2). Set on the top-level run; nested runs inherit it.
  final int maxSubagentDepth;

  /// Longest a background task may run before it is cancelled.
  final Duration backgroundTaskTimeout;

  /// Longest background result passed to the model; the rest is cut.
  final int maxBackgroundResultChars;

  /// Most deferred tools `search_tools` may load in one run.
  final int maxLoadedTools;

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
    this.interruptible = false,
    this.onCheckpoint,
    this.tracer,
    this.pricing,
    this.maxCost,
    this.traceErrorMessages = false,
    this.maxHandoffs = 5,
    this.maxBackgroundTasks = 4,
    this.maxSubagentDepth = 3,
    this.backgroundTaskTimeout = const Duration(minutes: 15),
    this.maxBackgroundResultChars = 20000,
    this.maxLoadedTools = 40,
  });
}
