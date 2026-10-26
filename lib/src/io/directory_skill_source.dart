import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:path/path.dart' as p;

import '../tools/skills.dart';
import 'workspace.dart';

/// Skills from a folder: each subfolder holding a `SKILL.md` is a skill,
/// and its other files (text only, not hidden, no links) are the skill's
/// files.
///
/// Reads are confined to the skill's folder (links are refused) and
/// capped: [maxFileBytes] per file, [maxFilesPerSkill] files listed per
/// skill, [maxSkills] skills. A skill that fails to parse is skipped with a
/// log line. The folder is trusted content: only point this at skills you
/// wrote or reviewed, keep it out of reach of the agent's write tools, and
/// note that hard links inside it can't be detected.
class DirectorySkillSource implements SkillSource {
  final String root;
  final int maxFileBytes;
  final int maxFilesPerSkill;
  final int maxSkills;

  const DirectorySkillSource(
    this.root, {
    this.maxFileBytes = 256 * 1024,
    this.maxFilesPerSkill = 100,
    this.maxSkills = 200,
  });

  static const _log = 'agentic_harness.skills';

  @override
  Future<List<Skill>> loadSkills() async {
    final dir = Directory(root);
    if (!await dir.exists()) return const [];
    final skills = <Skill>[];
    final folders = [
      await for (final e in dir.list(followLinks: false))
        if (e is Directory && !p.basename(e.path).startsWith('.')) e,
    ]..sort((a, b) => a.path.compareTo(b.path));
    for (final folder in folders) {
      if (skills.length >= maxSkills) break;
      final skillFile = File(p.join(folder.path, 'SKILL.md'));
      if (await FileSystemEntity.type(skillFile.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      try {
        final workspace = Workspace(folder.path);
        final files = await _listFiles(folder);
        final markdown = await _readText(workspace, 'SKILL.md');
        final skill = Skill.fromMarkdown(
          markdown,
          files: files,
          readFile: (path) => _readText(workspace, path),
        );
        if (skill.name != p.basename(folder.path)) {
          developer.log(
            'skill "${skill.name}" lives in folder '
            '"${p.basename(folder.path)}"; name them the same',
            name: _log,
            level: 800,
          );
        }
        skills.add(skill);
      } catch (e) {
        developer.log(
          'skipped skill ${p.basename(folder.path)}: $e',
          name: _log,
          level: 900,
        );
      }
    }
    return skills;
  }

  /// Most directory entries looked at per skill, kept or not.
  static const maxEntriesScanned = 5000;

  /// Lists a skill's files breadth-first, skipping hidden entries without
  /// entering them, at most 4 levels deep, with a scanning budget.
  Future<List<String>> _listFiles(Directory folder) async {
    final files = <String>[];
    var scanned = 0;
    final queue = <(Directory, int)>[(folder, 1)];
    while (queue.isNotEmpty && files.length < maxFilesPerSkill) {
      final (dir, depth) = queue.removeAt(0);
      final entries = <FileSystemEntity>[];
      await for (final e in dir.list(followLinks: false)) {
        if (++scanned > maxEntriesScanned) break;
        entries.add(e);
      }
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final e in entries) {
        final name = p.basename(e.path);
        if (name.startsWith('.') || _control.hasMatch(name)) continue;
        if (e is Directory && depth < 4) {
          queue.add((e, depth + 1));
        } else if (e is File) {
          final rel = p
              .relative(e.path, from: folder.path)
              .replaceAll(r'\', '/');
          if (rel == 'SKILL.md') continue;
          files.add(rel);
          if (files.length >= maxFilesPerSkill) break;
        }
      }
      if (scanned > maxEntriesScanned) break;
    }
    return files..sort();
  }

  static final _control = RegExp(r'[\x00-\x1f\x7f]');

  Future<String> _readText(Workspace workspace, String rel) async {
    final full = await workspace.resolve(rel);
    final expected = p.normalize(
      p.join(await workspace.canonicalRoot(), p.joinAll(rel.split('/'))),
    );
    if (!p.equals(full, expected)) {
      throw const WorkspaceViolation('links are not allowed in skills');
    }
    final file = File(full);
    if ((await file.stat()).type != FileSystemEntityType.file) {
      throw FileSystemException('not a regular file', rel);
    }
    // Read at most one byte past the cap, so a growing file can't slip by.
    final bytes = <int>[];
    await for (final chunk in file.openRead(0, maxFileBytes + 1)) {
      bytes.addAll(chunk);
    }
    if (bytes.length > maxFileBytes) {
      throw FileSystemException('file is larger than $maxFileBytes bytes', rel);
    }
    if (bytes.contains(0)) {
      throw FileSystemException('not a text file', rel);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }
}
