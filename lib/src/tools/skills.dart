import 'dart:developer' as developer;

import 'tool.dart';

/// A skill: instructions (and optional files) the model loads only when a
/// task calls for them.
///
/// The model sees each skill's [name] and [description] in an index; when
/// it loads the skill it gets the [instructions] and the list of [files],
/// which it reads one at a time. This keeps detailed guidance out of the
/// prompt until it is needed.
///
/// Skills are host content: they reach the model as tool results, so write
/// them as you would a system prompt, and only load skills you trust. Keep
/// skill folders out of reach of the agent's own write tools, or it could
/// plant instructions for later runs.
final class Skill {
  /// Lowercase letters, digits and hyphens, at most 64 characters.
  final String name;

  /// When to use the skill, in a sentence or two (at most 1024 characters).
  final String description;

  /// The full instructions, sent when the skill is loaded.
  final String instructions;

  /// Paths of the skill's extra files (references, templates, examples).
  final List<String> files;

  final Future<String> Function(String path)? _read;

  Skill({
    required this.name,
    required this.description,
    required this.instructions,
    this.files = const [],
    Future<String> Function(String path)? readFile,
  }) : _read = readFile {
    if (!validName.hasMatch(name)) {
      throw ArgumentError.value(name, 'name', 'Use a-z, 0-9 and -, up to 64');
    }
    if (description.trim().isEmpty || description.length > 1024) {
      throw ArgumentError.value(
        description,
        'description',
        'Describe when to use the skill in at most 1024 characters',
      );
    }
  }

  /// A skill whose files are held in memory.
  factory Skill.withFiles({
    required String name,
    required String description,
    required String instructions,
    Map<String, String> files = const {},
  }) => Skill(
    name: name,
    description: description,
    instructions: instructions,
    files: files.keys.toList()..sort(),
    readFile: (path) async => files[path]!,
  );

  /// Parses a `SKILL.md`: YAML-style front matter with `name` and
  /// `description` between `---` lines, then the instructions.
  factory Skill.fromMarkdown(
    String markdown, {
    List<String> files = const [],
    Future<String> Function(String path)? readFile,
  }) {
    final (meta, body) = parseFrontMatter(markdown);
    final name = meta['name'];
    final description = meta['description'];
    if (name == null || description == null) {
      throw const FormatException(
        'SKILL.md needs front matter with a name and a description',
      );
    }
    return Skill(
      name: name,
      description: description,
      instructions: body.trim(),
      files: files,
      readFile: readFile,
    );
  }

  static final validName = RegExp(r'^[a-z0-9][a-z0-9-]{0,63}$');

  /// The text of [path], one of [files].
  Future<String> readFile(String path) {
    final read = _read;
    if (read == null || !files.contains(path)) {
      throw ArgumentError.value(path, 'path', 'Not a file of this skill');
    }
    return read(path);
  }

  /// Splits `---`-delimited front matter (simple `key: value` lines,
  /// optionally quoted) from the rest of [markdown].
  ///
  /// Block values (`key: >` or `key: |` followed by indented lines) are
  /// folded or kept line by line. Throws [FormatException] when the front
  /// matter is never closed.
  static (Map<String, String>, String) parseFrontMatter(String markdown) {
    var text = markdown.replaceAll('\r\n', '\n');
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    if (!text.startsWith('---\n')) return (const {}, text);
    final close = RegExp(r'^---[ \t]*$', multiLine: true);
    final match = close.allMatches(text, 4).firstOrNull;
    if (match == null) {
      throw const FormatException('The front matter has no closing ---');
    }
    final lines = text.substring(4, match.start).split('\n');
    final meta = <String, String>{};
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final colon = line.indexOf(':');
      if (colon <= 0 || line.startsWith(' ') || line.startsWith('\t')) {
        continue;
      }
      var value = line.substring(colon + 1).trim();
      if (RegExp(r'^[>|][+-]?$').hasMatch(value)) {
        // A block value: the indented lines below.
        final block = <String>[];
        while (i + 1 < lines.length &&
            (lines[i + 1].startsWith(' ') ||
                lines[i + 1].startsWith('\t') ||
                lines[i + 1].trim().isEmpty)) {
          block.add(lines[++i].trim());
        }
        value =
            (value.startsWith('>') ? block.join(' ') : block.join('\n')).trim();
      } else if (value.length >= 2 &&
          ((value.startsWith('"') && value.endsWith('"')) ||
              (value.startsWith("'") && value.endsWith("'")))) {
        value = value.substring(1, value.length - 1);
      }
      meta[line.substring(0, colon).trim()] = value;
    }
    final rest = text.indexOf('\n', match.end);
    return (meta, rest < 0 ? '' : text.substring(rest + 1));
  }
}

/// Where skills come from (for example a folder of `SKILL.md` files; see
/// `DirectorySkillSource` in `io_tools.dart`).
abstract interface class SkillSource {
  Future<List<Skill>> loadSkills();
}

/// Gives an agent a library of skills: a `load_skill` tool whose
/// description is the index, and a `read_skill_file` tool. Add it to
/// `AgentSpec.toolProviders` (or its [tools] to `AgentSpec.tools`).
///
/// Index, instructions and files are capped so a large library can't
/// flood the context.
class SkillSet implements ToolProvider {
  final List<Skill> _skills;
  final List<SkillSource> sources;

  /// Longest index put in the `load_skill` description.
  final int maxIndexChars;

  /// Longest instructions or file text returned in one call.
  final int maxContentChars;

  /// Set when skills can contain the user's private data (for example a
  /// source backed by their notes): reading them then counts as a private
  /// read, so the standard permission mode asks before open-world calls.
  final bool containsPrivateData;

  SkillSet({
    List<Skill> skills = const [],
    this.sources = const [],
    this.maxIndexChars = 8000,
    this.maxContentChars = 50000,
    this.containsPrivateData = false,
  }) : _skills = List.of(skills);

  Future<Map<String, Skill>>? _loaded;

  /// Every skill, by name (sources are read once, again after a failure;
  /// the first skill with a name wins).
  Future<Map<String, Skill>> skills() => _loaded ??= _load();

  Future<Map<String, Skill>> _load() async {
    final byName = <String, Skill>{};
    void add(Skill s) {
      if (byName.containsKey(s.name)) {
        developer.log(
          'skill "${s.name}" defined twice; the first is used',
          name: 'agentic_harness.skills',
          level: 900,
        );
        return;
      }
      byName[s.name] = s;
    }

    _skills.forEach(add);
    var failed = false;
    for (final source in sources) {
      try {
        (await source.loadSkills()).forEach(add);
      } catch (e, st) {
        // Keep the other sources' skills; try this one again next time.
        failed = true;
        developer.log(
          'skill source failed: $e',
          name: 'agentic_harness.skills',
          error: e,
          stackTrace: st,
        );
      }
    }
    if (failed) _loaded = null;
    return byName;
  }

  /// Reads the sources again on the next run.
  void reload() => _loaded = null;

  @override
  Future<List<HarnessTool>> listTools() async {
    final skills = await this.skills();
    if (skills.isEmpty) return const [];
    return [
      _LoadSkillTool(this, _index(skills.values)),
      _ReadSkillFileTool(this),
    ];
  }

  String _index(Iterable<Skill> skills) {
    final lines = <String>[];
    var chars = 0;
    var left = 0;
    for (final s in skills) {
      final line = '- ${s.name}: ${_oneLine(s.description)}';
      if (chars + line.length > maxIndexChars) {
        left++;
        continue;
      }
      chars += line.length + 1;
      lines.add(line);
    }
    if (left > 0) {
      lines.add(
        '- … and $left more: call load_skill with any name to list them all.',
      );
    }
    return lines.join('\n');
  }

  static String _oneLine(String text) =>
      text.replaceAll(RegExp(r'[\x00-\x1f\x7f]+'), ' ').trim();

  String _cap(String text) =>
      text.length <= maxContentChars
          ? text
          : '${text.substring(0, maxContentChars)}\n[… cut at $maxContentChars '
              'characters …]';
}

class _LoadSkillTool extends HarnessTool {
  final SkillSet set;
  final String index;
  _LoadSkillTool(this.set, this.index);

  @override
  String get name => 'load_skill';

  @override
  String get description =>
      'Load a skill: detailed instructions for a kind of task. Load the '
      'matching skill before starting such a task, and follow it. Available '
      'skills:\n$index';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'name': {'type': 'string', 'description': 'The skill to load.'},
    },
    'required': ['name'],
  };

  @override
  ToolAnnotations get annotations => ToolAnnotations.readOnlyLocal;

  @override
  bool get readsPrivateData => set.containsPrivateData;

  @override
  String displayLabel(Map<String, Object?> input) =>
      'Loading the ${input['name']} skill…';

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final skills = await set.skills();
    final skill = skills['${input['name']}'];
    if (skill == null) {
      return ToolOutput.error(
        'No skill named "${input['name']}". Available: '
        '${(skills.keys.toList()..sort()).join(', ')}.',
      );
    }
    final buffer = StringBuffer('# Skill: ${skill.name}\n\n')
      ..write(skill.instructions);
    if (skill.files.isNotEmpty) {
      buffer.write(
        '\n\nFiles in this skill (read them with read_skill_file when the '
        'instructions call for them):\n'
        '${skill.files.where((f) => !_control.hasMatch(f)).map((f) => '- $f').join('\n')}',
      );
    }
    return ToolOutput.text(
      set._cap(buffer.toString()),
      structured: {
        'skill': skill.name,
        'files': skill.files.where((f) => !_control.hasMatch(f)).toList(),
      },
    );
  }
}

class _ReadSkillFileTool extends HarnessTool {
  final SkillSet set;
  _ReadSkillFileTool(this.set);

  @override
  String get name => 'read_skill_file';

  @override
  String get description =>
      'Read one of a loaded skill\'s files, by the path its instructions '
      'list.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'skill': {'type': 'string'},
      'path': {'type': 'string'},
    },
    'required': ['skill', 'path'],
  };

  @override
  ToolAnnotations get annotations => ToolAnnotations.readOnlyLocal;

  @override
  bool get readsPrivateData => set.containsPrivateData;

  @override
  String displayLabel(Map<String, Object?> input) =>
      'Reading ${input['path']} from the ${input['skill']} skill…';

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final skill = (await set.skills())['${input['skill']}'];
    if (skill == null) {
      return ToolOutput.error('No skill named "${input['skill']}".');
    }
    final path = '${input['path']}';
    if (!skill.files.contains(path)) {
      return ToolOutput.error(
        '${skill.name} has no file "$path". Its files: '
        '${skill.files.isEmpty ? '(none)' : skill.files.join(', ')}.',
      );
    }
    try {
      return ToolOutput.text(set._cap(await skill.readFile(path)));
    } catch (e) {
      return ToolOutput.error('Could not read $path (${e.runtimeType}).');
    }
  }
}

final _control = RegExp(r'[\x00-\x1f\x7f]');
