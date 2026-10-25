# agentic_harness

A pure Dart harness for tool-using AI agents. Give it a model, a system prompt and some tools, and it runs the loop: stream the model, validate and permission-check the tool calls it makes, run them, feed the results back, and repeat until the model answers. Everything that happens comes out as one typed, serializable event stream.

The core has no `dart:io` and no Flutter dependency, so it runs in Flutter apps (mobile and desktop), on servers and in CLIs.

## Features

- **Native tool-use loop.** Read-only calls run in parallel; others run in order. Every tool call gets exactly one result, including unknown tools, invalid input, denials, timeouts and repeated identical calls, so the model can always recover.
- **Model clients:** OpenAI-compatible (OpenAI, Azure, OpenRouter, LM Studio, vLLM), Anthropic (thinking, prompt caching), Ollama (native API, capability probing), Gemini (thought signatures, thinking levels), plus `PromptedToolCallingClient` to add tool calling to models without it.
- **JSON Schema tools** with input validation and type coercion, tool annotations (read-only, destructive, idempotent, open-world), separate model-facing and host-facing output.
- **Permissions and hooks:** allow/deny/ask rules, modes, a fail-closed `canUseTool` callback, and pre/post tool-use hooks.
- **Limits:** turn, token and wall-clock budgets, per-tool timeouts, cancellation that aborts the HTTP request.
- **Context management:** compaction calibrated against the provider's reported usage, which never separates a tool use from its result.
- **Structured output** validated against a JSON Schema, with one repair attempt.
- **Built-in tools:** `ask_user` (questions, choices, multi-field forms), `todo_write`, and subagents as tools.
- **Hardened IO tools** (`io_tools.dart`): a symlink-safe workspace filesystem, git with a subcommand allow-list, shell-free terminal and build/test runners, and HTTP with an SSRF guard.
- **Testing:** `FakeModelClient` plays scripted turns and records every request.

## Install

```sh
dart pub add agentic_harness
```

## Quick start

```dart
import 'dart:io';

import 'package:agentic_harness/agentic_harness.dart';

Future<void> main() async {
  final weather = FunctionTool(
    name: 'get_weather',
    description: 'Current weather for a city.',
    inputSchema: const {
      'type': 'object',
      'properties': {'city': {'type': 'string'}},
      'required': ['city'],
    },
    annotations: ToolAnnotations.readOnlyRemote,
    run: (input, context) async => ToolOutput.text('Sunny in ${input['city']}'),
  );

  final agent = AgentSpec(
    name: 'assistant',
    instructions: 'You are a helpful assistant.',
    model: AnthropicClient(
      AnthropicConfig(
        model: 'claude-sonnet-5-5',
        apiKey: Platform.environment['ANTHROPIC_API_KEY']!,
      ),
    ),
    tools: [weather],
  );

  final run = const Runner().run(agent, input: AgentMessage.user('Weather in Oslo?'));
  await for (final event in run.events) {
    switch (event) {
      case TextDelta(:final text):
        stdout.write(text);
      case ToolCallStarted(:final displayLabel):
        stdout.writeln('[$displayLabel]');
      default:
        break;
    }
  }
  final result = await run.result;
  print('\n${result.stopReason.name}, ${result.usage}');
}
```

Swap the client to change providers:

```dart
OpenAiChatClient(OpenAiChatConfig(model: 'gpt-5-mini', apiKey: key));
OllamaClient(const OllamaConfig(model: 'qwen3:8b'));
GeminiClient(GeminiConfig(model: 'gemini-3-flash', apiKey: key, thinkingLevel: 'low'));
```

## Asking before destructive actions

Tools are destructive unless their annotations say otherwise, and destructive calls go to `canUseTool`. Without a `canUseTool` callback they are denied.

```dart
final agent = AgentSpec(
  // ...
  permissions: PermissionPolicy(
    canUseTool: (call) async => await confirm(call.displayLabel)
        ? const Allow()
        : const Deny('The user declined.'),
  ),
);
```

## Learn more

- [Usage guide](doc/guide.md): the loop, clients, tools, permissions, context, events and testing.
- [Example](example/main.dart): a console agent with a permission prompt. It runs offline with a scripted model, or against Anthropic or OpenAI when an API key is set.

## License

MIT
