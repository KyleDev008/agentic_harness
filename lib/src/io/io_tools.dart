import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import '../core/message.dart';
import '../tools/tool.dart';
import 'net_guard.dart';
import 'process_runner.dart';
import 'sandbox.dart';
import 'workspace.dart';

// ── File system ──────────────────────────────────────────────────────────

/// Read, list, write and delete files inside a workspace directory.
///
/// Paths are workspace-relative and resolved through symlinks; nothing
/// outside the root (or inside `.git` for writes) is reachable. Reads are
/// capped at [maxReadBytes]. Give a [workspaceRoot] folder, or a [sandbox].
class FileSystemTool extends HarnessTool {
  final Sandbox sandbox;
  final int maxReadBytes;
  final bool allowWrites;

  FileSystemTool({
    String? workspaceRoot,
    Sandbox? sandbox,
    this.maxReadBytes = 256 * 1024,
    this.allowWrites = true,
  }) : sandbox = _sandbox(workspaceRoot, sandbox);

  /// The workspace folder (local and Docker sandboxes only).
  @Deprecated('Use sandbox')
  Workspace get workspace => _workspaceOf(sandbox);

  @override
  String get name => 'file_system';

  @override
  String get description =>
      'Work with files in the user\'s workspace folder. Actions: "read" '
      '(file text), "list" (directory entries), "write" (create/overwrite a '
      'file with content), "delete" (a file or empty folder). Paths are '
      'relative to the workspace root.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'action': {
        'type': 'string',
        'enum': ['read', 'list', 'write', 'delete'],
      },
      'path': {'type': 'string', 'description': 'Workspace-relative path.'},
      'content': {'type': 'string', 'description': 'File content for write.'},
    },
    'required': ['action'],
  };

  @override
  ToolAnnotations get annotations => const ToolAnnotations();

  @override
  ToolAnnotations annotationsFor(Map<String, Object?> input) =>
      switch (input['action']) {
        'read' || 'list' => ToolAnnotations.readOnlyLocal,
        _ => const ToolAnnotations(destructive: true),
      };

  @override
  String displayLabel(Map<String, Object?> input) {
    final path = '${input['path'] ?? ''}';
    return switch (input['action']) {
      'read' => 'Reading $path…',
      'list' => 'Listing ${path.isEmpty ? 'workspace' : path}…',
      'write' => 'Writing $path…',
      'delete' => 'Deleting $path…',
      _ => 'Using files…',
    };
  }

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final action = '${input['action']}';
    final rel = '${input['path'] ?? ''}';
    try {
      switch (action) {
        case 'read':
          final path = await sandbox.resolve(rel);
          if (isSensitivePath(path)) {
            return ToolOutput.error(
              'Reading $rel is blocked: it may contain credentials or keys.',
            );
          }
          if (await sandbox.typeOf(path) != SandboxEntryType.file) {
            return ToolOutput.error('File not found: $rel');
          }
          final length = await sandbox.length(path);
          final bytes = await sandbox.read(path, maxBytes: maxReadBytes);
          final text = utf8.decode(bytes, allowMalformed: true);
          return ToolOutput.text(
            length > maxReadBytes
                ? '$text\n\n[file truncated: showing $maxReadBytes of $length bytes]'
                : text,
          );
        case 'list':
          final path = await sandbox.resolve(rel);
          if (await sandbox.typeOf(path) != SandboxEntryType.directory) {
            return ToolOutput.error('Directory not found: $rel');
          }
          final listed = await sandbox.list(path, limit: 501);
          final entries = [
            for (final e in listed.take(500))
              e.type == SandboxEntryType.directory ? '${e.name}/' : e.name,
            if (listed.length > 500) '… (listing truncated)',
          ];
          return ToolOutput.text(
            entries.isEmpty ? '(empty)' : entries.join('\n'),
          );
        case 'write':
          if (!allowWrites) return ToolOutput.error('Writing is disabled.');
          if (rel.trim().isEmpty) return ToolOutput.error('path is required');
          final path = await sandbox.resolve(rel, forWrite: true);
          final content = utf8.encode('${input['content'] ?? ''}');
          await sandbox.write(path, content);
          return ToolOutput.text('Wrote ${content.length} bytes to $rel.');
        case 'delete':
          if (!allowWrites) return ToolOutput.error('Deleting is disabled.');
          if (rel.trim().isEmpty) return ToolOutput.error('path is required');
          final path = await sandbox.resolve(rel, forWrite: true);
          if (path.isEmpty) {
            return ToolOutput.error('Refusing to delete the workspace root.');
          }
          if (await sandbox.typeOf(path) == SandboxEntryType.notFound) {
            return ToolOutput.error('Not found: $rel');
          }
          await sandbox.delete(path);
          return ToolOutput.text('Deleted $rel.');
        default:
          return ToolOutput.error('Unknown action "$action".');
      }
    } on WorkspaceViolation catch (e) {
      return ToolOutput.error('Path rejected: ${e.message}.');
    } on FileSystemException catch (e) {
      // Never echo absolute paths back to the model.
      return ToolOutput.error(
        'File operation failed: ${e.osError?.message ?? e.message}',
      );
    }
  }
}

/// Whether a workspace-relative [path] looks like a credential or key file
/// (or git internals, which can hold tokens in remote URLs). Such files are
/// never read into a model context.
bool isSensitivePath(String path) {
  // `.env::$DATA`, `.env.` and `.env ` all name `.env` on Windows.
  final segments =
      p
          .split(path.replaceAll('\\', '/'))
          .map(
            (s) => s
                .toLowerCase()
                .split(':')
                .first
                .replaceFirst(RegExp(r'[. ]+$'), ''),
          )
          .toList();
  const dirs = {'.git', '.ssh', '.gnupg', '.aws', '.azure', '.kube', '.docker'};
  if (segments.any(dirs.contains)) return true;
  final name = segments.isEmpty ? '' : segments.last;
  const names = {
    '.npmrc',
    '.netrc',
    '.pypirc',
    '.git-credentials',
    '.pgpass',
    'credentials',
    'credentials.json',
    'secrets.json',
    'service-account.json',
    'daemon.json',
  };
  if (names.contains(name)) return true;
  if (name == '.env' || name.startsWith('.env.')) return true;
  if (name.startsWith('id_rsa') ||
      name.startsWith('id_ed25519') ||
      name.startsWith('id_ecdsa') ||
      name.startsWith('id_dsa')) {
    return true;
  }
  for (final ext in const [
    '.pem',
    '.key',
    '.p12',
    '.pfx',
    '.jks',
    '.keystore',
    '.kdbx',
  ]) {
    if (name.endsWith(ext)) return true;
  }
  return false;
}

// ── Git ──────────────────────────────────────────────────────────────────

/// Runs a safe subset of git inside the workspace.
///
/// Only allow-listed subcommands run; options that execute programs or
/// change configuration/paths (`-c`, `--exec`, `--upload-pack`, `-C`,
/// `--git-dir`, `--output`, …) are rejected; hooks and fsmonitor are
/// disabled for every invocation.
class GitTool extends HarnessTool {
  final Sandbox sandbox;
  final Duration commandTimeout;

  GitTool({
    String? workspaceRoot,
    Sandbox? sandbox,
    this.commandTimeout = const Duration(minutes: 2),
  }) : sandbox = _sandbox(workspaceRoot, sandbox);

  /// The workspace folder (local and Docker sandboxes only).
  @Deprecated('Use sandbox')
  Workspace get workspace => _workspaceOf(sandbox);

  static const readOnlyCommands = {
    'status',
    'diff',
    'log',
    'show',
    'blame',
    'ls-files',
    'rev-parse',
    'shortlog',
  };
  static const writeCommands = {
    'add',
    'commit',
    'checkout',
    'switch',
    'restore',
    'stash',
    'branch',
    'tag',
    'fetch',
    'pull',
    'push',
    'merge',
    'reset',
    'rm',
    'mv',
  };

  /// Options allowed per subcommand. Anything else starting with `-` is
  /// rejected: git accepts unambiguous abbreviations of long options
  /// (`--upload-pa=…`, `--outp=…`), so a deny-list cannot be complete.
  /// Options that read or write arbitrary files (`--no-index`, `--output`,
  /// `--contents`, `-F`, `--exclude-from`, …) are deliberately absent.
  static const Map<String, Set<String>> allowedOptions = {
    'status': {
      '-s',
      '--short',
      '--porcelain',
      '-b',
      '--branch',
      '-u',
      '--untracked-files',
    },
    'diff': {
      '--stat',
      '--numstat',
      '--shortstat',
      '--name-only',
      '--name-status',
      '--cached',
      '--staged',
      '--word-diff',
      '--no-color',
      '-U',
      '--unified',
      '-w',
      '--ignore-all-space',
      '--check',
    },
    'log': {
      '--oneline',
      '-n',
      '--max-count',
      '--stat',
      '--graph',
      '--decorate',
      '--all',
      '--since',
      '--until',
      '--after',
      '--before',
      '--author',
      '--grep',
      '-p',
      '--patch',
      '--format',
      '--pretty',
      '--no-merges',
      '--reverse',
      '--name-only',
      '--name-status',
      '--first-parent',
      '--abbrev-commit',
    },
    'show': {
      '--stat',
      '--name-only',
      '--name-status',
      '--oneline',
      '-p',
      '--patch',
      '--format',
      '--pretty',
      '--no-patch',
      '-s',
    },
    'blame': {'-L', '-w', '-e', '--porcelain', '-s'},
    'ls-files': {
      '-m',
      '--modified',
      '-o',
      '--others',
      '-c',
      '--cached',
      '-d',
      '--deleted',
      '--exclude-standard',
    },
    'rev-parse': {
      '--abbrev-ref',
      '--short',
      '--verify',
      '--show-toplevel',
      '--is-inside-work-tree',
    },
    'shortlog': {'-s', '--summary', '-n', '--numbered', '-e', '--email'},
    'add': {'-A', '--all', '-u', '--update', '-N', '--intent-to-add'},
    'commit': {
      '-a',
      '--all',
      '--amend',
      '--no-edit',
      '--allow-empty',
      '-m',
      '--message',
    },
    'checkout': {'-b', '-B'},
    'switch': {'-c', '--create', '-C', '--detach'},
    'restore': {'--staged', '--worktree', '-S', '-W', '--source'},
    'stash': {'-m', '--message', '-u', '--include-untracked', '--keep-index'},
    'branch': {
      '-a',
      '--all',
      '-r',
      '--remotes',
      '-d',
      '--delete',
      '-D',
      '-m',
      '--move',
      '-v',
      '--verbose',
      '--list',
      '--show-current',
    },
    'tag': {
      '-a',
      '--annotate',
      '-m',
      '--message',
      '-d',
      '--delete',
      '-l',
      '--list',
    },
    'fetch': {'--all', '--prune', '-p', '--tags'},
    'pull': {'--rebase', '--no-rebase', '--ff-only'},
    'push': {
      '-u',
      '--set-upstream',
      '--tags',
      '--force-with-lease',
      '--delete',
    },
    'merge': {
      '--no-ff',
      '--ff-only',
      '--abort',
      '--continue',
      '--squash',
      '-m',
    },
    'reset': {'--soft', '--mixed', '--hard'},
    'rm': {'--cached', '-r'},
    'mv': {},
  };

  /// Options whose following argument is a free-text value (message,
  /// author pattern, format, count…), not a path or ref.
  static const _valueOptions = {
    '-m',
    '--message',
    '--author',
    '--grep',
    '--since',
    '--until',
    '--after',
    '--before',
    '--format',
    '--pretty',
    '-n',
    '--max-count',
    '-L',
    '-U',
    '--unified',
    '--source',
    '-b',
    '-B',
    '-c',
    '--create',
    '-C',
  };

  static final _shortWithValue = RegExp(r'^(-[a-zA-Z])(.+)$');
  static final _remoteArg = RegExp(r'^[A-Za-z0-9._/+-]+(:[A-Za-z0-9._/+-]+)?$');

  /// Returns why [args] are rejected for [command], or `null` if allowed.
  static String? validateArgs(String command, List<String> args) {
    final allowed = allowedOptions[command] ?? const <String>{};
    var expectValue = false;
    for (final arg in args) {
      if (arg.contains('\x00') || arg.contains('\n')) {
        return 'arguments must not contain control characters';
      }
      if (expectValue) {
        expectValue = false;
        continue;
      }
      if (arg == '--') continue;
      if (arg.startsWith('-')) {
        final name = arg.split('=').first;
        var ok = allowed.contains(name);
        if (!ok) {
          final short = _shortWithValue.firstMatch(arg);
          ok = short != null && allowed.contains(short.group(1));
        }
        if (!ok) return 'option "$name" is not allowed for git $command';
        if (!arg.contains('=') && _valueOptions.contains(arg)) {
          expectValue = true;
        }
        continue;
      }
      if (p.isAbsolute(arg) ||
          RegExp(r'^[a-zA-Z]:').hasMatch(arg) ||
          arg.startsWith('~') ||
          p.split(arg).contains('..') ||
          arg.contains('://') ||
          arg.contains('::')) {
        return 'argument "$arg" points outside the repository';
      }
      // Also the path half of `rev:path` (e.g. `HEAD:.env`).
      final colon = arg.indexOf(':');
      if (isSensitivePath(arg) ||
          (colon >= 0 && isSensitivePath(arg.substring(colon + 1)))) {
        return 'argument "$arg" names a credential or key file';
      }
      if ({'fetch', 'pull', 'push'}.contains(command) &&
          !_remoteArg.hasMatch(arg)) {
        return 'only remote and branch names are allowed for git $command';
      }
    }
    return null;
  }

  @override
  String get name => 'git';

  @override
  String get description =>
      'Run git in the workspace repository. "command" is the subcommand '
      '(${[...readOnlyCommands, ...writeCommands].join(', ')}); "args" are '
      'extra arguments; "message" sets the commit message for commit.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'command': {'type': 'string'},
      'args': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'message': {'type': 'string'},
    },
    'required': ['command'],
  };

  @override
  ToolAnnotations get annotations => const ToolAnnotations();

  @override
  ToolAnnotations annotationsFor(Map<String, Object?> input) =>
      readOnlyCommands.contains(input['command'])
          ? ToolAnnotations.readOnlyLocal
          : const ToolAnnotations(destructive: true);

  @override
  String displayLabel(Map<String, Object?> input) =>
      'Running git ${input['command']}…';

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    if (!sandbox.canRunProcesses) {
      return ToolOutput.error('git is not available on this device.');
    }
    final command = '${input['command']}'.trim();
    if (!readOnlyCommands.contains(command) &&
        !writeCommands.contains(command)) {
      return ToolOutput.error('git subcommand "$command" is not allowed.');
    }
    final rawArgs = input['args'];
    final args =
        rawArgs is List ? rawArgs.map((a) => '$a').toList() : <String>[];
    final rejected = validateArgs(command, args);
    if (rejected != null) return ToolOutput.error('Not allowed: $rejected.');
    final message = input['message'];
    if (command == 'commit' && message is String && message.isNotEmpty) {
      args.addAll(['-m', message]);
    }
    final noHooks = await sandbox.pathInside('.agent-harness-no-hooks');
    try {
      final out = await sandbox.run(
        'git',
        [
          '-c', 'core.hooksPath=$noHooks',
          '-c', 'core.fsmonitor=false',
          // No transports that run programs or read arbitrary local paths.
          '-c', 'protocol.ext.allow=never',
          '-c', 'protocol.file.allow=never',
          '--no-pager',
          command,
          ...args,
        ],
        timeout: commandTimeout,
        cancel: context.cancel,
        environment: const {'GIT_TERMINAL_PROMPT': '0'},
      );
      final text = out.render();
      return out.exitCode == 0 && !out.timedOut
          ? ToolOutput.text(text)
          : ToolOutput.error(text);
    } on ProcessException catch (e) {
      return ToolOutput.error('git could not be started: ${e.message}');
    }
  }
}

// ── Processes ────────────────────────────────────────────────────────────

/// Runs a program in the workspace without a shell.
///
/// [allowedExecutables] restricts which programs may run (null = any).
/// Always classified destructive, so the standard policy asks the user.
class TerminalTool extends HarnessTool {
  final Sandbox sandbox;
  final Set<String>? allowedExecutables;
  final Duration commandTimeout;

  TerminalTool({
    String? workspaceRoot,
    Sandbox? sandbox,
    this.allowedExecutables,
    this.commandTimeout = const Duration(minutes: 2),
  }) : sandbox = _sandbox(workspaceRoot, sandbox);

  /// The workspace folder (local and Docker sandboxes only).
  @Deprecated('Use sandbox')
  Workspace get workspace => _workspaceOf(sandbox);

  @override
  String get name => 'terminal';

  @override
  String get description =>
      'Run a program in the workspace and return its output. The program is '
      'started directly, not through a shell: pipes, redirects, globbing, '
      '"&&" and shell built-ins (cd, dir, echo) do not work. Give the '
      'executable in "command" and its arguments in "args".';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'command': {'type': 'string', 'description': 'Executable name.'},
      'args': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'working_directory': {
        'type': 'string',
        'description': 'Workspace-relative directory (default: root).',
      },
    },
    'required': ['command'],
  };

  @override
  ToolAnnotations get annotations => const ToolAnnotations(destructive: true);

  @override
  String displayLabel(Map<String, Object?> input) =>
      'Running ${input['command']}…';

  @override
  Future<ToolOutput> call(Map<String, Object?> input, ToolContext context) =>
      _runCommand(
        this,
        sandbox,
        input,
        context,
        allowedExecutables,
        commandTimeout,
      );
}

/// Runs build and test tooling (flutter, dart, npm, cargo, …) in the
/// workspace without a shell. Classified destructive: build scripts can
/// run arbitrary code, so the standard policy asks the user.
class BuildTestTool extends HarnessTool {
  final Sandbox sandbox;
  final Set<String> allowedExecutables;
  final Duration commandTimeout;

  static const defaultExecutables = {
    'flutter',
    'dart',
    'npm',
    'npx',
    'yarn',
    'pnpm',
    'node',
    'cargo',
    'go',
    'python',
    'python3',
    'pytest',
    'gradle',
    'gradlew',
    'mvn',
    'make',
    'dotnet',
    'swift',
    'xcodebuild',
  };

  BuildTestTool({
    String? workspaceRoot,
    Sandbox? sandbox,
    this.allowedExecutables = defaultExecutables,
    this.commandTimeout = const Duration(minutes: 10),
  }) : sandbox = _sandbox(workspaceRoot, sandbox);

  /// The workspace folder (local and Docker sandboxes only).
  @Deprecated('Use sandbox')
  Workspace get workspace => _workspaceOf(sandbox);

  @override
  String get name => 'build_test';

  @override
  String get description =>
      'Run build or test tooling in the workspace (${allowedExecutables.join(', ')}). '
      'Give the executable in "command" and its arguments in "args"; no shell '
      'syntax is interpreted.';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'command': {'type': 'string'},
      'args': {
        'type': 'array',
        'items': {'type': 'string'},
      },
      'working_directory': {'type': 'string'},
    },
    'required': ['command'],
  };

  @override
  ToolAnnotations get annotations => const ToolAnnotations(destructive: true);

  @override
  String displayLabel(Map<String, Object?> input) =>
      'Running ${input['command']}…';

  @override
  Duration? get timeout => commandTimeout + const Duration(seconds: 10);

  @override
  Future<ToolOutput> call(Map<String, Object?> input, ToolContext context) =>
      _runCommand(
        this,
        sandbox,
        input,
        context,
        allowedExecutables,
        commandTimeout,
      );
}

/// The host folder behind [sandbox], for the deprecated `workspace`
/// getters.
Workspace _workspaceOf(Sandbox sandbox) => switch (sandbox) {
  LocalSandbox(:final workspace) => workspace,
  DockerSandbox(:final hostWorkspace) => hostWorkspace,
  _ => throw StateError('${sandbox.description} has no local workspace'),
};

/// The sandbox for a tool given either a folder or a sandbox.
Sandbox _sandbox(String? workspaceRoot, Sandbox? sandbox) {
  if ((workspaceRoot == null) == (sandbox == null)) {
    throw ArgumentError('Give either workspaceRoot or sandbox');
  }
  return sandbox ?? LocalSandbox(workspaceRoot!);
}

Future<ToolOutput> _runCommand(
  HarnessTool tool,
  Sandbox sandbox,
  Map<String, Object?> input,
  ToolContext context,
  Set<String>? allowed,
  Duration timeout,
) async {
  if (!sandbox.canRunProcesses) {
    return ToolOutput.error('${tool.name} is not available on this device.');
  }
  var command = '${input['command']}'.trim();
  final rawArgs = input['args'];
  var args = rawArgs is List ? rawArgs.map((a) => '$a').toList() : <String>[];
  if (args.isEmpty && command.contains(' ')) {
    final parts = splitCommandLine(command);
    if (parts.isEmpty) return ToolOutput.error('command is empty');
    command = parts.first;
    args = parts.sublist(1);
  }
  if (command.isEmpty) return ToolOutput.error('command is empty');
  if (command.contains('/') || command.contains(r'\')) {
    return ToolOutput.error('Give a program name, not a path.');
  }
  final lower = command.toLowerCase();
  if (lower.endsWith('.bat') || lower.endsWith('.cmd')) {
    // Batch files run through cmd.exe, which re-parses arguments: quotes,
    // %VAR%, & | < > ^ would allow command injection.
    final unsafe = RegExp(r'["%&|<>^!\r\n]');
    if (args.any(unsafe.hasMatch)) {
      return ToolOutput.error(
        'Arguments to $command must not contain quotes or the characters % & | < > ^ !.',
      );
    }
  }
  final base = lower.replaceAll(RegExp(r'\.(exe|bat|cmd)$'), '');
  if (allowed != null && !allowed.contains(base)) {
    return ToolOutput.error(
      '"$command" is not an allowed program (${allowed.join(', ')}).',
    );
  }
  try {
    final dir = await sandbox.resolve('${input['working_directory'] ?? ''}');
    final out = await sandbox.run(
      command,
      args,
      workingDirectory: dir,
      timeout: timeout,
      cancel: context.cancel,
    );
    final text = out.render();
    return out.exitCode == 0 && !out.timedOut
        ? ToolOutput.text(text)
        : ToolOutput.error(text);
  } on WorkspaceViolation catch (e) {
    return ToolOutput.error('working_directory rejected: ${e.message}.');
  } on ProcessException catch (e) {
    return ToolOutput.error('Could not start "$command": ${e.message}');
  }
}

// ── HTTP ─────────────────────────────────────────────────────────────────

/// Makes HTTP requests to public hosts.
///
/// Private/loopback/link-local destinations are refused (SSRF guard),
/// every redirect hop is re-validated and credentials are dropped on
/// cross-origin redirects, and bodies are capped at [maxBodyBytes].
/// [allowedHosts] (when set) restricts destinations further.
class HttpTool extends HarnessTool {
  final NetGuard guard;
  final Set<String>? allowedHosts;
  final int maxBodyBytes;
  final http.Client Function() clientFactory;

  HttpTool({
    this.guard = const NetGuard(),
    this.allowedHosts,
    this.maxBodyBytes = 512 * 1024,
    http.Client Function()? clientFactory,
  }) : clientFactory = clientFactory ?? http.Client.new;

  static const _methods = {'GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE'};

  @override
  String get name => 'http';

  @override
  String get description =>
      'Make an HTTP request to a public URL and return the status, headers '
      'and body (text, truncated if large).';

  @override
  Map<String, Object?> get inputSchema => const {
    'type': 'object',
    'properties': {
      'method': {
        'type': 'string',
        'enum': ['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE'],
      },
      'url': {'type': 'string'},
      'headers': {'type': 'object'},
      'body': {'type': 'string'},
    },
    'required': ['url'],
  };

  @override
  ToolAnnotations get annotations =>
      const ToolAnnotations(destructive: true, openWorld: true);

  /// Every request asks: a GET can carry data out in its URL, and the model
  /// controls headers. (Open-world reads are an exfiltration channel.)
  @override
  ToolAnnotations annotationsFor(Map<String, Object?> input) =>
      const ToolAnnotations(destructive: true, openWorld: true);

  @override
  String displayLabel(Map<String, Object?> input) {
    final host = Uri.tryParse('${input['url']}')?.host ?? 'the web';
    return 'Fetching $host…';
  }

  @override
  Future<ToolOutput> call(
    Map<String, Object?> input,
    ToolContext context,
  ) async {
    final method = '${input['method'] ?? 'GET'}'.toUpperCase();
    if (!_methods.contains(method)) {
      return ToolOutput.error('Unsupported method $method');
    }
    var uri = Uri.tryParse('${input['url']}'.trim());
    if (uri == null || !uri.hasScheme) return ToolOutput.error('Invalid URL');
    final rawHeaders = input['headers'];
    final headers = <String, String>{
      if (rawHeaders is Map)
        for (final e in rawHeaders.entries) '${e.key}': '${e.value}',
    };
    final body = input['body'];
    final client = clientFactory();
    final unregister = context.cancel.onCancel(client.close);
    try {
      for (var hop = 0; hop <= 5; hop++) {
        final hosts = allowedHosts;
        if (hosts != null && !hosts.contains(uri!.host.toLowerCase())) {
          return ToolOutput.error('Host ${uri.host} is not allowed.');
        }
        await guard.check(uri!);
        final request =
            http.Request(hop == 0 ? method : 'GET', uri)
              ..followRedirects = false
              ..headers.addAll(headers);
        if (hop == 0 && body is String && method != 'GET' && method != 'HEAD') {
          request.body = body;
        }
        final response = await client
            .send(request)
            .timeout(const Duration(seconds: 30));
        if (response.isRedirect ||
            (response.statusCode >= 300 &&
                response.statusCode < 400 &&
                response.headers['location'] != null)) {
          await response.stream.drain<void>();
          final next = uri.resolve(response.headers['location']!);
          if (next.origin != uri.origin) {
            headers.removeWhere(
              (k, _) => const {
                'authorization',
                'cookie',
                'proxy-authorization',
              }.contains(k.toLowerCase()),
            );
          }
          uri = next;
          continue;
        }
        final bytes = <int>[];
        var truncated = false;
        await for (final chunk in response.stream.timeout(
          const Duration(seconds: 30),
        )) {
          final room = maxBodyBytes - bytes.length;
          if (chunk.length >= room) {
            bytes.addAll(chunk.sublist(0, room));
            truncated = true;
            break;
          }
          bytes.addAll(chunk);
        }
        final text = utf8.decode(bytes, allowMalformed: true);
        final summary = StringBuffer('HTTP ${response.statusCode}\n');
        for (final h in const ['content-type', 'content-length', 'location']) {
          final v = response.headers[h];
          if (v != null) summary.writeln('$h: $v');
        }
        summary
          ..writeln()
          ..write(text);
        if (truncated) {
          summary.write('\n[body truncated at $maxBodyBytes bytes]');
        }
        return response.statusCode >= 400
            ? ToolOutput.error(summary.toString())
            : ToolOutput.text(summary.toString());
      }
      return ToolOutput.error('Too many redirects.');
    } on NetGuardViolation catch (e) {
      return ToolOutput.error('Request blocked: ${e.message}.');
    } on TimeoutException {
      return ToolOutput.error('The request timed out.');
    } on http.ClientException catch (e) {
      return ToolOutput.error('Request failed: ${e.message}');
    } on SocketException catch (e) {
      return ToolOutput.error('Request failed: ${e.message}');
    } finally {
      unregister();
      client.close();
    }
  }
}

// ── Images ───────────────────────────────────────────────────────────────

/// Loads an image file as an [ImageBlock], or `null` when the path is
/// unsafe (traversal, NUL, UNC), not a supported image type (png, jpeg,
/// webp, gif — checked on both the given and the symlink-resolved path),
/// empty, unreadable, or larger than [maxBytes].
///
/// The core never reads files; hosts that must restrict *which* files may
/// be read (e.g. app-managed attachment folders) check that first.
Future<ImageBlock?> loadImageBlock(
  String path, {
  int maxBytes = 15 * 1024 * 1024,
}) async {
  if (_unsafePath(path) || _mimeFor(path) == null) return null;
  try {
    final file = File(path);
    if (!await file.exists()) return null;
    final resolved = await file.resolveSymbolicLinks();
    final mime = _mimeFor(resolved);
    if (_unsafePath(resolved) || mime == null) return null;
    final target = File(resolved);
    final length = await target.length();
    if (length == 0 || length > maxBytes) return null;
    return ImageBlock(bytes: await target.readAsBytes(), mediaType: mime);
  } catch (_) {
    return null;
  }
}

String? _mimeFor(String path) => switch (p.extension(path).toLowerCase()) {
  '.png' => 'image/png',
  '.jpg' || '.jpeg' => 'image/jpeg',
  '.webp' => 'image/webp',
  '.gif' => 'image/gif',
  _ => null,
};

bool _unsafePath(String path) =>
    path.isEmpty ||
    path.contains('\x00') ||
    path.startsWith(r'\\') ||
    path.startsWith('//') ||
    p.split(path).contains('..');
