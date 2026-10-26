import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:path/path.dart' as p;

import '../tools/memory_tool.dart';
import 'workspace.dart';

/// A [MemoryStore] backed by a directory, for `MemoryTool`.
///
/// Paths go through [Workspace], and any path that passes through a link
/// is refused. Writes are atomic (temporary file, then rename) and, on
/// POSIX, owner-only. Files larger than [maxReadBytes] are refused rather
/// than loaded. Keep [root] writable only by the agent's own user.
class FileMemoryStore implements MemoryStore {
  final Workspace _workspace;
  final int maxReadBytes;

  FileMemoryStore(String root, {this.maxReadBytes = 4 * 1024 * 1024})
    : _workspace = Workspace(root) {
    Directory(root).createSync(recursive: true);
  }

  String get root => _workspace.root;

  /// The absolute path for [path]; refuses paths that pass through a link.
  Future<String> _resolve(String path, {bool forWrite = false}) async {
    final resolved = await _workspace.resolve(path, forWrite: forWrite);
    final expected = p.normalize(
      p.join(await _workspace.canonicalRoot(), p.joinAll(path.split('/'))),
    );
    if (!p.equals(resolved, expected)) {
      throw const WorkspaceViolation('links are not allowed in memory');
    }
    return resolved;
  }

  @override
  Future<MemoryEntry?> stat(String path) async {
    final full = await _resolve(path);
    switch (await FileSystemEntity.type(full, followLinks: false)) {
      case FileSystemEntityType.file:
        return MemoryEntry(
          path,
          isDirectory: false,
          size: await File(full).length(),
        );
      case FileSystemEntityType.directory:
        return MemoryEntry(path, isDirectory: true, size: await _size(full));
      default:
        return null;
    }
  }

  @override
  Future<String> read(String path) async {
    final file = File(await _resolve(path));
    if (await file.length() > maxReadBytes) {
      throw FileSystemException('memory file is too large', path);
    }
    return utf8.decode(await file.readAsBytes(), allowMalformed: true);
  }

  @override
  Future<void> write(String path, String text) async {
    final full = await _resolve(path, forWrite: true);
    await Directory(p.dirname(full)).create(recursive: true);
    // Hidden, so a listing never shows a half-written file.
    final temp = File(
      p.join(
        p.dirname(full),
        '.${p.basename(full)}.${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    try {
      await temp.writeAsString(text, flush: true);
      if (!Platform.isWindows) {
        await Process.run('chmod', ['600', temp.path]);
      }
      await temp.rename(full);
    } catch (_) {
      if (await temp.exists()) await temp.delete();
      rethrow;
    }
  }

  @override
  Future<List<MemoryEntry>> list(String path, {int depth = 2}) async {
    final base = await _resolve(path);
    final rootPath = await _workspace.canonicalRoot();
    final out = <MemoryEntry>[];
    Future<void> walk(Directory dir, int level) async {
      await for (final entity in dir.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name.startsWith('.') || name == 'node_modules') continue;
        final rel = p
            .relative(entity.path, from: rootPath)
            .replaceAll(r'\', '/');
        if (entity is File) {
          out.add(
            MemoryEntry(rel, isDirectory: false, size: await entity.length()),
          );
        } else if (entity is Directory) {
          out.add(
            MemoryEntry(rel, isDirectory: true, size: await _size(entity.path)),
          );
          if (level < depth) await walk(entity, level + 1);
        }
      }
    }

    await walk(Directory(base), 1);
    return out;
  }

  @override
  Future<void> delete(String path) async {
    final full = await _resolve(path, forWrite: true);
    if (p.equals(full, await _workspace.canonicalRoot())) {
      throw const WorkspaceViolation('the memory root cannot be deleted');
    }
    final type = await FileSystemEntity.type(full, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(full).delete(recursive: true);
    } else if (type != FileSystemEntityType.notFound) {
      await File(full).delete();
    }
    // Leave no empty directories behind.
    final rootPath = await _workspace.canonicalRoot();
    var parent = Directory(p.dirname(full));
    while (!p.equals(parent.path, rootPath) &&
        p.isWithin(rootPath, parent.path) &&
        await parent.list().isEmpty) {
      await parent.delete();
      parent = parent.parent;
    }
  }

  @override
  Future<void> rename(String from, String to) async {
    final source = await _resolve(from, forWrite: true);
    final target = await _resolve(to, forWrite: true);
    await Directory(p.dirname(target)).create(recursive: true);
    if (await FileSystemEntity.type(target, followLinks: false) !=
        FileSystemEntityType.notFound) {
      throw FileSystemException('destination exists', to);
    }
    final type = await FileSystemEntity.type(source, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(source).rename(target);
    } else {
      await File(source).rename(target);
    }
  }

  @override
  Future<int> fileCount() async {
    var count = 0;
    final dir = Directory(await _workspace.canonicalRoot());
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File && !p.basename(entity.path).startsWith('.')) count++;
    }
    return count;
  }

  static Future<int> _size(String dir) async {
    var total = 0;
    await for (final entity in Directory(
      dir,
    ).list(recursive: true, followLinks: false)) {
      if (entity is File) total += await entity.length();
    }
    return math.max(total, 0);
  }
}
