import 'dart:convert';

import '../core/cancellation.dart';
import '../core/ids.dart';
import '../core/message.dart';
import '../model/model_client.dart';

/// Adds tool calling to a [ModelClient] that has no native tool support
/// (on-device models, text-only proxies) by teaching the model a strict
/// text protocol and parsing it back into normal tool-use events.
///
/// Protocol (appended to the system prompt):
///
/// ````text
/// ```tool_call
/// {"name": "<tool>", "arguments": {...}}
/// ```
/// ````
///
/// `<tool_call>{...}</tool_call>` is accepted too (common in models trained
/// on that format). Guarantees:
/// - protocol text never appears in `TextDeltaEvent`s — text that could be
///   the start of a marker is held back until it is disambiguated;
/// - text the model writes *after* a tool call (often hallucinated results)
///   is dropped when it contains a results marker;
/// - a malformed call triggers one repair request; if that fails the call
///   is surfaced with a parse error so the runner reports it to the model;
/// - the exact raw output is stored as `providerMetadata['rawText']`, and
///   prior assistant turns are re-rendered from it byte-identically, so
///   stateful backends can reuse their KV cache.
class PromptedToolCallingClient implements ModelClient {
  final ModelClient inner;

  PromptedToolCallingClient(this.inner);

  static const _openFence = '```tool_call';
  static const _closeFence = '```';
  static const _openTag = '<tool_call>';
  static const _closeTag = '</tool_call>';
  static const _resultsHeader = 'Tool results:';

  @override
  String get id => 'prompted(${inner.id})';

  @override
  ModelCapabilities get capabilities => inner.capabilities.copyWith(
    nativeTools: true,
    parallelToolCalls: true,
    structuredOutput: false,
  );

  @override
  Future<void> close() => inner.close();

  @override
  Stream<ModelStreamEvent> stream(
    ModelRequest request, {
    CancelToken? cancel,
  }) async* {
    final hasTools =
        request.tools.isNotEmpty && request.toolChoice != ToolChoice.none;
    final innerRequest = ModelRequest(
      system: _system(request),
      messages: renderMessages(request.messages),
      maxOutputTokens: request.maxOutputTokens,
      temperature: request.temperature,
      topP: request.topP,
      thinking: request.thinking,
      cacheKey: request.cacheKey,
    );
    if (!hasTools) {
      yield* _passthrough(innerRequest, cancel);
      return;
    }

    // First pass streams live: visible text is yielded as soon as it is
    // known not to be part of a tool-call block.
    final parsed = _Collected();
    final parser = _StreamParser();
    await for (final event in inner.stream(innerRequest, cancel: cancel)) {
      switch (event) {
        case TextDeltaEvent(:final text):
          parsed.rawBuffer.write(text);
          final visible = parser.feed(text);
          if (visible.isNotEmpty) yield TextDeltaEvent(visible);
        case MessageStop(:final reason):
          parsed.stop = reason;
        case ToolUseStartEvent() ||
            ToolInputDeltaEvent() ||
            ToolUseEndEvent() ||
            MessageMetadataEvent():
          break;
        default:
          yield event;
      }
    }
    final tail = parser.finish();
    if (tail.isNotEmpty) yield TextDeltaEvent(tail);
    _finishParse(parsed, parser);

    var calls = parsed.calls;
    var raw = parsed.raw;
    var stop = parsed.stop;

    if (parsed.malformed != null) {
      // One repair attempt: show the model its own output and the error.
      final repair = await _collect(
        innerRequest.copyWith(
          messages: [
            ...innerRequest.messages,
            AgentMessage(role: Role.assistant, content: [TextBlock(raw)]),
            AgentMessage.user(
              'Your tool_call block was not valid JSON (${parsed.malformed}). '
              'Reply with only the corrected tool_call block.',
            ),
          ],
        ),
        cancel,
        suppressText: true,
      );
      if (repair.calls.isNotEmpty && repair.malformed == null) {
        calls = [...calls, ...repair.calls];
        raw = '$raw\n${repair.raw}';
        stop = ModelStopReason.toolUse;
      } else {
        calls = [
          ...calls,
          _ParsedCall(
            id: newId('call'),
            name: parsed.malformedName ?? 'unknown_tool',
            input: null,
            error: 'Malformed tool call: ${parsed.malformed}',
          ),
        ];
      }
      for (final e in repair.passthrough) {
        yield e;
      }
    }

    for (final call in calls) {
      yield ToolUseStartEvent(call.id, call.name);
      yield ToolUseEndEvent(
        call.id,
        call.name,
        call.input,
        parseError: call.error,
      );
    }
    yield MessageMetadataEvent({'rawText': raw});
    yield MessageStop(calls.isNotEmpty ? ModelStopReason.toolUse : stop);
  }

  Stream<ModelStreamEvent> _passthrough(
    ModelRequest request,
    CancelToken? cancel,
  ) async* {
    final raw = StringBuffer();
    await for (final event in inner.stream(request, cancel: cancel)) {
      if (event is TextDeltaEvent) raw.write(event.text);
      if (event is MessageStop) {
        yield MessageMetadataEvent({'rawText': raw.toString()});
      }
      yield event;
    }
  }

  Future<_Collected> _collect(
    ModelRequest request,
    CancelToken? cancel, {
    bool suppressText = false,
  }) async {
    final result = _Collected();
    final parser = _StreamParser();
    await for (final event in inner.stream(request, cancel: cancel)) {
      switch (event) {
        case TextDeltaEvent(:final text):
          result.rawBuffer.write(text);
          final visible = parser.feed(text);
          if (visible.isNotEmpty && !suppressText) {
            result.events.add(TextDeltaEvent(visible));
          }
        case MessageStop(:final reason):
          result.stop = reason;
        case ToolUseStartEvent() || ToolInputDeltaEvent() || ToolUseEndEvent():
          break; // inner client has no tools; ignore anything stray
        case MessageMetadataEvent():
          break;
        default:
          (suppressText ? result.passthrough : result.events).add(event);
      }
    }
    final tail = parser.finish();
    if (tail.isNotEmpty && !suppressText) {
      result.events.add(TextDeltaEvent(tail));
    }
    _finishParse(result, parser);
    return result;
  }

  static void _finishParse(_Collected result, _StreamParser parser) {
    result.raw = result.rawBuffer.toString();
    for (final block in parser.callBodies) {
      final decoded = _decodeCalls(block);
      if (decoded.error != null) {
        result.malformed ??= decoded.error;
        result.malformedName ??= decoded.nameHint;
      } else {
        result.calls.addAll(decoded.calls);
      }
    }
    if (parser.unterminated != null) {
      result.malformed ??= 'the block was not closed';
      result.malformedName ??= _nameHint(parser.unterminated!);
    }
  }

  String _system(ModelRequest request) {
    final base = request.system ?? '';
    if (request.tools.isEmpty || request.toolChoice == ToolChoice.none) {
      return base;
    }
    final buffer =
        StringBuffer(base)
          ..writeln()
          ..writeln()
          ..writeln('## Tool calling')
          ..writeln(
            'To call a tool, write a fenced block exactly like this and nothing '
            'else inside it:',
          )
          ..writeln(_openFence)
          ..writeln(
            '{"name": "<tool name>", "arguments": {<arguments as JSON>}}',
          )
          ..writeln(_closeFence)
          ..writeln(
            'You may write several tool_call blocks. After your tool calls, stop '
            'and wait — the results arrive in the next message, starting with '
            '"$_resultsHeader". Never write tool results yourself. Only call the '
            'tools listed below, with arguments matching their JSON schema. When '
            'you have everything you need, answer normally without a tool_call '
            'block.',
          )
          ..writeln()
          ..writeln('Available tools:');
    for (final tool in request.tools) {
      buffer
        ..writeln('- ${tool.name}: ${tool.description}')
        ..writeln('  arguments schema: ${jsonEncode(tool.inputSchema)}');
    }
    return buffer.toString().trimRight();
  }

  /// Renders a native transcript into plain text turns for the inner
  /// client. Public for tests.
  static List<AgentMessage> renderMessages(List<AgentMessage> messages) {
    final names = <String, String>{};
    final out = <AgentMessage>[];
    for (final message in messages) {
      if (message.role == Role.assistant) {
        for (final use in message.toolUses) {
          names[use.id] = use.name;
        }
        final raw = message.providerMetadata['rawText'];
        final text =
            raw is String
                ? raw
                : [
                  if (message.text.isNotEmpty) message.text,
                  for (final use in message.toolUses)
                    '$_openFence\n${jsonEncode({'name': use.name, 'arguments': use.input})}\n$_closeFence',
                ].join('\n');
        out.add(AgentMessage(role: Role.assistant, content: [TextBlock(text)]));
        continue;
      }
      final results = message.toolResults;
      final content = <ContentBlock>[];
      if (results.isNotEmpty) {
        final buffer = StringBuffer(_resultsHeader);
        for (final r in results) {
          buffer
            ..writeln()
            ..writeln(
              '[${names[r.toolUseId] ?? 'tool'}${r.isError ? ' — error' : ''}]',
            )
            ..writeln(r.text.isEmpty ? '(no output)' : neutralize(r.text));
        }
        content.add(TextBlock(buffer.toString().trimRight()));
      }
      for (final block in message.content) {
        if (block is TextBlock) content.add(TextBlock(neutralize(block.text)));
        if (block is ImageBlock) content.add(block);
      }
      if (content.isNotEmpty) {
        out.add(AgentMessage(role: Role.user, content: content));
      }
    }
    return out;
  }

  /// Breaks protocol markers inside text the model did not write (tool
  /// results, user content such as fetched pages or notes) with a
  /// zero-width space, so injected text cannot be echoed back as a tool
  /// call or spoof a results block.
  static String neutralize(String text) => text
      .replaceAll(_openFence, '``\u200B`tool_call')
      .replaceAll(_openTag, '<\u200Btool_call>')
      .replaceAll(_closeTag, '<\u200B/tool_call>')
      .replaceAll(_resultsHeader, 'Tool\u200B results:');

  static _Decoded _decodeCalls(String body) {
    final trimmed = body.trim();
    Object? decoded;
    try {
      decoded = jsonDecode(trimmed);
    } on FormatException catch (e) {
      return _Decoded.error('invalid JSON: ${e.message}', _nameHint(trimmed));
    }
    final items = decoded is List ? decoded : [decoded];
    final calls = <_ParsedCall>[];
    for (final item in items) {
      if (item is! Map) return _Decoded.error('expected a JSON object', null);
      final name = item['name'] ?? item['tool'] ?? item['tool_name'];
      if (name is! String || name.isEmpty) {
        return _Decoded.error('missing "name"', null);
      }
      var args =
          item['arguments'] ?? item['args'] ?? item['parameters'] ?? const {};
      if (args is String) {
        try {
          args = jsonDecode(args);
        } on FormatException {
          return _Decoded.error('"arguments" must be a JSON object', name);
        }
      }
      if (args is! Map) {
        return _Decoded.error('"arguments" must be a JSON object', name);
      }
      calls.add(
        _ParsedCall(
          id: newId('call'),
          name: name,
          input: args.cast<String, Object?>(),
        ),
      );
    }
    return _Decoded(calls);
  }

  static String? _nameHint(String text) =>
      RegExp(r'"name"\s*:\s*"([^"]+)"').firstMatch(text)?.group(1);
}

/// Incremental splitter of visible text vs tool-call bodies.
class _StreamParser {
  static const _openers = {
    PromptedToolCallingClient._openFence: PromptedToolCallingClient._closeFence,
    PromptedToolCallingClient._openTag: PromptedToolCallingClient._closeTag,
  };

  final StringBuffer _pending = StringBuffer();
  final List<String> callBodies = [];
  String? _closer;
  final StringBuffer _body = StringBuffer();

  /// Text written after the first call; emitted at the end unless it
  /// contains hallucinated results.
  final StringBuffer _afterCall = StringBuffer();

  String? unterminated;

  /// Feeds [text]; returns the part that is safe to show now.
  String feed(String text) {
    _pending.write(text);
    final visible = StringBuffer();
    while (true) {
      final buffer = _pending.toString();
      final closer = _closer;
      if (closer != null) {
        final end = buffer.indexOf(closer);
        if (end < 0) {
          // Keep a possible partial closer in pending; the rest is body.
          final keep = closer.length - 1;
          final cut = buffer.length > keep ? buffer.length - keep : 0;
          _body.write(buffer.substring(0, cut));
          _pending
            ..clear()
            ..write(buffer.substring(cut));
          break;
        }
        final candidate = '${_body.toString()}${buffer.substring(0, end)}';
        // A bare ``` may be part of the JSON itself (e.g. a markdown code
        // block inside a note payload): only close when the body so far is
        // complete JSON; otherwise keep the fence as body text.
        if (closer == PromptedToolCallingClient._closeFence &&
            !_isCompleteJson(candidate)) {
          _body.write(buffer.substring(0, end + closer.length));
          _pending
            ..clear()
            ..write(buffer.substring(end + closer.length));
          continue;
        }
        callBodies.add(candidate);
        _body.clear();
        _closer = null;
        _pending
          ..clear()
          ..write(buffer.substring(end + closer.length));
        continue;
      }
      var openIndex = -1;
      String? opener;
      for (final o in _openers.keys) {
        final i = buffer.indexOf(o);
        if (i >= 0 && (openIndex < 0 || i < openIndex)) {
          openIndex = i;
          opener = o;
        }
      }
      if (opener != null) {
        _emit(visible, buffer.substring(0, openIndex));
        _closer = _openers[opener];
        _pending
          ..clear()
          ..write(buffer.substring(openIndex + opener.length));
        continue;
      }
      // Hold back the longest suffix that could begin a marker.
      final hold = _partialMarkerLength(buffer);
      _emit(visible, buffer.substring(0, buffer.length - hold));
      _pending
        ..clear()
        ..write(buffer.substring(buffer.length - hold));
      break;
    }
    return visible.toString();
  }

  /// Flushes remaining visible text at end of stream.
  String finish() {
    final visible = StringBuffer();
    if (_closer != null) {
      unterminated = '${_body.toString()}${_pending.toString()}';
    } else {
      _emit(visible, _pending.toString());
    }
    _pending.clear();
    final after = _afterCall.toString();
    if (after.isNotEmpty &&
        !after.contains(PromptedToolCallingClient._resultsHeader) &&
        !after.contains('<tool_result')) {
      visible.write(after);
    }
    return visible.toString();
  }

  void _emit(StringBuffer visible, String text) {
    if (text.isEmpty) return;
    if (callBodies.isNotEmpty) {
      _afterCall.write(text);
    } else {
      visible.write(text);
    }
  }

  static bool _isCompleteJson(String text) {
    try {
      jsonDecode(text.trim());
      return true;
    } on FormatException {
      return false;
    }
  }

  static int _partialMarkerLength(String buffer) {
    var best = 0;
    for (final marker in _openers.keys) {
      for (var len = marker.length - 1; len > best; len--) {
        if (buffer.length >= len && buffer.endsWith(marker.substring(0, len))) {
          best = len;
          break;
        }
      }
    }
    return best;
  }
}

class _ParsedCall {
  final String id;
  final String name;
  final Map<String, Object?>? input;
  final String? error;
  _ParsedCall({required this.id, required this.name, this.input, this.error});
}

class _Decoded {
  final List<_ParsedCall> calls;
  final String? error;
  final String? nameHint;
  _Decoded(this.calls) : error = null, nameHint = null;
  _Decoded.error(this.error, this.nameHint) : calls = const [];
}

class _Collected {
  final List<ModelStreamEvent> events = [];
  final List<ModelStreamEvent> passthrough = [];
  final List<_ParsedCall> calls = [];
  final StringBuffer rawBuffer = StringBuffer();
  String raw = '';
  ModelStopReason stop = ModelStopReason.endTurn;
  String? malformed;
  String? malformedName;
}
