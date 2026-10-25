/// Filesystem, git, process and HTTP tools for agentic_harness.
///
/// Requires `dart:io` (desktop/mobile/server). Process-based tools report
/// themselves unavailable on Android and iOS.
library;

export 'src/io/io_tools.dart';
export 'src/io/net_guard.dart';
export 'src/io/process_runner.dart'
    show ProcessOutput, runProcess, processesSupported, splitCommandLine;
export 'src/io/workspace.dart';
