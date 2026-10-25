import 'dart:async';
import 'dart:convert';
import 'dart:io' hide BytesBuilder;
import 'dart:typed_data';

import '../core/cancellation.dart';

/// Output of [runProcess].
final class ProcessOutput {
  final int exitCode;
  final String stdout;
  final String stderr;
  final bool timedOut;
  final bool truncated;
  const ProcessOutput(
    this.exitCode,
    this.stdout,
    this.stderr, {
    this.timedOut = false,
    this.truncated = false,
  });

  String render() {
    final b = StringBuffer(
      'exit code: ${timedOut ? 'timed out (killed)' : exitCode}',
    );
    if (stdout.isNotEmpty) b.write('\n--- stdout ---\n$stdout');
    if (stderr.isNotEmpty) b.write('\n--- stderr ---\n$stderr');
    if (truncated) b.write('\n[output truncated]');
    return b.toString();
  }
}

/// Whether child processes can be started on this platform.
bool get processesSupported => !(Platform.isAndroid || Platform.isIOS);

/// Runs [executable] with [arguments] directly (no shell — no globbing,
/// pipes, `&&` or variable expansion), capping captured output and
/// killing the process on [timeout] or cancellation.
Future<ProcessOutput> runProcess(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  Duration timeout = const Duration(minutes: 2),
  CancelToken? cancel,
  int maxOutputBytes = 256 * 1024,
  Map<String, String>? environment,
}) async {
  if (!processesSupported) {
    throw UnsupportedError(
      'Running processes is not supported on this platform.',
    );
  }
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    runInShell: false,
    environment: environment,
  );
  final out = BytesBuilder(copy: false);
  final err = BytesBuilder(copy: false);
  var truncated = false;
  void collect(BytesBuilder sink, List<int> chunk) {
    final room = maxOutputBytes - sink.length;
    if (room <= 0) {
      truncated = true;
      return;
    }
    if (chunk.length > room) {
      sink.add(chunk.sublist(0, room));
      truncated = true;
    } else {
      sink.add(chunk);
    }
  }

  final outDone =
      process.stdout.listen((c) => collect(out, c)).asFuture<void>();
  final errDone =
      process.stderr.listen((c) => collect(err, c)).asFuture<void>();
  var timedOut = false;
  void kill() {
    if (Platform.isWindows) {
      // Kill the whole tree (build tools spawn children that would
      // otherwise keep running).
      unawaited(
        Process.run('taskkill', [
          '/PID',
          '${process.pid}',
          '/T',
          '/F',
        ]).then((_) {}, onError: (Object _) {}),
      );
    }
    process.kill(ProcessSignal.sigkill);
  }

  final unregister = cancel?.onCancel(kill);
  final timer = Timer(timeout, () {
    timedOut = true;
    kill();
  });
  int code;
  try {
    code = await process.exitCode;
    await Future.wait([
      outDone,
      errDone,
    ]).timeout(const Duration(seconds: 5), onTimeout: () => const []);
  } finally {
    timer.cancel();
    unregister?.call();
  }
  cancel?.throwIfCancelled();
  return ProcessOutput(
    code,
    utf8.decode(out.takeBytes(), allowMalformed: true),
    utf8.decode(err.takeBytes(), allowMalformed: true),
    timedOut: timedOut,
    truncated: truncated,
  );
}

/// Splits a command line into argv, honouring single/double quotes. No
/// other shell syntax is interpreted.
List<String> splitCommandLine(String line) {
  final args = <String>[];
  final current = StringBuffer();
  String? quote;
  var inToken = false;
  for (var i = 0; i < line.length; i++) {
    final ch = line[i];
    if (quote != null) {
      if (ch == quote) {
        quote = null;
      } else {
        current.write(ch);
      }
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
      inToken = true;
    } else if (ch == ' ' || ch == '\t') {
      if (inToken) {
        args.add(current.toString());
        current.clear();
        inToken = false;
      }
    } else {
      current.write(ch);
      inToken = true;
    }
  }
  if (inToken) args.add(current.toString());
  return args;
}
