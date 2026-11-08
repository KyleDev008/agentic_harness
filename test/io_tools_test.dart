import 'dart:io';

import 'package:agentic_harness/io_tools.dart';
import 'package:agentic_harness/agentic_harness.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as p;

ToolContext ctx() => ToolContext(
  cancel: CancelToken(),
  runId: 'r',
  toolUseId: 't',
  progress: (_) {},
  requestUserInput: (prompt, {inputType = 'text', choices, fields}) async => '',
  runState: {},
);

void main() {
  late Directory root;
  late Directory outside;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ah_ws_');
    outside = await Directory.systemTemp.createTemp('ah_out_');
    await File(p.join(outside.path, 'secret.txt')).writeAsString('secret');
    await File(p.join(root.path, 'a.txt')).writeAsString('hello');
  });

  tearDown(() async {
    await root.delete(recursive: true);
    await outside.delete(recursive: true);
  });

  group('FileSystemTool', () {
    test('reads, writes and lists inside the workspace', () async {
      final fs = FileSystemTool(workspaceRoot: root.path);
      expect(
        (await fs.call({'action': 'read', 'path': 'a.txt'}, ctx())).text,
        'hello',
      );
      final w = await fs.call({
        'action': 'write',
        'path': 'sub/b.txt',
        'content': 'x',
      }, ctx());
      expect(w.isError, isFalse);
      final list = await fs.call({'action': 'list', 'path': ''}, ctx());
      expect(list.text, contains('sub/'));
    });

    test('rejects traversal, absolute paths and .git writes', () async {
      final fs = FileSystemTool(workspaceRoot: root.path);
      for (final path in [
        '../secret.txt',
        'sub/../../x',
        p.join(outside.path, 'secret.txt'),
      ]) {
        final out = await fs.call({'action': 'read', 'path': path}, ctx());
        expect(out.isError, isTrue, reason: path);
        expect(out.text, isNot(contains(outside.path)));
      }
      final git = await fs.call({
        'action': 'write',
        'path': '.git/hooks/pre-commit',
        'content': 'evil',
      }, ctx());
      expect(git.isError, isTrue);
    });

    test('rejects symlink escapes', () async {
      final link = Link(p.join(root.path, 'escape'));
      try {
        await link.create(outside.path);
      } on FileSystemException {
        markTestSkipped('symlinks not permitted on this machine');
        return;
      }
      final fs = FileSystemTool(workspaceRoot: root.path);
      final out = await fs.call({
        'action': 'read',
        'path': 'escape/secret.txt',
      }, ctx());
      expect(out.isError, isTrue);
    });

    test('classifies reads as read-only and writes as destructive', () {
      final fs = FileSystemTool(workspaceRoot: root.path);
      expect(fs.annotationsFor({'action': 'read'}).readOnly, isTrue);
      expect(fs.annotationsFor({'action': 'delete'}).needsApproval, isTrue);
    });
  });

  group('GitTool', () {
    test('rejects config/exec injection and unknown subcommands', () async {
      final git = GitTool(workspaceRoot: root.path);
      final injected = await git.call({
        'command': 'status',
        'args': ['-c', 'core.fsmonitor=calc'],
      }, ctx());
      expect(injected.isError, isTrue);
      expect(injected.text, contains('not allowed'));
      final output = await git.call({
        'command': 'diff',
        'args': ['--output=/tmp/x'],
      }, ctx());
      expect(output.isError, isTrue);
      final unknown = await git.call({
        'command': 'config',
        'args': ['x'],
      }, ctx());
      expect(unknown.text, contains('not allowed'));
      expect(git.annotationsFor({'command': 'status'}).readOnly, isTrue);
      expect(git.annotationsFor({'command': 'push'}).needsApproval, isTrue);
    });
  });

  group('GitTool secret excludes', () {
    test('added only where content is printed or the tree is staged', () {
      bool excluded(String command, List<String> args) =>
          GitTool.withSecretExcludes(
            command,
            args,
          ).any((a) => a.startsWith(':(exclude'));
      expect(excluded('diff', []), isTrue);
      expect(excluded('show', ['HEAD']), isTrue);
      expect(excluded('log', ['-p']), isTrue);
      expect(excluded('log', ['--oneline']), isFalse);
      expect(excluded('add', ['-A']), isTrue);
      expect(excluded('add', ['src/a.dart']), isTrue);
      expect(excluded('add', []), isFalse); // would stage everything
      expect(excluded('status', []), isFalse);
    });

    test('commit -a is split into add -u and a plain commit', () {
      expect(GitTool.commitStagesAll(['-a']), isTrue);
      expect(GitTool.commitStagesAll(['-am', 'msg']), isTrue);
      expect(GitTool.commitStagesAll(['--all']), isTrue);
      expect(GitTool.commitStagesAll(['-m', '-a']), isFalse); // a message
      expect(GitTool.commitStagesAll(['-ma']), isFalse); // -m "a"
      expect(GitTool.commitStagesAll(['--amend', '--no-edit']), isFalse);
      expect(GitTool.withoutCommitAll(['-am', 'msg', '-a']), ['-m', 'msg']);
    });

    test('whole-tree show, diff and add skip credential files', () async {
      Future<ProcessResult> git(List<String> args) =>
          Process.run('git', args, workingDirectory: root.path);
      if ((await git(['init', '-q'])).exitCode != 0) {
        markTestSkipped('git is not installed');
        return;
      }
      await git(['config', 'user.email', 't@t']);
      await git(['config', 'user.name', 't']);
      await git(['config', 'core.autocrlf', 'false']);
      await File(p.join(root.path, '.env')).writeAsString('TOKEN=one\n');
      await Directory(p.join(root.path, 'keys')).create();
      await File(p.join(root.path, 'keys', 'Server.PEM')).writeAsString('K\n');
      await git(['add', '-A']);
      await git(['commit', '-qm', 'init']);
      await File(p.join(root.path, '.env')).writeAsString('TOKEN=two\n');
      await File(p.join(root.path, 'a.txt')).writeAsString('changed');
      await File(p.join(root.path, '.env.local')).writeAsString('X=1\n');

      final tool = GitTool(workspaceRoot: root.path);
      final show = await tool.call({
        'command': 'show',
        'args': ['HEAD'],
      }, ctx());
      expect(show.isError, isFalse, reason: show.text);
      expect(show.text, contains('a.txt'));
      expect(show.text, isNot(contains('TOKEN')));
      expect(show.text, isNot(contains('Server.PEM')));
      final diff = await tool.call({'command': 'diff'}, ctx());
      expect(diff.text, contains('changed'));
      expect(diff.text, isNot(contains('TOKEN')));
      await tool.call({
        'command': 'add',
        'args': ['-A'],
      }, ctx());
      final staged = await git(['diff', '--cached', '--name-only']);
      expect('${staged.stdout}'.trim(), 'a.txt');

      await git(['reset', '-q']);
      final commit = await tool.call({
        'command': 'commit',
        'args': ['-a'],
        'message': 'all',
      }, ctx());
      expect(commit.isError, isFalse, reason: commit.text);
      final committed = await git(['show', '--name-only', '--format=']);
      expect('${committed.stdout}'.trim(), 'a.txt');
    });
  });

  group('review regressions (io)', () {
    test('git rejects abbreviated options, absolute paths and URLs', () {
      expect(GitTool.validateArgs('log', ['--outp=x']), isNotNull);
      expect(
        GitTool.validateArgs('fetch', ['--upload-pa=sh', 'origin']),
        isNotNull,
      );
      expect(
        GitTool.validateArgs('diff', ['--no-index', '/etc/passwd', 'x']),
        isNotNull,
      );
      expect(
        GitTool.validateArgs('blame', ['--contents', '/etc/passwd']),
        isNotNull,
      );
      expect(GitTool.validateArgs('fetch', ['ext::sh -c id']), isNotNull);
      expect(GitTool.validateArgs('pull', ['git@evil:repo']), isNotNull);
      expect(GitTool.validateArgs('log', ['-n5', '--oneline']), isNull);
      expect(GitTool.validateArgs('commit', ['-m', 'fix ../thing']), isNull);
      expect(GitTool.validateArgs('push', ['origin', 'feature/x']), isNull);
      expect(GitTool.validateArgs('show', ['HEAD:.env']), isNotNull);
      // Pathspec globs and magic would reach credential files indirectly.
      for (final spec in [
        '*.env',
        '.en?',
        '[.]env',
        ':(top).env',
        ':/',
        ':!x',
      ]) {
        expect(GitTool.validateArgs('log', ['-p', '--', spec]), isNotNull);
      }
      expect(GitTool.validateArgs('show', ['HEAD~2', 'HEAD@{1}']), isNull);
      expect(
        GitTool.validateArgs('diff', ['main..HEAD', 'src/a.dart']),
        isNull,
      );
      expect(
        GitTool.validateArgs('diff', ['--', 'secrets/server.pem']),
        isNotNull,
      );
    });

    test('secret-bearing files cannot be read', () async {
      await Directory(p.join(root.path, '.git')).create();
      await File(p.join(root.path, '.git', 'config')).writeAsString('token');
      await File(p.join(root.path, '.env')).writeAsString('KEY=1');
      await File(p.join(root.path, 'server.pem')).writeAsString('key');
      final fs = FileSystemTool(workspaceRoot: root.path);
      for (final path in ['.git/config', '.env', 'server.pem']) {
        final out = await fs.call({'action': 'read', 'path': path}, ctx());
        expect(out.isError, isTrue, reason: path);
      }
      expect(isSensitivePath('docs/readme.md'), isFalse);
    });

    test('writes into any nested .git are blocked', () async {
      final fs = FileSystemTool(workspaceRoot: root.path);
      final out = await fs.call({
        'action': 'write',
        'path': 'vendor/lib/.git/hooks/pre-commit',
        'content': 'x',
      }, ctx());
      expect(out.isError, isTrue);
    });

    test('batch-file arguments with cmd metacharacters are refused', () async {
      final build = BuildTestTool(workspaceRoot: root.path);
      final out = await build.call({
        'command': 'npm.cmd',
        'args': ['run', 'x" & calc & "'],
      }, ctx());
      expect(out.isError, isTrue);
    });

    test('http requests always ask', () {
      expect(
        HttpTool().annotationsFor({
          'method': 'GET',
          'url': 'https://x',
        }).needsApproval,
        isTrue,
      );
    });
  });

  group('process tools', () {
    test('are destructive and do not use a shell', () {
      final terminal = TerminalTool(workspaceRoot: root.path);
      final build = BuildTestTool(workspaceRoot: root.path);
      expect(terminal.annotations.needsApproval, isTrue);
      expect(build.annotations.needsApproval, isTrue);
      expect(splitCommandLine('git commit -m "a b" && rm -rf /'), [
        'git',
        'commit',
        '-m',
        'a b',
        '&&',
        'rm',
        '-rf',
        '/',
      ]);
    });

    test('build_test refuses programs outside its allow-list', () async {
      final build = BuildTestTool(workspaceRoot: root.path);
      final out = await build.call({
        'command': 'powershell',
        'args': ['-c', 'x'],
      }, ctx());
      expect(out.isError, isTrue);
      expect(out.text, contains('not an allowed program'));
    });
  });

  group('NetGuard / HttpTool', () {
    test('blocks private, loopback, link-local and mapped addresses', () {
      for (final ip in [
        '127.0.0.1',
        '10.1.2.3',
        '172.20.0.1',
        '192.168.1.1',
        '169.254.169.254',
        '100.64.0.1',
        '0.0.0.0',
        '::1',
        'fd00::1',
        'fe80::1',
        '::ffff:10.0.0.1',
      ]) {
        expect(NetGuard.isBlocked(InternetAddress(ip)), isTrue, reason: ip);
      }
      expect(NetGuard.isBlocked(InternetAddress('8.8.8.8')), isFalse);
    });

    test('HttpTool refuses localhost and metadata endpoints', () async {
      final http = HttpTool();
      for (final url in [
        'http://localhost:8080/',
        'http://169.254.169.254/latest/meta-data',
        'http://[::1]/',
        'file:///etc/passwd',
      ]) {
        final out = await http.call({'url': url}, ctx());
        expect(out.isError, isTrue, reason: url);
      }
    });
  });

  test('loadImageBlock validates type and size', () async {
    final png = File(p.join(root.path, 'x.png'));
    await png.writeAsBytes([1, 2, 3]);
    final txt = File(p.join(root.path, 'x.txt'));
    await txt.writeAsString('nope');
    expect((await loadImageBlock(png.path))?.mediaType, 'image/png');
    expect(await loadImageBlock(txt.path), isNull);
    expect(await loadImageBlock(png.path, maxBytes: 2), isNull);
  });

  test('json schema coercion and errors', () {
    final v = validateJsonSchema(
      {
        'n': '3',
        'b': 'true',
        'tags': ['a', 1],
      },
      {
        'type': 'object',
        'properties': {
          'n': {'type': 'integer', 'minimum': 5},
          'b': {'type': 'boolean'},
          'tags': {
            'type': 'array',
            'items': {'type': 'string'},
          },
          'mode': {
            'type': 'string',
            'enum': ['x'],
          },
        },
        'required': ['mode'],
      },
    );
    expect(v.value, {
      'n': 3,
      'b': true,
      'tags': ['a', '1'],
    });
    expect(v.errors, containsAll([r'$.n must be >= 5', r'$.mode is required']));
  });
}
