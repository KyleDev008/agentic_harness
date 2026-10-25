# agentic_harness: Usage Guide

This guide covers building agents with `package:agentic_harness`. For a quick start, see the [README](../README.md); for a runnable program, see [example/main.dart](../example/main.dart).

## Entry points

| Library | Contains | Platforms |
|---|---|---|
| `package:agentic_harness/agentic_harness.dart` | Core: messages, model clients, `Runner`, tools, permissions, hooks, events, context management | All (no `dart:io`, no Flutter) |
| `package:agentic_harness/io_tools.dart` | `FileSystemTool`, `GitTool`, `TerminalTool`, `BuildTestTool`, `HttpTool`, `loadImageBlock` | Desktop and server. Process tools report themselves unavailable on Android and iOS |
| `package:agentic_harness/testing.dart` | `FakeModelClient` with scripted turns | Tests |

## A minimal agent

```dart
import 'dart:io';

import 'package:agentic_harness/agentic_harness.dart';

final weather = FunctionTool(
  name: 'get_weather',
  description: 'Current weather for a city.',
  inputSchema: const {
    'type': 'object',
    'properties': {'city': {'type': 'string'}},
    'required': ['city'],
  },
  annotations: ToolAnnotations.readOnlyRemote,
  run: (input, ctx) async => ToolOutput.text('Sunny in ${input['city']}'),
);

final agent = AgentSpec(
  name: 'assistant',
  instructions: 'You are a helpful assistant.',
  model: OllamaClient(const OllamaConfig(model: 'qwen3:8b')),
  tools: [weather, const AskUserTool(), const TodoWriteTool()],
  permissions: PermissionPolicy(canUseTool: (call) async => const Allow()),
);

final run = const Runner().run(agent, input: AgentMessage.user('Weather in Oslo?'));
await for (final event in run.events) {
  switch (event) {
    case TextDelta(:final text): stdout.write(text);
    case ToolCallStarted(:final displayLabel): print('\n[$displayLabel]');
    case UserInputRequested(:final requestId, :final prompt):
      run.respond(requestId, await askSomehow(prompt));
    default: break;
  }
}
final result = await run.result; // finalText, newMessages, usage, stopReason, todos
```

To continue a conversation, append `result.newMessages` to your history and pass it as `history:` on the next run. The new messages include the tool-use and tool-result turns, so the model keeps the full tool context.

## The loop

1. The runner streams the model.
2. If the model asked for tools, each call goes through these steps in order:
   - validated against its JSON Schema (simple values such as `"5"` are coerced to the declared type)
   - checked by the `preToolUse` hook
   - checked against the permission policy
   - executed
3. Read-only calls run in parallel, up to `RunConfig.maxParallelTools`. Other calls run one at a time, in order.
4. The results go back as one message with one result per call id, and the loop repeats.

**Every tool call gets exactly one result.** Unknown tools, invalid input, denied calls, timeouts and repeated identical calls all produce error results that the model can react to.

**Stop reasons:** `endTurn`, `maxTurns`, `budget` (`maxTotalTokens`), `timeout` (`wallClockBudget`), `cancelled`, `refusal`, `error`. A run never hangs or throws. Failures surface as `StopReason.error` with a typed `HarnessError` in `RunResult.error`, and as `RunError.errorClass` on the event stream.

**Host-initiated calls:** `Runner.run(initialToolCalls:)` runs tool calls triggered by the host (for example a UI button) before the first model call, through the same validation and permission pipeline. Such calls are always asked about when they write or reach outside the app, even in bypass mode.

**Structured output:** set `ModelSettings.outputSchema`. The final answer is validated against it, with one repair attempt; the parsed value is in `RunResult.structuredOutput`.

## Model clients

| Client | Use for | Notes |
|---|---|---|
| `OpenAiChatClient` | OpenAI, OpenRouter, LM Studio, vLLM, Azure (`apiKeyHeader: 'api-key'` + `api-version` query) | Reasoning models get `max_completion_tokens` and no temperature |
| `AnthropicClient` | Claude | Adaptive thinking, prompt caching, `eager_input_streaming`, server-side refusal fallback on supported models |
| `OllamaClient` | Ollama (local or cloud) | Uses the native `/api/chat` endpoint; capabilities are probed through `/api/show`, and `num_ctx` doubles as the context window |
| `GeminiClient` | Gemini | Thought signatures replayed (required by Gemini 3 for multi-step tool use), provider call ids echoed, `thinkingLevel` (Gemini 3+) or `thinkingBudget` (2.5), native structured output |
| `PromptedToolCallingClient(inner)` | Any model without native tools | A JSON `tool_call` text protocol; protocol text never reaches `TextDelta` |

All HTTP clients share `HttpTransport`. It provides:

- Retries: at most 3 attempts, on 429, 503/529, 408/504 and network errors, honouring `retry-after`.
- Cancellation through `AbortableRequest`.
- An idle timeout.
- No redirects (a redirect would re-send the API key to another host).

Client-specific state that must survive between turns (Anthropic thinking signatures, Gemini thought signatures, the prompted client's raw text) is stored on `AgentMessage.providerMetadata` and serialized with the message. Keep it when you persist history.

To write a client, implement `ModelClient.stream`. It must emit `ToolUseStart`/`ToolUseEnd` for each call and end with `MessageStop`.

## Tools

Subclass `HarnessTool`, or use `FunctionTool` for an inline tool. Things to set:

- **`annotations` / `annotationsFor(input)`:** `readOnly` calls run in parallel and are allowed by default. `destructive` calls ask for permission. Calls are retried only if they are `idempotent`. Override `annotationsFor` for tools whose behaviour depends on their arguments.
- **`displayLabel(input)`:** the UI label, such as "Reading notes…".
- **`ToolOutput(content:, structured:)`:** `content` goes to the model and is capped at `maxOutputChars`. `structured` is only for the host, never sent to the model, and never truncated.
- **`ToolContext`:**
  - `cancel` (honour it)
  - `progress()`
  - `requestUserInput()` — waiting here pauses both the tool timeout and the wall-clock budget
  - `runState`
- **`ToolProvider`** supplies dynamic tool sets, such as MCP servers. They are resolved at the start of each run.
- **`SubagentTool`** runs another `AgentSpec` as a tool, in its own context.

Built-ins: `AskUserTool` (free text, choices, or a multi-field form answered with a JSON object keyed by field id) and `TodoWriteTool` (the final list is in `RunResult.todos`).

## Permissions

Resolution order:

1. deny rules
2. allow rules
3. ask rules
4. the mode (`standard`, `strict` or `bypass`) together with the call's annotations
5. `canUseTool` for anything that resolved to "ask"

If there is no `canUseTool`, "ask" means deny. Time spent waiting on `canUseTool` doesn't count toward the tool timeout or the wall-clock budget.

In `standard` mode, open-world calls are asked about once the run has read private data (or from the start with `RunConfig.assumePrivateContext`), so a prompt-injected request can't quietly send it elsewhere.

`Hooks` add a `preToolUse` step (rewrite the input or block the call) and a `postToolUse` step (for example to redact output).

## Context

`ContextPolicy` compacts the working copy when the estimated prompt passes `compactAt` × the usable window. The estimate is calibrated against the provider's reported usage. Compaction runs in stages:

1. Clear old tool results.
2. Summarize older turns, if `summarize: true`.
3. Drop the oldest turns, keeping each tool use together with its result.

The caller's history is never modified. `RunConfig.contextWindow` can lower a client's own window (for example Ollama `num_ctx`) but never raise it.

## IO tools

`package:agentic_harness/io_tools.dart` is hardened for agents working on a real machine:

- **Filesystem:** paths are confined to a workspace, symlink-safe, and writes into `.git` are refused.
- **Git:** subcommand allow-list; config and hook injection are blocked.
- **Terminal and build/test:** no shell, allow-listed commands, processes killed on timeout or cancel.
- **HTTP:** SSRF guard (private and loopback addresses refused), every redirect re-validated.

## Events

`RunEvent` is one sealed class. Every event has `toJson()`, so a run can be logged, streamed to another process or replayed. The stream always ends with `RunCompleted`.

## Testing

```dart
import 'package:agentic_harness/testing.dart';

final model = FakeModelClient([
  FakeTurn.tools([const FakeToolCall('c1', 'get_weather', {'city': 'Oslo'})]),
  FakeTurn.text('It is sunny.'),
]);
// Run, then inspect model.requests / model.lastToolResults(1).
```
