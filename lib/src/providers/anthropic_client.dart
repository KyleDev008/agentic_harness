import 'dart:convert';

import '../core/cancellation.dart';
import '../core/errors.dart';
import '../core/message.dart';
import '../core/usage.dart';
import '../model/http_transport.dart';
import '../model/model_client.dart';
import '../model/tool_call_accumulator.dart';

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
    this.contextWindow,
  });

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
    structuredOutput: false,
    promptCaching: config.promptCaching,
    reportsUsage: true,
    contextWindow: config.contextWindow,
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
        if (config.usesRefusalFallback)
          'anthropic-beta': 'server-side-fallback-2026-07-01',
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
    final schemaHint =
        request.outputSchema == null
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
      'messages': toAnthropicMessages(request.messages),
      // With tool_choice none the definitions are still sent: a transcript
      // holding tool_use/tool_result blocks is rejected without them.
      if (tools.isNotEmpty) ...{
        if (request.toolChoice == ToolChoice.none)
          'tool_choice': {'type': 'none'},
        'tools': [
          for (var i = 0; i < tools.length; i++)
            {
              'name': tools[i].name,
              'description': tools[i].description,
              'input_schema': tools[i].inputSchema,
              if (config.eagerInputStreaming) 'eager_input_streaming': true,
              if (caching && i == tools.length - 1)
                'cache_control': {'type': 'ephemeral'},
            },
        ],
      },
      if (thinkingOn) 'thinking': {'type': 'adaptive', 'display': 'summarized'},
      if (config.effort != null) 'output_config': {'effort': config.effort},
      // Never both: several models reject temperature + top_p together.
      if (sampling && request.temperature != null)
        'temperature': request.temperature
      else if (sampling && request.topP != null)
        'top_p': request.topP,
      if (caching) 'cache_control': {'type': 'ephemeral'},
      if (config.usesRefusalFallback) 'fallbacks': 'default',
    };
  }

  /// Converts the harness transcript to Anthropic messages: consecutive
  /// same-role turns are merged, empty text is dropped, and the transcript
  /// always starts with a user turn and never ends with an assistant turn.
  static List<Map<String, Object?>> toAnthropicMessages(
    List<AgentMessage> messages,
  ) {
    final out = <Map<String, Object?>>[];
    for (final message in messages) {
      final blocks = <Map<String, Object?>>[];
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
    while (out.isNotEmpty && out.first['role'] != 'user') {
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

  static int _n(Object? v) => v is num ? v.toInt() : 0;

  @override
  Future<void> close() async => _transport.close();
}
