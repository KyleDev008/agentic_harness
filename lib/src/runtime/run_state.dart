part of 'runner.dart';

/// Why an interruptible run stopped (see `RunConfig.interruptible`).
sealed class RunInterruption {
  /// The tool call the run is waiting on.
  final String toolUseId;
  final String toolName;

  /// The call's input, after `preToolUse` hooks.
  final Map<String, Object?> input;
  final String displayLabel;

  const RunInterruption({
    required this.toolUseId,
    required this.toolName,
    required this.input,
    required this.displayLabel,
  });

  String get kind;

  Map<String, Object?> toJson() => {
    'kind': kind,
    'toolUseId': toolUseId,
    'toolName': toolName,
    'input': input,
    'displayLabel': displayLabel,
    ..._fields(),
  };

  Map<String, Object?> _fields() => const {};

  static RunInterruption fromJson(Map<String, Object?> json) {
    final toolUseId = _string(json, 'toolUseId');
    final toolName = _string(json, 'toolName');
    final input = _map(json['input'], 'input');
    final displayLabel = _string(json, 'displayLabel');
    switch (json['kind']) {
      case 'approval':
        final fingerprint = json['toolFingerprint'];
        return ApprovalInterruption(
          toolUseId: toolUseId,
          toolName: toolName,
          input: input,
          displayLabel: displayLabel,
          toolFingerprint: fingerprint is String ? fingerprint : null,
        );
      case 'input':
        final choices = json['choices'];
        final fields = json['fields'];
        return InputInterruption(
          toolUseId: toolUseId,
          toolName: toolName,
          input: input,
          displayLabel: displayLabel,
          requestId: _string(json, 'requestId'),
          prompt: _string(json, 'prompt'),
          inputType: _string(json, 'inputType'),
          choices: choices is List ? [for (final c in choices) '$c'] : null,
          fields:
              fields is List
                  ? [
                    for (final f in fields)
                      UserInputField.tryParse(f) ??
                          (throw const FormatException('Invalid input field')),
                  ]
                  : null,
        );
      default:
        throw FormatException('Unknown interruption kind: ${json['kind']}');
    }
  }
}

/// The run needs approval for a tool call. Resume with
/// [RunState.approve] or [RunState.reject].
final class ApprovalInterruption extends RunInterruption {
  /// Fingerprint of the tool's definition (description, schema and
  /// annotations) when approval was asked. If the tool changes before the
  /// run resumes, the recorded approval no longer applies and the call is
  /// not run. `null` in states saved before 2.1.
  final String? toolFingerprint;

  const ApprovalInterruption({
    required super.toolUseId,
    required super.toolName,
    required super.input,
    required super.displayLabel,
    this.toolFingerprint,
  });

  @override
  String get kind => 'approval';

  @override
  Map<String, Object?> _fields() => {
    if (toolFingerprint != null) 'toolFingerprint': toolFingerprint,
  };
}

/// A tool asked the user a question. Resume with [RunState.answer].
final class InputInterruption extends RunInterruption {
  final String requestId;
  final String prompt;
  final String inputType;
  final List<String>? choices;
  final List<UserInputField>? fields;

  const InputInterruption({
    required super.toolUseId,
    required super.toolName,
    required super.input,
    required super.displayLabel,
    required this.requestId,
    required this.prompt,
    required this.inputType,
    this.choices,
    this.fields,
  });

  @override
  String get kind => 'input';

  @override
  Map<String, Object?> _fields() => {
    'requestId': requestId,
    'prompt': prompt,
    'inputType': inputType,
    if (choices != null) 'choices': choices,
    if (fields != null) 'fields': [for (final f in fields!) f.toJson()],
  };
}

/// A JSON-serializable snapshot of a run, for resuming it later with
/// `Runner.resume` — after an [interruption], or from a checkpoint
/// (`RunConfig.onCheckpoint`) after a crash.
///
/// The spec, config and tools are not part of the state: pass them again
/// when resuming. Only the todo list survives from the tools' shared
/// `runState`.
///
/// The state holds the full transcript and the user's answers, so store it
/// as carefully as the conversation itself. [toJson] is not signed: anyone
/// who can edit the stored state can record an approval, reset the budgets
/// or change what the run resumes with. Where others could edit it, store
/// [toSignedJson] instead and read it with [RunState.fromSignedJson].
///
/// On resume the pending call is validated and checked against the
/// permission rules again. A recorded approval is trusted only while the
/// tool's definition (description, schema, annotations) is unchanged; if
/// the tool changed, the call is not run and the model is told to call it
/// again, which asks again.
///
/// Resuming is at-least-once: resuming the same state twice runs the
/// pending call twice, so mark a state as used before resuming it.
final class RunState {
  /// Format version of [toJson].
  static const int formatVersion = 1;

  final String runId;
  final String agentName;

  /// The transcript the next model call starts from (history, input and
  /// everything produced so far, possibly compacted).
  final List<AgentMessage> messages;

  /// Messages produced by the run so far (`RunResult.newMessages`).
  final List<AgentMessage> newMessages;
  final int turns;
  final Usage usage;

  /// Active time spent so far (counts toward `RunConfig.wallClockBudget`).
  final Duration elapsed;
  final List<Todo> todos;

  /// Cost so far in US dollars, when priced (see `RunResult.cost`).
  final double? cost;
  final String? _traceId;

  /// The agent in charge after handoffs (null: the starting agent).
  final String? _activeAgent;
  final int _handoffs;

  /// A handoff accepted in the turn that paused (target agent's name).
  final String? _pendingHandoff;

  /// Background tasks the pause or restart stopped (their labels).
  final List<String> _lostBackground;

  /// Background tasks not yet delivered to the model: finished ones with
  /// their result, running ones to take over on resume.
  final List<_SavedBackground> _background;

  /// Key for taking over tasks left running in this process.
  final String? _backgroundKey;

  /// Deferred tools loaded by search.
  final List<String> _loadedTools;

  /// What the run is waiting for; null for a checkpoint.
  RunInterruption? get interruption => _pending?.interruption;

  final Map<String, int> _callCounts;
  final bool _privateDataRead;
  final List<String> _hostCallIds;
  final bool _structuredRepairUsed;
  final bool _emptyRetryUsed;
  final _PendingTurn? _pending;

  const RunState._({
    required this.runId,
    required this.agentName,
    required this.messages,
    required this.newMessages,
    required this.turns,
    required this.usage,
    required this.elapsed,
    required this.todos,
    required Map<String, int> callCounts,
    required bool privateDataRead,
    required List<String> hostCallIds,
    required bool structuredRepairUsed,
    required bool emptyRetryUsed,
    required _PendingTurn? pending,
    this.cost,
    String? traceId,
    String? activeAgent,
    int handoffs = 0,
    String? pendingHandoff,
    List<String> lostBackground = const [],
    List<_SavedBackground> background = const [],
    String? backgroundKey,
    List<String> loadedTools = const [],
  }) : _traceId = traceId,
       _background = background,
       _backgroundKey = backgroundKey,
       _loadedTools = loadedTools,
       _activeAgent = activeAgent,
       _handoffs = handoffs,
       _pendingHandoff = pendingHandoff,
       _lostBackground = lostBackground,
       _callCounts = callCounts,
       _privateDataRead = privateDataRead,
       _hostCallIds = hostCallIds,
       _structuredRepairUsed = structuredRepairUsed,
       _emptyRetryUsed = emptyRetryUsed,
       _pending = pending;

  /// Whether the pending interruption has been answered, so the run can
  /// resume.
  bool get isReady =>
      _pending == null ||
      (_pending.interruption is ApprovalInterruption
          ? _pending.decision != null
          : _pending.answered);

  /// Approves the pending tool call, optionally with edited input.
  RunState approve({Map<String, Object?>? updatedInput}) =>
      _decide(Allow(updatedInput: updatedInput));

  /// Declines the pending tool call; [message] goes back to the model.
  RunState reject([String message = 'The user declined this action.']) =>
      _decide(Deny(message));

  RunState _decide(PermissionDecision decision) {
    final pending = _pending;
    if (pending == null || pending.interruption is! ApprovalInterruption) {
      throw StateError('The run is not waiting for an approval.');
    }
    return _with(pending.copyWith(decision: decision));
  }

  /// Answers the pending question.
  RunState answer(String answer) {
    final pending = _pending;
    if (pending == null || pending.interruption is! InputInterruption) {
      throw StateError('The run is not waiting for an answer.');
    }
    if (pending.answered) throw StateError('The question is already answered.');
    final question = pending.interruption as InputInterruption;
    return _with(
      pending.copyWith(
        answers: [...pending.answers, _Answer(question.prompt, answer)],
        answered: true,
      ),
    );
  }

  RunState _with(_PendingTurn pending) => RunState._(
    runId: runId,
    agentName: agentName,
    messages: messages,
    newMessages: newMessages,
    turns: turns,
    usage: usage,
    elapsed: elapsed,
    todos: todos,
    callCounts: _callCounts,
    privateDataRead: _privateDataRead,
    hostCallIds: _hostCallIds,
    structuredRepairUsed: _structuredRepairUsed,
    emptyRetryUsed: _emptyRetryUsed,
    pending: pending,
    cost: cost,
    traceId: _traceId,
    activeAgent: _activeAgent,
    handoffs: _handoffs,
    pendingHandoff: _pendingHandoff,
    lostBackground: _lostBackground,
    background: _background,
    backgroundKey: _backgroundKey,
    loadedTools: _loadedTools,
  );

  Map<String, Object?> toJson() => {
    'version': formatVersion,
    'runId': runId,
    'agentName': agentName,
    'messages': [for (final m in messages) m.toJson()],
    'newMessages': [for (final m in newMessages) m.toJson()],
    'turns': turns,
    'usage': usage.toJson(),
    'elapsedMs': elapsed.inMilliseconds,
    'todos': [for (final t in todos) t.toJson()],
    'callCounts': _callCounts,
    'privateDataRead': _privateDataRead,
    'hostCallIds': _hostCallIds,
    'structuredRepairUsed': _structuredRepairUsed,
    'emptyRetryUsed': _emptyRetryUsed,
    if (_pending != null) 'pending': _pending.toJson(),
    if (cost != null) 'cost': cost,
    if (_traceId != null) 'traceId': _traceId,
    if (_activeAgent != null) 'activeAgent': _activeAgent,
    if (_handoffs > 0) 'handoffs': _handoffs,
    if (_pendingHandoff != null) 'pendingHandoff': _pendingHandoff,
    if (_lostBackground.isNotEmpty) 'lostBackground': _lostBackground,
    if (_background.isNotEmpty)
      'background': [for (final b in _background) b.toJson()],
    if (_backgroundKey != null) 'backgroundKey': _backgroundKey,
    if (_loadedTools.isNotEmpty) 'loadedTools': _loadedTools,
  };

  /// [toJson] signed with HMAC-SHA256 under [key], for state stored where
  /// someone other than this process could edit it (a database, a file
  /// another app can write, a server). The state travels as a string so
  /// the signature covers its exact bytes. Read it back with
  /// [RunState.fromSignedJson] and the same key.
  ///
  /// Use a random key of at least 32 bytes kept in secure storage, never
  /// stored next to the state.
  Map<String, Object?> toSignedJson(List<int> key) {
    _checkKey(key);
    final state = jsonEncode(toJson());
    return {
      'signedState': state,
      'hmac': Hmac(sha256, key).convert(utf8.encode(state)).toString(),
    };
  }

  /// Parses [toSignedJson] output, verifying the signature first. Throws
  /// [FormatException] when the signature is missing or doesn't match
  /// (the state was changed, or signed with another key).
  factory RunState.fromSignedJson(Map<String, Object?> json, List<int> key) {
    _checkKey(key);
    final state = json['signedState'];
    final mac = json['hmac'];
    if (state is! String || mac is! String) {
      throw const FormatException('Run state: not a signed state');
    }
    final expected = Hmac(sha256, key).convert(utf8.encode(state)).toString();
    if (!_constantTimeEquals(expected, mac.toLowerCase())) {
      throw const FormatException('Run state: signature does not match');
    }
    final decoded = jsonDecode(state);
    return RunState.fromJson(_map(decoded, 'signedState'));
  }

  static void _checkKey(List<int> key) {
    if (key.length < 32) {
      throw ArgumentError.value(
        key.length,
        'key',
        'Use a key of at least 32 bytes',
      );
    }
  }

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  /// Parses [toJson] output. Throws [FormatException] for malformed or
  /// unsupported state.
  factory RunState.fromJson(Map<String, Object?> json) {
    if (json['version'] != formatVersion) {
      throw FormatException(
        'Unsupported run state version: ${json['version']}',
      );
    }
    final rawCounts = _map(json['callCounts'], 'callCounts');
    final pending = json['pending'];
    try {
      final messages = _messages(json['messages'], 'messages');
      final pendingTurn =
          pending == null
              ? null
              : _PendingTurn.fromJson(_map(pending, 'pending'));
      if (pendingTurn != null) {
        // The pending calls must be the transcript's last turn.
        final last = messages.isEmpty ? null : messages.last;
        final ids =
            last?.role == Role.assistant
                ? [for (final u in last!.toolUses) u.id]
                : const <String>[];
        final pendingIds = [for (final u in pendingTurn.uses) u.id];
        if (ids.length != pendingIds.length ||
            !Iterable<int>.generate(
              ids.length,
            ).every((i) => ids[i] == pendingIds[i])) {
          throw const FormatException('pending turn does not match messages');
        }
      }
      return RunState._(
        runId: _string(json, 'runId'),
        agentName: _string(json, 'agentName'),
        messages: messages,
        newMessages: _messages(json['newMessages'], 'newMessages'),
        turns: _int(json['turns'], 'turns'),
        usage: Usage.fromJson(_map(json['usage'], 'usage')),
        elapsed: Duration(milliseconds: _int(json['elapsedMs'], 'elapsedMs')),
        todos: [
          for (final t in _list(json['todos'], 'todos'))
            Todo.fromJson(_map(t, 'todos[]')),
        ],
        callCounts: {
          for (final e in rawCounts.entries) e.key: _int(e.value, 'callCounts'),
        },
        privateDataRead: json['privateDataRead'] == true,
        hostCallIds: [
          for (final id in _list(json['hostCallIds'], 'hostCallIds')) '$id',
        ],
        structuredRepairUsed: json['structuredRepairUsed'] == true,
        emptyRetryUsed: json['emptyRetryUsed'] == true,
        pending: pendingTurn,
        cost: switch (json['cost']) {
          final num c when c >= 0 && c.isFinite => c.toDouble(),
          _ => null,
        },
        traceId: switch (json['traceId']) {
          final String t when RegExp(r'^[0-9a-f]{32}$').hasMatch(t) => t,
          _ => null,
        },
        activeAgent: switch (json['activeAgent']) {
          final String a when a.isNotEmpty && a.length <= 200 => a,
          _ => null,
        },
        handoffs: switch (json['handoffs']) {
          final int h when h >= 0 => h,
          _ => 0,
        },
        pendingHandoff: switch (json['pendingHandoff']) {
          final String a when a.isNotEmpty && a.length <= 200 => a,
          _ => null,
        },
        loadedTools: [
          if (json['loadedTools'] case final List<Object?> names)
            for (final n in {...names.take(256)})
              if (n is String && n.length <= 128) n,
        ],
        lostBackground: [
          if (json['lostBackground'] case final List<Object?> labels)
            for (final l in labels.take(64))
              if (l is String) l.length <= 200 ? l : l.substring(0, 200),
        ],
        background: _SavedBackground.listFromJson(json['background']),
        backgroundKey: switch (json['backgroundKey']) {
          final String k when k.length <= 64 => k,
          _ => null,
        },
      );
    } on FormatException {
      rethrow;
    } on Object catch (e) {
      // Type errors from malformed nested values.
      throw FormatException('Invalid run state: ${e.runtimeType}');
    }
  }
}

/// A background task in a [RunState]: finished with its [result], or
/// still [running] when the run paused.
final class _SavedBackground {
  final String id;
  final String label;
  final bool running;
  final bool failed;
  final String? result;

  const _SavedBackground({
    required this.id,
    required this.label,
    required this.running,
    required this.failed,
    required this.result,
  });

  /// Longest result kept, so a stored state stays bounded.
  static const maxResultChars = 100000;

  /// Most result text kept across all tasks.
  static const maxTotalChars = 256 * 1024;

  /// Valid entries of [json], first of each id, within the caps.
  static List<_SavedBackground> listFromJson(Object? json) {
    if (json is! List) return const [];
    final out = <_SavedBackground>[];
    final ids = <String>{};
    var total = 0;
    for (final t in json.take(64)) {
      if (t is! Map) continue;
      var saved = fromJson(t);
      if (saved == null || !ids.add(saved.id)) continue;
      final result = saved.result;
      if (result != null) {
        final room = maxTotalChars - total;
        if (room <= 0) continue;
        if (result.length > room) {
          saved = _SavedBackground(
            id: saved.id,
            label: saved.label,
            running: saved.running,
            failed: saved.failed,
            result: result.substring(0, room),
          );
        }
        total += saved.result!.length;
      }
      out.add(saved);
    }
    return out;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'status':
        running
            ? 'running'
            : failed
            ? 'failed'
            : 'done',
    if (result != null) 'result': result,
  };

  static _SavedBackground? fromJson(Map<Object?, Object?> json) {
    final id = json['id'];
    final label = json['label'];
    final status = json['status'];
    if (id is! String || id.isEmpty || id.length > 100) return null;
    if (label is! String) return null;
    if (status != 'running' && status != 'failed' && status != 'done') {
      return null;
    }
    final result = json['result'];
    return _SavedBackground(
      id: id,
      label: label.length <= 200 ? label : label.substring(0, 200),
      running: status == 'running',
      failed: status == 'failed',
      result:
          result is String
              ? (result.length <= maxResultChars
                  ? result
                  : result.substring(0, maxResultChars))
              : null,
    );
  }
}

/// A turn whose tool calls stopped part-way at an interruption.
final class _PendingTurn {
  final List<ToolUseBlock> uses;
  final Map<String, String> parseErrors;

  /// Results of calls before [index]; later entries are null.
  final List<ToolResultBlock?> results;
  final int index;
  final RunInterruption interruption;
  final PermissionDecision? decision;

  /// Every answer given to [interruption]'s tool call so far; replayed in
  /// order when the call re-runs.
  final List<_Answer> answers;
  final bool answered;

  const _PendingTurn({
    required this.uses,
    required this.parseErrors,
    required this.results,
    required this.index,
    required this.interruption,
    this.decision,
    this.answers = const [],
    this.answered = false,
  });

  _PendingTurn copyWith({
    PermissionDecision? decision,
    List<_Answer>? answers,
    bool? answered,
  }) => _PendingTurn(
    uses: uses,
    parseErrors: parseErrors,
    results: results,
    index: index,
    interruption: interruption,
    decision: decision ?? this.decision,
    answers: answers ?? this.answers,
    answered: answered ?? this.answered,
  );

  Map<String, Object?> toJson() => {
    'uses': [for (final u in uses) u.toJson()],
    'parseErrors': parseErrors,
    'results': [for (final r in results) r?.toJson()],
    'index': index,
    'interruption': interruption.toJson(),
    if (decision case Allow(:final updatedInput))
      'decision': {
        'allow': true,
        if (updatedInput != null) 'updatedInput': updatedInput,
      },
    if (decision case Deny(:final message))
      'decision': {'allow': false, 'message': message},
    'answers': [for (final a in answers) a.toJson()],
    'answered': answered,
  };

  factory _PendingTurn.fromJson(Map<String, Object?> json) {
    final uses = [
      for (final u in _list(json['uses'], 'uses'))
        switch (ContentBlock.fromJson(_map(u, 'uses[]'))) {
          final ToolUseBlock use => use,
          _ => throw const FormatException('pending.uses must be tool uses'),
        },
    ];
    final results = [
      for (final r in _list(json['results'], 'results'))
        r == null
            ? null
            : switch (ContentBlock.fromJson(_map(r, 'results[]'))) {
              final ToolResultBlock result => result,
              _ =>
                throw const FormatException('pending.results must be results'),
            },
    ];
    final index = _int(json['index'], 'index');
    if (results.length != uses.length || index < 0 || index >= uses.length) {
      throw const FormatException('pending turn is inconsistent');
    }
    final interruption = RunInterruption.fromJson(
      _map(json['interruption'], 'interruption'),
    );
    if (interruption.toolUseId != uses[index].id) {
      throw const FormatException('pending interruption does not match');
    }
    final answers = [
      for (final a in _list(json['answers'], 'answers'))
        _Answer.fromJson(_map(a, 'answers[]')),
    ];
    final answered = json['answered'] == true;
    if (answered &&
        (interruption is! InputInterruption ||
            answers.isEmpty ||
            answers.last.prompt != interruption.prompt)) {
      throw const FormatException('pending answer does not match');
    }
    final rawDecision = json['decision'];
    PermissionDecision? decision;
    if (rawDecision is Map) {
      final updated = rawDecision['updatedInput'];
      decision =
          rawDecision['allow'] == true
              ? Allow(
                updatedInput:
                    updated == null ? null : _map(updated, 'updatedInput'),
              )
              : Deny(
                '${rawDecision['message'] ?? 'The user declined this action.'}',
              );
    }
    return _PendingTurn(
      uses: uses,
      parseErrors: {
        for (final e in _map(json['parseErrors'], 'parseErrors').entries)
          e.key: '${e.value}',
      },
      results: results,
      index: index,
      interruption: interruption,
      decision: decision,
      answers: answers,
      answered: answered,
    );
  }
}

String _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value is! String) throw FormatException('Run state: $key is missing');
  return value;
}

int _int(Object? value, String what) {
  if (value is! int || value < 0) {
    throw FormatException('Run state: $what is not a count');
  }
  return value;
}

Map<String, Object?> _map(Object? value, String what) {
  if (value is! Map) throw FormatException('Run state: $what is not an object');
  return value.cast<String, Object?>();
}

List<Object?> _list(Object? value, String what) {
  if (value is! List) throw FormatException('Run state: $what is not a list');
  return value;
}

List<AgentMessage> _messages(Object? value, String what) => [
  for (final m in _list(value, what)) AgentMessage.fromJson(_map(m, what)),
];

/// An answer to one of a replayable tool's questions.
final class _Answer {
  final String prompt;
  final String answer;
  const _Answer(this.prompt, this.answer);

  Map<String, Object?> toJson() => {'prompt': prompt, 'answer': answer};

  factory _Answer.fromJson(Map<String, Object?> json) =>
      _Answer(_string(json, 'prompt'), _string(json, 'answer'));
}
