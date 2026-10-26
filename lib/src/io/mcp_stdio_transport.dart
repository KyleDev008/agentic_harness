import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import '../core/cancellation.dart';
import '../mcp/mcp_transport.dart';
import 'process_runner.dart';

/// The stdio MCP transport: launches the server as a child process and
/// exchanges newline-delimited JSON-RPC over its stdin/stdout.
///
/// The process starts on the first request and lives until [close]. If it
/// exits or misbehaves, the transport fails every pending and later
/// request; create a new client to restart the server. Not available on
/// Android and iOS.
class McpStdioTransport implements McpTransport {
  final String executable;
  final List<String> arguments;
  final String? workingDirectory;

  /// Extra environment variables for the server.
  final Map<String, String>? environment;

  /// Pass this process's whole environment to the server. Off by default:
  /// the server then gets only [inheritedVariables] (what launchers such
  /// as `npx` need) plus [environment], so API keys and tokens in the
  /// host's environment stay private.
  final bool includeParentEnvironment;

  /// Variables copied from this process when [includeParentEnvironment] is
  /// off (case-insensitive on Windows).
  static const inheritedVariables = {
    'PATH',
    'PATHEXT',
    'HOME',
    'USER',
    'USERNAME',
    'LOGNAME',
    'SHELL',
    'LANG',
    'LC_ALL',
    'TERM',
    'TMPDIR',
    'TEMP',
    'TMP',
    'USERPROFILE',
    'APPDATA',
    'LOCALAPPDATA',
    'PROGRAMDATA',
    'PROGRAMFILES',
    'PROGRAMFILES(X86)',
    'SYSTEMROOT',
    'SYSTEMDRIVE',
    'WINDIR',
    'COMSPEC',
    'NUMBER_OF_PROCESSORS',
    'PROCESSOR_ARCHITECTURE',
  };

  /// Start through the system shell. Needed on Windows for `.cmd` shims
  /// such as `npx`; [executable] and [arguments] are then shell-parsed, so
  /// never put untrusted text in them.
  final bool runInShell;

  /// Largest single message accepted from the server.
  final int maxMessageChars;

  McpStdioTransport(
    this.executable, {
    this.arguments = const [],
    this.workingDirectory,
    this.environment,
    this.includeParentEnvironment = false,
    this.runInShell = false,
    this.maxMessageChars = 8 * 1024 * 1024,
  });

  Process? _process;
  Future<Process>? _starting;
  final Map<String, Completer<Map<String, Object?>>> _pending = {};
  final List<String> _partial = [];
  int _partialLength = 0;
  StreamSubscription<String>? _stdout;
  StreamSubscription<String>? _stderr;
  int? _exitCode;
  bool _closed = false;

  /// Why the transport stopped working, once it has.
  String? _failure;
  int _stderrLogged = 0;

  Map<String, String> _environment() {
    if (includeParentEnvironment) return environment ?? const {};
    return {
      for (final entry in Platform.environment.entries)
        if (inheritedVariables.contains(entry.key.toUpperCase()))
          entry.key: entry.value,
      ...?environment,
    };
  }

  Future<Process> _start() =>
      _starting ??= () async {
        if (!processesSupported) {
          throw UnsupportedError('stdio MCP servers need process support.');
        }
        final Process process;
        try {
          process = await Process.start(
            executable,
            arguments,
            workingDirectory: workingDirectory,
            environment: _environment(),
            includeParentEnvironment: includeParentEnvironment,
            runInShell: runInShell,
          );
        } on ProcessException catch (e) {
          _failure = 'Could not start $executable: ${e.message}';
          throw McpTransportError(_failure!);
        }
        _process = process;
        process.stdin.done.catchError((Object _) {
          // A broken pipe surfaces through stdout's onDone instead.
        });
        _stdout = process.stdout
            .transform(utf8.decoder)
            .listen(
              _onChunk,
              // Fail only after the last buffered line was handled, so a reply
              // written just before exiting still arrives.
              onDone:
                  () => _fail(
                    'The MCP server exited'
                    '${_exitCode == null ? '' : ' with code $_exitCode'}.',
                  ),
              onError: (Object _) => _fail('Lost the MCP server output.'),
            );
        _stderr = process.stderr.transform(utf8.decoder).listen((text) {
          // Log at most 64 KB per server; it may be chatty or hostile.
          if (_stderrLogged >= 65536) return;
          _stderrLogged += text.length;
          developer.log(
            text.length > 2000 ? '${text.substring(0, 2000)}…' : text,
            name: 'agentic_harness.mcp.stderr',
          );
        }, onError: (Object _) {});
        unawaited(process.exitCode.then((code) => _exitCode = code));
        return process;
      }();

  void _onChunk(String chunk) {
    var start = 0;
    while (_failure == null) {
      final newline = chunk.indexOf('\n', start);
      if (newline < 0) break;
      final piece = chunk.substring(start, newline);
      final line = _partial.isEmpty ? piece : (_partial..add(piece)).join();
      _partial.clear();
      _partialLength = 0;
      _onLine(line.trim());
      start = newline + 1;
    }
    if (_failure != null || start >= chunk.length) return;
    final rest = chunk.substring(start);
    _partial.add(rest);
    _partialLength += rest.length;
    if (_partialLength > maxMessageChars) {
      _partial.clear();
      _fail('The MCP server sent an oversized message.');
      _process?.kill();
    }
  }

  void _onLine(String line) {
    if (line.isEmpty) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException {
      developer.log(
        'non-JSON line from MCP server',
        name: 'agentic_harness.mcp',
      );
      return;
    }
    if (decoded is! Map) return;
    final message = decoded.cast<String, Object?>();
    final method = message['method'];
    final id = message['id'];
    if (method is String) {
      // A server request: answer pings, refuse everything else.
      if (id == null) return;
      _write({
        'jsonrpc': '2.0',
        'id': id,
        if (method == 'ping')
          'result': <String, Object?>{}
        else
          'error': {
            'code': McpError.methodNotFound,
            'message': 'Not supported',
          },
      });
      return;
    }
    if (id == null && message['error'] != null && _pending.length == 1) {
      // A parse error the server could not tie to a request.
      _pending.remove(_pending.keys.single)?.complete(message);
      return;
    }
    _pending.remove('$id')?.complete(message);
  }

  void _fail(String reason) {
    _failure ??= reason;
    final pending = List.of(_pending.values);
    _pending.clear();
    for (final completer in pending) {
      if (!completer.isCompleted) {
        completer.completeError(McpTransportError(reason));
      }
    }
  }

  void _write(Map<String, Object?> message) {
    try {
      _process?.stdin.writeln(jsonEncode(message));
    } catch (e) {
      _fail('Could not write to the MCP server: $e');
    }
  }

  void _checkUsable() {
    if (_closed) throw const McpTransportError('Transport closed');
    final failure = _failure;
    if (failure != null) throw McpTransportError(failure);
  }

  @override
  Future<Map<String, Object?>> request(
    Map<String, Object?> message, {
    String? protocolVersion,
    CancelToken? cancel,
  }) async {
    _checkUsable();
    cancel?.throwIfCancelled();
    await _start();
    _checkUsable();
    cancel?.throwIfCancelled();
    final id = '${message['id']}';
    final completer = Completer<Map<String, Object?>>();
    _pending[id] = completer;
    final unregister = cancel?.onCancel(() {
      if (_pending.remove(id) == null) return;
      // The spec forbids cancelling initialize.
      if (message['method'] != 'initialize') {
        _write({
          'jsonrpc': '2.0',
          'method': 'notifications/cancelled',
          'params': {'requestId': message['id'], 'reason': cancel.reason},
        });
      }
      completer.completeError(CancelledException(cancel.reason));
    });
    try {
      _write(message);
      return await completer.future;
    } finally {
      unregister?.call();
      _pending.remove(id);
    }
  }

  @override
  Future<void> notify(
    Map<String, Object?> message, {
    String? protocolVersion,
  }) async {
    _checkUsable();
    await _start();
    _checkUsable();
    _write(message);
  }

  /// stdio has no per-connection session beyond the process itself.
  @override
  void resetSession() {}

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _fail('Transport closed');
    final starting = _starting;
    if (starting == null) return;
    final Process process;
    try {
      process = await starting;
    } catch (_) {
      return;
    }
    try {
      await process.stdin.close();
    } catch (_) {
      // The process may already be gone.
    }
    Future<bool> exited(Duration wait) => process.exitCode
        .then((_) => true)
        .timeout(wait, onTimeout: () => false);
    if (!await exited(const Duration(seconds: 2))) {
      process.kill();
      if (!await exited(const Duration(seconds: 2))) {
        process.kill(ProcessSignal.sigkill);
      }
    }
    await _stdout?.cancel();
    await _stderr?.cancel();
  }
}
