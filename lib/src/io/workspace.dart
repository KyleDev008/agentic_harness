import 'dart:io';

import 'package:path/path.dart' as p;

/// Resolves model-supplied paths inside a workspace root, defeating `..`,
/// absolute paths, device paths and symlink/junction escapes.
class Workspace {
  final String root;
  String? _canonicalRoot;

  Workspace(this.root);

  Future<String> canonicalRoot() async =>
      _canonicalRoot ??= p.normalize(
        await Directory(root).resolveSymbolicLinks(),
      );

  /// Returns the canonical absolute path for [relative], or throws
  /// [WorkspaceViolation].
  ///
  /// Existing targets are resolved through symlinks and must stay inside
  /// the root; for a target that does not exist yet, its nearest existing
  /// ancestor is resolved instead. With [forWrite], paths inside `.git`
  /// are rejected (writing hooks/config there would allow code execution).
  Future<String> resolve(String relative, {bool forWrite = false}) async {
    final raw = relative.trim();
    if (raw.isEmpty) return canonicalRoot();
    if (raw.contains('\x00')) throw const WorkspaceViolation('NUL in path');
    if (p.isAbsolute(raw) ||
        raw.startsWith(r'\\') ||
        raw.startsWith('//') ||
        RegExp(r'^[a-zA-Z]:').hasMatch(raw)) {
      throw const WorkspaceViolation('use a path relative to the workspace');
    }
    final rootPath = await canonicalRoot();
    final joined = p.normalize(p.join(rootPath, raw));
    if (!_inside(rootPath, joined)) {
      throw const WorkspaceViolation('path escapes the workspace');
    }

    final resolved = await _resolveExistingPrefix(joined);
    if (!_inside(rootPath, resolved)) {
      throw const WorkspaceViolation('path escapes the workspace via a link');
    }
    if (forWrite) {
      // Any `.git` segment (nested clones, submodules): hooks or config
      // written there run code on the user's next git command.
      final rel = p.relative(resolved, from: rootPath);
      if (p.split(rel).any((s) => s.toLowerCase() == '.git')) {
        throw const WorkspaceViolation('writing inside .git is not allowed');
      }
    }
    return resolved;
  }

  /// Workspace-relative display form of [absolute] (never leaks the root).
  Future<String> display(String absolute) async =>
      p.relative(absolute, from: await canonicalRoot()).replaceAll(r'\', '/');

  static bool _inside(String root, String path) =>
      p.equals(root, path) || p.isWithin(root, path);

  /// Resolves symlinks for the longest existing prefix of [path] and
  /// appends the non-existing remainder.
  static Future<String> _resolveExistingPrefix(String path) async {
    var current = path;
    final tail = <String>[];
    while (true) {
      final type = await FileSystemEntity.type(current, followLinks: false);
      if (type != FileSystemEntityType.notFound) {
        final real =
            type == FileSystemEntityType.directory
                ? await Directory(current).resolveSymbolicLinks()
                : type == FileSystemEntityType.link
                ? await Link(current).resolveSymbolicLinks()
                : await File(current).resolveSymbolicLinks();
        return p.normalize(p.joinAll([real, ...tail.reversed]));
      }
      final parent = p.dirname(current);
      if (parent == current) return path;
      tail.add(p.basename(current));
      current = parent;
    }
  }
}

class WorkspaceViolation implements Exception {
  final String message;
  const WorkspaceViolation(this.message);
  @override
  String toString() => message;
}
