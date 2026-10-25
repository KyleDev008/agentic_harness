import 'dart:async';
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

/// Configuration for [OllamaClient].
final class OllamaConfig {
  final String model;

  /// Server root, e.g. `http://localhost:11434` or `https://ollama.com`.
  /// Trailing `/v1` or `/api` segments are stripped.
  final String baseUrl;

  /// Bearer key (Ollama Cloud, or an auth proxy in front of a server).
  final String? apiKey;

  /// `num_ctx`. Also reported as the context window, because Ollama
  /// truncates silently instead of erroring when it is exceeded.
  final int? numCtx;

  /// `num_gpu` (layers offloaded to GPU).
  final int? numGpu;

  /// How long the server keeps the model loaded between requests.
  final String keepAlive;
  final Map<String, String> headers;

  const OllamaConfig({
    required this.model,
    this.baseUrl = 'http://localhost:11434',
    this.apiKey,
    this.numCtx,
    this.numGpu,
    this.keepAlive = '30m',
    this.headers = const {},
  });
}

/// [ModelClient] for Ollama's native `/api/chat` endpoint (self-hosted or
/// Ollama Cloud).
///
/// The native endpoint is used rather than the OpenAI shim because the shim
/// drops `options` (`num_ctx`, `num_gpu`), `keep_alive` and `think`.
/// Model capabilities (tools / thinking / vision) are probed once per
/// server+model via `/api/show`, so `think` is only sent to models that
/// support it (others reject it).
class OllamaClient implements ModelClient {
  final OllamaConfig config;
  final HttpTransport _transport;
  final http.Client _probeClient;
  final RetryCallback? onRetry;

  static final Map<String, Set<String>> _capabilityCache = {};

  OllamaClient(
    this.config, {
    HttpTransport? transport,
    http.Client? probeClient,
    this.onRetry,
  }) : _transport = transport ?? HttpTransport(),
       _probeClient = probeClient ?? http.Client();

  static const _log = 'agentic_harness.ollama';

  @override
  String get id => 'ollama:${config.model}';

  @override
  ModelCapabilities get capabilities {
    final caps = _capabilityCache[_cacheKey];
    return ModelCapabilities(
      // Unknown until probed — optimistic, the runner degrades gracefully.
      nativeTools: caps == null || caps.contains('tools'),
      parallelToolCalls: true,
      vision: caps?.contains('vision') ?? true,
      thinking: caps?.contains('thinking') ?? false,
      structuredOutput: true,
      reportsUsage: true,
      contextWindow: config.numCtx,
      maxConcurrency: 2,
    );
  }

  String get _cacheKey => '${normalizeBaseUrl(config.baseUrl)}|${config.model}';

  /// Normalizes a configured base URL to Ollama's API root. Public for tests.
  static String normalizeBaseUrl(String configured) {
    var uri = Uri.parse(configured.trim());
    final host = uri.host.toLowerCase();
    if (host == 'api.ollama.com' || host == 'www.api.ollama.com') {
      uri = uri.replace(host: 'ollama.com');
    }
    var path = uri.path;
    while (true) {
      final before = path;
      while (path.endsWith('/')) {
        path = path.substring(0, path.length - 1);
      }
      for (final suffix in const ['/v1', '/api']) {
        if (path.toLowerCase().endsWith(suffix)) {
          path = path.substring(0, path.length - suffix.length);
        }
      }
      if (path == before) break;
    }
    return Uri(
      scheme: uri.scheme,
      userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
      host: uri.hasAuthority ? uri.host : null,
      port: uri.hasPort ? uri.port : null,
      path: path,
    ).toString();
  }

  /// Fetches (and caches) the model's capability list from `/api/show`.
  /// Returns `null` when the server does not report capabilities.
  Future<Set<String>?> probeCapabilities() async {
    final cached = _capabilityCache[_cacheKey];
    if (cached != null) return cached;
    try {
      final request =
          http.Request(
              'POST',
              Uri.parse('${normalizeBaseUrl(config.baseUrl)}/api/show'),
            )
            ..followRedirects = false
            ..headers.addAll(_headers())
            ..body = jsonEncode({'model': config.model});
      final response = await _probeClient
          .send(request)
          .timeout(const Duration(seconds: 10));
      final body = await readBoundedBody(response, maxBytes: 512 * 1024);
      if (response.statusCode != 200) return null;
      final decoded = jsonDecode(body);
      final caps = decoded is Map ? decoded['capabilities'] : null;
      if (caps is! List) return null;
      final set = caps.whereType<String>().toSet();
      _capabilityCache[_cacheKey] = set;
      return set;
    } catch (e) {
      developer.log('capability probe failed: ${e.runtimeType}', name: _log);
      return null;
    }
  }

  @override
  Stream<ModelStreamEvent> stream(
    ModelRequest request, {
    CancelToken? cancel,
  }) async* {
    final caps = await probeCapabilities();
    final wantsThinking = request.thinking?.enabled ?? false;
    final canThink = caps?.contains('thinking') ?? false;
    final sendTools =
        request.tools.isNotEmpty &&
        request.toolChoice != ToolChoice.none &&
        (caps == null || caps.contains('tools'));

    final body = <String, Object?>{
      'model': config.model,
      'messages': toOllamaMessages(request.system, request.messages),
      'stream': true,
      'keep_alive': config.keepAlive,
      if (sendTools)
        'tools': [
          for (final t in request.tools)
            {
              'type': 'function',
              'function': {
                'name': t.name,
                'description': t.description,
                'parameters': t.inputSchema,
              },
            },
        ],
      if (wantsThinking && canThink) 'think': true,
      if (request.outputSchema != null && !sendTools)
        'format': request.outputSchema,
      'options': {
        if (request.temperature != null) 'temperature': request.temperature,
        if (request.topP != null) 'top_p': request.topP,
        if (request.maxOutputTokens != null)
          'num_predict': request.maxOutputTokens,
        if (config.numCtx != null) 'num_ctx': config.numCtx,
        if (config.numGpu != null) 'num_gpu': config.numGpu,
      },
    };

    final uri = Uri.parse('${normalizeBaseUrl(config.baseUrl)}/api/chat');
    final response = await _transport.postJson(
      uri,
      body,
      headers: _headers(),
      cancel: cancel,
      onRetry: onRetry,
      logName: _log,
    );

    final calls = ToolCallAccumulator();
    var hasCalls = false;
    String? doneReason;
    await for (final event in _transport.ndjson(response, cancel: cancel)) {
      final error = event['error'];
      if (error != null) {
        throw ProviderError('Ollama error: ${truncateForError('$error')}');
      }
      final message = event['message'];
      if (message is Map) {
        final thinking = message['thinking'];
        if (thinking is String && thinking.isNotEmpty) {
          yield ThinkingDeltaEvent(thinking);
        }
        final content = message['content'];
        if (content is String && content.isNotEmpty) {
          yield TextDeltaEvent(content);
        }
        final toolCalls = message['tool_calls'];
        if (toolCalls is List) {
          for (final call in toolCalls) {
            if (call is! Map) continue;
            final fn = call['function'];
            if (fn is! Map) continue;
            final name = fn['name'];
            if (name is! String || name.isEmpty) continue;
            hasCalls = true;
            for (final e in calls.addComplete(
              id: call['id'] as String?,
              name: name,
              arguments: fn['arguments'],
            )) {
              yield e;
            }
          }
        }
      }
      if (event['done'] == true) {
        doneReason = event['done_reason'] as String?;
        int n(Object? v) => v is num ? v.toInt() : 0;
        yield UsageReport(
          Usage(
            inputTokens: n(event['prompt_eval_count']),
            outputTokens: n(event['eval_count']),
          ),
        );
      }
    }
    yield MessageStop(
      hasCalls
          ? ModelStopReason.toolUse
          : doneReason == 'length'
          ? ModelStopReason.maxTokens
          : ModelStopReason.endTurn,
    );
  }

  /// Converts the harness transcript to Ollama native messages.
  static List<Map<String, Object?>> toOllamaMessages(
    String? system,
    List<AgentMessage> messages,
  ) {
    final namesById = <String, String>{};
    final out = <Map<String, Object?>>[];
    if (system != null && system.isNotEmpty) {
      out.add({'role': 'system', 'content': system});
    }
    for (final message in messages) {
      if (message.role == Role.assistant) {
        final uses = message.toolUses;
        for (final u in uses) {
          namesById[u.id] = u.name;
        }
        out.add({
          'role': 'assistant',
          'content': message.text,
          if (uses.isNotEmpty)
            'tool_calls': [
              for (final u in uses)
                {
                  'function': {'name': u.name, 'arguments': u.input},
                },
            ],
        });
        continue;
      }
      for (final result in message.toolResults) {
        final text = result.text;
        out.add({
          'role': 'tool',
          'content':
              result.isError
                  ? 'Error: $text'
                  : (text.isEmpty ? '(no output)' : text),
          if (namesById[result.toolUseId] != null)
            'tool_name': namesById[result.toolUseId],
        });
      }
      final text = message.content
          .whereType<TextBlock>()
          .map((b) => b.text)
          .where((t) => t.isNotEmpty)
          .join('\n');
      final images = [
        for (final img in message.content.whereType<ImageBlock>())
          if (img.base64Data != null) img.base64Data!,
      ];
      if (text.isEmpty && images.isEmpty) continue;
      out.add({
        'role': 'user',
        'content': text,
        if (images.isNotEmpty) 'images': images,
      });
    }
    return out;
  }

  Map<String, String> _headers() {
    final key = config.apiKey;
    return {
      if (key != null && key.isNotEmpty) 'Authorization': 'Bearer $key',
      ...config.headers,
    };
  }

  @override
  Future<void> close() async {
    _transport.close();
    _probeClient.close();
  }
}
