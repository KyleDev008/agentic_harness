import '../core/cancellation.dart';
import '../core/message.dart';
import '../core/usage.dart';

/// A model backend: turns a [ModelRequest] into a stream of normalized
/// [ModelStreamEvent]s.
///
/// Implementations must:
/// - emit `ToolUseStart` → zero or more `ToolInputDelta` → `ToolUseEnd` per
///   tool call, with an id unique within the response;
/// - emit exactly one [MessageStop] as the final event on success;
/// - throw a `HarnessError` subtype on failure (never hang), and stop
///   promptly when [cancel] fires (throwing `CancelledException`).
abstract interface class ModelClient {
  /// Human-readable identity for logs/events, e.g. `openai:gpt-4.1`.
  String get id;

  ModelCapabilities get capabilities;

  Stream<ModelStreamEvent> stream(ModelRequest request, {CancelToken? cancel});

  /// Releases transports. The client must not be used afterwards.
  Future<void> close();
}

/// Everything a model call needs.
final class ModelRequest {
  /// System instructions.
  final String? system;
  final List<AgentMessage> messages;
  final List<ToolDefinition> tools;
  final ToolChoice toolChoice;
  final int? maxOutputTokens;
  final double? temperature;
  final double? topP;

  /// When set, the final answer must be JSON matching this schema. Clients
  /// that support native structured output use it; the runner validates
  /// either way.
  final Map<String, Object?>? outputSchema;
  final ThinkingConfig? thinking;

  /// Stable conversation id for stateful backends (KV-cache reuse) and
  /// prompt-cache routing. Never sent to providers as content.
  final String? cacheKey;

  const ModelRequest({
    this.system,
    required this.messages,
    this.tools = const [],
    this.toolChoice = ToolChoice.auto,
    this.maxOutputTokens,
    this.temperature,
    this.topP,
    this.outputSchema,
    this.thinking,
    this.cacheKey,
  });

  ModelRequest copyWith({
    String? system,
    List<AgentMessage>? messages,
    List<ToolDefinition>? tools,
    ToolChoice? toolChoice,
    int? maxOutputTokens,
  }) => ModelRequest(
    system: system ?? this.system,
    messages: messages ?? this.messages,
    tools: tools ?? this.tools,
    toolChoice: toolChoice ?? this.toolChoice,
    maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
    temperature: temperature,
    topP: topP,
    outputSchema: outputSchema,
    thinking: thinking,
    cacheKey: cacheKey,
  );
}

/// A tool as presented to the model.
final class ToolDefinition {
  final String name;
  final String description;

  /// JSON Schema for the tool input; must be an `object` schema.
  final Map<String, Object?> inputSchema;

  const ToolDefinition({
    required this.name,
    required this.description,
    required this.inputSchema,
  });
}

/// Whether / which tools the model must call.
enum ToolChoice { auto, none, required }

/// Extended-thinking / reasoning configuration.
final class ThinkingConfig {
  final bool enabled;

  /// Token budget for thinking where the provider supports one.
  final int? budgetTokens;

  const ThinkingConfig({this.enabled = true, this.budgetTokens});
}

/// What a client can do; used by the runner and context manager.
final class ModelCapabilities {
  /// Native function/tool calling. When false, wrap the client in
  /// `PromptedToolCallingClient` to use tools.
  final bool nativeTools;
  final bool parallelToolCalls;
  final bool vision;
  final int? maxImagesPerTurn;
  final bool thinking;
  final bool structuredOutput;
  final bool promptCaching;

  /// Whether the client emits real [UsageReport]s.
  final bool reportsUsage;

  /// Context window in tokens, when known.
  final int? contextWindow;

  /// Maximum concurrent requests (1 for on-device models).
  final int maxConcurrency;

  const ModelCapabilities({
    this.nativeTools = true,
    this.parallelToolCalls = true,
    this.vision = false,
    this.maxImagesPerTurn,
    this.thinking = false,
    this.structuredOutput = false,
    this.promptCaching = false,
    this.reportsUsage = true,
    this.contextWindow,
    this.maxConcurrency = 8,
  });

  ModelCapabilities copyWith({
    bool? nativeTools,
    bool? parallelToolCalls,
    int? contextWindow,
    bool? structuredOutput,
  }) => ModelCapabilities(
    nativeTools: nativeTools ?? this.nativeTools,
    parallelToolCalls: parallelToolCalls ?? this.parallelToolCalls,
    vision: vision,
    maxImagesPerTurn: maxImagesPerTurn,
    thinking: thinking,
    structuredOutput: structuredOutput ?? this.structuredOutput,
    promptCaching: promptCaching,
    reportsUsage: reportsUsage,
    contextWindow: contextWindow ?? this.contextWindow,
    maxConcurrency: maxConcurrency,
  );
}

/// Why the model stopped generating.
enum ModelStopReason { endTurn, toolUse, maxTokens, stopSequence, refusal }

/// Normalized streaming events emitted by every [ModelClient].
sealed class ModelStreamEvent {
  const ModelStreamEvent();
}

final class TextDeltaEvent extends ModelStreamEvent {
  final String text;
  const TextDeltaEvent(this.text);
}

final class ThinkingDeltaEvent extends ModelStreamEvent {
  final String text;
  const ThinkingDeltaEvent(this.text);
}

/// Completed thinking block with its provider [signature] (Anthropic), so
/// it can be replayed verbatim on the next request.
final class ThinkingCompleteEvent extends ModelStreamEvent {
  final String text;
  final String? signature;

  /// Encrypted payload of a redacted thinking block.
  final String? redactedData;
  const ThinkingCompleteEvent(this.text, {this.signature, this.redactedData});
}

final class ToolUseStartEvent extends ModelStreamEvent {
  final String id;
  final String name;
  const ToolUseStartEvent(this.id, this.name);
}

/// A fragment of the tool input JSON as it streams.
final class ToolInputDeltaEvent extends ModelStreamEvent {
  final String id;
  final String jsonFragment;
  const ToolInputDeltaEvent(this.id, this.jsonFragment);
}

/// A complete tool call. [input] is `null` and [parseError] set when the
/// arguments were not a valid JSON object (e.g. truncated output).
final class ToolUseEndEvent extends ModelStreamEvent {
  final String id;
  final String name;
  final Map<String, Object?>? input;
  final String? parseError;
  const ToolUseEndEvent(this.id, this.name, this.input, {this.parseError});
}

final class UsageReport extends ModelStreamEvent {
  final Usage usage;
  const UsageReport(this.usage);
}

/// Client-specific data to store on the assistant message's
/// `providerMetadata` (merged).
final class MessageMetadataEvent extends ModelStreamEvent {
  final Map<String, Object?> metadata;
  const MessageMetadataEvent(this.metadata);
}

/// Always the last event of a successful stream.
final class MessageStop extends ModelStreamEvent {
  final ModelStopReason reason;
  const MessageStop(this.reason);
}
