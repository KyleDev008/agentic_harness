/// Token counts for one model call, or summed over a run.
///
/// [cacheReadTokens]/[cacheWriteTokens] are prompt-cache counters (Anthropic
/// `cache_read_input_tokens`/`cache_creation_input_tokens`, OpenAI
/// `cached_tokens`). They are part of, not in addition to, [inputTokens]
/// for providers that report them that way; see each client's docs.
final class Usage {
  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;

  const Usage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
  });

  static const zero = Usage();

  int get totalTokens => inputTokens + outputTokens;

  Usage operator +(Usage other) => Usage(
    inputTokens: inputTokens + other.inputTokens,
    outputTokens: outputTokens + other.outputTokens,
    cacheReadTokens: cacheReadTokens + other.cacheReadTokens,
    cacheWriteTokens: cacheWriteTokens + other.cacheWriteTokens,
  );

  Map<String, Object?> toJson() => {
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    if (cacheReadTokens > 0) 'cacheReadTokens': cacheReadTokens,
    if (cacheWriteTokens > 0) 'cacheWriteTokens': cacheWriteTokens,
  };

  factory Usage.fromJson(Map<String, Object?> json) => Usage(
    inputTokens: _int(json['inputTokens']),
    outputTokens: _int(json['outputTokens']),
    cacheReadTokens: _int(json['cacheReadTokens']),
    cacheWriteTokens: _int(json['cacheWriteTokens']),
  );

  static int _int(Object? v) => v is num ? v.toInt() : 0;

  @override
  String toString() =>
      'Usage(in: $inputTokens, out: $outputTokens'
      '${cacheReadTokens > 0 ? ', cacheRead: $cacheReadTokens' : ''}'
      '${cacheWriteTokens > 0 ? ', cacheWrite: $cacheWriteTokens' : ''})';
}
