import 'dart:async';
import 'dart:convert';

import '../core/cancellation.dart';
import '../core/message.dart';
import '../core/usage.dart';
import '../model/model_client.dart';

/// One scripted model response for [FakeModelClient].
final class FakeTurn {
  final String text;
  final List<FakeToolCall> toolCalls;
  final ModelStopReason? stop;
  final Usage usage;

  /// Throw this instead of responding.
  final Object? error;

  /// Delay before the response (to test cancellation/timeouts).
  final Duration delay;

  const FakeTurn({
    this.text = '',
    this.toolCalls = const [],
    this.stop,
    this.usage = const Usage(inputTokens: 10, outputTokens: 5),
    this.error,
    this.delay = Duration.zero,
  });

  factory FakeTurn.text(String text) => FakeTurn(text: text);

  factory FakeTurn.tools(List<FakeToolCall> calls, {String text = ''}) =>
      FakeTurn(text: text, toolCalls: calls);
}

final class FakeToolCall {
  final String id;
  final String name;
  final Map<String, Object?> input;

  /// Raw argument text; overrides [input] (use to simulate broken JSON).
  final String? rawArguments;

  const FakeToolCall(this.id, this.name, this.input, {this.rawArguments});
}

/// A deterministic [ModelClient] that replays scripted [FakeTurn]s and
/// records every request — for unit-testing agents and hosts without a
/// network.
class FakeModelClient implements ModelClient {
  final List<FakeTurn> _script;

  /// Every request received, in order.
  final List<ModelRequest> requests = [];

  @override
  final ModelCapabilities capabilities;

  FakeModelClient(
    List<FakeTurn> script, {
    this.capabilities = const ModelCapabilities(),
  }) : _script = List.of(script);

  @override
  String get id => 'fake';

  int get remaining => _script.length;

  @override
  Stream<ModelStreamEvent> stream(
    ModelRequest request, {
    CancelToken? cancel,
  }) async* {
    requests.add(request);
    if (_script.isEmpty) {
      throw StateError('FakeModelClient: no scripted turn left');
    }
    final turn = _script.removeAt(0);
    if (turn.delay > Duration.zero) {
      await Future.any([
        Future<void>.delayed(turn.delay),
        if (cancel != null) cancel.whenCancelled,
      ]);
    }
    cancel?.throwIfCancelled();
    if (turn.error != null) throw turn.error!;
    // Stream text in small chunks like a real provider.
    for (var i = 0; i < turn.text.length; i += 7) {
      yield TextDeltaEvent(
        turn.text.substring(i, (i + 7).clamp(0, turn.text.length)),
      );
    }
    for (final call in turn.toolCalls) {
      yield ToolUseStartEvent(call.id, call.name);
      final raw = call.rawArguments ?? jsonEncode(call.input);
      yield ToolInputDeltaEvent(call.id, raw);
      Map<String, Object?>? input;
      String? error;
      try {
        final decoded = jsonDecode(raw);
        input = decoded is Map ? decoded.cast<String, Object?>() : null;
        if (input == null) error = 'not an object';
      } on FormatException catch (e) {
        error = e.message;
      }
      yield ToolUseEndEvent(call.id, call.name, input, parseError: error);
    }
    yield UsageReport(turn.usage);
    yield MessageStop(
      turn.stop ??
          (turn.toolCalls.isEmpty
              ? ModelStopReason.endTurn
              : ModelStopReason.toolUse),
    );
  }

  /// Text of the last message of the [index]th request.
  String lastMessageText(int index) => requests[index].messages.last.text;

  /// Tool results carried by the last message of the [index]th request.
  List<ToolResultBlock> lastToolResults(int index) =>
      requests[index].messages.last.toolResults;

  @override
  Future<void> close() async {}
}
