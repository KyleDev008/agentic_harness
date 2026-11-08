// Runs DockerSandbox against a real Docker engine. Skipped by default (see
// dart_test.yaml); run with:
//
//   dart test -t live --run-skipped test/live/docker_sandbox_live_test.dart
//
// Needs a running engine and network access to pull `node:22-alpine` and
// `alpine/git` once.
@Tags(['live'])
library;

import 'dart:io';

import 'package:agentic_harness/agentic_harness.dart';
import 'package:agentic_harness/io_tools.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;

  setUpAll(() async {
    final probe = DockerSandbox(workspaceRoot: '.', image: 'node:22-alpine');
    if (!await probe.available()) {
      fail('No Docker engine is running.');
    }
    for (final image in ['node:22-alpine', 'alpine/git']) {
      final pulled =
          await DockerSandbox(workspaceRoot: '.', image: image).pullImage();
      if (!pulled) fail('Could not pull $image.');
    }
  });

  setUp(() async {
    root = await Directory.systemTemp.createTemp('harness_live_');
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  ToolContext ctx() => ToolContext(
    cancel: CancelToken(),
    runId: 'live',
    toolUseId: 't',
    progress: (_) {},
    requestUserInput:
        (prompt, {inputType = 'text', choices, fields}) async => '',
    runState: {},
  );

  test('runs a program in the mounted workspace', () async {
    await File(p.join(root.path, 'input.txt')).writeAsString('hello');
    final box = DockerSandbox(
      workspaceRoot: root.path,
      image: 'node:22-alpine',
    );
    final out = await box.run('node', [
      '-e',
      "const fs=require('fs');"
          "fs.writeFileSync('output.txt', fs.readFileSync('input.txt','utf8').toUpperCase());"
          'console.log(process.cwd())',
    ]);
    expect(out.exitCode, 0, reason: out.stderr);
    expect(out.stdout.trim(), '/workspace');
    expect(await File(p.join(root.path, 'output.txt')).readAsString(), 'HELLO');
  });

  test('is locked down: no network, read-only root, non-root', () async {
    final box = DockerSandbox(
      workspaceRoot: root.path,
      image: 'node:22-alpine',
    );
    final net = await box.run('node', [
      '-e',
      "fetch('https://example.com').then(()=>process.exit(0),()=>process.exit(3))",
    ], timeout: const Duration(seconds: 30));
    expect(net.exitCode, 3, reason: 'network should be unreachable');

    final rootFs = await box.run('node', [
      '-e',
      "try{require('fs').writeFileSync('/etc/x','1');process.exit(0)}catch(e){process.exit(4)}",
    ]);
    expect(rootFs.exitCode, 4, reason: 'root filesystem should be read-only');

    final tmp = await box.run('node', [
      '-e',
      "require('fs').writeFileSync('/tmp/x','1')",
    ]);
    expect(tmp.exitCode, 0, reason: tmp.stderr);

    final uid = await box.run('node', ['-e', 'console.log(process.getuid())']);
    expect(uid.stdout.trim(), isNot('0'));
  });

  test('npm runs inside the container', () async {
    await File(p.join(root.path, 'package.json')).writeAsString(
      '{"name":"x","version":"1.0.0","scripts":{"hi":"echo hi"}}',
    );
    final box = DockerSandbox(
      workspaceRoot: root.path,
      image: 'node:22-alpine',
    );
    final out = await box.run('npm', ['run', 'hi', '--silent']);
    expect(out.exitCode, 0, reason: out.stderr);
    expect(out.stdout, contains('hi'));
  });

  test('a timed-out container is killed and removed', () async {
    final box = DockerSandbox(
      workspaceRoot: root.path,
      image: 'node:22-alpine',
    );
    final out = await box.run('node', [
      '-e',
      'setTimeout(()=>{}, 60000)',
    ], timeout: const Duration(seconds: 3));
    expect(out.timedOut, isTrue);
    // Removal is by name; nothing labelled by the harness should be left.
    expect(await box.reapOrphans(), 0);
  });

  test('GitTool works through the sandbox, with .git read-only', () async {
    Future<void> git(List<String> args) async {
      final r = await Process.run('git', args, workingDirectory: root.path);
      expect(r.exitCode, 0, reason: '${r.stderr}');
    }

    await git(['init', '-q']);
    await git(['config', 'user.email', 'live@test']);
    await git(['config', 'user.name', 'live']);
    await File(p.join(root.path, 'a.txt')).writeAsString('a');
    await git(['add', 'a.txt']);
    await git(['commit', '-qm', 'first']);
    await File(p.join(root.path, 'a.txt')).writeAsString('b');

    final tool = GitTool(
      sandbox: DockerSandbox(
        workspaceRoot: root.path,
        image: 'alpine/git',
        readOnlyGit: true,
      ),
    );
    final status = await tool.call({
      'command': 'status',
      'args': ['--short'],
    }, ctx());
    expect(status.isError, isFalse, reason: status.text);
    expect(status.text, contains('a.txt'));

    final commit = await tool.call({
      'command': 'commit',
      'args': ['-a'],
      'message': 'should fail',
    }, ctx());
    expect(commit.isError, isTrue, reason: '.git is mounted read-only');
  });
}
