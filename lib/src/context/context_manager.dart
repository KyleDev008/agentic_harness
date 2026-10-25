import 'dart:convert';

import '../core/cancellation.dart';
import '../core/message.dart';
import '../model/model_client.dart';

/// When and how the working context is reduced.
final class ContextPolicy {
  final bool enabled;

  /// Compact when the estimated prompt exceeds this fraction of the usable
  /// window (context window minus the output reservation).
  final double compactAt;

  /// Most recent messages always kept verbatim.
  final int keepRecentMessages;

  /// Use one model call to summarize older history before truncating.
  /// Costs a request; the summary lives only in this run's working copy.
  final bool summarize;

  /// Window to assume when neither the request nor the client knows one.
  final int? fallbackContextWindow;

  const ContextPolicy({
    this.enabled = true,
    this.compactAt = 0.8,
    this.keepRecentMessages = 6,
    this.summarize = false,
    this.fallbackContextWindow,
  });

  static const disabled = ContextPolicy(enabled: false);
}

/// Estimates prompt size and compacts a transcript to fit.
///
/// Estimates use ~4 characters per token, calibrated by the ratio between
/// the provider's reported input tokens and the estimate for the previous
/// request — so after the first call the estimate tracks the real
/// tokenizer closely without shipping one.
class ContextManager {
  final ContextPolicy policy;
  double _calibration = 1.0;
  int? _lastEstimate;

  ContextManager(this.policy);

  static const _imageTokens = 1200;

  /// Raw (uncalibrated) estimate for a request.
  int rawEstimate(
    String? system,
    List<AgentMessage> messages,
    List<ToolDefinition> tools,
  ) {
    var chars = (system ?? '').length;
    for (final t in tools) {
      chars +=
          t.name.length +
          t.description.length +
          jsonEncode(t.inputSchema).length;
    }
    var images = 0;
    for (final m in messages) {
      for (final b in m.content) {
        switch (b) {
          case TextBlock(:final text):
            chars += text.length;
          case ThinkingBlock(:final text):
            chars += text.length;
          case ToolUseBlock(:final input, :final name):
            chars += name.length + jsonEncode(input).length;
          case ToolResultBlock():
            chars += b.text.length;
          case ImageBlock():
            images++;
        }
      }
      chars += 8; // role/framing overhead
    }
    return (chars / 4).ceil() + images * _imageTokens;
  }

  int estimate(
    String? system,
    List<AgentMessage> messages,
    List<ToolDefinition> tools,
  ) => (rawEstimate(system, messages, tools) * _calibration).ceil();

  /// Records the estimate sent with a request, to calibrate against usage.
  void noteRequest(int rawEstimateTokens) => _lastEstimate = rawEstimateTokens;

  /// Calibrates using the provider-reported input tokens of the last call.
  void noteUsage(int reportedInputTokens) {
    final last = _lastEstimate;
    if (last == null || last <= 0 || reportedInputTokens <= 0) return;
    final ratio = reportedInputTokens / last;
    // Ignore implausible ratios (e.g. a server reporting cached-only counts).
    if (ratio > 0.25 && ratio < 4) _calibration = ratio;
  }

  /// Returns a compacted copy of [messages] that fits [contextWindow] after
  /// reserving [outputReserve] tokens, or `null` when nothing was needed.
  ///
  /// [summarizer] is used only when `policy.summarize` is on.
  Future<CompactionResult?> compact({
    required String? system,
    required List<AgentMessage> messages,
    required List<ToolDefinition> tools,
    required int? contextWindow,
    required int outputReserve,
    ModelClient? summarizer,
    CancelToken? cancel,
  }) async {
    if (!policy.enabled) return null;
    final window = contextWindow ?? policy.fallbackContextWindow;
    if (window == null || window <= 0) return null;
    // Never let the output reservation swallow a small window.
    final usable = window - outputReserve.clamp(0, window ~/ 2);
    if (usable <= 0) return null;
    final limit = (usable * policy.compactAt).floor();
    final before = estimate(system, messages, tools);
    if (before <= limit) return null;

    final stages = <String>[];
    var working = List<AgentMessage>.of(messages);
    final keep = policy.keepRecentMessages.clamp(1, 1000);

    // Stage 1: clear bulky old tool results.
    final cleared = _clearOldToolResults(working, keep);
    if (cleared != null) {
      working = cleared;
      stages.add('clear_tool_results');
      if (estimate(system, working, tools) <= limit) {
        return CompactionResult(
          working,
          stages,
          before,
          estimate(system, working, tools),
        );
      }
    }

    // Stage 2: summarize older turns.
    if (policy.summarize && summarizer != null && working.length > keep + 1) {
      final split = _safeSplit(working, working.length - keep);
      if (split > 0) {
        final summary = await _summarize(
          summarizer,
          working.sublist(0, split),
          cancel,
        );
        if (summary != null && summary.trim().isNotEmpty) {
          working = [
            AgentMessage.user(
              '[Summary of the earlier conversation]\n$summary',
            ),
            ...working.sublist(split),
          ];
          stages.add('summarize');
          if (estimate(system, working, tools) <= limit) {
            return CompactionResult(
              working,
              stages,
              before,
              estimate(system, working, tools),
            );
          }
        }
      }
    }

    // Stage 3: drop the oldest turns, keeping tool use/result pairs intact
    // and always keeping the latest message.
    var dropped = false;
    while (working.length > 1 && estimate(system, working, tools) > limit) {
      final next = _safeSplit(working, 1);
      final cut = next <= 0 ? 1 : next;
      if (cut >= working.length) break;
      working = working.sublist(cut);
      dropped = true;
    }
    if (dropped) {
      // A transcript must start with a user turn.
      while (working.length > 1 && working.first.role != Role.user) {
        working = working.sublist(1);
      }
      if (working.first.toolResults.isNotEmpty) {
        final rest =
            working.first.content.where((b) => b is! ToolResultBlock).toList();
        working = [
          AgentMessage(
            role: Role.user,
            content:
                rest.isEmpty
                    ? [const TextBlock('(earlier context truncated)')]
                    : rest,
          ),
          ...working.sublist(1),
        ];
      }
      stages.add('truncate');
    }
    if (stages.isEmpty) return null;
    return CompactionResult(
      working,
      stages,
      before,
      estimate(system, working, tools),
    );
  }

  /// Smallest index >= [minIndex] where the transcript can be split without
  /// separating a tool use from its result (the message at the index must
  /// not carry tool results). Returns -1 when none exists.
  static int _safeSplit(List<AgentMessage> messages, int minIndex) {
    for (var i = minIndex; i < messages.length; i++) {
      if (messages[i].toolResults.isEmpty) return i;
    }
    return -1;
  }

  static List<AgentMessage>? _clearOldToolResults(
    List<AgentMessage> messages,
    int keep,
  ) {
    final cutoff = messages.length - keep;
    var changed = false;
    final out = <AgentMessage>[];
    for (var i = 0; i < messages.length; i++) {
      final m = messages[i];
      if (i >= cutoff || m.toolResults.isEmpty) {
        out.add(m);
        continue;
      }
      out.add(
        m.copyWith(
          content: [
            for (final b in m.content)
              if (b is ToolResultBlock && b.text.length > 200)
                ToolResultBlock(
                  toolUseId: b.toolUseId,
                  isError: b.isError,
                  content: const [
                    TextBlock('[result cleared to save context]'),
                  ],
                )
              else
                b,
          ],
        ),
      );
      changed = true;
    }
    return changed ? out : null;
  }

  static Future<String?> _summarize(
    ModelClient model,
    List<AgentMessage> older,
    CancelToken? cancel,
  ) async {
    final transcript = StringBuffer();
    for (final m in older) {
      transcript.writeln('${m.role.name}: ${m.text}');
      for (final u in m.toolUses) {
        transcript.writeln('  [called ${u.name}(${jsonEncode(u.input)})]');
      }
      for (final r in m.toolResults) {
        final text = r.text;
        transcript.writeln(
          '  [result: ${text.length > 400 ? '${text.substring(0, 400)}…' : text}]',
        );
      }
    }
    final buffer = StringBuffer();
    try {
      await for (final event in model.stream(
        ModelRequest(
          system:
              'You compress conversations. Write a concise summary of the '
              'conversation below that preserves user goals, decisions, '
              'facts, ids and open tasks. Output only the summary.',
          messages: [AgentMessage.user(transcript.toString())],
          maxOutputTokens: 1024,
        ),
        cancel: cancel,
      )) {
        if (event is TextDeltaEvent) buffer.write(event.text);
      }
    } catch (_) {
      return null; // fall through to truncation
    }
    return buffer.toString();
  }
}

final class CompactionResult {
  final List<AgentMessage> messages;
  final List<String> stages;
  final int tokensBefore;
  final int tokensAfter;
  const CompactionResult(
    this.messages,
    this.stages,
    this.tokensBefore,
    this.tokensAfter,
  );
}
