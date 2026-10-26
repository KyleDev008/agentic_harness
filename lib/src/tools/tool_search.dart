import 'dart:math';

import 'tool.dart';

/// Tools that stay out of the prompt until the model looks them up.
///
/// Wrap a large catalogue (an MCP server's tools, say) so the model sees
/// only a `search_tools` tool at first; a search loads the matching tools,
/// and from the next model call on they can be called like any other.
/// Saves prompt tokens and keeps the model's choice focused.
///
/// ```dart
/// AgentSpec(toolProviders: [DeferredTools(McpToolset(client, prefix: 'gh'))]);
/// ```
class DeferredTools implements ToolProvider {
  final ToolProvider? _provider;
  final List<HarnessTool> _tools;

  /// Defers every tool [provider] lists.
  DeferredTools(ToolProvider provider)
    : _provider = provider,
      _tools = const [];

  /// Defers [tools].
  DeferredTools.of(List<HarnessTool> tools)
    : _provider = null,
      _tools = List.of(tools);

  @override
  Future<List<HarnessTool>> listTools() async => [
    for (final t in _provider == null ? _tools : await _provider.listTools())
      t.deferLoading ? t : _DeferredTool(t),
  ];
}

/// [inner] with `deferLoading` on; everything else is passed through.
class _DeferredTool extends HarnessTool {
  final HarnessTool inner;
  _DeferredTool(this.inner);

  @override
  bool get deferLoading => true;
  @override
  String get name => inner.name;
  @override
  String get description => inner.description;
  @override
  Map<String, Object?> get inputSchema => inner.inputSchema;
  @override
  ToolAnnotations get annotations => inner.annotations;
  @override
  ToolAnnotations annotationsFor(Map<String, Object?> input) =>
      inner.annotationsFor(input);
  @override
  String displayLabel(Map<String, Object?> input) => inner.displayLabel(input);
  @override
  Duration? get timeout => inner.timeout;
  @override
  int get maxOutputChars => inner.maxOutputChars;
  @override
  bool get replayable => inner.replayable;
  @override
  String? get anthropicType => inner.anthropicType;
  @override
  bool get readsPrivateData => inner.readsPrivateData;
  @override
  bool get startsRuns => inner.startsRuns;
  @override
  Future<ToolOutput> call(Map<String, Object?> input, ToolContext context) =>
      inner.call(input, context);
}

/// Keyword search over tools (BM25 over name, description and parameter
/// names; names count double).
class ToolSearchIndex {
  final List<HarnessTool> tools;
  final List<Map<String, int>> _terms = [];
  final Map<String, int> _docFreq = {};
  late final double _avgLength;

  ToolSearchIndex(List<HarnessTool> tools) : tools = List.unmodifiable(tools) {
    var total = 0;
    for (final t in this.tools) {
      final terms = <String, int>{};
      void add(Iterable<String> words, int weight) {
        for (final w in words) {
          terms[w] = (terms[w] ?? 0) + weight;
        }
      }

      add(tokenize(t.name), 2);
      add(tokenize(t.description), 1);
      final props = t.inputSchema['properties'];
      if (props is Map) add(props.keys.expand((k) => tokenize('$k')), 1);
      _terms.add(terms);
      total += terms.values.fold(0, (a, b) => a + b);
      for (final term in terms.keys) {
        _docFreq[term] = (_docFreq[term] ?? 0) + 1;
      }
    }
    _avgLength = this.tools.isEmpty ? 1 : total / this.tools.length;
  }

  /// Lowercase words (any script), splitting camelCase, acronyms
  /// (`HTTPServer`), snake_case and kebab-case, without common stop words.
  static List<String> tokenize(String text) =>
      text
          .replaceAllMapped(
            RegExp(r'([a-z0-9])([A-Z])'),
            (m) => '${m[1]} ${m[2]}',
          )
          .replaceAllMapped(
            RegExp(r'([A-Z]+)([A-Z][a-z])'),
            (m) => '${m[1]} ${m[2]}',
          )
          .toLowerCase()
          .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
          .where((w) => !_stopWords.contains(w))
          .where((w) => w.length > 1)
          .toList();

  /// The best matches for [query], most relevant first.
  List<HarnessTool> search(String query, {int limit = 5}) {
    final words = tokenize(query).toSet();
    if (words.isEmpty) return const [];
    const k1 = 1.2;
    const b = 0.75;
    final n = tools.length;
    final scored = <(double, int)>[];
    for (var i = 0; i < n; i++) {
      final terms = _terms[i];
      final length = terms.values.fold(0, (a, c) => a + c);
      var score = 0.0;
      for (final w in words) {
        final tf = terms[w];
        if (tf == null) continue;
        final df = _docFreq[w]!;
        final idf = log(1 + (n - df + 0.5) / (df + 0.5));
        score +=
            idf *
            (tf * (k1 + 1)) /
            (tf + k1 * (1 - b + b * length / _avgLength));
      }
      if (tools[i].name.toLowerCase() == query.trim().toLowerCase()) {
        score += 10;
      }
      if (score > 0) scored.add((score, i));
    }
    scored.sort((x, y) => y.$1.compareTo(x.$1));
    return [for (final s in scored.take(limit)) tools[s.$2]];
  }
}

/// The run's `search_tools` tool: finds deferred tools and loads them.
/// Created by the runner when an agent has deferred tools.
class ToolSearchTool extends HarnessTool {
  final ToolSearchIndex index;

  /// Loads tools by name; returns the names it couldn't load (the run's
  /// limit on loaded tools).
  final List<String> Function(List<String> names) load;

  /// Most tools returned per search.
  final int maxResults;

  ToolSearchTool(this.index, this.load, {this.maxResults = 5});

  static const toolName = 'search_tools';

  @override
  String get name => toolName;

  @override
  String get description {
    final names = index.tools.map((t) => t.name).toList()..sort();
    return 'Find and load tools. ${names.length} more tools are available '
        'but not loaded yet; search by what you need (keywords) and the best '
        'matches are loaded so you can call them next. Use "select:name1,'
        'name2" to load tools by exact name.'
        '${names.length <= 60 ? ' Tool names: ${names.join(', ')}.' : ''}';
  }

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'query': {
        'type': 'string',
        'description': 'Keywords, or "select:" followed by tool names.',
      },
    },
    'required': ['query'],
  };

  @override
  ToolAnnotations get annotations => ToolAnnotations.readOnlyLocal;

  @override
  bool get readsPrivateData => false;

  @override
  String displayLabel(Map<String, Object?> input) => 'Looking for tools…';

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final query = '${input['query'] ?? ''}'.trim();
    List<HarnessTool> found;
    var missing = const <String>[];
    if (query.toLowerCase().startsWith('select:')) {
      final wanted =
          query
              .substring(7)
              .split(',')
              .map((n) => n.trim())
              .where((n) => n.isNotEmpty)
              .toSet();
      found = [
        for (final t in index.tools)
          if (wanted.contains(t.name)) t,
      ];
      missing = wanted.difference({for (final t in found) t.name}).toList();
      if (missing.isNotEmpty && found.isEmpty) {
        return ToolOutput.error(
          'No tools named ${missing.join(', ')}. Search by keywords instead.',
        );
      }
    } else {
      found = index.search(query, limit: maxResults);
    }
    if (found.isEmpty) {
      return ToolOutput.text(
        'No tools matched "$query". Try other words, or describe the action.',
      );
    }
    final refused = load([for (final t in found) t.name]);
    if (refused.length == found.length) {
      return ToolOutput.error(
        'The limit on loaded tools is reached; use the tools already loaded.',
      );
    }
    found = [
      for (final t in found)
        if (!refused.contains(t.name)) t,
    ];
    String brief(String text) {
      final line = text.replaceAll(RegExp(r'\s+'), ' ').trim();
      return line.length <= 300 ? line : '${line.substring(0, 297)}…';
    }

    return ToolOutput.text(
      'Loaded; you can call these now:\n'
      '${found.map((t) => '- ${t.name}: ${brief(t.description)}').join('\n')}'
      '${missing.isEmpty ? '' : '\nNot found: ${missing.join(', ')}.'}'
      '${refused.isEmpty ? '' : '\nNot loaded (the limit on loaded tools is reached): ${refused.join(', ')}.'}',
      structured: {
        'loaded': [for (final t in found) t.name],
      },
    );
  }
}

const _stopWords = {
  'a',
  'an',
  'and',
  'are',
  'as',
  'at',
  'be',
  'by',
  'for',
  'from',
  'in',
  'into',
  'is',
  'it',
  'its',
  'me',
  'my',
  'of',
  'on',
  'or',
  'please',
  'that',
  'the',
  'this',
  'to',
  'use',
  'with',
  'you',
  'your',
  'can',
  'need',
  'want',
  'tool',
  'tools',
};
