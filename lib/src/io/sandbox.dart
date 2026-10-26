import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../core/cancellation.dart';
import 'process_runner.dart';
import 'workspace.dart';

/// What a sandbox path points at.
enum SandboxEntryType { notFound, file, directory, link }

/// One entry of [Sandbox.list].
final class SandboxEntry {
  final String name;
  final SandboxEntryType type;
  const SandboxEntry(this.name, this.type);
}

/// Where the IO tools touch files and run programs.
///
/// Paths are workspace-relative and `/`-separated; [resolve] validates one
/// and returns its canonical form (`''` is the root), which the other
/// methods take. An implementation must keep every operation inside its
/// workspace, refusing escapes with [WorkspaceViolation].
///
/// [LocalSandbox] is a folder on this machine; [DockerSandbox] runs
/// programs in a locked-down container. Implement this for a remote
/// sandbox service.
abstract interface class Sandbox {
  /// For messages, e.g. `local folder` or `Docker (node:20)`.
  String get description;

  /// Whether [run] can start programs here.
  bool get canRunProcesses;

  /// The canonical workspace-relative form of [path]; throws
  /// [WorkspaceViolation] for paths outside the workspace (or inside
  /// `.git`, with [forWrite]).
  Future<String> resolve(String path, {bool forWrite = false});

  /// [path] as programs started by [run] see it (absolute).
  Future<String> pathInside(String path);

  Future<SandboxEntryType> typeOf(String path);
  Future<int> length(String path);

  /// At most [maxBytes] from the start of the file.
  Future<List<int>> read(String path, {required int maxBytes});

  /// A directory's entries sorted by name, at most [limit].
  Future<List<SandboxEntry>> list(String path, {int limit = 500});

  /// Writes a file, creating its parent directories.
  Future<void> write(String path, List<int> bytes);

  /// Deletes a file, link or empty directory.
  Future<void> delete(String path);

  /// Runs [executable] with [arguments] (no shell) in [workingDirectory],
  /// capping output and stopping it on [timeout] or cancellation.
  Future<ProcessOutput> run(
    String executable,
    List<String> arguments, {
    String workingDirectory = '',
    Duration timeout = const Duration(minutes: 2),
    CancelToken? cancel,
    int maxOutputBytes = 256 * 1024,
    Map<String, String>? environment,
  });
}

/// A folder on this machine: symlink-safe paths through [Workspace], and
/// programs run directly with [runProcess].
class LocalSandbox implements Sandbox {
  final Workspace workspace;
  LocalSandbox(String root) : workspace = Workspace(root);

  @override
  String get description => 'local folder';

  @override
  bool get canRunProcesses => processesSupported;

  Future<String> _full(String path) async => p.normalize(
    p.join(await workspace.canonicalRoot(), p.joinAll(path.split('/'))),
  );

  @override
  Future<String> resolve(String path, {bool forWrite = false}) async {
    final full = await workspace.resolve(path, forWrite: forWrite);
    final rel = p.relative(full, from: await workspace.canonicalRoot());
    return rel == '.' ? '' : p.split(rel).join('/');
  }

  @override
  Future<String> pathInside(String path) => _full(path);

  @override
  Future<SandboxEntryType> typeOf(String path) async =>
      switch (await FileSystemEntity.type(
        await _full(path),
        followLinks: false,
      )) {
        FileSystemEntityType.file => SandboxEntryType.file,
        FileSystemEntityType.directory => SandboxEntryType.directory,
        FileSystemEntityType.link => SandboxEntryType.link,
        _ => SandboxEntryType.notFound,
      };

  @override
  Future<int> length(String path) async => File(await _full(path)).length();

  @override
  Future<List<int>> read(String path, {required int maxBytes}) async {
    final raf = await File(await _full(path)).open();
    try {
      return await raf.read(maxBytes);
    } finally {
      await raf.close();
    }
  }

  @override
  Future<List<SandboxEntry>> list(String path, {int limit = 500}) async {
    // Collect a bounded number, sort, then take the first [limit].
    final out = <SandboxEntry>[];
    await for (final e in Directory(
      await _full(path),
    ).list(followLinks: false)) {
      out.add(
        SandboxEntry(
          p.basename(e.path),
          e is Directory
              ? SandboxEntryType.directory
              : e is Link
              ? SandboxEntryType.link
              : SandboxEntryType.file,
        ),
      );
      if (out.length >= max(limit, 10000)) break;
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out.length <= limit ? out : out.sublist(0, limit);
  }

  @override
  Future<void> write(String path, List<int> bytes) async {
    final file = File(await _full(path));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes, flush: true);
  }

  @override
  Future<void> delete(String path) async {
    final full = await _full(path);
    switch (await FileSystemEntity.type(full, followLinks: false)) {
      case FileSystemEntityType.directory:
        await Directory(full).delete(); // non-recursive by design
      case FileSystemEntityType.link:
        await Link(full).delete();
      case FileSystemEntityType.notFound:
        break;
      default:
        await File(full).delete();
    }
  }

  @override
  Future<ProcessOutput> run(
    String executable,
    List<String> arguments, {
    String workingDirectory = '',
    Duration timeout = const Duration(minutes: 2),
    CancelToken? cancel,
    int maxOutputBytes = 256 * 1024,
    Map<String, String>? environment,
  }) async => runProcess(
    executable,
    arguments,
    workingDirectory: await _full(workingDirectory),
    timeout: timeout,
    cancel: cancel,
    maxOutputBytes: maxOutputBytes,
    environment: environment,
  );
}

/// Signature of [runProcess], injectable for tests.
typedef ProcessRunner =
    Future<ProcessOutput> Function(
      String executable,
      List<String> arguments, {
      required String workingDirectory,
      Duration timeout,
      CancelToken? cancel,
      int maxOutputBytes,
      Map<String, String>? environment,
    });

/// Runs each program in a fresh, locked-down Docker container, with the
/// workspace folder mounted at `/workspace`.
///
/// Files are read and written on the host through a [LocalSandbox] on the
/// same folder (so file tools stay fast and confined); programs (`git`,
/// builds, tests, the terminal tool) run inside the container, which has:
/// - the program as its entrypoint (an image's own entrypoint never runs);
/// - no network unless [network] says otherwise (`host` needs
///   [allowHostNetwork]);
/// - all Linux capabilities dropped and no privilege escalation;
/// - a non-root user: [user], else this process's own uid:gid on Linux
///   and macOS (set [runAsRoot] only with rootless Docker or userns-remap);
/// - a read-only root filesystem with a writable `/tmp` (also `HOME`);
/// - memory (no extra swap), CPU, process, open-file and file-size limits;
/// - an init process, labels for [reapOrphans], and removal by name
///   (`docker rm -f`, retried) on timeout or cancellation;
/// - `--pull=never`: pull the image yourself ([pullImage]), ideally pinned
///   by digest (`image@sha256:…`).
///
/// The container can still change everything in the mounted folder,
/// including `.git` hooks and config, build scripts and IDE settings that
/// later run on the host: point it at a throwaway copy or worktree and
/// review the diff, or set [readOnlyGit]. Containers share the host
/// kernel (Docker Desktop adds a VM); for hostile code prefer a VM-backed
/// runtime or a remote sandbox.
class DockerSandbox implements Sandbox {
  final String image;
  final LocalSandbox _files;

  /// `none` (default) or a Docker network such as `bridge` (which can
  /// reach the host's network and cloud metadata endpoints).
  final String network;
  final bool allowHostNetwork;

  /// Memory limit (`512m`, `2g`); swap is not added on top.
  final String memory;
  final double cpus;
  final int pidsLimit;

  /// Largest file a command may write, in bytes.
  final int maxFileBytes;

  /// `uid:gid` to run as; see the class doc for the default.
  final String? user;
  final bool runAsRoot;
  final bool readOnlyRoot;

  /// Mount the workspace's `.git` directory read-only (commits from the
  /// container then fail). Nested repositories and submodules aren't
  /// covered, and a worktree (`.git` file) is refused.
  final bool readOnlyGit;
  final String dockerExecutable;
  final ProcessRunner _runner;

  DockerSandbox({
    required String workspaceRoot,
    required this.image,
    this.network = 'none',
    this.allowHostNetwork = false,
    this.memory = '1g',
    this.cpus = 2,
    this.pidsLimit = 256,
    this.maxFileBytes = 1024 * 1024 * 1024,
    String? user,
    this.runAsRoot = false,
    this.readOnlyRoot = true,
    this.readOnlyGit = false,
    this.dockerExecutable = 'docker',
    ProcessRunner runner = runProcess,
  }) : _files = LocalSandbox(workspaceRoot),
       _runner = runner,
       user = user ?? (runAsRoot ? null : _defaultUser()) {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._/:@-]*$').hasMatch(image)) {
      throw ArgumentError.value(image, 'image', 'Not a Docker image name');
    }
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]*$').hasMatch(network) ||
        (network == 'host' && !allowHostNetwork)) {
      throw ArgumentError.value(
        network,
        'network',
        'Not an allowed network (host needs allowHostNetwork)',
      );
    }
    if (this.user != null && !RegExp(r'^\d+(:\d+)?$').hasMatch(this.user!)) {
      throw ArgumentError.value(this.user, 'user', 'Use uid or uid:gid');
    }
    if (!RegExp(r'^\d+[bkmg]?$', caseSensitive: false).hasMatch(memory)) {
      throw ArgumentError.value(memory, 'memory', 'Use a size such as 1g');
    }
    if (!cpus.isFinite || cpus <= 0) {
      throw ArgumentError.value(cpus, 'cpus', 'Must be positive');
    }
    if (pidsLimit <= 0 || maxFileBytes <= 0) {
      throw ArgumentError('pidsLimit and maxFileBytes must be positive');
    }
  }

  static const mountPoint = '/workspace';

  /// The host folder the container mounts.
  Workspace get hostWorkspace => _files.workspace;

  /// Label on every container this class starts.
  static const label = 'agentic-harness';

  /// This process's uid:gid on Linux and macOS (null on Windows, where
  /// Docker Desktop's VM owns the files).
  static String? _defaultUser() {
    if (Platform.isWindows || !processesSupported) return null;
    try {
      final uid = Process.runSync('id', ['-u']).stdout.toString().trim();
      final gid = Process.runSync('id', ['-g']).stdout.toString().trim();
      if (RegExp(r'^\d+$').hasMatch(uid) && RegExp(r'^\d+$').hasMatch(gid)) {
        return '$uid:$gid';
      }
    } catch (_) {}
    return '65534:65534'; // nobody
  }

  @override
  String get description => 'Docker ($image)';

  @override
  bool get canRunProcesses => processesSupported;

  Future<ProcessOutput?> _docker(
    List<String> args, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      return await _runner(
        dockerExecutable,
        args,
        workingDirectory: Directory.systemTemp.path,
        timeout: timeout,
      );
    } on ProcessException {
      return null;
    } on UnsupportedError {
      return null;
    }
  }

  /// Whether the Docker engine answers.
  Future<bool> available() async {
    final out = await _docker(['version', '--format', '{{.Server.Version}}']);
    return out != null && out.exitCode == 0 && !out.timedOut;
  }

  /// Pulls [image] (containers run with `--pull=never`).
  Future<bool> pullImage({
    Duration timeout = const Duration(minutes: 10),
  }) async {
    final out = await _docker(['pull', image], timeout: timeout);
    return out != null && out.exitCode == 0 && !out.timedOut;
  }

  /// Removes containers this class started that are still around (for
  /// example after the host process died). Returns how many.
  Future<int> reapOrphans() async {
    final listed = await _docker(['ps', '-aq', '--filter', 'label=$label']);
    if (listed == null || listed.exitCode != 0) return 0;
    final ids =
        listed.stdout
            .split(RegExp(r'\s+'))
            .where((id) => RegExp(r'^[0-9a-f]{6,64}$').hasMatch(id))
            .toList();
    if (ids.isEmpty) return 0;
    await _docker(['rm', '-f', ...ids], timeout: const Duration(seconds: 60));
    return ids.length;
  }

  @override
  Future<String> resolve(String path, {bool forWrite = false}) =>
      _files.resolve(path, forWrite: forWrite);

  @override
  Future<String> pathInside(String path) async =>
      path.isEmpty ? mountPoint : '$mountPoint/$path';

  @override
  Future<SandboxEntryType> typeOf(String path) => _files.typeOf(path);
  @override
  Future<int> length(String path) => _files.length(path);
  @override
  Future<List<int>> read(String path, {required int maxBytes}) =>
      _files.read(path, maxBytes: maxBytes);
  @override
  Future<List<SandboxEntry>> list(String path, {int limit = 500}) =>
      _files.list(path, limit: limit);
  @override
  Future<void> write(String path, List<int> bytes) => _files.write(path, bytes);
  @override
  Future<void> delete(String path) => _files.delete(path);

  /// The `docker run` arguments for one command. Public for tests.
  Future<List<String>> runArguments(
    String name,
    String executable,
    List<String> arguments, {
    String workingDirectory = '',
    Map<String, String>? environment,
  }) async {
    // A Windows-style name means the same program inside Linux.
    final program = executable.replaceFirst(
      RegExp(r'\.exe$', caseSensitive: false),
      '',
    );
    if (program.isEmpty ||
        program.startsWith('-') ||
        RegExp(r'[\x00-\x1f]').hasMatch(program)) {
      throw ArgumentError.value(executable, 'executable', 'Not a program name');
    }
    final source = await _files.workspace.canonicalRoot();
    if (RegExp(r'[,"\r\n]').hasMatch(source)) {
      throw const WorkspaceViolation(
        'the workspace path must not contain commas, quotes or line breaks',
      );
    }
    final env = <String, String>{
      // A read-only root has no writable home; git also needs to trust
      // the mounted folder, which another user may own.
      'HOME': '/tmp',
      'GIT_CONFIG_COUNT': '1',
      'GIT_CONFIG_KEY_0': 'safe.directory',
      'GIT_CONFIG_VALUE_0': mountPoint,
      ...?environment,
    };
    for (final key in env.keys) {
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(key)) {
        throw ArgumentError.value(key, 'environment', 'Invalid variable name');
      }
    }
    final gitDir = Directory(p.join(source, '.git'));
    if (readOnlyGit &&
        await FileSystemEntity.type(gitDir.path, followLinks: false) ==
            FileSystemEntityType.file) {
      // A worktree's .git is a file pointing elsewhere: it can't be
      // protected this way, so refuse rather than run unprotected.
      throw const WorkspaceViolation(
        'readOnlyGit needs a .git directory (this is a worktree)',
      );
    }
    return [
      'run',
      '--rm',
      '--init',
      '--pull=never',
      '--name', name,
      '--label', label,
      '--network', network,
      '--cap-drop', 'ALL',
      '--security-opt', 'no-new-privileges',
      '--pids-limit', '$pidsLimit',
      '--memory', memory,
      '--memory-swap', memory,
      '--cpus', '$cpus',
      '--ulimit', 'nofile=1024:1024',
      '--ulimit', 'fsize=$maxFileBytes:$maxFileBytes',
      if (readOnlyRoot) ...['--read-only', '--tmpfs', '/tmp:rw,size=256m'],
      if (user != null) ...['--user', user!],
      '--mount', 'type=bind,source=$source,target=$mountPoint',
      if (readOnlyGit && gitDir.existsSync()) ...[
        '--mount',
        'type=bind,source=${gitDir.path},target=$mountPoint/.git,readonly',
      ],
      '--workdir', await pathInside(workingDirectory),
      for (final e in env.entries) ...['--env', '${e.key}=${e.value}'],
      // The program is the entrypoint: an image's own entrypoint must not
      // receive it as an argument (that would bypass allow-lists).
      '--entrypoint=$program',
      image,
      ...arguments,
    ];
  }

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
    cancel?.throwIfCancelled();
    final name = 'agentic-harness-${_suffix()}';
    final args = await runArguments(
      name,
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    final source = await _files.workspace.canonicalRoot();
    Future<void>? removing;
    // Stopping the docker client doesn't stop the container. `rm -f`
    // covers created and running containers; retry in case the engine
    // hasn't registered it yet.
    Future<void> remove() =>
        removing ??= () async {
          for (var attempt = 0; attempt < 5; attempt++) {
            final out = await _docker(['rm', '-f', name]);
            final gone =
                out != null &&
                (out.exitCode == 0 || out.stderr.contains('No such container'));
            if (gone && attempt > 0) return;
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
        }();
    final unregister = cancel?.onCancel(() => unawaited(remove()));
    try {
      final ProcessOutput out;
      try {
        out = await _runner(
          dockerExecutable,
          args,
          workingDirectory: Directory.systemTemp.path,
          timeout: timeout,
          cancel: cancel,
          maxOutputBytes: maxOutputBytes,
        );
      } on ProcessException catch (e) {
        throw ProcessException(
          dockerExecutable,
          const [],
          'Docker could not be started (${e.message}); is it installed and '
          'running?',
          e.errorCode,
        );
      }
      if (out.timedOut) await remove();
      // Keep host paths out of what the model sees.
      String redact(String s) => s.replaceAll(source, mountPoint);
      return ProcessOutput(
        out.exitCode,
        redact(out.stdout),
        redact(out.stderr),
        timedOut: out.timedOut,
        truncated: out.truncated,
      );
    } finally {
      unregister?.call();
      if (cancel?.isCancelled ?? false) await remove();
    }
  }

  static final _random = Random.secure();
  static String _suffix() =>
      base64Url
          .encode(List.generate(9, (_) => _random.nextInt(256)))
          .replaceAll(RegExp('[^A-Za-z0-9]'), 'x')
          .toLowerCase();
}
