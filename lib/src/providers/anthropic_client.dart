import 'dart:convert';
import 'dart:developer' as developer;

import '../core/cancellation.dart';
import '../core/errors.dart';
import '../core/message.dart';
import '../core/usage.dart';
import '../model/http_transport.dart';
import '../model/model_client.dart';
import '../model/tool_call_accumulator.dart';

/// Server-side compaction (`compact_20260112`, beta): when the prompt
/// reaches [triggerTokens], the API summarizes the earlier conversation and
/// continues from the summary.
final class AnthropicCompaction {
  /// Input tokens that trigger compaction (at least 50,000).
  final int triggerTokens;

  /// Replaces the server's summarization prompt. When null and the request
  /// has tools, [textOnlyInstructions] is sent, because a model with tools
  /// sometimes calls one instead of writing the summary.
  final String? instructions;

  const AnthropicCompaction({this.triggerTokens = 150000, this.instructions})
    : assert(triggerTokens >= 50000, 'triggerTokens must be at least 50000');

  static const textOnlyInstructions =
      'Summarize the transcript inside <summary></summary> tags. Include '
      'relevant information in the summary for continuing the task in the '
      'next context window. Do not call any tools while writing this '
      'summary; respond with text only.';
}

/// Server-side clearing of old tool results (`clear_tool_uses_20250919`,
/// beta). The full history is still sent; the API removes old results
/// from the prompt it gives the model.
final class AnthropicToolResultClearing {
  /// Input tokens above which clearing starts.
  final int triggerTokens;

  /// Most recent tool uses kept.
  final int keepToolUses;

  /// Clear at least this many tokens or nothing, so a clear is worth the
  /// prompt-cache write it causes.
  final int? clearAtLeastTokens;

  /// Tools whose results are never cleared. Add `memory` when the agent
  /// uses the memory tool.
  final List<String> excludeTools;

  /// Also clear the cleared calls' inputs.
  final bool clearToolInputs;

  const AnthropicToolResultClearing({
    this.triggerTokens = 100000,
    this.keepToolUses = 3,
    this.clearAtLeastTokens,
    this.excludeTools = const [],
    this.clearToolInputs = false,
  });
}

/// Server-side clearing of old thinking blocks (`clear_thinking_20251015`,
/// beta).
final class AnthropicThinkingClearing {
  /// Assistant turns whose thinking is kept; null keeps all of it.
  final int? keepTurns;

  const AnthropicThinkingClearing({this.keepTurns});
}

/// Anthropic's server-side context management. Any combination may be set.
final class AnthropicContextManagement {
  final AnthropicCompaction? compaction;
  final AnthropicToolResultClearing? clearToolResults;
  final AnthropicThinkingClearing? clearThinking;

  const AnthropicContextManagement({
    this.compaction,
    this.clearToolResults,
    this.clearThinking,
  });

  bool get clears => clearToolResults != null || clearThinking != null;
}

/// Configuration for [AnthropicClient].
final class AnthropicConfig {
  final String model;
  final String apiKey;

  /// API root; `/v1/messages` is appended.
  final String baseUrl;
  final String apiVersion;
  final Map<String, String> headers;

  /// Default `max_tokens` when the request sets none. Streaming is always
  /// used, so a generous cap is safe; lower it for older models with small
  /// output limits.
  final int defaultMaxTokens;

  /// `output_config.effort` (`low` … `max`). `null` uses the model default.
  final String? effort;

  /// Whether to send `temperature`/`top_p`. Current Claude models reject
  /// non-default sampling values; `null` decides by model name (only
  /// `claude-3*`, `*-4-5` and `*-4-6` models receive them).
  final bool? sendSampling;

  /// Prompt caching: a breakpoint on the system prompt and the last tool,
  /// plus top-level automatic caching for the conversation prefix.
  final bool promptCaching;

  /// Stream tool inputs as they are generated (`eager_input_streaming`).
  /// Inputs are then not validated server-side — the runner validates them
  /// against the tool schema. Disable for proxies that reject the field.
  final bool eagerInputStreaming;

  /// Server-side refusal fallback (`fallbacks: "default"`) for models that
  /// support it, on the first-party API only. When a safety classifier
  /// declines, the API re-runs the request on a fallback model.
  final bool refusalFallback;

  /// Native structured output (`output_config.format`) for
  /// `ModelSettings.outputSchema`. `null` decides by model name (Claude 3
  /// and the original Claude 4 models get a prompt instruction instead).
  final bool? nativeStructuredOutput;

  /// Server-side compaction and clearing. With compaction on, the runner's
  /// own `ContextPolicy` compaction is skipped.
  final AnthropicContextManagement? contextManagement;

  /// Declare tools with an `anthropicType` (such as the memory tool) as
  /// that Anthropic-defined tool rather than by their schema.
  final bool nativeToolTypes;

  final int? contextWindow;

  const AnthropicConfig({
    required this.model,
    required this.apiKey,
    this.baseUrl = 'https://api.anthropic.com',
    this.apiVersion = '2023-06-01',
    this.headers = const {},
    this.defaultMaxTokens = 32000,
    this.effort,
    this.sendSampling,
    this.promptCaching = true,
    this.eagerInputStreaming = true,
    this.refusalFallback = true,
    this.nativeStructuredOutput,
    this.contextManagement,
    this.nativeToolTypes = true,
    this.contextWindow,
  });

  /// `anthropic-beta` values this configuration needs.
  List<String> get betas => [
    if (usesRefusalFallback) 'server-side-fallback-2026-07-01',
    if (contextManagement?.compaction != null) 'compact-2026-01-12',
    if (contextManagement?.clears ?? false) 'context-management-2025-06-27',
  ];

  bool get structuredOutputSupported {
    if (nativeStructuredOutput != null) return nativeStructuredOutput!;
    final m = model.toLowerCase();
    return !(m.startsWith('claude-3') ||
        RegExp(r'^claude-(opus|sonnet)-4(-0|-2025\d{4})?$').hasMatch(m));
  }

  bool get samplingAllowed {
    if (sendSampling != null) return sendSampling!;
    final m = model.toLowerCase();
    return m.startsWith('claude-3') || m.contains('-4-5') || m.contains('-4-6');
  }

  static const _fallbackModels = {
    'claude-fable-5-1',
    'claude-opus-5-5',
    'claude-opus-5',
    'claude-sonnet-5-5',
  };

  bool get usesRefusalFallback {
    if (!refusalFallback) return false;
    final host = Uri.tryParse(baseUrl)?.host ?? '';
    return host == 'api.anthropic.com' && _fallbackModels.contains(model);
  }
}

/// [ModelClient] for the Anthropic Messages API (raw HTTP + SSE).
///
/// Native `tool_use`/`tool_result` blocks, adaptive extended thinking with
/// signature round-trip, prompt caching, and cache-token usage. Requests
/// never end with an assistant message (no prefill), never contain empty
/// text blocks, and never force a specific tool — current models reject
/// all three.
class AnthropicClient implements ModelClient {
  final AnthropicConfig config;
  final HttpTransport _transport;
  final RetryCallback? onRetry;

  AnthropicClient(this.config, {HttpTransport? transport, this.onRetry})
    : _transport = transport ?? HttpTransport();

  static const _log = 'agentic_harness.anthropic';

  @override
  String get id => 'anthropic:${config.model}';

  @override
  ModelCapabilities get capabilities => ModelCapabilities(
    nativeTools: true,
    parallelToolCalls: true,
    vision: true,
    thinking: true,
    structuredOutput: config.structuredOutputSupported,
    promptCaching: config.promptCaching,
    reportsUsage: true,
    contextWindow: config.contextWindow,
    serverCompaction: config.contextManagement?.compaction != null,
    maxOutputTokens: config.defaultMaxTokens,
  );

  @override
  Stream<ModelStreamEvent> stream(
    ModelRequest request, {
    CancelToken? cancel,
  }) async* {
    var base = config.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/v1')) base = base.substring(0, base.length - 3);
    final uri = Uri.parse('$base/v1/messages');

    final response = await _transport.postJson(
      uri,
      buildBody(request),
      headers: {
        'x-api-key': config.apiKey,
        'anthropic-version': config.apiVersion,
        'Accept': 'text/event-stream',
        if (config.betas.isNotEmpty) 'anthropic-beta': config.betas.join(','),
        ...config.headers,
      },
      cancel: cancel,
      onRetry: onRetry,
      logName: _log,
    );

    final calls = ToolCallAccumulator();
    final blockKinds = <int, String>{};
    final blockIds = <int, String>{};
    final thinking = <int, StringBuffer>{};
    final signatures = <int, String>{};
    var inputTokens = 0;
    var cacheRead = 0;
    var cacheWrite = 0;
    var outputTokens = 0;
    var compactionInput = 0;
    var compactionOutput = 0;
    String? compaction;
    var compactionDeltas = false;
    String? stopReason;

    await for (final event in _transport.sseJson(response, cancel: cancel)) {
      switch (event['type']) {
        case 'message_start':
          final message = event['message'];
          final usage = message is Map ? message['usage'] : null;
          if (usage is Map) {
            inputTokens = _n(usage['input_tokens']);
            cacheRead = _n(usage['cache_read_input_tokens']);
            cacheWrite = _n(usage['cache_creation_input_tokens']);
            outputTokens = _n(usage['output_tokens']);
          }
        case 'content_block_start':
          final index = _n(event['index']);
          final block = event['content_block'];
          if (block is! Map) break;
          final kind = block['type'] as String? ?? '';
          blockKinds[index] = kind;
          if (kind == 'tool_use') {
            final id = block['id'] as String? ?? '';
            blockIds[index] = id;
            for (final e in calls.add(
              index,
              id: id,
              name: block['name'] as String?,
            )) {
              yield e;
            }
          } else if (kind == 'redacted_thinking') {
            final data = block['data'];
            if (data is String) {
              yield ThinkingCompleteEvent('', redactedData: data);
            }
          } else if (kind == 'compaction') {
            final content = block['content'];
            if (content is String) compaction = content;
          } else if (kind == 'thinking') {
            thinking[index] = StringBuffer(block['thinking'] as String? ?? '');
          } else if (kind == 'text') {
            final text = block['text'];
            if (text is String && text.isNotEmpty) yield TextDeltaEvent(text);
          }
        case 'content_block_delta':
          final index = _n(event['index']);
          final delta = event['delta'];
          if (delta is! Map) break;
          switch (delta['type']) {
            case 'text_delta':
              final text = delta['text'];
              if (text is String && text.isNotEmpty) yield TextDeltaEvent(text);
            case 'thinking_delta':
              final text = delta['thinking'];
              if (text is String && text.isNotEmpty) {
                (thinking[index] ??= StringBuffer()).write(text);
                yield ThinkingDeltaEvent(text);
              }
            case 'signature_delta':
              final sig = delta['signature'];
              if (sig is String) {
                signatures[index] = (signatures[index] ?? '') + sig;
              }
            case 'compaction_delta':
              final content = delta['content'];
              if (content is String) {
                compaction =
                    compactionDeltas ? (compaction ?? '') + content : content;
                compactionDeltas = true;
              }
            case 'input_json_delta':
              final partial = delta['partial_json'];
              if (partial is String) {
                for (final e in calls.add(index, argumentsFragment: partial)) {
                  yield e;
                }
              }
          }
        case 'content_block_stop':
          final index = _n(event['index']);
          if (blockKinds[index] == 'thinking') {
            yield ThinkingCompleteEvent(
              thinking[index]?.toString() ?? '',
              signature: signatures[index],
            );
          }
        case 'message_delta':
          final delta = event['delta'];
          if (delta is Map && delta['stop_reason'] is String) {
            stopReason = delta['stop_reason'] as String;
          }
          final usage = event['usage'];
          if (usage is Map && usage['output_tokens'] != null) {
            outputTokens = _n(usage['output_tokens']);
          }
          // Compaction runs as its own sampling step; the top-level counts
          // leave it out.
          final iterations = usage is Map ? usage['iterations'] : null;
          if (iterations is List) {
            compactionInput = 0;
            compactionOutput = 0;
            for (final it in iterations) {
              if (it is Map && it['type'] == 'compaction') {
                compactionInput +=
                    _n(it['input_tokens']) +
                    _n(it['cache_read_input_tokens']) +
                    _n(it['cache_creation_input_tokens']);
                compactionOutput += _n(it['output_tokens']);
              }
            }
          }
          final edits = event['context_management'];
          final applied = edits is Map ? edits['applied_edits'] : null;
          if (applied is List && applied.isNotEmpty) {
            developer.log(
              'context edits applied: ${jsonEncode(applied)}',
              name: _log,
            );
          }
        case 'error':
          final error = event['error'];
          final type = error is Map ? error['type'] : null;
          final message = error is Map ? '${error['message']}' : '$error';
          if (type == 'overloaded_error') throw OverloadedError(message);
          if (type == 'rate_limit_error') throw RateLimitError(message);
          throw ProviderError(
            'Stream error ($type): ${truncateForError(message)}',
          );
      }
    }

    final ends = calls.finishAll();
    for (final e in ends) {
      yield e;
    }
    final summary = compaction;
    if (summary != null && summary.trim().isNotEmpty) {
      yield MessageMetadataEvent({
        compactionMetadataKey: {
          'summary': summary,
          'tokensBefore': compactionInput,
        },
      });
    } else if (summary != null || compactionInput > 0) {
      developer.log('compaction returned no summary', name: _log, level: 900);
    }
    // Reported before the message's own usage, which stays the last report
    // (the runner calibrates its estimate on it).
    if (compactionInput > 0 || compactionOutput > 0) {
      yield UsageReport(
        Usage(inputTokens: compactionInput, outputTokens: compactionOutput),
      );
    }
    yield UsageReport(
      Usage(
        inputTokens: inputTokens + cacheRead + cacheWrite,
        outputTokens: outputTokens,
        cacheReadTokens: cacheRead,
        cacheWriteTokens: cacheWrite,
      ),
    );
    yield MessageStop(switch (stopReason) {
      'tool_use' => ModelStopReason.toolUse,
      'max_tokens' => ModelStopReason.maxTokens,
      'stop_sequence' => ModelStopReason.stopSequence,
      'refusal' => ModelStopReason.refusal,
      _ =>
        ends.whereType<ToolUseEndEvent>().isNotEmpty
            ? ModelStopReason.toolUse
            : ModelStopReason.endTurn,
    });
  }

  /// Builds the Messages API request body. Public for tests.
  Map<String, Object?> buildBody(ModelRequest request) {
    final caching = config.promptCaching;
    final system = request.system;
    final tools = request.tools;
    final thinkingOn = request.thinking?.enabled ?? false;
    final sampling = config.samplingAllowed && !thinkingOn;
    final schema = request.outputSchema;
    final native = schema != null && config.structuredOutputSupported;
    final schemaHint =
        schema == null || native
            ? null
            : 'Respond with only a JSON value matching this JSON Schema, '
                'no prose or code fences:\n${jsonEncode(request.outputSchema)}';
    final systemText = [
      if (system != null && system.isNotEmpty) system,
      if (schemaHint != null) schemaHint,
    ].join('\n\n');

    return {
      'model': config.model,
      'max_tokens': request.maxOutputTokens ?? config.defaultMaxTokens,
      'stream': true,
      if (systemText.isNotEmpty)
        'system': [
          {
            'type': 'text',
            'text': systemText,
            if (caching) 'cache_control': {'type': 'ephemeral'},
          },
        ],
      'messages': toAnthropicMessages(
        request.messages,
        serverCompaction: config.contextManagement?.compaction != null,
      ),
      if (config.contextManagement case final cm?)
        'context_management': {'edits': _edits(cm, tools.isNotEmpty)},
      // With tool_choice none the definitions are still sent: a transcript
      // holding tool_use/tool_result blocks is rejected without them.
      if (tools.isNotEmpty) ...{
        if (request.toolChoice == ToolChoice.none)
          'tool_choice': {'type': 'none'},
        'tools': [
          for (var i = 0; i < tools.length; i++)
            {
              if (config.nativeToolTypes && tools[i].anthropicType != null) ...{
                'type': tools[i].anthropicType,
                'name': tools[i].name,
              } else ...{
                'name': tools[i].name,
                'description': tools[i].description,
                'input_schema': tools[i].inputSchema,
                if (config.eagerInputStreaming) 'eager_input_streaming': true,
              },
              if (caching && i == tools.length - 1)
                'cache_control': {'type': 'ephemeral'},
            },
        ],
      },
      if (thinkingOn) 'thinking': {'type': 'adaptive', 'display': 'summarized'},
      if (config.effort != null || native)
        'output_config': {
          if (config.effort != null) 'effort': config.effort,
          if (native)
            'format': {
              'type': 'json_schema',
              'schema': structuredOutputSchema(schema),
            },
        },
      // Never both: several models reject temperature + top_p together.
      if (sampling && request.temperature != null)
        'temperature': request.temperature
      else if (sampling && request.topP != null)
        'top_p': request.topP,
      if (caching) 'cache_control': {'type': 'ephemeral'},
      if (config.usesRefusalFallback) 'fallbacks': 'default',
    };
  }

  /// Context edits; thinking clearing must come first.
  static List<Map<String, Object?>> _edits(
    AnthropicContextManagement cm,
    bool hasTools,
  ) {
    final compaction = cm.compaction;
    final instructions =
        compaction?.instructions ??
        (hasTools ? AnthropicCompaction.textOnlyInstructions : null);
    return [
      if (cm.clearThinking case final t?)
        {
          'type': 'clear_thinking_20251015',
          'keep':
              t.keepTurns == null
                  ? 'all'
                  : {'type': 'thinking_turns', 'value': t.keepTurns},
        },
      if (cm.clearToolResults case final c?)
        {
          'type': 'clear_tool_uses_20250919',
          'trigger': {'type': 'input_tokens', 'value': c.triggerTokens},
          'keep': {'type': 'tool_uses', 'value': c.keepToolUses},
          if (c.clearAtLeastTokens != null)
            'clear_at_least': {
              'type': 'input_tokens',
              'value': c.clearAtLeastTokens,
            },
          if (c.excludeTools.isNotEmpty) 'exclude_tools': c.excludeTools,
          if (c.clearToolInputs) 'clear_tool_inputs': true,
        },
      if (compaction != null)
        {
          'type': 'compact_20260112',
          'trigger': {
            'type': 'input_tokens',
            'value': compaction.triggerTokens,
          },
          if (instructions != null) 'instructions': instructions,
        },
    ];
  }

  static const _supportedFormats = {
    'date-time',
    'time',
    'date',
    'duration',
    'email',
    'hostname',
    'uri',
    'ipv4',
    'ipv6',
    'uuid',
  };

  static const _droppedKeywords = {
    'minimum',
    'maximum',
    'exclusiveMinimum',
    'exclusiveMaximum',
    'multipleOf',
    'minLength',
    'maxLength',
    'maxItems',
    'uniqueItems',
  };

  /// Reduces a JSON Schema to what structured output accepts: numeric,
  /// string and most array constraints are dropped, `minItems` is capped at
  /// 1, objects get `additionalProperties: false`, `oneOf` becomes `anyOf`
  /// and unsupported string formats are removed. The runner still checks
  /// the answer against the original schema.
  static Map<String, Object?> structuredOutputSchema(
    Map<String, Object?> schema,
  ) {
    Object? walk(Object? node) {
      if (node is List) return node.map(walk).toList();
      if (node is! Map) return node;
      final out = <String, Object?>{};
      for (final entry in node.entries) {
        final key = '${entry.key}';
        final value = entry.value;
        if (_droppedKeywords.contains(key)) continue;
        switch (key) {
          case 'minItems':
            if (value is num) out[key] = value > 1 ? 1 : value.toInt();
          case 'format':
            if (_supportedFormats.contains(value)) out[key] = value;
          case 'additionalProperties':
            break;
          case 'oneOf':
            out['anyOf'] = walk(value);
          case 'properties' || r'$defs' || 'definitions':
            out[key] =
                value is Map
                    ? {for (final p in value.entries) '${p.key}': walk(p.value)}
                    : value;
          default:
            out[key] = walk(value);
        }
      }
      final type = out['type'];
      final isObject =
          type == 'object' ||
          (type is List && type.contains('object')) ||
          out.containsKey('properties');
      if (isObject) out['additionalProperties'] = false;
      return out;
    }

    return walk(schema) as Map<String, Object?>;
  }

  /// Converts the harness transcript to Anthropic messages: consecutive
  /// same-role turns are merged, empty text is dropped, and the transcript
  /// always starts with a user turn (or the latest server compaction) and
  /// never ends with an assistant turn.
  ///
  /// With [serverCompaction], history before the latest compaction is not
  /// sent (the API ignores it). Without it, compaction summaries are left
  /// out and the full history is sent, since the request has no beta
  /// header for the block.
  static List<Map<String, Object?>> toAnthropicMessages(
    List<AgentMessage> messages, {
    bool serverCompaction = false,
  }) {
    String? summaryOf(AgentMessage m) =>
        serverCompaction && m.role == Role.assistant ? _summary(m) : null;
    final latest = messages.lastIndexWhere((m) => summaryOf(m) != null);
    final out = <Map<String, Object?>>[];
    for (final message in latest < 0 ? messages : messages.skip(latest)) {
      final summary = summaryOf(message);
      final blocks = <Map<String, Object?>>[
        if (summary != null) {'type': 'compaction', 'content': summary},
      ];
      for (final block in message.content) {
        switch (block) {
          case TextBlock(:final text):
            if (text.trim().isNotEmpty) {
              blocks.add({'type': 'text', 'text': text});
            }
          case ImageBlock():
            final b64 = block.base64Data;
            if (b64 != null) {
              blocks.add({
                'type': 'image',
                'source': {
                  'type': 'base64',
                  'media_type': block.mediaType ?? 'image/png',
                  'data': b64,
                },
              });
            } else if (block.url != null) {
              blocks.add({
                'type': 'image',
                'source': {'type': 'url', 'url': block.url.toString()},
              });
            }
          case ThinkingBlock(:final redactedData) when redactedData != null:
            if (message.role == Role.assistant) {
              blocks.add({'type': 'redacted_thinking', 'data': redactedData});
            }
          case ThinkingBlock(:final text, :final signature):
            // Only signed blocks can be replayed.
            if (message.role == Role.assistant && signature != null) {
              blocks.add({
                'type': 'thinking',
                'thinking': text,
                'signature': signature,
              });
            }
          case ToolUseBlock(:final id, :final name, :final input):
            blocks.add({
              'type': 'tool_use',
              'id': id,
              'name': name,
              'input': input,
            });
          case ToolResultBlock():
            final text = block.text;
            blocks.add({
              'type': 'tool_result',
              'tool_use_id': block.toolUseId,
              'content': text.isEmpty ? '(no output)' : text,
              if (block.isError) 'is_error': true,
            });
        }
      }
      if (blocks.isEmpty) continue;
      final role = message.role == Role.user ? 'user' : 'assistant';
      if (out.isNotEmpty && out.last['role'] == role) {
        final prev = (out.last['content'] as List).cast<Map<String, Object?>>();
        // tool_result blocks must lead a user turn.
        if (role == 'user' && blocks.any((b) => b['type'] == 'tool_result')) {
          out.last['content'] = [
            ...prev.where((b) => b['type'] == 'tool_result'),
            ...blocks.where((b) => b['type'] == 'tool_result'),
            ...prev.where((b) => b['type'] != 'tool_result'),
            ...blocks.where((b) => b['type'] != 'tool_result'),
          ];
        } else {
          out.last['content'] = [...prev, ...blocks];
        }
      } else {
        out.add({'role': role, 'content': blocks});
      }
    }
    while (out.isNotEmpty &&
        out.first['role'] != 'user' &&
        (out.first['content'] as List).first['type'] != 'compaction') {
      out.removeAt(0);
    }
    if (out.isEmpty || out.last['role'] == 'assistant') {
      out.add({
        'role': 'user',
        'content': [
          {'type': 'text', 'text': 'Continue.'},
        ],
      });
    }
    return out;
  }

  /// Longest compaction summary replayed; a longer one is not trusted.
  static const maxSummaryChars = 200000;

  static String? _summary(AgentMessage message) {
    final meta = message.providerMetadata[compactionMetadataKey];
    final summary = meta is Map ? meta['summary'] : null;
    return summary is String &&
            summary.isNotEmpty &&
            summary.length <= maxSummaryChars
        ? summary
        : null;
  }

  static int _n(Object? v) => v is num ? v.toInt() : 0;

  @override
  Future<void> close() async => _transport.close();
}
