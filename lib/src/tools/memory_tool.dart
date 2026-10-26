import 'dart:async';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'tool.dart';

/// A file or directory in a [MemoryStore].
final class MemoryEntry {
  /// Path relative to the memory root, `/`-separated (`''` is the root).
  final String path;
  final bool isDirectory;

  /// Size in bytes on disk, or characters for [InMemoryMemoryStore]; for a
  /// directory, the size of everything in it.
  final int size;

  const MemoryEntry(this.path, {required this.isDirectory, required this.size});
}

/// Storage behind [MemoryTool].
///
/// Paths are already validated by the tool: relative to the memory root,
/// `/`-separated, without empty, `.` or `..` segments, and never hidden.
/// Writing a file creates its parent directories.
abstract interface class MemoryStore {
  /// The entry at [path], or null when nothing exists there.
  Future<MemoryEntry?> stat(String path);

  /// Text of the file at [path].
  Future<String> read(String path);

  Future<void> write(String path, String text);

  /// Everything under the directory [path], up to [depth] levels deep, not
  /// including the directory itself.
  Future<List<MemoryEntry>> list(String path, {int depth = 2});

  /// Deletes a file, or a directory with everything in it.
  Future<void> delete(String path);

  Future<void> rename(String from, String to);

  /// Number of files in the store.
  Future<int> fileCount();
}

/// A [MemoryStore] held in memory, for tests and short-lived agents.
class InMemoryMemoryStore implements MemoryStore {
  final Map<String, String> files = {};

  @override
  Future<MemoryEntry?> stat(String path) async {
    final file = files[path];
    if (file != null) {
      return MemoryEntry(path, isDirectory: false, size: _bytes(file));
    }
    final prefix = path.isEmpty ? '' : '$path/';
    final inside = files.entries.where((e) => e.key.startsWith(prefix));
    if (path.isNotEmpty && inside.isEmpty) return null;
    return MemoryEntry(
      path,
      isDirectory: true,
      size: inside.fold(0, (sum, e) => sum + _bytes(e.value)),
    );
  }

  @override
  Future<String> read(String path) async => files[path]!;

  @override
  Future<void> write(String path, String text) async => files[path] = text;

  @override
  Future<List<MemoryEntry>> list(String path, {int depth = 2}) async {
    final prefix = path.isEmpty ? '' : '$path/';
    final dirs = <String>{};
    final out = <MemoryEntry>[];
    for (final entry in files.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      final rest = entry.key.substring(prefix.length).split('/');
      for (var i = 1; i < rest.length && i <= depth; i++) {
        dirs.add(prefix + rest.take(i).join('/'));
      }
      if (rest.length <= depth) {
        out.add(
          MemoryEntry(entry.key, isDirectory: false, size: _bytes(entry.value)),
        );
      }
    }
    for (final dir in dirs) {
      out.add((await stat(dir))!);
    }
    return out;
  }

  @override
  Future<void> delete(String path) async {
    files.remove(path);
    files.removeWhere((key, _) => key.startsWith('$path/'));
  }

  @override
  Future<void> rename(String from, String to) async {
    final moved = {
      for (final e in files.entries)
        if (e.key == from) to: e.value,
      for (final e in files.entries)
        if (e.key.startsWith('$from/'))
          '$to${e.key.substring(from.length)}': e.value,
    };
    await delete(from);
    files.addAll(moved);
  }

  @override
  Future<int> fileCount() async => files.length;

  static int _bytes(String text) => text.length;
}

/// Claude's memory tool: a `/memories` directory of notes the model reads
/// and writes across conversations (`view`, `create`, `str_replace`,
/// `insert`, `delete`, `rename`).
///
/// The Anthropic client declares it as the native `memory_20250818` tool;
/// other providers see the JSON schema below. Paths are confined to
/// `/memories`, and file size, file count and view length are capped.
///
/// `view` is a local read, so the standard permission mode treats the run
/// as holding private data afterwards; `delete` asks for approval like any
/// destructive call (allow it with a `PermissionRule('memory', allow)` if
/// the agent should prune freely).
///
/// Memory is a persistent prompt-injection channel: anything a run reads
/// from the web, files or MCP servers can be written here and come back as
/// "notes" in every later run. For agents that handle untrusted content,
/// set [askBeforeWrites] (or add an ask rule for `memory`) so the user sees
/// each write, and never let secrets be stored in it.
class MemoryTool extends HarnessTool {
  final MemoryStore store;

  /// Largest file, in characters.
  final int maxFileChars;
  final int maxFiles;

  /// Longest text `view` returns without a `view_range`.
  final int maxViewChars;

  /// Every write asks for approval in the standard permission mode.
  final bool askBeforeWrites;

  MemoryTool(
    this.store, {
    this.maxFileChars = 100000,
    this.maxFiles = 500,
    this.maxViewChars = 16000,
    this.askBeforeWrites = false,
  });

  /// Commands run one at a time, so checks and writes don't interleave.
  Future<void> _queue = Future.value();

  static const root = '/memories';
  static const int maxPathChars = 256;
  static const int maxDepth = 8;

  @override
  String get name => 'memory';

  @override
  String? get anthropicType => 'memory_20250818';

  @override
  String get description =>
      'Your memory directory, $root: notes that persist across '
      'conversations. View it before starting a task and record progress '
      'and lessons as you work. Commands: view (a directory listing, or a '
      'file with line numbers; optional view_range [start, end], end -1 for '
      'the rest), create (create or overwrite a file with file_text), '
      'str_replace (replace a unique old_str with new_str), insert '
      '(insert_text after line insert_line, 0 for the top), delete, rename '
      '(old_path to new_path). Keep it organized; never store secrets.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'command': {
        'type': 'string',
        'enum': ['view', 'create', 'str_replace', 'insert', 'delete', 'rename'],
      },
      'path': {'type': 'string', 'description': 'A path under /memories.'},
      'view_range': {
        'type': 'array',
        'items': {'type': 'integer'},
      },
      'file_text': {'type': 'string'},
      'old_str': {'type': 'string'},
      'new_str': {'type': 'string'},
      'insert_line': {'type': 'integer'},
      'insert_text': {'type': 'string'},
      'old_path': {'type': 'string'},
      'new_path': {'type': 'string'},
    },
    'required': ['command'],
  };

  @override
  ToolAnnotations get annotations => const ToolAnnotations();

  @override
  ToolAnnotations annotationsFor(Map<String, Object?> input) =>
      switch (input['command']) {
        'view' => ToolAnnotations.readOnlyLocal,
        'delete' => const ToolAnnotations(),
        _ when askBeforeWrites => const ToolAnnotations(),
        _ => ToolAnnotations.additiveWrite,
      };

  @override
  String displayLabel(Map<String, Object?> input) => switch (input['command']) {
    'view' => 'Checking memory…',
    'delete' => 'Deleting a memory…',
    _ => 'Updating memory…',
  };

  @override
  Future<ToolOutput> call(Map<String, Object?> input, ToolContext context) {
    final result = _queue.then((_) => _run(input));
    _queue = result.then((_) {}, onError: (Object _) {});
    return result;
  }

  Future<ToolOutput> _run(Map<String, Object?> input) async {
    try {
      return switch (input['command']) {
        'view' => await _view(input),
        'create' => await _create(input),
        'str_replace' => await _replace(input),
        'insert' => await _insert(input),
        'delete' => await _delete(input),
        'rename' => await _rename(input),
        final other => ToolOutput.error('Error: unknown command $other'),
      };
    } on _PathError catch (e) {
      return ToolOutput.error('Error: ${e.message}');
    } on Exception catch (e, st) {
      // Store failures (disk errors, a refused link): a clear message, not
      // a retried exception.
      developer.log(
        'memory store failed: $e',
        name: 'agentic_harness.memory',
        error: e,
        stackTrace: st,
      );
      return ToolOutput.error(
        'Error: the memory store could not complete this (${e.runtimeType}).',
      );
    }
  }

  Future<ToolOutput> _view(Map<String, Object?> input) async {
    final shown = _shown(input['path']);
    final path = _parse(shown);
    final entry = await store.stat(path);
    if (entry == null) {
      return ToolOutput.error(
        'The path $shown does not exist. Please provide a valid path.',
      );
    }
    if (entry.isDirectory) {
      final children =
          (await store.list(
              path,
            )).where((e) => !e.path.split('/').last.startsWith('.')).toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      return ToolOutput.text(
        [
          "Here're the files and directories up to 2 levels deep in $shown, "
              'excluding hidden items and node_modules:',
          '${_size(entry.size)}\t$shown',
          for (final c in children) '${_size(c.size)}\t${_display(c.path)}',
        ].join('\n'),
      );
    }
    final lines = (await store.read(path)).split('\n');
    if (lines.length > 999999) {
      return ToolOutput.error(
        'File $shown exceeds maximum line limit of 999,999 lines.',
      );
    }
    var start = 1;
    var end = lines.length;
    final range = input['view_range'];
    if (range is List && range.isNotEmpty) {
      if (range.length != 2 || range[0] is! int || range[1] is! int) {
        return ToolOutput.error(
          'Error: view_range must be [start_line, end_line].',
        );
      }
      start = range[0] as int;
      end = range[1] == -1 ? lines.length : range[1] as int;
      if (start < 1 || start > lines.length || end < start) {
        return ToolOutput.error(
          'Error: Invalid view_range ${range.join(', ')}. The file has '
          '${lines.length} lines.',
        );
      }
      end = math.min(end, lines.length);
    }
    final out = StringBuffer("Here's the content of $shown with line numbers:");
    var chars = 0;
    for (var i = start; i <= end; i++) {
      final line = lines[i - 1];
      if (chars + line.length > maxViewChars && i > start) {
        out.write(
          '\n[Truncated at line ${i - 1} of ${lines.length}: use view_range '
          'to read the rest.]',
        );
        break;
      }
      chars += line.length + 1;
      out.write('\n${'$i'.padLeft(6)}\t$line');
    }
    return ToolOutput.text(out.toString());
  }

  Future<ToolOutput> _create(Map<String, Object?> input) async {
    final shown = _shown(input['path']);
    final path = _parse(shown);
    if (path.isEmpty) return ToolOutput.error('Error: $shown is a directory');
    final text = input['file_text'];
    if (text is! String) {
      return ToolOutput.error('Error: file_text is required');
    }
    if (text.length > maxFileChars) {
      return ToolOutput.error(
        'Error: file_text is longer than $maxFileChars characters. Split it '
        'into smaller files.',
      );
    }
    final existing = await store.stat(path);
    if (existing != null && existing.isDirectory) {
      return ToolOutput.error('Error: $shown is a directory');
    }
    if (existing == null && await store.fileCount() >= maxFiles) {
      return ToolOutput.error(
        'Error: memory holds the maximum of $maxFiles files. Delete or merge '
        'files first.',
      );
    }
    await _ensureNoFileAncestor(path);
    await store.write(path, text);
    return ToolOutput.text('File created successfully at: $shown');
  }

  Future<ToolOutput> _replace(Map<String, Object?> input) async {
    final shown = _shown(input['path']);
    final path = await _existingFile(shown);
    if (path == null) {
      return ToolOutput.error(
        'Error: The path $shown does not exist. Please provide a valid path.',
      );
    }
    final oldStr = input['old_str'];
    if (oldStr is! String || oldStr.isEmpty) {
      return ToolOutput.error('Error: old_str is required');
    }
    final newStr = input['new_str'] is String ? input['new_str'] as String : '';
    final text = await store.read(path);
    final at = <int>[];
    for (
      var i = text.indexOf(oldStr);
      i >= 0;
      i = text.indexOf(oldStr, i + oldStr.length)
    ) {
      at.add(i);
    }
    if (at.isEmpty) {
      return ToolOutput.error(
        'No replacement was performed, old_str `$oldStr` did not appear '
        'verbatim in $shown.',
      );
    }
    if (at.length > 1) {
      final lines = [for (final i in at) _lineOf(text, i)];
      return ToolOutput.error(
        'No replacement was performed. Multiple occurrences of old_str '
        '`$oldStr` in lines: ${lines.join(', ')}. Please ensure it is unique',
      );
    }
    final updated = text.replaceRange(
      at.first,
      at.first + oldStr.length,
      newStr,
    );
    if (updated.length > maxFileChars) {
      return ToolOutput.error(
        'Error: the file would exceed $maxFileChars characters.',
      );
    }
    await store.write(path, updated);
    final line = _lineOf(updated, at.first);
    final lines = updated.split('\n');
    final from = math.max(1, line - 2);
    final to = math.min(
      lines.length,
      line + '\n'.allMatches(newStr).length + 2,
    );
    return ToolOutput.text(
      [
        'The memory file has been edited.',
        for (var i = from; i <= to; i++) '${'$i'.padLeft(6)}\t${lines[i - 1]}',
      ].join('\n'),
    );
  }

  Future<ToolOutput> _insert(Map<String, Object?> input) async {
    final shown = _shown(input['path']);
    final path = await _existingFile(shown);
    if (path == null) {
      return ToolOutput.error('Error: The path $shown does not exist');
    }
    final line = input['insert_line'];
    final insert = input['insert_text'];
    if (line is! int || insert is! String) {
      return ToolOutput.error(
        'Error: insert_line and insert_text are required',
      );
    }
    final lines = (await store.read(path)).split('\n');
    if (line < 0 || line > lines.length) {
      return ToolOutput.error(
        'Error: Invalid `insert_line` parameter: $line. It should be within '
        'the range of lines of the file: [0, ${lines.length}]',
      );
    }
    final added =
        insert.endsWith('\n') ? insert.substring(0, insert.length - 1) : insert;
    lines.insertAll(line, added.split('\n'));
    final updated = lines.join('\n');
    if (updated.length > maxFileChars) {
      return ToolOutput.error(
        'Error: the file would exceed $maxFileChars characters.',
      );
    }
    await store.write(path, updated);
    return ToolOutput.text('The file $shown has been edited.');
  }

  Future<ToolOutput> _delete(Map<String, Object?> input) async {
    final shown = _shown(input['path']);
    final path = _parse(shown);
    if (path.isEmpty) {
      return ToolOutput.error('Error: The $root directory cannot be deleted');
    }
    if (await store.stat(path) == null) {
      return ToolOutput.error('Error: The path $shown does not exist');
    }
    await store.delete(path);
    return ToolOutput.text('Successfully deleted $shown');
  }

  Future<ToolOutput> _rename(Map<String, Object?> input) async {
    final oldShown = _shown(input['old_path']);
    final newShown = _shown(input['new_path']);
    final from = _parse(oldShown);
    final to = _parse(newShown);
    if (from.isEmpty || to.isEmpty) {
      return ToolOutput.error('Error: The $root directory cannot be renamed');
    }
    if (await store.stat(from) == null) {
      return ToolOutput.error('Error: The path $oldShown does not exist');
    }
    if (await store.stat(to) != null) {
      return ToolOutput.error(
        'Error: The destination $newShown already exists',
      );
    }
    if (to.startsWith('$from/')) {
      return ToolOutput.error('Error: $oldShown cannot be moved inside itself');
    }
    // Moving a directory carries its nesting along.
    final nested = (await store.list(from, depth: maxDepth + 1)).fold(
      0,
      (deepest, e) =>
          math.max(deepest, e.path.split('/').length - from.split('/').length),
    );
    if (to.split('/').length + nested > maxDepth) {
      return ToolOutput.error('Error: the result would be nested too deeply');
    }
    await _ensureNoFileAncestor(to);
    await store.rename(from, to);
    return ToolOutput.text('Successfully renamed $oldShown to $newShown');
  }

  /// The store path of an existing file at [shown], or null.
  Future<String?> _existingFile(String shown) async {
    final path = _parse(shown);
    if (path.isEmpty) return null;
    final entry = await store.stat(path);
    return entry == null || entry.isDirectory ? null : path;
  }

  /// A file can't also be a directory: refuse `a/b` when `a` is a file.
  Future<void> _ensureNoFileAncestor(String path) async {
    final parts = path.split('/');
    for (var i = 1; i < parts.length; i++) {
      final entry = await store.stat(parts.take(i).join('/'));
      if (entry != null && !entry.isDirectory) {
        throw _PathError('${_display(parts.take(i).join('/'))} is a file');
      }
    }
  }

  static String _shown(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) {
      throw const _PathError('a path under /memories is required');
    }
    var path = raw.trim();
    while (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }

  /// Validates [shown] and returns it relative to the root.
  static String _parse(String shown) {
    if (shown.length > maxPathChars) {
      throw const _PathError('the path is too long');
    }
    if (shown != root && !shown.startsWith('$root/')) {
      throw _PathError('$shown is outside $root');
    }
    final rest = shown == root ? '' : shown.substring(root.length + 1);
    if (rest.isEmpty) return '';
    final segments = rest.split('/');
    if (segments.length > maxDepth) {
      throw const _PathError('the path is nested too deeply');
    }
    for (final segment in segments) {
      if (segment.isEmpty ||
          segment.startsWith('.') ||
          segment.endsWith('.') ||
          segment.endsWith(' ') ||
          segment.contains('%') ||
          segment.contains(r'\') ||
          _badChars.hasMatch(segment) ||
          _reserved.hasMatch(segment.split('.').first.trim()) ||
          segment.toLowerCase() == 'node_modules') {
        throw _PathError('invalid path segment "$segment"');
      }
    }
    return segments.join('/');
  }

  /// Control, Windows-special, line-separator, zero-width and bidi
  /// characters (the last ones can disguise a name in a listing).
  static final _badChars = RegExp(
    '[\\x00-\\x1f\\x7f:*?"<>|\\u0085\\u200b-\\u200f\\u2028-\\u202e\\u2066-\\u2069\\ufeff]',
  );

  /// Windows device names, also with an extension (`nul.md`).
  static final _reserved = RegExp(
    r'^(con|prn|aux|nul|com[0-9¹²³]|lpt[0-9¹²³]|conin\$|conout\$)$',
    caseSensitive: false,
  );

  static String _display(String path) => path.isEmpty ? root : '$root/$path';

  static int _lineOf(String text, int index) =>
      '\n'.allMatches(text.substring(0, index)).length + 1;

  static String _size(int bytes) {
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}K';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}M';
  }
}

class _PathError implements Exception {
  final String message;
  const _PathError(this.message);
}
