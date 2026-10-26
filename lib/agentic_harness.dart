/// Agentic harness — a pure Dart tool-use agent loop (no `dart:io`, no Flutter).
///
/// ```dart
/// final agent = AgentSpec(
///   name: 'assistant',
///   instructions: 'You are helpful.',
///   model: OllamaClient(const OllamaConfig(model: 'qwen3')),
///   tools: [myTool, const AskUserTool()],
///   permissions: PermissionPolicy(canUseTool: askTheUser),
/// );
/// final run = const Runner().run(agent, input: AgentMessage.user('Hi'));
/// await for (final event in run.events) { /* render */ }
/// final result = await run.result;
/// ```
///
/// Filesystem / process / HTTP tools live in
/// `package:agentic_harness/io_tools.dart`; test doubles in
/// `package:agentic_harness/testing.dart`.
library;

export 'src/context/context_manager.dart'
    show ContextPolicy, ContextManager, CompactionResult;
export 'src/core/cancellation.dart';
export 'src/core/errors.dart';
export 'src/core/ids.dart';
export 'src/core/json_schema.dart';
export 'src/core/message.dart';
export 'src/core/usage.dart';
export 'src/events/run_event.dart';
export 'src/governance/permissions.dart';
export 'src/model/http_transport.dart'
    show HttpTransport, RetryPolicy, RetryCallback, errorFromStatus;
export 'src/model/model_client.dart';
export 'src/model/tool_call_accumulator.dart';
export 'src/mcp/mcp_client.dart';
export 'src/mcp/mcp_toolset.dart';
export 'src/mcp/mcp_transport.dart' hide headerValue;
export 'src/providers/anthropic_client.dart';
export 'src/providers/gemini_client.dart';
export 'src/providers/ollama_client.dart';
export 'src/providers/openai_chat_client.dart';
export 'src/providers/openai_responses_client.dart';
export 'src/providers/prompted_tool_calling_client.dart';
export 'src/runtime/agent_spec.dart';
export 'src/runtime/runner.dart';
export 'src/telemetry/pricing.dart';
export 'src/telemetry/telemetry.dart';
export 'src/tools/agent_tool.dart';
export 'src/tools/builtin_tools.dart';
export 'src/tools/memory_tool.dart';
export 'src/tools/skills.dart';
export 'src/tools/tool_search.dart';
export 'src/tools/tool.dart';
