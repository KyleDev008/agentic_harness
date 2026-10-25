import 'dart:convert';

import '../core/ids.dart';
import 'model_client.dart';

/// Rebuilds streamed tool calls from fragments, keyed by a provider slot
/// (index or id), and turns them into normalized events.
///
/// Fragments for one slot are concatenated; [finishAll] parses each buffer
/// as a JSON object. Missing ids are filled with fresh unique ids so every
/// call can be answered by a tool result.
class ToolCallAccumulator {
  final Map<Object, _PendingCall> _calls = {};
  final List<Object> _order = [];

  bool get isEmpty => _calls.isEmpty;

  /// Adds a fragment for [slot]. Returns the events to emit now
  /// (`ToolUseStart` the first time a named call is seen, then
  /// `ToolInputDelta`s).
  List<ModelStreamEvent> add(
    Object slot, {
    String? id,
    String? name,
    String? argumentsFragment,
  }) {
    final events = <ModelStreamEvent>[];
    var call = _calls[slot];
    if (call == null) {
      call = _PendingCall();
      _calls[slot] = call;
      _order.add(slot);
    }
    if (id != null && id.isNotEmpty && call.id == null) call.id = id;
    if (name != null && name.isNotEmpty) call.name.write(name);
    if (!call.started && call.name.isNotEmpty) {
      call.id ??= newId('call');
      call.started = true;
      events.add(ToolUseStartEvent(call.id!, call.name.toString()));
    }
    if (argumentsFragment != null && argumentsFragment.isNotEmpty) {
      call.arguments.write(argumentsFragment);
      if (call.started) {
        events.add(ToolInputDeltaEvent(call.id!, argumentsFragment));
      }
    }
    return events;
  }

  /// Records a call whose arguments arrived already decoded (Ollama,
  /// Gemini). Returns its start/end events.
  List<ModelStreamEvent> addComplete({
    String? id,
    required String name,
    required Object? arguments,
  }) {
    final callId = (id == null || id.isEmpty) ? newId('call') : id;
    final slot = 'complete_${_order.length}';
    final call =
        _PendingCall()
          ..id = callId
          ..started = true
          ..finished = true;
    call.name.write(name);
    _calls[slot] = call;
    _order.add(slot);
    final parsed = _asObject(arguments);
    return [
      ToolUseStartEvent(callId, name),
      ToolUseEndEvent(
        callId,
        name,
        parsed,
        parseError: parsed == null ? 'Arguments were not a JSON object' : null,
      ),
    ];
  }

  /// Emits `ToolUseEnd` for every call not yet finished, in arrival order.
  List<ModelStreamEvent> finishAll() {
    final events = <ModelStreamEvent>[];
    for (final slot in _order) {
      final call = _calls[slot]!;
      if (call.finished) continue;
      call.finished = true;
      final name = call.name.toString();
      if (name.isEmpty) continue; // fragments with no name are unusable
      if (!call.started) {
        call.id ??= newId('call');
        events.add(ToolUseStartEvent(call.id!, name));
      }
      final raw = call.arguments.toString().trim();
      Map<String, Object?>? input;
      String? error;
      if (raw.isEmpty) {
        input = const {};
      } else {
        try {
          input = _asObject(jsonDecode(raw));
          if (input == null) error = 'Arguments were not a JSON object';
        } on FormatException catch (e) {
          error = 'Invalid JSON arguments: ${e.message}';
        }
      }
      events.add(ToolUseEndEvent(call.id!, name, input, parseError: error));
    }
    return events;
  }

  static Map<String, Object?>? _asObject(Object? value) {
    if (value is Map) return value.cast<String, Object?>();
    if (value is String) {
      final trimmed = value.trim();
      if (trimmed.isEmpty) return const {};
      try {
        final decoded = jsonDecode(trimmed);
        if (decoded is Map) return decoded.cast<String, Object?>();
      } on FormatException {
        return null;
      }
    }
    if (value == null) return const {};
    return null;
  }
}

class _PendingCall {
  String? id;
  final StringBuffer name = StringBuffer();
  final StringBuffer arguments = StringBuffer();
  bool started = false;
  bool finished = false;
}
