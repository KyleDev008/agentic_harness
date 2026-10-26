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

/// Configuration for [OpenAiResponsesClient].
final class OpenAiResponsesConfig {
  final String model;
  final String? apiKey;

  /// API root; `/responses` is appended.
  final String baseUrl;
  final Map<String, String> headers;

  /// Extra query parameters (e.g. Azure's `api-version`).
  final Map<String, String> queryParameters;

  /// Header that carries [apiKey]. `Authorization` sends `Bearer <key>`;
  /// any other name (Azure: `api-key`) sends the raw key.
  final String apiKeyHeader;

  /// Whether [model] reasons (o-series / gpt-5 and later): sampling
  /// parameters are omitted and reasoning items are carried between turns.
  /// Defaults to a name heuristic; set it for deployments with custom names
  /// (Azure).
  final bool? reasoningModel;

  /// `reasoning.effort` (`minimal` … `high`, model-dependent). `null` uses
  /// the model default.
  final String? reasoningEffort;

  /// `reasoning.summary` when thinking is requested (`auto`, `concise`,
  /// `detailed`); summaries stream as thinking text. Some organizations
  /// must be verified to get summaries: set null to ask for none.
  final String? reasoningSummary;

  /// Let OpenAI store responses. Off by default: the client is stateless
  /// and carries encrypted reasoning between turns itself, which also works
  /// under zero data retention.
  final bool store;

  /// With [store], send `previous_response_id` and only the turns after the
  /// last stored response instead of the whole history. OpenAI then keeps
  /// the conversation (30 days by default; not available under zero data
  /// retention). The client chains only when the earlier history is exactly
  /// what that response saw, so compaction or edits fall back to a full
  /// resend.
  final bool chainResponses;

  final int? contextWindow;
  final bool vision;

  const OpenAiResponsesConfig({
    required this.model,
    this.apiKey,
    this.baseUrl = 'https://api.openai.com/v1',
    this.headers = const {},
    this.queryParameters = const {},
    this.apiKeyHeader = 'Authorization',
    this.reasoningModel,
    this.reasoningEffort,
    this.reasoningSummary = 'auto',
    this.store = false,
    this.chainResponses = false,
    this.contextWindow,
    this.vision = true,
  }) : assert(!chainResponses || store, 'chainResponses requires store');

  bool get isReasoningModel {
    if (reasoningModel != null) return reasoningModel!;
    final name = model.toLowerCase().split('/').last;
    return RegExp(r'^(o\d|gpt-[5-9]|gpt-\d{2})').hasMatch(name);
  }
}

/// [ModelClient] for the OpenAI Responses API (`/v1/responses`).
///
/// Function calls and their outputs are `function_call` /
/// `function_call_output` items correlated by `call_id`. Reasoning items
/// (with `encrypted_content` when [OpenAiResponsesConfig.store] is off) are
/// kept on the assistant message (`providerMetadata['openaiResponses']`)
/// and replayed in their original order, so a reasoning model keeps its
/// chain of thought across tool calls. Reasoning summaries stream as
/// thinking.
class OpenAiResponsesClient implements ModelClient {
  final OpenAiResponsesConfig config;
  final HttpTransport _transport;
  final RetryCallback? onRetry;

  OpenAiResponsesClient(this.config, {HttpTransport? transport, this.onRetry})
    : _transport = transport ?? HttpTransport();

  static const _log = 'agentic_harness.openai_responses';

  /// `AgentMessage.providerMetadata` key for this client's state:
  /// `{'id', 'stored', 'prefix', 'items'}`, where items are reasoning items
  /// and `{'message': text}` / `{'call': callId}` placeholders in output
  /// order, and `prefix` fingerprints the history the response saw.
  static const metadataKey = 'openaiResponses';

  /// Most reasoning items kept from, and replayed for, one response.
  static const int maxReasoningItems = 64;

  /// Largest `encrypted_content` kept; a larger item is dropped.
  static const int maxEncryptedChars = 1024 * 1024;

  /// Longest reasoning summary part kept.
  static const int maxSummaryChars = 16000;

  /// Most text, arguments and reasoning one response may stream.
  static const int maxResponseChars = 16 * 1024 * 1024;

  @override
  String get id => 'openai-responses:${config.model}';

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
        (config.apiKey ?? '').isNotEmpty &&
        !_isLoopback(uri.host)) {
      developer.log(
        'API key will be sent over plaintext HTTP to ${uri.host}',
        name: _log,
        level: 900,
      );
    }
    // A chained request whose stored response is gone (expired after 30
    // days, deleted, or another project) is sent again with the full
    // history, as long as nothing has been streamed yet.
    var chain = true;
    while (true) {
      final chained = chain && _canChain(request);
      var started = false;
      try {
        await for (final event in _attempt(uri, request, chain, cancel)) {
          started = true;
          yield event;
        }
        return;
      } on HarnessError catch (e) {
        if (!chained || started || !_previousResponseMissing(e)) rethrow;
        developer.log(
          'stored response unavailable; resending the full history',
          name: _log,
          level: 900,
        );
        chain = false;
      }
    }
  }

  bool _canChain(ModelRequest request) =>
      config.store &&
      config.chainResponses &&
      _chainPoint(request.system, request.messages) != null;

  /// Whether [e] says the `previous_response_id` can't be found.
  static bool _previousResponseMissing(HarnessError e) {
    final message = e.message.toLowerCase();
    if (e is NotFoundError) return message.contains('response');
    return e is ProviderError &&
        (message.contains('previous_response') ||
            (e.statusCode == 400 && message.contains('not found')));
  }

  Stream<ModelStreamEvent> _attempt(
    Uri uri,
    ModelRequest request,
    bool chain,
    CancelToken? cancel,
  ) async* {
    final response = await _transport.postJson(
      uri,
      buildBody(request, chain: chain),
      headers: _headers(),
      cancel: cancel,
      onRetry: onRetry,
      logName: _log,
    );
    final state = _ResponseState(
      stored: config.store,
      prefix: _fingerprint(request.system, request.messages),
    );
    final contentType = response.headers['content-type'] ?? '';
    if (!contentType.contains('text/event-stream')) {
      yield* _parseBuffered(response, state, cancel);
      return;
    }
    await for (final event in _transport.sseJson(response, cancel: cancel)) {
      for (final e in state.handle(event)) {
        yield e;
      }
      if (state.done) break;
    }
    yield* state.finish();
  }

  Stream<ModelStreamEvent> _parseBuffered(
    http.StreamedResponse response,
    _ResponseState state,
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
    final status = decoded['status'];
    if (decoded['error'] is Map ||
        status == 'failed' ||
        status == 'cancelled') {
      throw _ResponseState.error(decoded['error'] ?? {'code': status});
    }
    final output = decoded['output'];
    if (output is List) {
      for (var i = 0; i < output.length; i++) {
        final item = output[i];
        if (item is! Map) continue;
        for (final e in state.handle({
          'type': 'response.output_item.done',
          'output_index': i,
          'item': item,
        })) {
          yield e;
        }
      }
    }
    for (final e in state.handle({
      'type': 'response.${status == 'incomplete' ? 'incomplete' : 'completed'}',
      'response': decoded,
    })) {
      yield e;
    }
    yield* state.finish();
  }

  /// Builds the request body. Public for tests.
  ///
  /// With [chain] false, the full history is sent even when the request
  /// could be chained.
  Map<String, Object?> buildBody(ModelRequest request, {bool chain = true}) {
    final reasoning = config.isReasoningModel;
    final thinkingOn = request.thinking?.enabled ?? false;
    final tools = request.tools;
    final chained =
        chain && config.store && config.chainResponses
            ? _chainPoint(request.system, request.messages)
            : null;
    final schema = request.outputSchema;
    final summary = thinkingOn ? config.reasoningSummary : null;
    return {
      'model': config.model,
      if (request.system != null && request.system!.isNotEmpty)
        'instructions': request.system,
      'input': toResponsesInput(
        chained == null
            ? request.messages
            : request.messages.sublist(chained.$1 + 1),
        store: config.store,
      ),
      if (chained != null) 'previous_response_id': chained.$2,
      'stream': true,
      'store': config.store,
      if (reasoning && !config.store)
        'include': ['reasoning.encrypted_content'],
      if (reasoning && (summary != null || config.reasoningEffort != null))
        'reasoning': {
          if (config.reasoningEffort != null) 'effort': config.reasoningEffort,
          if (summary != null) 'summary': summary,
        },
      if (tools.isNotEmpty) ...{
        'tools': [
          for (final t in tools)
            {
              'type': 'function',
              'name': t.name,
              'description': t.description,
              'parameters': t.inputSchema,
              // The runner validates inputs; strict mode would reject
              // schemas that aren't fully required/closed.
              'strict': false,
            },
        ],
        'tool_choice': switch (request.toolChoice) {
          ToolChoice.auto => 'auto',
          ToolChoice.none => 'none',
          ToolChoice.required => 'required',
        },
      },
      if (request.maxOutputTokens != null)
        'max_output_tokens': request.maxOutputTokens,
      if (!reasoning && request.temperature != null)
        'temperature': request.temperature,
      if (!reasoning && request.topP != null) 'top_p': request.topP,
      if (schema != null && tools.isEmpty)
        'text': {
          'format': {
            'type': 'json_schema',
            'name': 'final_answer',
            'schema': schema,
            'strict': false,
          },
        },
      if (request.cacheKey != null) 'prompt_cache_key': request.cacheKey,
    };
  }

  /// The last assistant message to chain from: written by this client with
  /// `store` on, after exactly the history it saw then, with newer turns
  /// after it. Returns its index and response id.
  (int, String)? _chainPoint(String? system, List<AgentMessage> messages) {
    final i = messages.lastIndexWhere((m) => m.role == Role.assistant);
    if (i < 0 || i == messages.length - 1) return null;
    final meta = messages[i].providerMetadata[metadataKey];
    if (meta is! Map || meta['stored'] != true) return null;
    final id = meta['id'];
    if (id is! String || id.isEmpty || id.length > 256) return null;
    if (meta['prefix'] != _fingerprint(system, messages.sublist(0, i))) {
      return null;
    }
    return (i, id);
  }

  /// Fingerprint of the endpoint, model, instructions and history a
  /// response was made from (FNV-1a, two seeds; not a security hash).
  String _fingerprint(String? system, List<AgentMessage> messages) {
    final text = jsonEncode([
      config.baseUrl,
      config.model,
      system ?? '',
      for (final m in messages) m.toJson(),
    ]);
    String fnv(int seed) {
      var hash = seed;
      for (final unit in text.codeUnits) {
        hash ^= unit;
        hash = (hash * 0x01000193) & 0xffffffff;
      }
      return hash.toRadixString(16).padLeft(8, '0');
    }

    return fnv(0x811c9dc5) + fnv(0x050c5d1f);
  }

  /// Converts the harness transcript to Responses API input items. With
  /// [store] off, reasoning items without `encrypted_content` are left out
  /// (the API could not resolve them).
  static List<Map<String, Object?>> toResponsesInput(
    List<AgentMessage> messages, {
    bool store = false,
  }) {
    final out = <Map<String, Object?>>[];
    for (final message in messages) {
      if (message.role == Role.assistant) {
        out.addAll(_assistantItems(message, store: store));
        continue;
      }
      for (final result in message.toolResults) {
        out.add({
          'type': 'function_call_output',
          'call_id': result.toolUseId,
          'output': _resultOutput(result),
        });
      }
      final parts = <Map<String, Object?>>[
        for (final block in message.content)
          if (block is TextBlock && block.text.isNotEmpty)
            {'type': 'input_text', 'text': block.text}
          else if (block is ImageBlock && _imageUrl(block) != null)
            {'type': 'input_image', 'image_url': _imageUrl(block)},
      ];
      if (parts.isNotEmpty) {
        out.add({'role': 'user', 'content': parts});
      }
    }
    return out;
  }

  /// An assistant turn's items, with its reasoning items back in place.
  static List<Map<String, Object?>> _assistantItems(
    AgentMessage message, {
    required bool store,
  }) {
    final text = message.text;
    final uses = {for (final u in message.toolUses) u.id: u};
    Map<String, Object?> textItem(String text) => {
      'type': 'message',
      'role': 'assistant',
      'content': [
        {'type': 'output_text', 'text': text},
      ],
    };
    Map<String, Object?> callItem(ToolUseBlock u) => {
      'type': 'function_call',
      'call_id': u.id,
      'name': u.name,
      'arguments': jsonEncode(u.input),
    };

    final meta = message.providerMetadata[metadataKey];
    final order =
        meta is Map && meta['items'] is List
            ? (meta['items'] as List)
                .whereType<Map<dynamic, dynamic>>()
                .toList()
            : const <Map<dynamic, dynamic>>[];
    // Per-message texts are used only if they still add up to the turn's
    // text; otherwise the whole text goes in the first message slot.
    final parts = [
      for (final entry in order)
        if (entry.containsKey('message')) entry['message'],
    ];
    final split =
        parts.every((p) => p is String) &&
        parts.join() == text &&
        text.isNotEmpty;

    final out = <Map<String, Object?>>[];
    var textSent = text.isEmpty;
    var reasoningCount = 0;
    for (final entry in order) {
      if (entry['type'] == 'reasoning') {
        if (reasoningCount >= maxReasoningItems) continue;
        final item = _replayReasoning(entry, store: store);
        if (item != null) {
          out.add(item);
          reasoningCount++;
        }
      } else if (entry.containsKey('message')) {
        if (split) {
          final part = entry['message'] as String;
          if (part.isNotEmpty) out.add(textItem(part));
          textSent = true;
        } else if (!textSent) {
          out.add(textItem(text));
          textSent = true;
        }
      } else if (uses.remove(entry['call']) case final use?) {
        out.add(callItem(use));
      }
    }
    // Reasoning must be followed by the output it led to.
    while (out.isNotEmpty && out.last['type'] == 'reasoning') {
      out.removeLast();
    }
    // Anything the order doesn't cover (another client wrote the turn).
    if (!textSent) out.add(textItem(text));
    out.addAll(uses.values.map(callItem));
    return out;
  }

  /// A stored reasoning item rebuilt from known fields only, or null when
  /// it can't be replayed.
  static Map<String, Object?>? _replayReasoning(
    Map<dynamic, dynamic> entry, {
    required bool store,
  }) {
    final id = entry['id'];
    final encrypted = entry['encrypted_content'];
    final validId = id is String && id.isNotEmpty && id.length <= 256;
    final validEncrypted =
        encrypted is String && encrypted.length <= maxEncryptedChars;
    if (!validEncrypted && (!store || !validId)) return null;
    final summary = entry['summary'];
    return {
      'type': 'reasoning',
      if (validId) 'id': id,
      'summary': [
        if (summary is List)
          for (final s in summary.take(16))
            if (s is Map && s['text'] is String)
              {
                'type': 'summary_text',
                'text': _cap(s['text'] as String, maxSummaryChars),
              },
      ],
      if (validEncrypted) 'encrypted_content': encrypted,
    };
  }

  static Object _resultOutput(ToolResultBlock result) {
    final text = result.text;
    final body =
        text.isNotEmpty
            ? (result.isError ? 'Error: $text' : text)
            : (result.isError ? 'Error' : '(no output)');
    final images = [
      for (final b in result.content.whereType<ImageBlock>())
        if (_imageUrl(b) != null)
          {'type': 'input_image', 'image_url': _imageUrl(b)},
    ];
    if (images.isEmpty) return body;
    return [
      {'type': 'input_text', 'text': body},
      ...images,
    ];
  }

  static String? _imageUrl(ImageBlock block) =>
      block.dataUrl ?? block.url?.toString();

  static String _cap(String text, int max) =>
      text.length <= max ? text : text.substring(0, max);

  /// Parses a Responses `usage` object.
  static Usage parseUsage(Map<dynamic, dynamic> usage) {
    int n(Object? v) => v is num ? v.toInt() : 0;
    final details = usage['input_tokens_details'];
    return Usage(
      inputTokens: n(usage['input_tokens']),
      outputTokens: n(usage['output_tokens']),
      cacheReadTokens: details is Map ? n(details['cached_tokens']) : 0,
      cacheWriteTokens: details is Map ? n(details['cache_write_tokens']) : 0,
    );
  }

  Uri _endpoint() {
    var base = config.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    final uri = Uri.parse('$base/responses');
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

/// Turns Responses stream events into harness events.
class _ResponseState {
  final bool stored;
  final String prefix;
  _ResponseState({required this.stored, required this.prefix});

  static const _log = 'agentic_harness.openai_responses';
  static const int _maxIndex = 1023;

  final calls = ToolCallAccumulator();

  /// Output indexes whose arguments or text arrived as deltas, and calls
  /// already named (the accumulator appends names).
  final Set<int> _streamedArgs = {};
  final Set<int> _streamedText = {};
  final Set<int> _startedCalls = {};

  /// Output order: reasoning items and placeholders, by output index.
  final Map<int, Map<String, Object?>> _items = {};
  final Map<int, StringBuffer> _texts = {};
  final Map<int, StringBuffer> _summaries = {};
  String? _responseId;
  Usage? _usage;
  String? _incompleteReason;
  bool _refused = false;
  int _chars = 0;
  bool done = false;

  void _count(int chars) {
    _chars += chars;
    if (_chars > OpenAiResponsesClient.maxResponseChars) {
      throw const ProviderError('The response is too large.');
    }
  }

  List<ModelStreamEvent> handle(Map<String, Object?> event) {
    final out = <ModelStreamEvent>[];
    final type = event['type'];
    final rawIndex = event['output_index'];
    final index = rawIndex is num ? rawIndex.toInt() : -1;
    if (rawIndex != null && (index < 0 || index > _maxIndex)) return out;
    switch (type) {
      case 'response.created' || 'response.in_progress':
        final response = event['response'];
        if (response is Map && response['id'] is String) {
          _responseId = response['id'] as String;
        }
      case 'response.output_item.added':
        final item = event['item'];
        if (item is! Map) break;
        if (item['type'] == 'function_call') {
          final callId = _string(item['call_id']);
          final name = _string(item['name']);
          _items[index] = {'call': callId};
          if (name != null && name.isNotEmpty) {
            _startedCalls.add(index);
            out.addAll(calls.add(index, id: callId, name: name));
          }
        } else if (item['type'] == 'message') {
          _items[index] = {'message': ''};
        }
      case 'response.output_text.delta' || 'response.refusal.delta':
        final delta = event['delta'];
        if (type == 'response.refusal.delta') _refused = true;
        if (delta is String && delta.isNotEmpty) {
          _count(delta.length);
          _streamedText.add(index);
          _items[index] ??= {'message': ''};
          (_texts[index] ??= StringBuffer()).write(delta);
          out.add(TextDeltaEvent(delta));
        }
      case 'response.function_call_arguments.delta':
        final delta = event['delta'];
        if (delta is String && delta.isNotEmpty) {
          _count(delta.length);
          _streamedArgs.add(index);
          out.addAll(calls.add(index, argumentsFragment: delta));
        }
      case 'response.reasoning_summary_text.delta':
        final delta = event['delta'];
        if (delta is String && delta.isNotEmpty) {
          _count(delta.length);
          (_summaries[index] ??= StringBuffer()).write(delta);
          out.add(ThinkingDeltaEvent(delta));
        }
      case 'response.reasoning_summary_part.done':
        final buffer = _summaries[index];
        if (buffer != null && buffer.isNotEmpty) {
          buffer.write('\n\n');
          out.add(const ThinkingDeltaEvent('\n\n'));
        }
      case 'response.output_item.done':
        final item = event['item'];
        if (item is Map) out.addAll(_itemDone(index, item));
      case 'response.completed' || 'response.incomplete':
        final response = event['response'];
        if (response is Map) {
          if (response['id'] is String) _responseId = response['id'] as String;
          final usage = response['usage'];
          if (usage is Map) _usage = OpenAiResponsesClient.parseUsage(usage);
          final details = response['incomplete_details'];
          if (details is Map) _incompleteReason = _string(details['reason']);
        }
        done = true;
      case 'response.failed' || 'error':
        final response = event['response'];
        throw error(
          response is Map ? response['error'] : (event['error'] ?? event),
        );
    }
    return out;
  }

  List<ModelStreamEvent> _itemDone(int index, Map<dynamic, dynamic> item) {
    switch (item['type']) {
      case 'reasoning':
        final encrypted = item['encrypted_content'];
        if (encrypted is String) _count(encrypted.length);
        final kept =
            _items.values.where((i) => i['type'] == 'reasoning').length;
        final summary = item['summary'];
        final parts = [
          if (summary is List)
            for (final s in summary)
              if (s is Map && s['text'] is String)
                OpenAiResponsesClient._cap(
                  s['text'] as String,
                  OpenAiResponsesClient.maxSummaryChars,
                ),
        ];
        if (kept < OpenAiResponsesClient.maxReasoningItems &&
            (encrypted is! String ||
                encrypted.length <= OpenAiResponsesClient.maxEncryptedChars)) {
          final id = _string(item['id']);
          _items[index] = {
            'type': 'reasoning',
            if (id != null) 'id': id,
            'summary': [
              for (final text in parts) {'type': 'summary_text', 'text': text},
            ],
            if (encrypted is String) 'encrypted_content': encrypted,
          };
        } else {
          developer.log('reasoning item not kept (cap)', name: _log);
        }
        final text =
            parts.isNotEmpty
                ? parts.join('\n\n')
                : (_summaries[index]?.toString().trim() ?? '');
        return text.isEmpty ? const [] : [ThinkingCompleteEvent(text)];
      case 'message':
        final content = item['content'];
        final texts = <String>[];
        if (content is List) {
          for (final part in content) {
            if (part is! Map) continue;
            if (part['type'] == 'refusal') _refused = true;
            final text = part['text'] ?? part['refusal'];
            if (text is String && text.isNotEmpty) texts.add(text);
          }
        }
        final streamed = _streamedText.contains(index);
        final text = streamed ? _texts[index].toString() : texts.join();
        _items[index] = {'message': text};
        if (streamed) return const [];
        _count(text.length);
        return [for (final t in texts) TextDeltaEvent(t)];
      case 'function_call':
        final callId = _string(item['call_id']);
        final name = _string(item['name']);
        _items[index] = {'call': callId};
        final events = <ModelStreamEvent>[
          if (name != null && name.isNotEmpty && _startedCalls.add(index))
            ...calls.add(index, id: callId, name: name),
        ];
        if (!_streamedArgs.contains(index)) {
          final args = item['arguments'];
          if (args is String && args.isNotEmpty) {
            _count(args.length);
            events.addAll(calls.add(index, argumentsFragment: args));
          }
        }
        return events;
      default:
        return const [];
    }
  }

  Stream<ModelStreamEvent> finish() async* {
    if (!done) {
      throw const NetworkError(
        'The response stream ended before it completed.',
      );
    }
    final ends = calls.finishAll();
    for (final e in ends) {
      yield e;
    }
    // Streamed text whose item never reported done.
    for (final entry in _texts.entries) {
      if (_items[entry.key] case {'message': ''}) {
        _items[entry.key] = {'message': entry.value.toString()};
      }
    }
    final ordered = (_items.keys.toList()..sort()).map((k) => _items[k]!);
    yield MessageMetadataEvent({
      OpenAiResponsesClient.metadataKey: {
        if (_responseId != null) 'id': _responseId,
        'stored': stored,
        'prefix': prefix,
        'items': ordered.toList(),
      },
    });
    if (_usage case final usage?) yield UsageReport(usage);
    yield MessageStop(switch (_incompleteReason) {
      _ when ends.whereType<ToolUseEndEvent>().isNotEmpty =>
        ModelStopReason.toolUse,
      'max_output_tokens' => ModelStopReason.maxTokens,
      'content_filter' => ModelStopReason.refusal,
      _ when _refused => ModelStopReason.refusal,
      _ => ModelStopReason.endTurn,
    });
  }

  /// Maps a Responses error object to a typed error.
  static HarnessError error(Object? error) {
    final code = truncateForError(
      error is Map ? '${error['code'] ?? error['type'] ?? ''}' : '',
      64,
    );
    final raw = error is Map ? error['message'] : null;
    final message = truncateForError(
      raw is String && raw.isNotEmpty ? raw : 'no details',
    );
    developer.log('response failed ($code)', name: _log, level: 900);
    return switch (code) {
      'rate_limit_exceeded' => RateLimitError(message),
      'server_error' || 'server_is_overloaded' => OverloadedError(message),
      'context_length_exceeded' => ContextOverflowError(message),
      _ => ProviderError('Response failed ($code): $message'),
    };
  }

  static String? _string(Object? v) => v is String ? v : null;
}
