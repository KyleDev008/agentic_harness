/// Filesystem, git, process and HTTP tools for agentic_harness, plus the
/// stdio MCP transport.
///
/// Requires `dart:io` (desktop/mobile/server). Process-based tools report
/// themselves unavailable on Android and iOS.
library;

export 'src/io/directory_skill_source.dart';
export 'src/io/file_memory_store.dart';
export 'src/io/io_tools.dart';
export 'src/io/mcp_stdio_transport.dart';
export 'src/io/net_guard.dart';
export 'src/io/process_runner.dart'
    show ProcessOutput, runProcess, processesSupported, splitCommandLine;
export 'src/io/sandbox.dart';
export 'src/io/workspace.dart';
