import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import '../context/context_manager.dart';
import '../core/cancellation.dart';
import '../core/errors.dart';
import '../core/ids.dart';
import '../core/json_schema.dart';
import '../core/message.dart';
import '../core/usage.dart';
import '../events/run_event.dart';
import '../governance/permissions.dart';
import '../model/http_transport.dart';
import '../model/model_client.dart';
import '../tools/builtin_tools.dart';
import '../tools/tool.dart';
import 'agent_spec.dart';

/// The outcome of a run.
final class RunResult {
  /// Text of the last assistant message (the final answer).
  final String finalText;

  /// Messages produced by this run (assistant turns and tool-result turns),
  /// excluding the input. Append them to the caller's history to continue
  /// the conversation with full tool context.
  final List<AgentMessage> newMessages;
  final Usage usage;
  final StopReason stopReason;
  final int turns;
  final List<Todo> todos;

  /// Parsed JSON when `ModelSettings.outputSchema` was set and the answer
  /// validated.
  final Object? structuredOutput;

  /// The error when [stopReason] is [StopReason.error].
  final Object? error;

  const RunResult({
    required this.finalText,
    required this.newMessages,
    required this.usage,
    required this.stopReason,
    required this.turns,
    required this.todos,
    this.structuredOutput,
    this.error,
  });
}

/// A run in progress.
abstract interface class AgentRun {
  String get id;

  /// Every event of the run, ending with [RunCompleted]. Single
  /// subscription; events are buffered until listened to.
  Stream<RunEvent> get events;

  /// Completes when the run ends. Never completes with an error — failures
  /// are reported as [StopReason.error] with [RunResult.error].
  Future<RunResult> get result;

  /// The pending `ask_user` request, if the run is waiting for one.
  UserInputRequested? get pendingUserInput;

  /// Answers a [UserInputRequested]. Returns false if [requestId] is not
  /// pending.
  bool respond(String requestId, String answer);

  /// Stops the run: aborts the model request, signals tools, and fails any
  /// pending question/approval. Idempotent.
  void cancel([String reason = 'Cancelled by user']);
}

/// Runs agents: the tool-use loop.
///
/// Each turn streams the model; if it requested tools they are validated,
/// permission-checked and executed (read-only calls in parallel, others in
/// order), their results appended as one message, and the loop continues
/// until the model answers without tools or a limit is hit. Every tool use
/// gets exactly one result, unknown/invalid calls are reported back to the
/// model, and failures end the run with a typed error — a run never hangs.
class Runner {
  const Runner();

  /// Starts a run of [spec] answering [input] after [history].
  ///
  /// [initialToolCalls] are host-initiated tool calls (e.g. a UI button
  /// bound to a tool) executed before the first model call, through the
  /// normal validation, permission and execution pipeline. They are
  /// recorded as an assistant `tool_use` turn followed by their results, so
  /// the model continues from the outcome. Give each a unique id.
  AgentRun run(
    AgentSpec spec, {
    List<AgentMessage> history = const [],
    required AgentMessage input,
    RunConfig config = const RunConfig(),
    CancelToken? cancel,
    List<ToolUseBlock> initialToolCalls = const [],
  }) {
    final run = _AgentRunImpl(
      spec,
      history,
      input,
      config,
      cancel,
      initialToolCalls,
    );
    // Start on a later microtask so the caller can subscribe first (the
    // single-subscription controller buffers anyway).
    scheduleMicrotask(run._start);
    return run;
  }
}

class _AgentRunImpl implements AgentRun {
  final AgentSpec spec;
  final List<AgentMessage> history;
  final AgentMessage input;
  final RunConfig config;
  final CancelToken _cancel;
  final List<ToolUseBlock> initialToolCalls;

  @override
  final String id = newId('run');

  final _events = StreamController<RunEvent>();
  final _result = Completer<RunResult>();
  final _active = Stopwatch();
  final Map<String, Object?> _runState = {};
  final Map<String, int> _callCounts = {};
  bool _privateDataRead = false;

  /// Ids of [initialToolCalls] (see `ToolCallRequest.hostInitiated`).
  late final Set<String> _hostCallIds = {
    for (final c in initialToolCalls) c.id,
  };
  final List<AgentMessage> _produced = [];
  late final ContextManager _context = ContextManager(config.context);

  Usage _usage = Usage.zero;
  int _turn = 0;
  int _pauseDepth = 0;
  UserInputRequested? _pendingInput;
  Completer<String>? _pendingInputCompleter;

  _AgentRunImpl(
    this.spec,
    this.history,
    this.input,
    this.config,
    CancelToken? cancel,
    this.initialToolCalls,
  ) : _cancel = cancel?.child() ?? CancelToken() {
    _runState[todosRunStateKey] = List<Todo>.of(config.initialTodos);
    _privateDataRead = config.assumePrivateContext;
    _cancel.onCancel(() {
      final c = _pendingInputCompleter;
      if (c != null && !c.isCompleted) {
        c.completeError(CancelledException(_cancel.reason));
      }
    });
  }

  @override
  Stream<RunEvent> get events => _events.stream;

  @override
  Future<RunResult> get result => _result.future;

  @override
  UserInputRequested? get pendingUserInput => _pendingInput;

  @override
  void cancel([String reason = 'Cancelled by user']) => _cancel.cancel(reason);

  @override
  bool respond(String requestId, String answer) {
    final pending = _pendingInput;
    final completer = _pendingInputCompleter;
    if (pending == null ||
        completer == null ||
        pending.requestId != requestId) {
      return false;
    }
    if (completer.isCompleted) return false;
    completer.complete(answer);
    return true;
  }

  void _emit(RunEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  void _pause() {
    if (_pauseDepth++ == 0) _active.stop();
  }

  void _resume() {
    if (--_pauseDepth == 0) _active.start();
  }

  Future<void> _start() async {
    _active.start();
    StopReason stop = StopReason.error;
    Object? error;
    Object? structured;
    try {
      _emit(RunStarted(id, agentName: spec.name, model: spec.model.id));
      final outcome = await runZoned(
        _loop,
        zoneValues: {
          retryZoneKey:
              (int attempt, Duration delay, HarnessError e) => _emit(
                Retrying(
                  id,
                  attempt: attempt,
                  delay: delay,
                  errorClass: e.errorClass,
                ),
              ),
        },
      );
      stop = outcome.$1;
      structured = outcome.$2;
    } on CancelledException {
      stop = StopReason.cancelled;
    } catch (e, st) {
      if (_cancel.isCancelled) {
        stop = StopReason.cancelled;
      } else {
        error = e;
        stop = StopReason.error;
        developer.log(
          'run failed: $e',
          name: 'agentic_harness.runner',
          error: e,
          stackTrace: st,
        );
        _emit(
          RunError(
            id,
            errorClass: classifyError(e),
            message:
                e is HarnessError
                    ? e.message
                    : 'Unexpected error: ${e.runtimeType}',
            error: e,
          ),
        );
      }
    } finally {
      _active.stop();
      _closeDanglingToolUses();
    }

    final finalText =
        _produced.reversed
            .firstWhere(
              (m) => m.role == Role.assistant && m.text.trim().isNotEmpty,
              orElse:
                  () => const AgentMessage(role: Role.assistant, content: []),
            )
            .text;
    _emit(RunCompleted(id, stop));
    // Not awaited: close() on an unlistened single-subscription controller
    // only completes once someone listens, and hosts may only await
    // [result].
    unawaited(_events.close());
    _result.complete(
      RunResult(
        finalText: finalText,
        newMessages: List.unmodifiable(_produced),
        usage: _usage,
        stopReason: stop,
        turns: _turn,
        todos: List.unmodifiable(
          (_runState[todosRunStateKey] as List<Todo>?) ?? const <Todo>[],
        ),
        structuredOutput: structured,
        error: error,
      ),
    );
  }

  /// Ensures the transcript never ends with unanswered tool uses (e.g. the
  /// run was cancelled while tools ran).
  void _closeDanglingToolUses() {
    if (_produced.isEmpty) return;
    final last = _produced.last;
    if (last.role != Role.assistant || last.toolUses.isEmpty) return;
    _produced.add(
      AgentMessage(
        role: Role.user,
        content: [
          for (final use in last.toolUses)
            ToolResultBlock(
              toolUseId: use.id,
              isError: true,
              content: const [TextBlock('Not executed: the run was stopped.')],
            ),
        ],
      ),
    );
  }

  Future<(StopReason, Object?)> _loop() async {
    final tools = await _resolveTools();
    final byName = <String, HarnessTool>{};
    for (final t in tools) {
      byName.putIfAbsent(t.name, () => t);
    }
    final definitions = [
      for (final t in byName.values)
        ToolDefinition(
          name: t.name,
          description: t.description,
          inputSchema: t.inputSchema,
        ),
    ];
    var working = <AgentMessage>[...history, input];
    var structuredRepairUsed = false;
    var emptyRetryUsed = false;

    // Host-initiated calls (e.g. a UI button bound to a tool) run first,
    // through the same validation/permission/execution pipeline, recorded
    // as an assistant tool_use turn so the model sees them as its own.
    if (initialToolCalls.isNotEmpty) {
      final calls = AgentMessage(
        role: Role.assistant,
        content: List<ContentBlock>.of(initialToolCalls),
        providerMetadata: const {'hostInitiated': true},
      );
      working = [...working, calls];
      _produced.add(calls);
      final hostResponse = _ModelResponse()..content.addAll(initialToolCalls);
      final results = await _executeTools(hostResponse, byName);
      final resultMessage = AgentMessage(role: Role.user, content: results);
      working = [...working, resultMessage];
      _produced.add(resultMessage);
    }

    while (true) {
      _cancel.throwIfCancelled();
      if (_turn >= config.maxTurns) return (StopReason.maxTurns, null);
      final budget = config.wallClockBudget;
      if (budget != null && _active.elapsed > budget) {
        return (StopReason.timeout, null);
      }
      final maxTokens = config.maxTotalTokens;
      if (maxTokens != null && _usage.totalTokens >= maxTokens) {
        return (StopReason.budget, null);
      }

      // Context management on the working copy.
      final compaction = await _context.compact(
        system: spec.instructions,
        messages: working,
        tools: definitions,
        contextWindow: _effectiveWindow(
          config.contextWindow,
          spec.model.capabilities.contextWindow,
        ),
        outputReserve: spec.settings.maxOutputTokens ?? 4096,
        summarizer: spec.model,
        cancel: _cancel,
      );
      if (compaction != null) {
        working = compaction.messages;
        _emit(
          ContextCompacted(
            id,
            stage: compaction.stages.join('+'),
            tokensBefore: compaction.tokensBefore,
            tokensAfter: compaction.tokensAfter,
          ),
        );
      }

      _turn++;
      _emit(TurnStarted(id, _turn));
      var response = await _callModel(working, definitions);

      // Some models return nothing when tools are offered; retry once with
      // tool calls disabled so the user still gets an answer. Definitions
      // stay in the request: the transcript may already hold tool blocks,
      // which providers reject without them.
      if (response.isEmpty && definitions.isNotEmpty && !emptyRetryUsed) {
        emptyRetryUsed = true;
        developer.log(
          'empty response with tools — retrying with tool_choice none',
          name: 'agentic_harness.runner',
        );
        response = await _callModel(
          working,
          definitions,
          toolChoice: ToolChoice.none,
        );
      }

      if (response.content.isNotEmpty) {
        final assistant = AgentMessage(
          role: Role.assistant,
          content: response.content,
          providerMetadata: response.metadata,
        );
        working = [...working, assistant];
        _produced.add(assistant);
      }

      if (response.stop == ModelStopReason.refusal &&
          response.toolUses.isEmpty) {
        return (StopReason.refusal, null);
      }

      if (response.toolUses.isEmpty) {
        final schema = spec.settings.outputSchema;
        if (schema == null) return (StopReason.endTurn, null);
        final check = _checkStructured(response.text, schema);
        if (check.errors.isEmpty) return (StopReason.endTurn, check.value);
        if (structuredRepairUsed) {
          throw ProviderError(
            'The model did not return valid structured output: ${check.errors.take(3).join('; ')}',
          );
        }
        structuredRepairUsed = true;
        final repair = AgentMessage.user(
          'Your answer must be only a JSON value matching this JSON Schema '
          '(no prose, no code fences): ${jsonEncode(schema)}\n'
          'Problems: ${check.errors.take(5).join('; ')}',
        );
        working = [...working, repair];
        _produced.add(repair);
        continue;
      }

      final results = await _executeTools(response, byName);
      final resultMessage = AgentMessage(role: Role.user, content: results);
      working = [...working, resultMessage];
      _produced.add(resultMessage);
    }
  }

  /// Completes with [future], or throws [CancelledException] as soon as the
  /// run is cancelled.
  Future<T> _untilCancelled<T>(Future<T> future) => Future.any([
    future,
    _cancel.whenCancelled.then<T>(
      (_) => throw CancelledException(_cancel.reason),
    ),
  ]);

  /// Forwards [source] until the run is cancelled, then ends with a
  /// [CancelledException] even if the source never yields again (e.g. a
  /// client blocked in on-device prefill).
  Stream<T> _streamUntilCancelled<T>(Stream<T> source) {
    late final StreamController<T> controller;
    StreamSubscription<T>? sub;
    void Function()? unregister;
    controller = StreamController<T>(
      onListen: () {
        sub = source.listen(
          controller.add,
          onError: controller.addError,
          onDone: () {
            unregister?.call();
            controller.close();
          },
        );
        unregister = _cancel.onCancel(() {
          unawaited(sub?.cancel().catchError((Object _) {}));
          if (!controller.isClosed) {
            controller.addError(CancelledException(_cancel.reason));
            controller.close();
          }
        });
      },
      onCancel: () {
        unregister?.call();
        return sub?.cancel().catchError((Object _) {});
      },
    );
    return controller.stream;
  }

  Future<List<HarnessTool>> _resolveTools() async {
    final tools = <HarnessTool>[...spec.tools];
    for (final provider in spec.toolProviders) {
      try {
        tools.addAll(
          await _untilCancelled(
            provider.listTools().timeout(const Duration(seconds: 20)),
          ),
        );
      } on CancelledException {
        rethrow;
      } catch (e, st) {
        developer.log(
          'tool provider failed: $e',
          name: 'agentic_harness.runner',
          error: e,
          stackTrace: st,
        );
      }
    }
    return tools;
  }

  Future<_ModelResponse> _callModel(
    List<AgentMessage> messages,
    List<ToolDefinition> tools, {
    ToolChoice toolChoice = ToolChoice.auto,
  }) async {
    final settings = spec.settings;
    final request = ModelRequest(
      system: spec.instructions,
      messages: messages,
      tools: tools,
      toolChoice: toolChoice,
      maxOutputTokens: settings.maxOutputTokens,
      temperature: settings.temperature,
      topP: settings.topP,
      thinking: settings.thinking,
      outputSchema: settings.outputSchema,
      cacheKey: config.cacheKey,
    );
    _context.noteRequest(
      _context.rawEstimate(spec.instructions, messages, tools),
    );

    final response = _ModelResponse();
    final text = StringBuffer();
    // Tool names by use id, so input deltas can say which tool they feed.
    final toolNames = <String, String>{};
    void flushText() {
      if (text.isEmpty) return;
      response.content.add(TextBlock(text.toString()));
      text.clear();
    }

    await for (final event in _streamUntilCancelled(
      spec.model.stream(request, cancel: _cancel),
    )) {
      switch (event) {
        case TextDeltaEvent(text: final t):
          text.write(t);
          _emit(TextDelta(id, t));
        case ThinkingDeltaEvent(text: final t):
          _emit(ThinkingDelta(id, t));
        case ThinkingCompleteEvent(
          text: final t,
          :final signature,
          :final redactedData,
        ):
          flushText();
          response.content.add(
            ThinkingBlock(t, signature: signature, redactedData: redactedData),
          );
        case ToolUseStartEvent(id: final useId, :final name):
          toolNames[useId] = name;
        case ToolInputDeltaEvent(id: final useId, :final jsonFragment):
          _emit(
            ToolInputDelta(id, useId, jsonFragment, name: toolNames[useId]),
          );
        case ToolUseEndEvent(
          id: final useId,
          :final name,
          :final input,
          :final parseError,
        ):
          flushText();
          response.content.add(
            ToolUseBlock(id: useId, name: name, input: input ?? const {}),
          );
          if (parseError != null) response.parseErrors[useId] = parseError;
        case UsageReport(:final usage):
          _usage = _usage + usage;
          _context.noteUsage(usage.inputTokens);
          _emit(UsageUpdated(id, call: usage, total: _usage));
        case MessageMetadataEvent(:final metadata):
          response.metadata.addAll(metadata);
        case MessageStop(:final reason):
          response.stop = reason;
      }
    }
    flushText();
    _cancel.throwIfCancelled();
    return response;
  }

  // ── Tools ───────────────────────────────────────────────────────────────

  Future<List<ContentBlock>> _executeTools(
    _ModelResponse response,
    Map<String, HarnessTool> byName,
  ) async {
    final uses = response.toolUses;
    final results = List<ToolResultBlock?>.filled(uses.length, null);
    final batch = <Future<void>>[];

    Future<void> flushBatch() async {
      if (batch.isEmpty) return;
      final pending = List.of(batch);
      batch.clear();
      await Future.wait(pending);
    }

    try {
      for (var i = 0; i < uses.length; i++) {
        _cancel.throwIfCancelled();
        final use = uses[i];
        final prepared = await _prepare(
          use,
          byName,
          response.parseErrors[use.id],
        );
        if (prepared.result != null) {
          results[i] = prepared.result;
          continue;
        }
        final index = i;
        Future<void> execute() async {
          results[index] = await _execute(
            use,
            prepared.tool!,
            prepared.input!,
            prepared.request!,
          );
        }

        if (prepared.request!.annotations.readOnly) {
          // Handle cancellation right away: the loop may be suspended in a
          // later call's approval when this one is cancelled, and an
          // unobserved error would escape to the zone.
          batch.add(
            execute().catchError((Object e) {
              if (e is! CancelledException) throw e;
            }),
          );
          if (batch.length >= config.maxParallelTools) await flushBatch();
        } else {
          await flushBatch();
          await execute();
        }
      }
      await flushBatch();
    } finally {
      if (batch.isNotEmpty) {
        await Future.wait([for (final f in batch) f.catchError((Object _) {})]);
      }
    }
    return [
      for (var i = 0; i < uses.length; i++)
        results[i] ??
            ToolResultBlock(
              toolUseId: uses[i].id,
              isError: true,
              content: const [TextBlock('Not executed.')],
            ),
    ];
  }

  Future<_Prepared> _prepare(
    ToolUseBlock use,
    Map<String, HarnessTool> byName,
    String? parseError,
  ) async {
    _Prepared fail(String message, {String? label}) {
      _emit(
        ToolCallStarted(
          id,
          toolUseId: use.id,
          name: use.name,
          input: use.input,
          displayLabel: label ?? use.name,
        ),
      );
      _emitResult(use, message, null, true, Duration.zero);
      return _Prepared.done(
        ToolResultBlock(
          toolUseId: use.id,
          isError: true,
          content: [TextBlock(message)],
        ),
      );
    }

    final tool = byName[use.name];
    if (tool == null) {
      final available = byName.keys.toList()..sort();
      return fail(
        'Unknown tool "${use.name}". Available tools: '
        '${available.isEmpty ? '(none)' : available.join(', ')}.',
      );
    }
    if (parseError != null) {
      return fail(
        'Your call to ${use.name} could not be parsed ($parseError). If the '
        'arguments were cut off, send a shorter call.',
      );
    }

    final validation = validateJsonSchema(use.input, tool.inputSchema);
    if (!validation.isValid || validation.value is! Map) {
      return fail(
        'Invalid arguments for ${use.name}: ${validation.errors.take(6).join('; ')}. '
        'Fix the arguments and call the tool again.',
      );
    }
    var input = (validation.value as Map).cast<String, Object?>();

    final signature = '${use.name}:${_canonicalJson(input)}';
    final count = (_callCounts[signature] ?? 0) + 1;
    _callCounts[signature] = count;
    if (count > config.maxRepeatedCalls) {
      return fail(
        'You already called ${use.name} with these exact arguments '
        '${count - 1} times. Use the earlier result or try a different approach.',
      );
    }

    var annotations = tool.annotationsFor(input);
    var label = tool.displayLabel(input);
    var request = ToolCallRequest(
      toolUseId: use.id,
      toolName: use.name,
      input: input,
      annotations: annotations,
      displayLabel: label,
      afterPrivateRead: _privateDataRead,
      hostInitiated: _hostCallIds.contains(use.id),
    );
    _emit(
      ToolCallStarted(
        id,
        toolUseId: use.id,
        name: use.name,
        input: input,
        displayLabel: label,
      ),
    );

    final pre = spec.hooks.preToolUse;
    if (pre != null) {
      final hookResult = await pre(request);
      switch (hookResult) {
        case BlockCall(:final message):
          return _blocked(use, message);
        case ContinueCall(:final updatedInput):
          if (updatedInput != null) {
            input = updatedInput;
            annotations = tool.annotationsFor(input);
            label = tool.displayLabel(input);
            request = ToolCallRequest(
              toolUseId: use.id,
              toolName: use.name,
              input: input,
              annotations: annotations,
              displayLabel: label,
              afterPrivateRead: _privateDataRead,
              hostInitiated: _hostCallIds.contains(use.id),
            );
          }
      }
    }

    if (config.dryRun &&
        (!request.annotations.readOnly || request.annotations.openWorld)) {
      return _blocked(
        use,
        'Not executed: dry-run mode is on. Describe what you would do instead.',
      );
    }

    final policy = spec.permissions;
    final decision = policy.evaluate(request);
    switch (decision.behavior) {
      case PermissionBehavior.allow:
        break;
      case PermissionBehavior.deny:
        return _blocked(
          use,
          decision.reason ?? 'This action is not permitted.',
        );
      case PermissionBehavior.ask:
        final canUse = policy.canUseTool;
        if (canUse == null) {
          return _blocked(
            use,
            'This action needs user approval, which is not available here.',
          );
        }
        _emit(
          ApprovalRequested(
            id,
            toolUseId: use.id,
            name: use.name,
            input: input,
            displayLabel: label,
          ),
        );
        _pause();
        PermissionDecision answer;
        try {
          answer = await Future.any([
            canUse(request),
            _cancel.whenCancelled.then<PermissionDecision>(
              (_) => throw CancelledException(_cancel.reason),
            ),
          ]);
        } finally {
          _resume();
        }
        switch (answer) {
          case Deny(:final message):
            return _blocked(use, message);
          case Allow(:final updatedInput):
            if (updatedInput != null) {
              input = updatedInput;
              request = ToolCallRequest(
                toolUseId: use.id,
                toolName: use.name,
                input: input,
                annotations: tool.annotationsFor(input),
                displayLabel: tool.displayLabel(input),
                afterPrivateRead: _privateDataRead,
                hostInitiated: _hostCallIds.contains(use.id),
              );
            }
        }
    }

    return _Prepared(tool, input, request);
  }

  _Prepared _blocked(ToolUseBlock use, String message) {
    _emitResult(use, message, null, true, Duration.zero);
    return _Prepared.done(
      ToolResultBlock(
        toolUseId: use.id,
        isError: true,
        content: [TextBlock(message)],
      ),
    );
  }

  Future<ToolResultBlock> _execute(
    ToolUseBlock use,
    HarnessTool tool,
    Map<String, Object?> input,
    ToolCallRequest request,
  ) async {
    final watch = Stopwatch()..start();
    final attempts = request.annotations.idempotent ? 2 : 1;
    ToolOutput output = ToolOutput.error('Tool did not run.');
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        output = await _invokeWithTimeout(use, tool, input);
        break;
      } on CancelledException {
        if (_cancel.isCancelled) rethrow;
        output = ToolOutput.error('The tool call was cancelled.');
        break;
      } on _ToolTimeout catch (t) {
        output = ToolOutput.error(
          '${tool.name} timed out after ${t.after.inSeconds}s.',
        );
        break;
      } catch (e, st) {
        developer.log(
          'tool ${tool.name} threw: $e',
          name: 'agentic_harness.runner',
          error: e,
          stackTrace: st,
        );
        output = ToolOutput.error('${tool.name} failed (${e.runtimeType}).');
        if (attempt < attempts) continue;
      }
    }

    final post = spec.hooks.postToolUse;
    if (post != null) {
      try {
        output = await post(request, output);
      } catch (e) {
        developer.log(
          'postToolUse hook threw: $e',
          name: 'agentic_harness.runner',
        );
      }
    }

    final text = _cap(output.text, tool.maxOutputChars);
    final content = <ContentBlock>[
      TextBlock(
        text.isEmpty ? (output.isError ? 'Error' : '(no output)') : text,
      ),
      ...output.content.whereType<ImageBlock>(),
    ];
    _emitResult(
      use,
      text,
      output.structured,
      output.isError,
      watch.elapsed,
      input: input,
    );
    final a = request.annotations;
    if (!output.isError) {
      // Local reads bring private data into the run (see afterPrivateRead).
      if (a.readOnly && !a.openWorld) _privateDataRead = true;
      // A successful write changes state, so re-reading is legitimate again.
      if (!a.readOnly) _callCounts.clear();
    }
    return ToolResultBlock(
      toolUseId: use.id,
      content: content,
      isError: output.isError,
    );
  }

  Future<ToolOutput> _invokeWithTimeout(
    ToolUseBlock use,
    HarnessTool tool,
    Map<String, Object?> input,
  ) async {
    final limit = tool.timeout ?? config.toolTimeout;
    final callToken = _cancel.child();
    final timeout = _PausableTimeout(limit);
    final context = ToolContext(
      cancel: callToken,
      runId: id,
      toolUseId: use.id,
      progress: (message) => _emit(ToolProgress(id, use.id, message)),
      requestUserInput: (
        prompt, {
        String inputType = 'text',
        List<String>? choices,
        List<UserInputField>? fields,
      }) async {
        timeout.pause();
        try {
          return await _askUser(prompt, inputType, choices, fields);
        } finally {
          timeout.resume();
        }
      },
      runState: _runState,
    );
    try {
      return await Future.any([
        tool.call(input, context),
        timeout.future.then<ToolOutput>((_) {
          callToken.cancel('Tool timed out');
          throw _ToolTimeout(limit);
        }),
        _cancel.whenCancelled.then<ToolOutput>(
          (_) => throw CancelledException(_cancel.reason),
        ),
      ]);
    } finally {
      timeout.dispose();
    }
  }

  /// The run's window, capped by the client's hard limit when it has one.
  static int? _effectiveWindow(int? configured, int? clientLimit) {
    if (configured == null || configured <= 0) return clientLimit;
    if (clientLimit == null || clientLimit <= 0) return configured;
    return configured < clientLimit ? configured : clientLimit;
  }

  Future<String> _askUser(
    String prompt,
    String inputType,
    List<String>? choices,
    List<UserInputField>? fields,
  ) async {
    // One question at a time; later askers wait their turn.
    while (_pendingInputCompleter != null) {
      try {
        await _pendingInputCompleter!.future;
      } catch (_) {
        break;
      }
    }
    _cancel.throwIfCancelled();
    final completer = Completer<String>();
    final event = UserInputRequested(
      id,
      requestId: newId('input'),
      prompt: prompt,
      inputType: inputType,
      choices: choices,
      fields: fields,
    );
    _pendingInput = event;
    _pendingInputCompleter = completer;
    _emit(event);
    _pause();
    try {
      return await completer.future;
    } finally {
      _resume();
      _pendingInput = null;
      _pendingInputCompleter = null;
    }
  }

  void _emitResult(
    ToolUseBlock use,
    String content,
    Object? structured,
    bool isError,
    Duration duration, {
    Map<String, Object?>? input,
  }) {
    _emit(
      ToolResultEvent(
        id,
        toolUseId: use.id,
        name: use.name,
        input: input ?? use.input,
        content: content,
        structured: structured,
        isError: isError,
        duration: duration,
      ),
    );
  }

  static String _cap(String text, int max) {
    if (text.length <= max || max <= 0) return text;
    final head = (max * 0.7).floor();
    final tail = max - head;
    final omitted = text.length - head - tail;
    return '${text.substring(0, head)}\n\n[… $omitted characters truncated …]\n\n'
        '${text.substring(text.length - tail)}';
  }

  static String _canonicalJson(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => '$k').toList()..sort();
      return '{${keys.map((k) => '${jsonEncode(k)}:${_canonicalJson(value[k])}').join(',')}}';
    }
    if (value is List) return '[${value.map(_canonicalJson).join(',')}]';
    return jsonEncode(value);
  }

  static ({Object? value, List<String> errors}) _checkStructured(
    String text,
    Map<String, Object?> schema,
  ) {
    var candidate = text.trim();
    final fence = RegExp(
      r'^```[a-zA-Z]*\s*([\s\S]*?)\s*```$',
    ).firstMatch(candidate);
    if (fence != null) candidate = fence.group(1)!.trim();
    Object? decoded;
    try {
      decoded = jsonDecode(candidate);
    } on FormatException catch (e) {
      return (value: null, errors: ['not valid JSON (${e.message})']);
    }
    final validation = validateJsonSchema(decoded, schema);
    return (value: validation.value, errors: validation.errors);
  }
}

class _ModelResponse {
  final List<ContentBlock> content = [];
  final Map<String, Object?> metadata = {};
  final Map<String, String> parseErrors = {};
  ModelStopReason stop = ModelStopReason.endTurn;

  List<ToolUseBlock> get toolUses => content.whereType<ToolUseBlock>().toList();
  String get text => content.whereType<TextBlock>().map((b) => b.text).join();
  bool get isEmpty => text.trim().isEmpty && toolUses.isEmpty;
}

class _Prepared {
  final HarnessTool? tool;
  final Map<String, Object?>? input;
  final ToolCallRequest? request;
  final ToolResultBlock? result;

  _Prepared(this.tool, this.input, this.request) : result = null;
  _Prepared.done(this.result) : tool = null, input = null, request = null;
}

class _ToolTimeout implements Exception {
  final Duration after;
  _ToolTimeout(this.after);
}

/// A timeout that can be paused (while a tool waits for the user).
class _PausableTimeout {
  final Completer<void> _completer = Completer<void>();
  Duration _remaining;
  Timer? _timer;
  final Stopwatch _watch = Stopwatch();

  _PausableTimeout(this._remaining) {
    resume();
  }

  Future<void> get future => _completer.future;

  void pause() {
    if (_timer == null) return;
    _timer!.cancel();
    _timer = null;
    _watch.stop();
    _remaining -= _watch.elapsed;
    _watch.reset();
  }

  void resume() {
    if (_timer != null || _completer.isCompleted) return;
    _watch
      ..reset()
      ..start();
    _timer = Timer(_remaining.isNegative ? Duration.zero : _remaining, () {
      if (!_completer.isCompleted) _completer.complete();
    });
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
