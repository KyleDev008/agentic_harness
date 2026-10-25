import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;

import '../core/cancellation.dart';
import '../core/errors.dart';
import '../core/message.dart';
import '../core/usage.dart';
import '../model/http_transport.dart';
import '../model/model_client.dart';
import '../model/tool_call_accumulator.dart';

/// Configuration for [OpenAiChatClient].
final class OpenAiChatConfig {
  final String model;
  final String? apiKey;

  /// API root, e.g. `https://api.openai.com/v1`,
  /// `https://openrouter.ai/api/v1`, `http://localhost:1234/v1` (LM Studio).
  /// `/chat/completions` is appended.
  final String baseUrl;

  /// Extra headers (e.g. OpenRouter's `HTTP-Referer`).
  final Map<String, String> headers;

  /// Extra query parameters (e.g. Azure's `api-version`).
  final Map<String, String> queryParameters;

  /// Header that carries [apiKey]. `Authorization` sends `Bearer <key>`;
  /// any other name (Azure: `api-key`) sends the raw key.
  final String apiKeyHeader;

  /// Whether [model] is a reasoning model (o-series / gpt-5 family):
  /// `max_completion_tokens` is sent instead of `max_tokens` and
  /// `temperature`/`top_p` are omitted. Defaults to a name heuristic.
  final bool? reasoningModel;

  /// Send `stream_options.include_usage`. Disable for servers that reject
  /// the field.
  final bool requestStreamUsage;

  final int? contextWindow;
  final bool vision;

  const OpenAiChatConfig({
    required this.model,
    this.apiKey,
    this.baseUrl = 'https://api.openai.com/v1',
    this.headers = const {},
    this.queryParameters = const {},
    this.apiKeyHeader = 'Authorization',
    this.reasoningModel,
    this.requestStreamUsage = true,
    this.contextWindow,
    this.vision = true,
  });

  bool get isReasoningModel {
    if (reasoningModel != null) return reasoningModel!;
    final name = model.toLowerCase().split('/').last;
    return RegExp(r'^(o\d|gpt-5)').hasMatch(name);
  }
}

/// [ModelClient] for the OpenAI Chat Completions API and compatible servers
/// (OpenRouter, LM Studio, vLLM, Azure OpenAI, llama.cpp server, …).
///
/// Uses native tool calling: results go back as `role: tool` messages
/// correlated by `tool_call_id`, parallel calls are supported, and usage is
/// requested on the final stream chunk.
class OpenAiChatClient implements ModelClient {
  final OpenAiChatConfig config;
  final HttpTransport _transport;
  final RetryCallback? onRetry;

  OpenAiChatClient(this.config, {HttpTransport? transport, this.onRetry})
    : _transport = transport ?? HttpTransport();

  static const _log = 'agentic_harness.openai';

  @override
  String get id => 'openai:${config.model}';

  @override
  ModelCapabilities get capabilities => ModelCapabilities(
    nativeTools: true,
    parallelToolCalls: true,
    vision: config.vision,
    thinking: config.isReasoningModel,
    structuredOutput: true,
    reportsUsage: true,
    contextWindow: config.contextWindow,
  );

  @override
  Stream<ModelStreamEvent> stream(
    ModelRequest request, {
    CancelToken? cancel,
  }) async* {
    final uri = _endpoint();
    if (uri.scheme == 'http' &&
        config.apiKey != null &&
        !_isLoopback(uri.host)) {
      developer.log(
        'API key will be sent over plaintext HTTP to ${uri.host}',
        name: _log,
        level: 900,
      );
    }
    final body = buildBody(request);
    final response = await _transport.postJson(
      uri,
      body,
      headers: _headers(),
      cancel: cancel,
      onRetry: onRetry,
      logName: _log,
    );

    final contentType = response.headers['content-type'] ?? '';
    if (!contentType.contains('text/event-stream')) {
      yield* _parseBuffered(response, cancel);
      return;
    }

    final calls = ToolCallAccumulator();
    String? finishReason;
    await for (final event in _transport.sseJson(response, cancel: cancel)) {
      final error = event['error'];
      if (error != null) {
        throw ProviderError(
          'Stream error: ${truncateForError(jsonEncode(error))}',
        );
      }
      final usage = event['usage'];
      if (usage is Map) yield UsageReport(parseUsage(usage));

      final choices = event['choices'];
      if (choices is! List || choices.isEmpty) continue;
      final choice = choices.first;
      if (choice is! Map) continue;
      final reason = choice['finish_reason'];
      if (reason is String) finishReason = reason;
      final delta = choice['delta'];
      if (delta is! Map) continue;

      final reasoning = _reasoning(delta);
      if (reasoning.isNotEmpty) yield ThinkingDeltaEvent(reasoning);
      final content = delta['content'];
      if (content is String && content.isNotEmpty) {
        yield TextDeltaEvent(content);
      }

      final toolCalls = delta['tool_calls'];
      if (toolCalls is List) {
        for (final call in toolCalls) {
          if (call is! Map) continue;
          final fn = call['function'];
          final index = call['index'];
          for (final e in calls.add(
            index is num ? index.toInt() : (call['id'] ?? 0),
            id: call['id'] as String?,
            name: fn is Map ? fn['name'] as String? : null,
            argumentsFragment: fn is Map ? fn['arguments'] as String? : null,
          )) {
            yield e;
          }
        }
      }
    }
    final ends = calls.finishAll();
    for (final e in ends) {
      yield e;
    }
    yield MessageStop(_stopReason(finishReason, hasToolCalls: ends.isNotEmpty));
  }

  Stream<ModelStreamEvent> _parseBuffered(
    http.StreamedResponse response,
    CancelToken? cancel,
  ) async* {
    final raw = await readBoundedBody(response, maxBytes: maxStreamBufferChars);
    cancel?.throwIfCancelled();
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      throw ProviderError('Malformed JSON response: ${truncateForError(raw)}');
    }
    if (decoded is! Map) throw const ProviderError('Malformed JSON response');
    final usage = decoded['usage'];
    if (usage is Map) yield UsageReport(parseUsage(usage));
    final choices = decoded['choices'];
    final choice = choices is List && choices.isNotEmpty ? choices.first : null;
    final message = choice is Map ? choice['message'] : null;
    if (message is! Map) {
      yield const MessageStop(ModelStopReason.endTurn);
      return;
    }
    final reasoning = _reasoning(message);
    if (reasoning.isNotEmpty) yield ThinkingDeltaEvent(reasoning);
    final content = message['content'];
    if (content is String && content.isNotEmpty) yield TextDeltaEvent(content);
    final calls = ToolCallAccumulator();
    final toolCalls = message['tool_calls'];
    if (toolCalls is List) {
      var i = 0;
      for (final call in toolCalls) {
        if (call is! Map) continue;
        final fn = call['function'];
        for (final e in calls.add(
          i++,
          id: call['id'] as String?,
          name: fn is Map ? fn['name'] as String? : null,
          argumentsFragment: fn is Map ? '${fn['arguments'] ?? ''}' : null,
        )) {
          yield e;
        }
      }
    }
    final ends = calls.finishAll();
    for (final e in ends) {
      yield e;
    }
    yield MessageStop(
      _stopReason(
        choice is Map ? choice['finish_reason'] as String? : null,
        hasToolCalls: ends.isNotEmpty,
      ),
    );
  }

  /// Builds the Chat Completions request body. Public for tests.
  Map<String, Object?> buildBody(ModelRequest request) {
    final reasoning = config.isReasoningModel;
    final tools = request.tools;
    return {
      'model': config.model,
      'messages': toOpenAiMessages(request.system, request.messages),
      'stream': true,
      if (config.requestStreamUsage) 'stream_options': {'include_usage': true},
      if (tools.isNotEmpty) ...{
        'tools': [
          for (final t in tools)
            {
              'type': 'function',
              'function': {
                'name': t.name,
                'description': t.description,
                'parameters': t.inputSchema,
              },
            },
        ],
        'tool_choice': switch (request.toolChoice) {
          ToolChoice.auto => 'auto',
          ToolChoice.none => 'none',
          ToolChoice.required => 'required',
        },
      },
      if (request.maxOutputTokens != null)
        (reasoning ? 'max_completion_tokens' : 'max_tokens'):
            request.maxOutputTokens,
      if (!reasoning && request.temperature != null)
        'temperature': request.temperature,
      if (!reasoning && request.topP != null) 'top_p': request.topP,
      if (request.outputSchema != null && tools.isEmpty)
        'response_format': {
          'type': 'json_schema',
          'json_schema': {
            'name': 'final_answer',
            'schema': request.outputSchema,
          },
        },
    };
  }

  /// Converts the harness transcript to OpenAI messages.
  static List<Map<String, Object?>> toOpenAiMessages(
    String? system,
    List<AgentMessage> messages,
  ) {
    final out = <Map<String, Object?>>[];
    if (system != null && system.isNotEmpty) {
      out.add({'role': 'system', 'content': system});
    }
    for (final message in messages) {
      if (message.role == Role.assistant) {
        final text = message.text;
        final uses = message.toolUses;
        // e.g. a thinking-only turn — some servers reject empty content.
        if (text.isEmpty && uses.isEmpty) continue;
        out.add({
          'role': 'assistant',
          'content': text.isEmpty && uses.isNotEmpty ? null : text,
          if (uses.isNotEmpty)
            'tool_calls': [
              for (final u in uses)
                {
                  'id': u.id,
                  'type': 'function',
                  'function': {
                    'name': u.name,
                    'arguments': jsonEncode(u.input),
                  },
                },
            ],
        });
        continue;
      }
      // User turn: tool results first (they must directly follow the
      // assistant tool_calls), then any user-authored content.
      for (final result in message.toolResults) {
        out.add({
          'role': 'tool',
          'tool_call_id': result.toolUseId,
          'content': _resultText(result),
        });
      }
      final parts = <Map<String, Object?>>[];
      var hasImage = false;
      for (final block in message.content) {
        switch (block) {
          case TextBlock(:final text) when text.isNotEmpty:
            parts.add({'type': 'text', 'text': text});
          case ImageBlock():
            final url = block.dataUrl ?? block.url?.toString();
            if (url != null) {
              hasImage = true;
              parts.add({
                'type': 'image_url',
                'image_url': {'url': url},
              });
            }
          default:
            break;
        }
      }
      if (parts.isEmpty) continue;
      out.add({
        'role': 'user',
        'content':
            hasImage
                ? parts
                : parts.map((p) => p['text']).whereType<String>().join('\n'),
      });
    }
    return out;
  }

  static String _resultText(ToolResultBlock result) {
    final text = result.text;
    if (text.isNotEmpty) return result.isError ? 'Error: $text' : text;
    return result.isError ? 'Error' : '(no output)';
  }

  /// Parses an OpenAI `usage` object.
  static Usage parseUsage(Map<dynamic, dynamic> usage) {
    int n(Object? v) => v is num ? v.toInt() : 0;
    final details = usage['prompt_tokens_details'];
    return Usage(
      inputTokens: n(usage['prompt_tokens']),
      outputTokens: n(usage['completion_tokens']),
      cacheReadTokens: details is Map ? n(details['cached_tokens']) : 0,
    );
  }

  static String _reasoning(Map<dynamic, dynamic> delta) {
    for (final key in const ['reasoning_content', 'reasoning', 'thinking']) {
      final value = delta[key];
      if (value is String && value.isNotEmpty) return value;
    }
    return '';
  }

  static ModelStopReason _stopReason(
    String? reason, {
    required bool hasToolCalls,
  }) {
    if (hasToolCalls) return ModelStopReason.toolUse;
    return switch (reason) {
      'length' => ModelStopReason.maxTokens,
      'content_filter' => ModelStopReason.refusal,
      _ => ModelStopReason.endTurn,
    };
  }

  Uri _endpoint() {
    var base = config.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    final uri = Uri.parse('$base/chat/completions');
    return config.queryParameters.isEmpty
        ? uri
        : uri.replace(
          queryParameters: {...uri.queryParameters, ...config.queryParameters},
        );
  }

  Map<String, String> _headers() {
    final key = config.apiKey;
    return {
      'Accept': 'text/event-stream',
      if (key != null && key.isNotEmpty)
        config.apiKeyHeader:
            config.apiKeyHeader.toLowerCase() == 'authorization'
                ? 'Bearer $key'
                : key,
      ...config.headers,
    };
  }

  static bool _isLoopback(String host) =>
      host == 'localhost' ||
      host == '127.0.0.1' ||
      host == '::1' ||
      host == '[::1]';

  @override
  Future<void> close() async => _transport.close();
}
