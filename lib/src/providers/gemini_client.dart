import '../core/cancellation.dart';
import '../core/errors.dart';
import '../core/message.dart';
import '../core/usage.dart';
import '../model/http_transport.dart';
import '../model/model_client.dart';
import '../model/tool_call_accumulator.dart';

/// Configuration for [GeminiClient].
final class GeminiConfig {
  final String model;
  final String apiKey;
  final String baseUrl;
  final Map<String, String> headers;
  final int? contextWindow;

  /// `thinkingLevel` for Gemini 3+ models (`minimal`, `low`, `medium`,
  /// `high`). When null, [ThinkingConfig.budgetTokens] is sent as
  /// `thinkingBudget` instead (Gemini 2.5). The API rejects both together.
  final String? thinkingLevel;

  const GeminiConfig({
    required this.model,
    required this.apiKey,
    this.baseUrl = 'https://generativelanguage.googleapis.com/v1beta',
    this.headers = const {},
    this.contextWindow,
    this.thinkingLevel,
  });
}

/// [ModelClient] for the Gemini API (`streamGenerateContent` over SSE).
///
/// Native `functionCall`/`functionResponse` with provider call ids echoed
/// back, streaming text and thoughts, vision, usage, structured output and
/// thinking control. Thought signatures are stored on the assistant
/// message (`providerMetadata['gemini']`) and replayed on the exact part
/// they arrived on, which Gemini 3 requires for multi-step tool use. When
/// the first call of a step has no signature (host-initiated, from another
/// provider, or lost in storage) it gets the documented validator-bypass
/// signature instead. Tool schemas
/// are reduced to the OpenAPI subset Gemini accepts. The API key travels
/// in the `x-goog-api-key` header, never the URL.
class GeminiClient implements ModelClient {
  final GeminiConfig config;
  final HttpTransport _transport;
  final RetryCallback? onRetry;

  GeminiClient(this.config, {HttpTransport? transport, this.onRetry})
    : _transport = transport ?? HttpTransport();

  @override
  String get id => 'gemini:${config.model}';

  @override
  ModelCapabilities get capabilities => ModelCapabilities(
    nativeTools: true,
    vision: true,
    thinking: true,
    structuredOutput: true,
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
    final uri = Uri.parse(
      '$base/models/${Uri.encodeComponent(config.model)}:streamGenerateContent',
    ).replace(queryParameters: {'alt': 'sse'});

    final response = await _transport.postJson(
      uri,
      buildBody(request),
      headers: {'x-goog-api-key': config.apiKey, ...config.headers},
      cancel: cancel,
      onRetry: onRetry,
      logName: 'agentic_harness.gemini',
    );

    final calls = ToolCallAccumulator();
    var hasCalls = false;
    String? finish;
    Usage? usage;
    final signatures = <String, String>{};
    final providerCallIds = <String>[];
    String? textSignature;
    await for (final event in _transport.sseJson(response, cancel: cancel)) {
      final error = event['error'];
      if (error != null) {
        throw ProviderError('Gemini error: ${truncateForError('$error')}');
      }
      final meta = event['usageMetadata'];
      if (meta is Map) {
        int n(Object? v) => v is num ? v.toInt() : 0;
        usage = Usage(
          inputTokens: n(meta['promptTokenCount']),
          outputTokens:
              n(meta['candidatesTokenCount']) + n(meta['thoughtsTokenCount']),
          cacheReadTokens: n(meta['cachedContentTokenCount']),
        );
      }
      final candidates = event['candidates'];
      if (candidates is! List || candidates.isEmpty) continue;
      final candidate = candidates.first;
      if (candidate is! Map) continue;
      if (candidate['finishReason'] is String) {
        finish = candidate['finishReason'] as String;
      }
      final content = candidate['content'];
      final parts = content is Map ? content['parts'] : null;
      if (parts is! List) continue;
      for (final part in parts) {
        if (part is! Map) continue;
        final signature = part['thoughtSignature'] ?? part['thought_signature'];
        final text = part['text'];
        if (text is String && text.isNotEmpty) {
          yield part['thought'] == true
              ? ThinkingDeltaEvent(text)
              : TextDeltaEvent(text);
        }
        final call = part['functionCall'];
        if (call is Map && call['name'] is String) {
          hasCalls = true;
          final providerId = call['id'];
          for (final e in calls.addComplete(
            id: providerId is String ? providerId : null,
            name: call['name'] as String,
            arguments: call['args'],
          )) {
            if (e is ToolUseEndEvent) {
              if (signature is String) signatures[e.id] = signature;
              if (providerId is String && providerId.isNotEmpty) {
                providerCallIds.add(e.id);
              }
            }
            yield e;
          }
        } else if (signature is String && part['thought'] != true) {
          // Text responses carry the signature on the last part (possibly
          // an empty one when streaming).
          textSignature = signature;
        }
      }
    }
    yield MessageMetadataEvent({
      'gemini': {
        if (signatures.isNotEmpty) 'signatures': signatures,
        if (providerCallIds.isNotEmpty) 'callIds': providerCallIds,
        if (textSignature != null) 'textSignature': textSignature,
      },
    });
    if (usage != null) yield UsageReport(usage);
    yield MessageStop(
      hasCalls
          ? ModelStopReason.toolUse
          : switch (finish) {
            'MAX_TOKENS' => ModelStopReason.maxTokens,
            'SAFETY' ||
            'PROHIBITED_CONTENT' ||
            'BLOCKLIST' ||
            'SPII' ||
            'RECITATION' => ModelStopReason.refusal,
            _ => ModelStopReason.endTurn,
          },
    );
  }

  /// Builds the request body. Public for tests.
  Map<String, Object?> buildBody(ModelRequest request) {
    final namesById = <String, String>{};
    final providerIds = <String>{};
    final contents = <Map<String, Object?>>[];
    for (final message in request.messages) {
      final rawMeta = message.providerMetadata['gemini'];
      final meta = rawMeta is Map ? rawMeta : null;
      final rawSignatures = meta?['signatures'];
      final signatures = rawSignatures is Map ? rawSignatures : const {};
      final rawCallIds = meta?['callIds'];
      if (rawCallIds is List) {
        providerIds.addAll(rawCallIds.whereType<String>());
      }
      var firstCall = true;
      final parts = <Map<String, Object?>>[];
      for (final block in message.content) {
        switch (block) {
          case TextBlock(:final text) when text.isNotEmpty:
            parts.add({'text': text});
          case ImageBlock():
            final b64 = block.base64Data;
            if (b64 != null) {
              parts.add({
                'inline_data': {
                  'mime_type': block.mediaType ?? 'image/png',
                  'data': b64,
                },
              });
            }
          case ToolUseBlock(:final id, :final name, :final input):
            namesById[id] = name;
            final signature = _replayable(signatures[id]);
            parts.add({
              'functionCall': {
                if (providerIds.contains(id)) 'id': id,
                'name': name,
                'args': input,
              },
              // Gemini 3 rejects a step whose first call is unsigned.
              if (signature != null)
                'thoughtSignature': signature
              else if (firstCall)
                'thoughtSignature': bypassSignature,
            });
            firstCall = false;
          case ToolResultBlock():
            parts.add({
              'functionResponse': {
                if (providerIds.contains(block.toolUseId))
                  'id': block.toolUseId,
                'name': namesById[block.toolUseId] ?? 'tool',
                'response': {
                  block.isError ? 'error' : 'content':
                      block.text.isEmpty ? '(no output)' : block.text,
                },
              },
            });
          default:
            break;
        }
      }
      if (parts.isEmpty) continue;
      final textSignature = _replayable(meta?['textSignature']);
      if (textSignature != null) {
        final last = parts.lastWhere(
          (p) => p.containsKey('text'),
          orElse: () => const {},
        );
        if (last.isNotEmpty) last['thoughtSignature'] = textSignature;
      }
      final role = message.role == Role.user ? 'user' : 'model';
      if (contents.isNotEmpty && contents.last['role'] == role) {
        contents.last['parts'] = [
          ...(contents.last['parts'] as List),
          ...parts,
        ];
      } else {
        contents.add({'role': role, 'parts': parts});
      }
    }
    final system = request.system;
    return {
      if (system != null && system.isNotEmpty)
        'systemInstruction': {
          'parts': [
            {'text': system},
          ],
        },
      'contents': contents,
      if (request.tools.isNotEmpty)
        'tools': [
          {
            'functionDeclarations': [
              for (final t in request.tools)
                {
                  'name': t.name,
                  'description': t.description,
                  'parameters': sanitizeSchema(t.inputSchema),
                },
            ],
          },
        ],
      if (request.tools.isNotEmpty)
        'toolConfig': {
          'functionCallingConfig': {
            'mode': switch (request.toolChoice) {
              ToolChoice.auto => 'AUTO',
              ToolChoice.none => 'NONE',
              ToolChoice.required => 'ANY',
            },
          },
        },
      'generationConfig': {
        if (request.temperature != null) 'temperature': request.temperature,
        if (request.topP != null) 'topP': request.topP,
        if (request.maxOutputTokens != null)
          'maxOutputTokens': request.maxOutputTokens,
        if (request.outputSchema != null && request.tools.isEmpty) ...{
          'responseMimeType': 'application/json',
          'responseSchema': sanitizeSchema(request.outputSchema!),
        },
        if (thinkingConfig(request.thinking) case final thinking?)
          'thinkingConfig': thinking,
      },
    };
  }

  /// Signature Gemini accepts for function calls it did not generate
  /// (documented for injected calls and histories from other models).
  static const bypassSignature = 'context_engineering_is_the_way_to_go';

  /// History can come from storage or another device, so a stored
  /// signature is replayed only if it is a plausibly sized string.
  static String? _replayable(Object? signature) =>
      signature is String && signature.isNotEmpty && signature.length <= 65536
          ? signature
          : null;

  Map<String, Object?>? thinkingConfig(ThinkingConfig? thinking) {
    final enabled = thinking?.enabled ?? false;
    final level = config.thinkingLevel;
    if (!enabled && level == null) return null;
    return {
      if (enabled) 'includeThoughts': true,
      if (level != null)
        'thinkingLevel': level
      else if (thinking?.budgetTokens case final budget?)
        'thinkingBudget': budget,
    };
  }

  static const _allowedKeys = {
    'type',
    'description',
    'properties',
    'required',
    'items',
    'enum',
    'format',
    'nullable',
    'minimum',
    'maximum',
    'minItems',
    'maxItems',
  };

  /// Reduces a JSON Schema to the OpenAPI subset Gemini accepts: unknown
  /// keywords are dropped, arrays get an `items` schema, and multi-type
  /// lists collapse to their first non-null type.
  static Map<String, Object?> sanitizeSchema(Map<String, Object?> schema) {
    final out = <String, Object?>{};
    for (final entry in schema.entries) {
      if (!_allowedKeys.contains(entry.key)) continue;
      final value = entry.value;
      switch (entry.key) {
        case 'type':
          if (value is List) {
            final types =
                value.whereType<String>().where((t) => t != 'null').toList();
            out['type'] = types.isEmpty ? 'string' : types.first;
            if (value.contains('null')) out['nullable'] = true;
          } else {
            out['type'] = value;
          }
        case 'properties':
          if (value is Map) {
            out['properties'] = {
              for (final p in value.entries)
                if (p.value is Map)
                  '${p.key}': sanitizeSchema(
                    (p.value as Map).cast<String, Object?>(),
                  ),
            };
          }
        case 'items':
          if (value is Map) {
            out['items'] = sanitizeSchema(value.cast<String, Object?>());
          }
        default:
          out[entry.key] = value;
      }
    }
    if (out['type'] == 'array' && out['items'] == null) {
      out['items'] = {'type': 'string'};
    }
    return out;
  }

  @override
  Future<void> close() async => _transport.close();
}
