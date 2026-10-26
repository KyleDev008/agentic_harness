import 'dart:math';

import '../core/usage.dart';

/// What a model costs, in US dollars per million tokens.
///
/// Cache prices default to the input price. Cache tokens are taken to be
/// part of `Usage.inputTokens`, as every bundled client reports them.
///
/// Two refinements cover how providers actually bill:
/// - [longContext]: prompts over [longContextThreshold] input tokens pay
///   these prices instead (each request on its own), as on Claude Haiku
///   5.5, Gemini 2.5 Pro or the GPT-5.4+ flagships.
/// - [next]: from [nextFrom] on, [next] applies (announced price changes).
final class ModelPricing {
  final double inputPerMillion;
  final double outputPerMillion;
  final double? cacheReadPerMillion;
  final double? cacheWritePerMillion;
  final int? longContextThreshold;
  final ModelPricing? longContext;
  final DateTime? nextFrom;
  final ModelPricing? next;

  const ModelPricing({
    required this.inputPerMillion,
    required this.outputPerMillion,
    this.cacheReadPerMillion,
    this.cacheWritePerMillion,
    this.longContextThreshold,
    this.longContext,
    this.nextFrom,
    this.next,
  });

  /// Free (local models).
  static const free = ModelPricing(inputPerMillion: 0, outputPerMillion: 0);

  /// The prices that apply to a request with [inputTokens] at [at] (now by
  /// default).
  ModelPricing resolve(int inputTokens, {DateTime? at}) {
    var p = this;
    final when = at ?? DateTime.now();
    // Follow announced changes, then the prompt-size tier.
    for (var i = 0; i < 8; i++) {
      final from = p.nextFrom;
      final next = p.next;
      if (from == null || next == null || when.isBefore(from)) break;
      p = next;
    }
    final threshold = p.longContextThreshold;
    final long = p.longContext;
    if (threshold != null && long != null && inputTokens > threshold) {
      return long.resolve(inputTokens, at: when);
    }
    return p;
  }

  /// The cost of one request's [usage] in US dollars.
  double cost(Usage usage, {DateTime? at}) {
    final p = resolve(usage.inputTokens, at: at);
    final cached = usage.cacheReadTokens + usage.cacheWriteTokens;
    final plain = max(0, usage.inputTokens - cached);
    return (plain * p.inputPerMillion +
            usage.cacheReadTokens *
                (p.cacheReadPerMillion ?? p.inputPerMillion) +
            usage.cacheWriteTokens *
                (p.cacheWritePerMillion ?? p.inputPerMillion) +
            usage.outputTokens * p.outputPerMillion) /
        1e6;
  }

  Map<String, Object?> toJson() => {
    'input': inputPerMillion,
    'output': outputPerMillion,
    if (cacheReadPerMillion != null) 'cacheRead': cacheReadPerMillion,
    if (cacheWritePerMillion != null) 'cacheWrite': cacheWritePerMillion,
    if (longContextThreshold != null)
      'longContextThreshold': longContextThreshold,
    if (longContext != null) 'longContext': longContext!.toJson(),
    if (nextFrom != null) 'nextFrom': nextFrom!.toUtc().toIso8601String(),
    if (next != null) 'next': next!.toJson(),
  };

  /// Parses [toJson] output; throws [FormatException] for invalid prices.
  factory ModelPricing.fromJson(Map<String, Object?> json, [int depth = 0]) {
    if (depth > 8) throw const FormatException('Pricing nested too deeply');
    double price(String key, {bool required = false}) {
      final v = json[key];
      if (v is num && v.isFinite && v >= 0) return v.toDouble();
      if (v == null && !required) return -1;
      throw FormatException('Invalid price "$key"');
    }

    double? optional(String key) {
      final v = price(key);
      return v < 0 ? null : v;
    }

    final threshold = json['longContextThreshold'];
    final long = json['longContext'];
    final next = json['next'];
    final nextFrom = json['nextFrom'];
    // Tiers and schedules come in pairs; half of one is a mistake.
    if ((threshold == null) != (long == null)) {
      throw const FormatException(
        'longContextThreshold and longContext go together',
      );
    }
    if ((nextFrom == null) != (next == null)) {
      throw const FormatException('nextFrom and next go together');
    }
    if (threshold != null &&
        (threshold is! num ||
            threshold <= 0 ||
            threshold != threshold.round())) {
      throw const FormatException('Invalid longContextThreshold');
    }
    if (long != null && long is! Map) {
      throw const FormatException('Invalid longContext');
    }
    if (next != null && next is! Map) {
      throw const FormatException('Invalid next');
    }
    final from = nextFrom is String ? DateTime.tryParse(nextFrom) : null;
    if (nextFrom != null && from == null) {
      throw const FormatException('Invalid nextFrom');
    }
    return ModelPricing(
      inputPerMillion: price('input', required: true),
      outputPerMillion: price('output', required: true),
      cacheReadPerMillion: optional('cacheRead'),
      cacheWritePerMillion: optional('cacheWrite'),
      longContextThreshold: (threshold as num?)?.round(),
      longContext:
          long is Map
              ? ModelPricing.fromJson(long.cast<String, Object?>(), depth + 1)
              : null,
      nextFrom: from,
      next:
          next is Map
              ? ModelPricing.fromJson(next.cast<String, Object?>(), depth + 1)
              : null,
    );
  }
}

/// Prices by model.
///
/// Keys are a client id (`anthropic:claude-opus-5-5`) or a bare model name
/// (`claude-opus-5-5`); a key ending in `*` matches by prefix, the longest
/// prefix winning. Lookups also try the name without a provider path
/// (`anthropic/…` on OpenRouter, `models/…` on Gemini), without a date
/// suffix (`gpt-4.1-2025-04-14`), and inside `prompted(…)`.
///
/// [builtIn] holds list prices as of [builtInAsOf]; prices change, so load
/// fresh ones with [PricingTable.fromJson] (for example from your own
/// server) and layer them with [withOverrides].
final class PricingTable {
  final Map<String, ModelPricing> models;

  /// Used for any model not in [models]; null leaves it unpriced.
  final ModelPricing? fallback;

  const PricingTable(this.models, {this.fallback});

  /// No prices at all: cost tracking off.
  static const none = PricingTable({});

  /// Pricing for the client [id] (`ModelClient.id`), or [fallback].
  ///
  /// Provider-qualified keys (`ollama:*`) win over bare names, so a local
  /// model named like a hosted one isn't billed as the hosted one.
  ModelPricing? forModel(String id) {
    final candidates = _candidates(id);
    final qualified = candidates.first;
    String? bestPrefix(Iterable<String> names, {required bool qualifiedKeys}) {
      String? best;
      for (final key in models.keys) {
        if (!key.endsWith('*') || key.contains(':') != qualifiedKeys) continue;
        final prefix = key.substring(0, key.length - 1);
        if (names.any((n) => n.startsWith(prefix)) &&
            (best == null || key.length > best.length)) {
          best = key;
        }
      }
      return best;
    }

    final byId = models[qualified];
    if (byId != null) return byId;
    final byProvider = bestPrefix([qualified], qualifiedKeys: true);
    if (byProvider != null) return models[byProvider];
    for (final name in candidates.skip(1)) {
      final exact = models[name];
      if (exact != null) return exact;
    }
    final byName = bestPrefix(candidates.skip(1), qualifiedKeys: false);
    return byName == null ? fallback : models[byName];
  }

  static List<String> _candidates(String id) {
    var inner = id;
    while (inner.startsWith('prompted(') && inner.endsWith(')')) {
      inner = inner.substring(9, inner.length - 1);
    }
    final out = <String>[inner];
    var name =
        inner.contains(':') ? inner.substring(inner.indexOf(':') + 1) : inner;
    out.add(name);
    if (name.contains('/')) {
      name = name.substring(name.lastIndexOf('/') + 1);
      out.add(name);
    }
    final undated = name
        .replaceFirst(RegExp(r'-latest$'), '')
        .replaceFirst(RegExp(r'-\d{4}-\d{2}-\d{2}$'), '')
        .replaceFirst(RegExp(r'-\d{8}$'), '')
        .replaceFirst(RegExp(r'@\d{8}$'), '');
    if (undated != name) out.add(undated);
    return out;
  }

  /// This table with [overrides] taking precedence (and its fallback, when
  /// it has one).
  PricingTable withOverrides(PricingTable overrides) => PricingTable({
    ...models,
    ...overrides.models,
  }, fallback: overrides.fallback ?? fallback);

  Map<String, Object?> toJson() => {
    'models': {for (final e in models.entries) e.key: e.value.toJson()},
    if (fallback != null) 'fallback': fallback!.toJson(),
  };

  /// Parses `{"models": {"name": {"input": 4, "output": 20, ...}},
  /// "fallback": {...}}`. Invalid entries throw [FormatException].
  factory PricingTable.fromJson(Map<String, Object?> json) {
    final raw = json['models'];
    if (raw is! Map) throw const FormatException('Pricing: "models" missing');
    final fallback = json['fallback'];
    return PricingTable(
      {
        for (final e in raw.entries)
          '${e.key}': switch (e.value) {
            final Map<dynamic, dynamic> m => ModelPricing.fromJson(
              m.cast<String, Object?>(),
            ),
            _ => throw FormatException('Pricing for "${e.key}" is invalid'),
          },
      },
      fallback:
          fallback is Map
              ? ModelPricing.fromJson(fallback.cast<String, Object?>())
              : null,
    );
  }

  /// When [builtIn]'s prices were taken from the providers' pricing pages.
  static final builtInAsOf = DateTime.utc(2026, 10, 26);

  /// Standard list prices (USD per million tokens) for Anthropic, OpenAI
  /// and Gemini models, as of [builtInAsOf], plus local Ollama models as
  /// free. Batch, priority, regional and fast-mode rates are not covered.
  static final builtIn = PricingTable({
    // Anthropic (cache writes: 5-minute TTL).
    'claude-fable-5-1': _ModelPrices.fable51,
    'claude-mythos-5-1': _ModelPrices.fable51,
    'claude-fable-5': _ModelPrices.fable5,
    'claude-mythos-5': _ModelPrices.fable5,
    'claude-opus-5-5': const ModelPricing(
      inputPerMillion: 4,
      outputPerMillion: 20,
      cacheReadPerMillion: 0.20,
      cacheWritePerMillion: 5,
    ),
    'claude-opus-5': _ModelPrices.opus45,
    'claude-opus-4-8': _ModelPrices.opus45,
    'claude-opus-4-7': _ModelPrices.opus45,
    'claude-opus-4-6': _ModelPrices.opus45,
    'claude-opus-4-5': _ModelPrices.opus45,
    'claude-opus-4-1': _ModelPrices.opus4,
    'claude-opus-4': _ModelPrices.opus4,
    'claude-opus-4-0': _ModelPrices.opus4,
    'claude-sonnet-5-5': const ModelPricing(
      inputPerMillion: 2,
      outputPerMillion: 10,
      cacheReadPerMillion: 0.10,
      cacheWritePerMillion: 2.5,
    ),
    'claude-sonnet-5': const ModelPricing(
      inputPerMillion: 2,
      outputPerMillion: 10,
      cacheReadPerMillion: 0.20,
      cacheWritePerMillion: 2.5,
    ),
    'claude-sonnet-4-6': _ModelPrices.sonnet4,
    'claude-sonnet-4-5': _ModelPrices.sonnet4,
    'claude-sonnet-4': _ModelPrices.sonnet4,
    'claude-sonnet-4-0': _ModelPrices.sonnet4,
    'claude-haiku-5-5': const ModelPricing(
      inputPerMillion: 0.10,
      outputPerMillion: 0.50,
      cacheReadPerMillion: 0.01,
      cacheWritePerMillion: 0.125,
      longContextThreshold: 100000,
      longContext: ModelPricing(
        inputPerMillion: 0.50,
        outputPerMillion: 2.50,
        cacheReadPerMillion: 0.05,
        cacheWritePerMillion: 0.625,
      ),
    ),
    'claude-haiku-4-5': const ModelPricing(
      inputPerMillion: 1,
      outputPerMillion: 5,
      cacheReadPerMillion: 0.10,
      cacheWritePerMillion: 1.25,
    ),
    'claude-3-5-haiku': const ModelPricing(
      inputPerMillion: 0.80,
      outputPerMillion: 4,
      cacheReadPerMillion: 0.08,
      cacheWritePerMillion: 1,
    ),
    // OpenAI (standard tier; flagships bill prompts over 272K higher).
    'gpt-6-astra': const ModelPricing(
      inputPerMillion: 10,
      outputPerMillion: 50,
      cacheReadPerMillion: 1,
      longContextThreshold: 272000,
      longContext: ModelPricing(
        inputPerMillion: 20,
        outputPerMillion: 75,
        cacheReadPerMillion: 2,
      ),
    ),
    'gpt-6.1-sol': const ModelPricing(
      inputPerMillion: 2,
      outputPerMillion: 10,
      cacheReadPerMillion: 0.10,
      longContextThreshold: 272000,
      longContext: ModelPricing(
        inputPerMillion: 4,
        outputPerMillion: 15,
        cacheReadPerMillion: 0.20,
      ),
    ),
    'gpt-6-sol': const ModelPricing(
      inputPerMillion: 2,
      outputPerMillion: 10,
      cacheReadPerMillion: 0.20,
      longContextThreshold: 272000,
      longContext: ModelPricing(
        inputPerMillion: 4,
        outputPerMillion: 15,
        cacheReadPerMillion: 0.40,
      ),
    ),
    'gpt-6-luna': const ModelPricing(
      inputPerMillion: 0.10,
      outputPerMillion: 0.50,
      cacheReadPerMillion: 0.01,
      longContextThreshold: 272000,
      longContext: ModelPricing(
        inputPerMillion: 0.20,
        outputPerMillion: 0.75,
        cacheReadPerMillion: 0.02,
      ),
    ),
    'gpt-5.6-sol': const ModelPricing(
      inputPerMillion: 4,
      outputPerMillion: 20,
      cacheReadPerMillion: 0.40,
      longContextThreshold: 272000,
      longContext: ModelPricing(
        inputPerMillion: 8,
        outputPerMillion: 30,
        cacheReadPerMillion: 0.80,
      ),
    ),
    'gpt-5.6-terra': const ModelPricing(
      inputPerMillion: 2,
      outputPerMillion: 12,
      cacheReadPerMillion: 0.20,
      longContextThreshold: 272000,
      longContext: ModelPricing(
        inputPerMillion: 4,
        outputPerMillion: 18,
        cacheReadPerMillion: 0.40,
      ),
    ),
    'gpt-5.6-luna': const ModelPricing(
      inputPerMillion: 0.20,
      outputPerMillion: 1.20,
      cacheReadPerMillion: 0.02,
      longContextThreshold: 272000,
      longContext: ModelPricing(
        inputPerMillion: 0.40,
        outputPerMillion: 1.80,
        cacheReadPerMillion: 0.04,
      ),
    ),
    'gpt-5.5': const ModelPricing(
      inputPerMillion: 5,
      outputPerMillion: 30,
      cacheReadPerMillion: 0.50,
      longContextThreshold: 272000,
      longContext: ModelPricing(
        inputPerMillion: 10,
        outputPerMillion: 45,
        cacheReadPerMillion: 1,
      ),
    ),
    'gpt-5.5-pro': _ModelPrices.gptPro,
    'gpt-5.4': const ModelPricing(
      inputPerMillion: 2.50,
      outputPerMillion: 15,
      cacheReadPerMillion: 0.25,
      longContextThreshold: 272000,
      longContext: ModelPricing(
        inputPerMillion: 5,
        outputPerMillion: 22.50,
        cacheReadPerMillion: 0.50,
      ),
    ),
    'gpt-5.4-pro': _ModelPrices.gptPro,
    'gpt-5.4-mini': const ModelPricing(
      inputPerMillion: 0.75,
      outputPerMillion: 4.50,
      cacheReadPerMillion: 0.075,
    ),
    'gpt-5.4-nano': const ModelPricing(
      inputPerMillion: 0.20,
      outputPerMillion: 1.25,
      cacheReadPerMillion: 0.02,
    ),
    'gpt-5.3-codex': _ModelPrices.gpt52,
    'gpt-5.2': _ModelPrices.gpt52,
    'gpt-5.2-pro': const ModelPricing(
      inputPerMillion: 21,
      outputPerMillion: 168,
    ),
    'gpt-5.1': _ModelPrices.gpt5,
    'gpt-5': _ModelPrices.gpt5,
    'gpt-5-mini': const ModelPricing(
      inputPerMillion: 0.25,
      outputPerMillion: 2,
      cacheReadPerMillion: 0.025,
    ),
    'gpt-5-nano': const ModelPricing(
      inputPerMillion: 0.05,
      outputPerMillion: 0.40,
      cacheReadPerMillion: 0.005,
    ),
    'gpt-5-pro': const ModelPricing(inputPerMillion: 15, outputPerMillion: 120),
    'gpt-4.1': const ModelPricing(
      inputPerMillion: 2,
      outputPerMillion: 8,
      cacheReadPerMillion: 0.50,
    ),
    'gpt-4.1-mini': const ModelPricing(
      inputPerMillion: 0.40,
      outputPerMillion: 1.60,
      cacheReadPerMillion: 0.10,
    ),
    'gpt-4.1-nano': const ModelPricing(
      inputPerMillion: 0.10,
      outputPerMillion: 0.40,
      cacheReadPerMillion: 0.025,
    ),
    'gpt-4o': const ModelPricing(
      inputPerMillion: 2.50,
      outputPerMillion: 10,
      cacheReadPerMillion: 1.25,
    ),
    'gpt-4o-mini': const ModelPricing(
      inputPerMillion: 0.15,
      outputPerMillion: 0.60,
      cacheReadPerMillion: 0.075,
    ),
    'o3': const ModelPricing(
      inputPerMillion: 2,
      outputPerMillion: 8,
      cacheReadPerMillion: 0.50,
    ),
    'o3-pro': const ModelPricing(inputPerMillion: 20, outputPerMillion: 80),
    'o4-mini': const ModelPricing(
      inputPerMillion: 1.10,
      outputPerMillion: 4.40,
      cacheReadPerMillion: 0.275,
    ),
    'o3-mini': const ModelPricing(
      inputPerMillion: 1.10,
      outputPerMillion: 4.40,
      cacheReadPerMillion: 0.55,
    ),
    'o1': const ModelPricing(
      inputPerMillion: 15,
      outputPerMillion: 60,
      cacheReadPerMillion: 7.50,
    ),
    // Gemini (paid tier; announced increases are scheduled).
    'gemini-4-argon': ModelPricing(
      inputPerMillion: 2,
      outputPerMillion: 10,
      cacheReadPerMillion: 0.10,
      nextFrom: _ModelPrices.dec2026,
      next: const ModelPricing(
        inputPerMillion: 4,
        outputPerMillion: 20,
        cacheReadPerMillion: 0.20,
      ),
    ),
    'gemini-3.8-flash': _ModelPrices.gemini36Flash,
    'gemini-3.6-flash': _ModelPrices.gemini36Flash,
    'gemini-3.5-flash-lite': const ModelPricing(
      inputPerMillion: 0.30,
      outputPerMillion: 2.50,
      cacheReadPerMillion: 0.03,
    ),
    'gemini-3.1-flash-lite': const ModelPricing(
      inputPerMillion: 0.25,
      outputPerMillion: 1.50,
      cacheReadPerMillion: 0.025,
    ),
    'gemini-3.1-pro-preview*': const ModelPricing(
      inputPerMillion: 2,
      outputPerMillion: 12,
      cacheReadPerMillion: 0.20,
      longContextThreshold: 200000,
      longContext: ModelPricing(
        inputPerMillion: 4,
        outputPerMillion: 18,
        cacheReadPerMillion: 0.40,
      ),
    ),
    'gemini-3-flash-preview': const ModelPricing(
      inputPerMillion: 0.50,
      outputPerMillion: 3,
      cacheReadPerMillion: 0.05,
    ),
    'gemini-2.5-pro': const ModelPricing(
      inputPerMillion: 1.25,
      outputPerMillion: 10,
      cacheReadPerMillion: 0.125,
      longContextThreshold: 200000,
      longContext: ModelPricing(
        inputPerMillion: 2.50,
        outputPerMillion: 15,
        cacheReadPerMillion: 0.25,
      ),
    ),
    'gemini-2.5-flash': const ModelPricing(
      inputPerMillion: 0.30,
      outputPerMillion: 2.50,
      cacheReadPerMillion: 0.03,
    ),
    'gemini-2.5-flash-lite': const ModelPricing(
      inputPerMillion: 0.10,
      outputPerMillion: 0.40,
      cacheReadPerMillion: 0.01,
    ),
    // Local models.
    'ollama:*': ModelPricing.free,
  });
}

/// Prices shared by several models in [PricingTable.builtIn].
abstract final class _ModelPrices {
  static const fable51 = ModelPricing(
    inputPerMillion: 10,
    outputPerMillion: 50,
    cacheReadPerMillion: 0.25,
    cacheWritePerMillion: 12.50,
  );
  static const fable5 = ModelPricing(
    inputPerMillion: 10,
    outputPerMillion: 50,
    cacheReadPerMillion: 1,
    cacheWritePerMillion: 12.50,
  );
  static const opus45 = ModelPricing(
    inputPerMillion: 5,
    outputPerMillion: 25,
    cacheReadPerMillion: 0.50,
    cacheWritePerMillion: 6.25,
  );
  static const opus4 = ModelPricing(
    inputPerMillion: 15,
    outputPerMillion: 75,
    cacheReadPerMillion: 1.50,
    cacheWritePerMillion: 18.75,
  );
  static const sonnet4 = ModelPricing(
    inputPerMillion: 3,
    outputPerMillion: 15,
    cacheReadPerMillion: 0.30,
    cacheWritePerMillion: 3.75,
  );
  static const gptPro = ModelPricing(
    inputPerMillion: 30,
    outputPerMillion: 180,
    longContextThreshold: 272000,
    longContext: ModelPricing(inputPerMillion: 60, outputPerMillion: 270),
  );
  static const gpt52 = ModelPricing(
    inputPerMillion: 1.75,
    outputPerMillion: 14,
    cacheReadPerMillion: 0.175,
  );
  static const gpt5 = ModelPricing(
    inputPerMillion: 1.25,
    outputPerMillion: 10,
    cacheReadPerMillion: 0.125,
  );
  static final dec2026 = DateTime.utc(2026, 12, 1);
  static final jan2027 = DateTime.utc(2027, 1, 1);
  static final gemini36Flash = ModelPricing(
    inputPerMillion: 0.75,
    outputPerMillion: 3.75,
    cacheReadPerMillion: 0.075,
    nextFrom: _ModelPrices.jan2027,
    next: const ModelPricing(
      inputPerMillion: 1.50,
      outputPerMillion: 7.50,
      cacheReadPerMillion: 0.15,
    ),
  );
}
