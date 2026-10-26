import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agentic_harness/agentic_harness.dart';
import 'package:agentic_harness/io_tools.dart';
import 'package:test/test.dart';

ToolContext ctx([CancelToken? cancel]) => ToolContext(
  cancel: cancel ?? CancelToken(),
  runId: 'r',
  toolUseId: 't',
  progress: (_) {},
  requestUserInput: (prompt, {inputType = 'text', choices, fields}) async => '',
  runState: {},
);

/// Records docker invocations instead of running them.
class FakeDocker {
  final calls = <List<String>>[];
  ProcessOutput Function(List<String> args) reply =
      (_) => const ProcessOutput(0, 'ok', '');
  Duration delay = Duration.zero;

  Future<ProcessOutput> call(
    String executable,
    List<String> arguments, {
    required String workingDirectory,
    Duration timeout = const Duration(minutes: 2),
    CancelToken? cancel,
    int maxOutputBytes = 256 * 1024,
    Map<String, String>? environment,
  }) async {
    calls.add([executable, ...arguments]);
    if (delay > Duration.zero && arguments.first == 'run') {
      await Future.any([
        Future<void>.delayed(delay),
        if (cancel != null) cancel.whenCancelled,
      ]);
      if (timeout < delay) {
        return const ProcessOutput(-1, '', '', timedOut: true);
      }
    }
    return reply(arguments);
  }
}

/// A sandbox held in memory, standing in for a remote sandbox service.
class MemorySandbox implements Sandbox {
  final files = <String, String>{};
  final runs = <String>[];

  @override
  String get description => 'memory';
  @override
  bool get canRunProcesses => true;
  @override
  Future<String> resolve(String path, {bool forWrite = false}) async {
    final parts = path.split('/').where((s) => s.isNotEmpty && s != '.');
    if (parts.contains('..') || path.startsWith('/')) {
      throw const WorkspaceViolation('path escapes the workspace');
    }
    return parts.join('/');
  }

  @override
  Future<String> pathInside(String path) async => '/sandbox/$path';
  @override
  Future<SandboxEntryType> typeOf(String path) async =>
      files.containsKey(path)
          ? SandboxEntryType.file
          : path.isEmpty || files.keys.any((k) => k.startsWith('$path/'))
          ? SandboxEntryType.directory
          : SandboxEntryType.notFound;
  @override
  Future<int> length(String path) async => utf8.encode(files[path]!).length;
  @override
  Future<List<int>> read(String path, {required int maxBytes}) async =>
      utf8.encode(files[path]!).take(maxBytes).toList();
  @override
  Future<List<SandboxEntry>> list(String path, {int limit = 500}) async => [
    for (final k in files.keys)
      if (path.isEmpty ? !k.contains('/') : k.startsWith('$path/'))
        SandboxEntry(k.split('/').last, SandboxEntryType.file),
  ];
  @override
  Future<void> write(String path, List<int> bytes) async =>
      files[path] = utf8.decode(bytes);
  @override
  Future<void> delete(String path) async => files.remove(path);
  @override
  Future<ProcessOutput> run(
    String executable,
    List<String> arguments, {
    String workingDirectory = '',
    Duration timeout = const Duration(minutes: 2),
    CancelToken? cancel,
    int maxOutputBytes = 256 * 1024,
    Map<String, String>? environment,
  }) async {
    runs.add([executable, ...arguments].join(' '));
    return ProcessOutput(0, 'ran in $workingDirectory', '');
  }
}

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('sandbox_test'));
  tearDown(() => root.deleteSync(recursive: true));

  group('LocalSandbox', () {
    test('confines paths and handles files', () async {
      final box = LocalSandbox(root.path);
      expect(await box.resolve(''), '');
      expect(await box.resolve('a/../b.txt'), 'b.txt');
      expect(
        () => box.resolve('../outside'),
        throwsA(isA<WorkspaceViolation>()),
      );
      expect(
        () => box.resolve('.git/config', forWrite: true),
        throwsA(isA<WorkspaceViolation>()),
      );
      await box.write('dir/a.txt', utf8.encode('hello'));
      expect(await box.typeOf('dir'), SandboxEntryType.directory);
      expect(await box.typeOf('dir/a.txt'), SandboxEntryType.file);
      expect(utf8.decode(await box.read('dir/a.txt', maxBytes: 3)), 'hel');
      expect((await box.list('dir')).single.name, 'a.txt');
      // Directories are only deleted when empty.
      await expectLater(box.delete('dir'), throwsA(isA<FileSystemException>()));
      await box.delete('dir/a.txt');
      expect(await box.typeOf('dir/a.txt'), SandboxEntryType.notFound);
      expect(await box.pathInside('x'), endsWith('x'));
    });

    test('tools take a folder or a sandbox, not both or neither', () {
      expect(() => FileSystemTool(), throwsArgumentError);
      expect(
        () => FileSystemTool(
          workspaceRoot: root.path,
          sandbox: LocalSandbox(root.path),
        ),
        throwsArgumentError,
      );
    });
  });

  group('tools on another sandbox', () {
    test('file and terminal tools work through the interface', () async {
      final box = MemorySandbox();
      final fs = FileSystemTool(sandbox: box);
      await fs.call({
        'action': 'write',
        'path': 'notes/todo.md',
        'content': 'buy milk',
      }, ctx());
      expect(box.files['notes/todo.md'], 'buy milk');
      expect(
        (await fs.call({
          'action': 'read',
          'path': 'notes/todo.md',
        }, ctx())).text,
        'buy milk',
      );
      expect(
        (await fs.call({'action': 'read', 'path': '../x'}, ctx())).text,
        contains('Path rejected'),
      );
      expect(
        (await fs.call({'action': 'read', 'path': '.env'}, ctx())).text,
        contains('blocked'),
      );

      final terminal = TerminalTool(sandbox: box);
      final out = await terminal.call({
        'command': 'ls',
        'args': ['-la'],
        'working_directory': 'notes',
      }, ctx());
      expect(out.text, contains('ran in notes'));
      expect(box.runs.single, 'ls -la');

      final git = GitTool(sandbox: box);
      await git.call({'command': 'status'}, ctx());
      expect(
        box.runs.last,
        contains('core.hooksPath=/sandbox/.agent-harness-no-hooks'),
      );
    });
  });

  group('DockerSandbox', () {
    DockerSandbox box(FakeDocker docker, {String? user = '1000:1000'}) =>
        DockerSandbox(
          workspaceRoot: root.path,
          image: 'node:20-alpine',
          user: user,
          runner: docker.call,
        );

    test('locks the container down', () async {
      final docker = FakeDocker();
      Directory('${root.path}/app').createSync();
      final args = await box(docker).runArguments(
        'agentic-harness-test',
        'npm.exe',
        ['test'],
        workingDirectory: 'app',
        environment: {'CI': '1'},
      );
      String after(String flag) => args[args.indexOf(flag) + 1];
      expect(args.take(4), ['run', '--rm', '--init', '--pull=never']);
      expect(after('--label'), 'agentic-harness');
      expect(after('--network'), 'none');
      expect(after('--cap-drop'), 'ALL');
      expect(after('--security-opt'), 'no-new-privileges');
      expect(after('--pids-limit'), '256');
      expect(after('--memory-swap'), '1g');
      expect(args, contains('nofile=1024:1024'));
      expect(args, contains('--read-only'));
      expect(after('--user'), '1000:1000');
      expect(after('--mount'), startsWith('type=bind,source='));
      expect(after('--mount'), endsWith(',target=/workspace'));
      expect(after('--workdir'), '/workspace/app');
      expect(args, containsAll(['HOME=/tmp', 'CI=1']));
      // The program is the entrypoint; .exe is dropped for Linux.
      expect(args.sublist(args.length - 3), [
        '--entrypoint=npm',
        'node:20-alpine',
        'test',
      ]);
      expect(
        () => box(
          docker,
        ).runArguments('n', 'x', [], environment: {'BAD KEY': '1'}),
        throwsArgumentError,
      );
      expect(
        () => box(docker).runArguments('n', '--privileged', []),
        throwsArgumentError,
      );
    });

    test('settings are validated', () {
      DockerSandbox make({
        String image = 'node',
        String network = 'none',
        String? user,
        String memory = '1g',
        double cpus = 1,
      }) => DockerSandbox(
        workspaceRoot: root.path,
        image: image,
        network: network,
        user: user,
        memory: memory,
        cpus: cpus,
      );
      expect(() => make(image: 'node; rm -rf /'), throwsArgumentError);
      expect(() => make(network: 'host --privileged'), throwsArgumentError);
      expect(() => make(network: 'host'), throwsArgumentError);
      expect(() => make(user: 'root'), throwsArgumentError);
      expect(() => make(memory: '1 gig'), throwsArgumentError);
      expect(() => make(cpus: double.nan), throwsArgumentError);
      expect(
        DockerSandbox(
          workspaceRoot: root.path,
          image: 'node',
          network: 'host',
          allowHostNetwork: true,
        ).network,
        'host',
      );
      // Root only on request.
      expect(
        DockerSandbox(
          workspaceRoot: root.path,
          image: 'node',
          runAsRoot: true,
        ).user,
        isNull,
      );
      if (!Platform.isWindows) {
        expect(
          DockerSandbox(workspaceRoot: root.path, image: 'node').user,
          matches(RegExp(r'^\d+:\d+$')),
        );
      }
    });

    test('.git can be mounted read-only', () async {
      Directory('${root.path}/.git').createSync();
      final args = await DockerSandbox(
        workspaceRoot: root.path,
        image: 'node',
        readOnlyGit: true,
        runner: FakeDocker().call,
      ).runArguments('n', 'git', ['status']);
      expect(
        args.where((a) => a.contains('target=/workspace/.git,readonly')),
        hasLength(1),
      );
    });

    test('readOnlyGit refuses a worktree', () async {
      File('${root.path}/.git').writeAsStringSync('gitdir: ../elsewhere');
      await expectLater(
        DockerSandbox(
          workspaceRoot: root.path,
          image: 'node',
          readOnlyGit: true,
          runner: FakeDocker().call,
        ).runArguments('n', 'git', ['status']),
        throwsA(isA<WorkspaceViolation>()),
      );
    });

    test('tools run inside the container; files stay on the host', () async {
      final docker = FakeDocker();
      final sandbox = DockerSandbox(
        workspaceRoot: root.path,
        image: 'alpine/git',
        runner: docker.call,
      );
      final git = GitTool(sandbox: sandbox);
      final out = await git.call({'command': 'status'}, ctx());
      expect(out.isError, isFalse);
      final call = docker.calls.single;
      expect(call.first, 'docker');
      expect(call, containsAll(['--entrypoint=git', 'alpine/git']));
      expect(
        call.join(' '),
        contains('core.hooksPath=/workspace/.agent-harness-no-hooks'),
      );

      final fs = FileSystemTool(sandbox: sandbox);
      await fs.call({
        'action': 'write',
        'path': 'a.txt',
        'content': 'x',
      }, ctx());
      expect(File('${root.path}/a.txt').readAsStringSync(), 'x');
      expect(docker.calls, hasLength(1));
      // Older code reading `workspace` still works.
      // ignore: deprecated_member_use_from_same_package
      expect(fs.workspace.root, root.path);
    });

    test('host paths are kept out of the output', () async {
      final docker = FakeDocker();
      final sandbox = box(docker);
      final source = await sandbox.hostWorkspace.canonicalRoot();
      docker.reply = (_) => ProcessOutput(1, '', 'error in $source/x');
      final out = await sandbox.run('ls', []);
      expect(out.stderr, 'error in /workspace/x');
    });

    test('a timed-out or cancelled command removes its container', () async {
      final docker = FakeDocker()..delay = const Duration(milliseconds: 200);
      final sandbox = box(docker);
      final out = await sandbox.run('sleep', [
        '60',
      ], timeout: const Duration(milliseconds: 20));
      expect(out.timedOut, isTrue);
      final name = docker.calls.first[docker.calls.first.indexOf('--name') + 1];
      // Removed (and checked again) before run returns.
      final removals = docker.calls.where((c) => c[1] == 'rm').toList();
      expect(removals.length, greaterThanOrEqualTo(2));
      expect(removals.first, ['docker', 'rm', '-f', name]);

      docker.calls.clear();
      final cancel = CancelToken();
      final pending = sandbox.run('sleep', ['60'], cancel: cancel);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      cancel.cancel();
      await pending;
      expect(docker.calls.where((c) => c[1] == 'rm'), isNotEmpty);
    });

    test('a missing docker gives a clear error', () async {
      final sandbox = DockerSandbox(
        workspaceRoot: root.path,
        image: 'node',
        runner:
            (
              executable,
              arguments, {
              required workingDirectory,
              timeout = const Duration(minutes: 2),
              cancel,
              maxOutputBytes = 256 * 1024,
              environment,
            }) async =>
                throw const ProcessException('docker', [], 'not found', 2),
      );
      await expectLater(
        sandbox.run('ls', []),
        throwsA(
          isA<ProcessException>().having(
            (e) => e.message,
            'message',
            contains('Docker could not be started'),
          ),
        ),
      );
      expect(await sandbox.available(), isFalse);
    });

    test('orphans are found by label and removed', () async {
      final docker =
          FakeDocker()
            ..reply =
                (args) =>
                    args.first == 'ps'
                        ? const ProcessOutput(
                          0,
                          'abc123def456\n0123456789ab\n',
                          '',
                        )
                        : const ProcessOutput(0, '', '');
      expect(await box(docker).reapOrphans(), 2);
      expect(docker.calls.first, [
        'docker',
        'ps',
        '-aq',
        '--filter',
        'label=agentic-harness',
      ]);
      expect(docker.calls.last, [
        'docker',
        'rm',
        '-f',
        'abc123def456',
        '0123456789ab',
      ]);
    });

    test('availability is checked through docker version', () async {
      final docker =
          FakeDocker()
            ..reply = (_) => const ProcessOutput(1, '', 'Cannot connect');
      expect(await box(docker).available(), isFalse);
      expect(docker.calls.single.sublist(0, 2), ['docker', 'version']);
    });
  });

  test('credential files are found behind Windows name tricks', () {
    expect(isSensitivePath('.env::\$DATA'), isTrue);
    expect(isSensitivePath('config/.env.'), isTrue);
    expect(isSensitivePath('keys/id_rsa '), isTrue);
    expect(isSensitivePath('notes.txt'), isFalse);
  });
}
