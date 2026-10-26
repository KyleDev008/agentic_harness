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
| `OpenAiResponsesClient` | OpenAI's Responses API (`/v1/responses`), recommended for OpenAI reasoning models | Stateless by default (`store: false`): encrypted reasoning items are kept on the transcript and replayed between tool calls, so the model keeps its reasoning; reasoning summaries stream as thinking. With `store: true, chainResponses: true` it sends `previous_response_id` and only the new turns, but only while the earlier history is unchanged (compaction or edits fall back to a full resend); if a stored response has expired (30 days by default) or was deleted, the client resends the full history once. Stored conversations stay with OpenAI and don't work under zero data retention. Set `reasoningModel` for deployments whose names don't reveal it (Azure) |
| `AnthropicClient` | Claude | Adaptive thinking, prompt caching, `eager_input_streaming`, server-side refusal fallback on supported models |
| `OllamaClient` | Ollama (local or cloud) | Uses the native `/api/chat` endpoint; capabilities are probed through `/api/show`, and `num_ctx` doubles as the context window |
| `GeminiClient` | Gemini | Thought signatures replayed (required by Gemini 3 for multi-step tool use), provider call ids echoed, `thinkingLevel` (Gemini 3+) or `thinkingBudget` (2.5), native structured output |
| `PromptedToolCallingClient(inner)` | Any model without native tools | A JSON `tool_call` text protocol; protocol text never reaches `TextDelta` |

All HTTP clients share `HttpTransport`. It provides:

- Retries: at most 3 attempts, on 429, 503/529, 408/504 and network errors, honouring `retry-after`.
- Cancellation through `AbortableRequest`.
- An idle timeout.
- No redirects (a redirect would re-send the API key to another host).

Client-specific state that must survive between turns (Anthropic thinking signatures and compaction summaries, Gemini thought signatures, Responses reasoning items, the prompted client's raw text) is stored on `AgentMessage.providerMetadata` and serialized with the message. Keep it when you persist history.

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

## MCP servers

`McpToolset` exposes a Model Context Protocol server's tools to an agent. Add it to `AgentSpec.toolProviders`:

```dart
final docs = McpToolset(
  McpClient(McpHttpTransport(
    Uri.parse('https://mcp.example.com/mcp'),
    headers: {'Authorization': 'Bearer $token'},
  )),
  prefix: 'docs', // tools become docs__<name>
  timeout: const Duration(minutes: 2),
);
final agent = AgentSpec(/* ... */, toolProviders: [docs]);
```

For a local server, use `McpStdioTransport` from `io_tools.dart`:

```dart
McpClient(McpStdioTransport('npx', arguments: ['-y', '@acme/mcp-server']))
```

- **Versions:** the client speaks the stateless 2026-07-28 protocol and falls back to the `initialize` handshake (2025-11-25, 2025-06-18, 2025-03-26) for older servers. It declares no client capabilities, so servers don't send sampling, roots or elicitation requests.
- **Untrusted servers:** remote endpoints must use https. A stdio server gets only basic variables such as `PATH` and `HOME`, plus `environment`, so set `includeParentEnvironment: true` only for servers you trust. `prefix` is required so a server can't take another tool's name; use `''` to opt out. `onToolsChanged` lets you refuse tool definitions that change after first use.
- **Annotations are untrusted.** By default every MCP tool is treated as destructive and open-world, so the standard policy asks before each call. Pass `trustAnnotations: true` only for servers you control: a `readOnlyHint` then skips approval.
- **Output:** text and images go to the model. Audio and resources become short notes. `structuredContent` is the host-facing `structured` value.
- **Lifecycle:** the tool list is cached for `cacheFor` (5 minutes by default), and `invalidate()` drops it. Call `close()` when you're done, which also stops a stdio server process.

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

## Tool search

Large tool catalogues (an MCP server with dozens of tools, say) cost prompt tokens on every call and make the model's choice harder. Defer them:

```dart
AgentSpec(
  name: 'ops',
  instructions: '…',
  model: claude,
  tools: [askUser],                                   // always offered
  toolProviders: [DeferredTools(McpToolset(github, prefix: 'gh'))],
);
```

- Deferred tools (`DeferredTools(provider)`, `DeferredTools.of(tools)`, or a tool whose `deferLoading` is true) aren't sent to the model. Instead it gets `search_tools`: keyword search (BM25 over names, descriptions and parameter names) that loads the best matches, or `select:name1,name2` for exact names. Its description says how many tools are waiting and, for up to 60, their names.
- Loaded tools are offered from the next model call, after the always-on ones, for the rest of the run (a paused run resumes with them; a handoff starts the new agent with none). `RunConfig.maxLoadedTools` (40) caps them: a search loads as many matches as fit and names the rest. A deferred tool the model calls by name without searching runs and is loaded too, unless the cap is reached. Search drops common stop words, splits camelCase, acronyms and snake_case, and works in any script; a tool already named `search_tools` is replaced by the built-in one (with a log line).
- Deferring changes only what the model sees: permissions, approvals and hooks apply to deferred tools as to any other. Loading tools changes the tool list, which invalidates a provider's prompt cache from that point.

## Skills

A skill is a set of instructions (and optional files) the model loads only when a task needs it, so detailed guidance stays out of the prompt until then.

```dart
final skills = SkillSet(
  skills: [
    Skill.withFiles(
      name: 'invoices',
      description: 'Use when writing or checking an invoice.',
      instructions: 'Always include the VAT number. Start from template.md.',
      files: {'template.md': '…'},
    ),
  ],
  sources: [DirectorySkillSource('skills')], // io_tools.dart: folders with a SKILL.md
);
final agent = AgentSpec(name: 'support', instructions: '…', model: claude, toolProviders: [skills]);
```

- The model sees a `load_skill` tool whose description indexes every skill (name and when to use it), and `read_skill_file` for a skill's files. Loading returns the instructions and the list of files.
- `SKILL.md` uses front matter with `name` (a-z, 0-9, `-`) and `description`, then the instructions. `DirectorySkillSource` treats each subfolder with a `SKILL.md` as a skill and its other text files (not hidden, no links, up to 4 levels) as files; reads are confined to the folder and capped.
- The index, instructions and files are capped (`maxIndexChars`, `maxContentChars`). A source that fails is logged and tried again on the next run; the other skills stay available.
- `SKILL.md` front matter supports single-line values and `>` / `|` block values (a UTF-8 BOM is fine); an unclosed front matter block is an error.
- Skills are host content: they reach the model as tool results with system-prompt-like authority, so load only skills you wrote or reviewed, and keep skill folders out of reach of the agent's own write tools. Loading one doesn't count as reading private data unless you set `SkillSet(containsPrivateData: true)` (for skills built from the user's own notes).

## Handoffs and subagents

**Handoffs** pass the whole conversation to another agent:

```dart
final billing = AgentSpec(name: 'Billing', instructions: '…', model: claude, tools: [refund]);
final triage = AgentSpec(
  name: 'Triage',
  instructions: 'Route each request to the right team.',
  model: claude,
  handoffs: [Handoff(billing, inputFilter: HandoffFilters.removeToolCalls)],
);
```

- The model sees a `transfer_to_billing` tool. Calling it ends the turn's tools as usual, then Billing's instructions, model, tools and permissions apply for the rest of the run, on the same transcript (or the filtered one). The run emits `HandoffOccurred`, and `RunResult.agentName` names the agent that finished.
- One handoff per turn; `RunConfig.maxHandoffs` (5) stops agents passing the conversation back and forth. A paused run resumes with the agent it was handed to, including a handoff accepted in the turn that paused.
- **Approval:** a transfer runs without asking unless `Handoff.requiresApproval` is true, or (by default) the run has read private data and the target's permissions are in bypass mode while the current agent's aren't — so a prompt-injected agent can't quietly pass the conversation, injected text included, to a more permissive one. The default only looks at bypass mode: a target with broader allow rules, or standard mode under a strict agent, transfers without asking, so set `requiresApproval: true` on handoffs to agents that can do more. Give privileged agents their own permission policy; `HandoffFilters.removeToolCalls` drops tool traffic but not injected plain text.
- When the new agent uses a different model, earlier thinking blocks and client state are dropped (another model can't use them), and the transcript always ends on a user turn. Transfer tools take precedence over other tools with the same name.

**Subagents** (`SubagentTool`) work on a self-contained task with a fresh context and return an answer:

- With `background: true` the call returns a task id at once and the subagent works alongside the parent. Its answer reaches the parent as a message (marked untrusted) at the next turn; if the parent tries to finish while tasks are out, it waits for them and continues. `BackgroundTaskStarted` / `BackgroundTaskFinished` track them. A background subagent can't ask the user questions (and its approval prompts are declined), is cancelled after `RunConfig.backgroundTaskTimeout` (15 minutes) and when the run ends. Its answer is wrapped in a tag with a random name it can't close or forge, labelled untrusted, and cut at `RunConfig.maxBackgroundResultChars` (20,000).
- `RunConfig.maxBackgroundTasks` (4) caps tasks running at once; `RunConfig.maxSubagentDepth` (3, set on the top-level run) caps nesting.
- A cost budget covers every subagent: they share one ledger, each call reserves its worst-case cost first, open subagents get an equal share of what is left, and a call that doesn't fit waits (up to five minutes) for others to finish before the run stops.
- Background tasks don't survive a pause or a restart: on resume the model is told which tasks were stopped, so it can start them again.

## Durable runs

By default a run waits in memory for approvals (`canUseTool`) and questions (`respond`). To let a run wait for hours, or survive a restart, set `RunConfig(interruptible: true)`:

```dart
const config = RunConfig(interruptible: true);
var result = await runner.run(agent, input: input, config: config).result;

while (result.stopReason == StopReason.interrupted) {
  await store.save(jsonEncode(result.state!.toJson()));
  // …later, possibly in a new process…
  final state = RunState.fromJson(jsonDecode(await store.load()));
  final answered = switch (state.interruption!) {
    ApprovalInterruption() => await userApproves() ? state.approve() : state.reject(),
    final InputInterruption q => state.answer(await askUser(q.prompt, q.choices)),
  };
  result = await runner.resume(agent, answered, config: config).result;
}
```

- **What stops the run:** a call that resolves to "ask" (`canUseTool` is not called), and a question from a tool whose `replayable` is true, such as `ask_user`. The run ends with `StopReason.interrupted` and `RunResult.state`; the usual `ApprovalRequested` / `UserInputRequested` events are still emitted.
- **Replay:** a replayable tool is re-run from the start on resume, with its earlier answers returned in order, each only to the same question (if the wording changes, the user is asked again). It must not have side effects before its questions. Questions from other tools (for example a subagent) still wait in memory through `respond`.
- **Resume:** pass the same spec (matched by name) and config. Tools are resolved again, and the run keeps its id, turn count, usage, todo list and active time. Calls before the interruption are not repeated; the rest of the turn runs as usual. The pending call is checked again: schema validation (also of edited input), dry-run, and the permission rules (a deny rule added meanwhile blocks it, and a call that was never approved is blocked if it now needs approval). `preToolUse` hooks are not re-run; their earlier rewrite is kept. The resumed run emits `RunStarted` and the pending call's `ToolCallStarted` again.
- **Checkpoints:** `RunConfig.onCheckpoint` receives a `RunState` at the start of every turn. Resuming one after a crash re-sends the last model call, and the model may repeat that turn's tool calls.
- **At-least-once:** resuming the same state twice runs the pending call twice. Delete or mark a state as used before resuming it, and make destructive tools idempotent where you can (the `toolUseId` makes a good key).
- **Storage:** the state holds the whole transcript and the user's answers in plain JSON, so store it like the conversation. It isn't signed: whoever can edit it can record an approval, reset the turn/token/time budgets, or clear the private-data flag. Keep it where only your app can write, or sign it yourself. Only the todo list survives from the tools' shared `runState`.

## Tracing and cost

```dart
final spans = OtlpHttpExporter(Uri.parse('http://localhost:4318/v1/traces'));
final config = RunConfig(
  tracer: spans,
  // Optional: the built-in list is used by default. Layer fresher prices
  // (e.g. fetched from your server) over it.
  pricing: PricingTable.builtIn.withOverrides(PricingTable.fromJson(remoteJson)),
  maxCost: 0.50,
);
// …run…
await spans.close();
```

- **Spans:** one `invoke_agent` span per run, a `chat` span per model call and an `execute_tool` span per tool call. A subagent's run nests under the call that started it, in the same trace. Only tools that declare `startsRuns` (like `SubagentTool`) receive `ToolContext.telemetry` to pass to `Runner.run`, so other tools can't add spans or cost. Attributes follow the OpenTelemetry GenAI conventions (`gen_ai.request.model`, `gen_ai.usage.input_tokens`, `gen_ai.tool.name`, …); prompt, answer and tool text are never recorded. Span errors carry only the error class and HTTP status, since provider messages can echo request content; `RunConfig.traceErrorMessages` puts the full message in. A tool call that pauses for approval, or is cancelled, records its outcome in `agentic_harness.tool.outcome` rather than as an error.
- **Exporters:** `InMemorySpanExporter` for tests or an in-app trace view, `OtlpHttpExporter` for any OpenTelemetry collector (OTLP/HTTP JSON, batched, one request at a time; https required unless the collector is on loopback or `allowInsecureHttp` is set; redirects are not followed; call `close()` before exit), or implement `SpanExporter`. `toOtlpJson` converts spans yourself.
- **Prices:** `PricingTable.builtIn` holds standard list prices for Anthropic, OpenAI and Gemini models as of `PricingTable.builtInAsOf` (2026-10-26), including Claude Haiku 5.5's and the OpenAI flagships' long-prompt prices and Gemini's announced increases; Ollama models are free. It is the default. Lookups accept client ids, bare names, OpenRouter-style `vendor/model`, Gemini `models/…`, dated snapshots and `prompted(…)`. Prices change: load current ones with `PricingTable.fromJson` (for example from your own server) and layer them with `withOverrides`; a `fallback` price covers unknown models. Batch, priority, regional (`inference_geo`) and fast-mode rates, and server-tool fees (web search), are not modelled. `PricingTable.none` turns cost tracking off.
- **Cost:** `RunResult.cost` and `UsageUpdated.cost` include subagents and the runner's own summarizing compaction.
- **Budget (`maxCost`):** before each model call the runner prices the prompt conservatively — the estimate plus a margin (30% until it has been calibrated against reported usage, 10% after), the dearer tier when the prompt is near a long-context threshold, and the cache-write rate when that is above the input rate — and caps the call's output tokens to what the remaining budget can pay for, never above the agent's own `maxOutputTokens` (or the client's default, or 16,384). When even 256 output tokens won't fit, the run stops with `StopReason.budget` before calling, and `RunResult.error` says why. The runner's summarizing compaction runs only if the budget can pay for it (otherwise it truncates). Subagents share the parent's budget (see Handoffs and subagents). A budgeted run whose model has no price stops at once instead of running unmetered. It is a best-effort cap: a prompt estimate off by more than the margin, Anthropic server-side compaction's extra summarizing step, and Gemini thinking tokens beyond the output limit can still take a run slightly over.
- Durable runs keep their trace id and cost across a resume.

## Context

`ContextPolicy` compacts the working copy when the estimated prompt passes `compactAt` × the usable window. The estimate is calibrated against the provider's reported usage. Compaction runs in stages:

1. Clear old tool results.
2. Summarize older turns, if `summarize: true`.
3. Drop the oldest turns, keeping each tool use together with its result.

The caller's history is never modified. `RunConfig.contextWindow` can lower a client's own window (for example Ollama `num_ctx`) but never raise it.

### Server-side context management (Anthropic)

`AnthropicConfig.contextManagement` hands context management to the API (beta features; the client sends the beta headers):

```dart
AnthropicClient(AnthropicConfig(
  model: 'claude-opus-5-5',
  apiKey: key,
  contextManagement: AnthropicContextManagement(
    compaction: AnthropicCompaction(triggerTokens: 150000),
    clearToolResults: AnthropicToolResultClearing(keepToolUses: 5),
    clearThinking: AnthropicThinkingClearing(keepTurns: 2),
  ),
));
```

- **Compaction** (`compact_20260112`): when the prompt reaches the trigger, the API summarizes the earlier conversation and continues. The summary is kept on the assistant message (`providerMetadata['compaction']`), later requests start from it, and the run emits `ContextCompacted(stage: 'server')`. The runner's own `ContextPolicy` compaction is skipped while it is on. When the request has tools, the summary prompt tells the model not to call one (otherwise it sometimes does and no summary comes back); pass `instructions` to replace it. Compaction tokens are added to the run's usage.
- **Clearing** (`clear_tool_uses_20250919`, `clear_thinking_20251015`): the full history is still sent; the API removes old tool results or thinking from what the model sees. Use `clearAtLeastTokens` so each clear is worth the prompt-cache write it causes, and add `memory` to `excludeTools` when the agent uses the memory tool.
- **Turning compaction off later:** stored summaries are then ignored and the full history is sent again. Summaries live in the transcript, so keep stored history and `RunState` where only your app can write: a forged summary replaces everything before it.
- Anthropic's docs don't say whether compaction and clearing may be combined in one request; the client sends both when both are set (thinking clearing first, as required).

### Memory

`MemoryTool(store)` gives the agent a `/memories` directory that persists across conversations. The Anthropic client declares it as Claude's native `memory_20250818` tool (`AnthropicConfig.nativeToolTypes: false` sends the schema instead); other providers get the JSON schema.

- Stores: `InMemoryMemoryStore`, or `FileMemoryStore(dir)` from `io_tools.dart` (symlink-safe, atomic writes).
- Paths must stay under `/memories`: `..`, `.`, hidden names, encoded, invisible or Windows-special characters, Windows device names (`nul`, `con`, …), trailing dots and deep nesting are rejected. Files, file count and unranged views are capped, and commands run one at a time. `FileMemoryStore` also refuses any path through a link; keep its directory writable only by the agent's user.
- `view` is a local read (it marks the run as holding private data); `delete` asks for approval in the standard mode.
- **Memory carries prompt injection forward:** text a run reads from the web, files or MCP servers can be saved as a note and come back in every later run. For agents that handle untrusted content, set `MemoryTool(store, askBeforeWrites: true)` so each write needs approval. Keep secrets out of it.

## IO tools

`package:agentic_harness/io_tools.dart` is hardened for agents working on a real machine:

- **Filesystem:** paths are confined to a workspace, symlink-safe, and writes into `.git` are refused.
- **Git:** subcommand allow-list; config and hook injection are blocked.
- **Terminal and build/test:** no shell, allow-listed commands, processes killed on timeout or cancel.
- **HTTP:** SSRF guard (private and loopback addresses refused), every redirect re-validated.

### Sandboxes

The file, git, terminal and build/test tools take either a `workspaceRoot` folder or a `sandbox`:

```dart
final box = DockerSandbox(workspaceRoot: '/work/project-copy', image: 'node:20@sha256:…');
if (!await box.available()) { /* Docker isn't running */ }
await box.pullImage();      // containers run with --pull=never
await box.reapOrphans();    // remove containers left by a crashed run
final tools = [FileSystemTool(sandbox: box), GitTool(sandbox: box), BuildTestTool(sandbox: box)];
```

- `LocalSandbox(root)` is the default: a folder on this machine, programs run directly.
- `DockerSandbox` runs every program in a fresh container with the folder mounted at `/workspace`:
  - the program is the container's entrypoint, so an image's own entrypoint never receives it;
  - no network unless `network` says so (`bridge` can reach your LAN and cloud metadata endpoints; `host` needs `allowHostNetwork`);
  - all Linux capabilities dropped, no privilege escalation, and a non-root user: `user`, else this process's own uid:gid on Linux and macOS (`runAsRoot` only with rootless Docker or userns-remap);
  - read-only root filesystem with a writable `/tmp` (also `HOME`); memory without extra swap, CPU, process, open-file and file-size limits;
  - labelled and removed with `docker rm -f` (retried) on timeout or cancel; host paths are replaced by `/workspace` in the output.
- Files are read and written on the host through the same confinement as `LocalSandbox`. The image needs the programs the agent runs (for example `git`); pin it by digest.
- **What it doesn't protect:** the container can change everything in the mounted folder, including `.git` hooks and config, build scripts and IDE settings that run on the host later. Point it at a throwaway copy or worktree and review the diff, or set `readOnlyGit: true` when the agent doesn't need to commit. Containers share the host kernel (Docker Desktop adds a VM); for hostile code prefer a VM-backed runtime or a remote sandbox. The sensitive-file check is a guardrail: a terminal with no allow-list can still `cat` anything in the folder.
- Implement `Sandbox` to use a remote sandbox service: paths come in workspace-relative and already validated by `resolve`, which must refuse escapes.

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
