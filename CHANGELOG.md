# Changelog

## 2.0.1

- Documentation is now published at [projects.kylecox.co.za/agentic_harness/docs](https://projects.kylecox.co.za/agentic_harness/docs/), linked from the pub.dev page. No code changes.

## 2.0.0

**Breaking for exhaustive switches only.** Code written for 1.0 compiles unchanged unless it switches over every `StopReason` value or every `RunEvent` type without a `default`:
- `StopReason.interrupted` is new (only produced when `RunConfig.interruptible` is on).
- New `RunEvent` types: `HandoffOccurred`, `BackgroundTaskStarted`, `BackgroundTaskFinished`.

Add the new cases, or a `default`. Behaviour changes are listed under **Tracing and cost** below.

- **MCP client.** `McpToolset` exposes a Model Context Protocol server's tools as agent tools.
  - Transports: `McpHttpTransport` (Streamable HTTP, JSON or SSE responses) and `McpStdioTransport` (child process, in `io_tools.dart`).
  - Speaks the stateless 2026-07-28 protocol, and falls back to the `initialize` handshake for servers on 2025-11-25, 2025-06-18 or 2025-03-26.
  - Server tool annotations are ignored unless `trustAnnotations: true`, so untrusted servers can't skip approval by claiming to be read-only.
  - Tool names get a required `prefix` and are sanitized; text, image, resource and structured content are converted.
  - Hardened against hostile servers: https required for remote endpoints (`allowInsecureHttp` to override), stdio servers get only an allow-listed environment, size caps on responses, streams, tool lists, schemas and images, permission labels never use server text, and `onToolsChanged` reports tool definitions that change after first use.
- **Native structured output on Anthropic.** `ModelSettings.outputSchema` is sent as `output_config.format`, reduced to the schema subset the API accepts, and the runner still checks the answer against the full schema. Claude 3 and the original Claude 4 models keep the prompt instruction; `AnthropicConfig.nativeStructuredOutput` overrides the choice.
- **Durable runs.** With `RunConfig(interruptible: true)` a run stops at an approval or an `ask_user` question with `StopReason.interrupted` and a JSON-serializable `RunResult.state`. Answer it with `RunState.approve` / `reject` / `answer` and continue with `Runner.resume`, even in a new process. `RunConfig.onCheckpoint` snapshots each turn for crash recovery. Tools opt into question replay with `HarnessTool.replayable`.
  - **Breaking for exhaustive switches:** `StopReason` has a new `interrupted` value, only produced by interruptible runs.
- **Anthropic server-side context management.** `AnthropicConfig.contextManagement` turns on compaction (`compact_20260112`), tool-result clearing and thinking clearing, with the beta headers. Compaction summaries are kept on the transcript and replayed, earlier history is no longer sent, compaction tokens count toward usage, and the run emits `ContextCompacted(stage: 'server')`. `ModelCapabilities.serverCompaction` makes the runner skip its own compaction.
- **Memory tool.** `MemoryTool` with `InMemoryMemoryStore` and `FileMemoryStore` (`io_tools.dart`): a confined `/memories` directory, declared to Claude as the native `memory_20250818` tool through the new `HarnessTool.anthropicType` / `ToolDefinition.anthropicType`.
- **OpenAI Responses API client.** `OpenAiResponsesClient` streams `/v1/responses`: function calls as `function_call` / `function_call_output` items, reasoning summaries as thinking, and reasoning items (encrypted when `store` is off, the default) carried on the transcript and replayed in their original order. Optional `previous_response_id` chaining with `store: true, chainResponses: true`, used only while the earlier history is unchanged; if the stored response has expired or been deleted, the request is resent once with the full history. Failed, cancelled or cut-off responses raise typed errors; buffered JSON responses are handled too; stored reasoning is size-capped and rebuilt from known fields on replay.
- `HttpTransport`'s plaintext-HTTP credential warning now recognises only literal private addresses as local (`10.example.com` no longer counts).
- **Tracing and cost.** `RunConfig.tracer` receives OpenTelemetry-style spans (run, model calls, tool calls, subagents nested in the same trace) with GenAI attributes and no content; `InMemorySpanExporter` and `OtlpHttpExporter` (OTLP/HTTP JSON) are included. `RunConfig.pricing` (`PricingTable` / `ModelPricing`) gives `RunResult.cost` and `UsageUpdated.cost`, subagents included, and `RunConfig.maxCost` is a cost budget. Tools that declare `HarnessTool.startsRuns` (like `SubagentTool`) get `ToolContext.telemetry` to pass to `Runner.run(telemetry:)`. Span errors hold only the error class unless `RunConfig.traceErrorMessages` is set.
  - **Built-in prices** (`PricingTable.builtIn`, as of 2026-10-26) for Anthropic, OpenAI and Gemini, with long-prompt tiers and scheduled price changes, free Ollama, JSON loading (`PricingTable.fromJson`, `withOverrides`, `fallback`); used by default.
  - **`maxCost` is enforced before each call:** the prompt is priced conservatively and the call's output tokens are capped to what the remaining budget can pay for; subagents share the parent's budget; summarizing compaction runs only when affordable and is counted. `ModelCapabilities.maxOutputTokens` (set by the Anthropic client) bounds the cap.
  - **Behaviour changes:** `RunResult.cost` is now filled for known models without any configuration (`PricingTable.none` turns it off), and a run with `maxCost` on a model without a price now stops with `StopReason.budget` (and a `StateError` in `RunResult.error`) instead of ignoring the limit. Tools with `startsRuns` no longer run in a parallel batch. `OtlpHttpExporter` requires https for remote collectors and never follows redirects.
- **Handoffs.** `AgentSpec.handoffs` (`Handoff`, `HandoffFilters`) give the model `transfer_to_<agent>` tools that hand the rest of the run to another agent on the same transcript; `HandoffOccurred`, `RunResult.agentName`, `RunConfig.maxHandoffs`; `Handoff.requiresApproval` (asks by default when moving to a bypass-mode agent after private data was read); paused runs resume with the active agent.
- **Background subagents.** `SubagentTool(background: true)` returns a task id at once; results reach the parent as messages in an unforgeable wrapper and the parent waits for outstanding tasks before finishing (`BackgroundTaskStarted` / `BackgroundTaskFinished`, `RunConfig.maxBackgroundTasks`, `backgroundTaskTimeout`, `maxBackgroundResultChars`). `RunConfig.maxSubagentDepth` caps nesting.
- **Shared budget ledger.** `BudgetLedger` replaces the remaining-budget snapshot: calls reserve their worst-case cost up the run tree, concurrent subagents get fair shares, and a call that doesn't fit waits for in-flight calls before stopping. `RunTelemetry` now carries the ledger, depth and background starter.
- **Skills.** `Skill` / `SkillSet` (a `ToolProvider`) give the model a `load_skill` tool indexing every skill and a `read_skill_file` tool, so instructions and reference files load on demand; `Skill.fromMarkdown` parses `SKILL.md`, and `DirectorySkillSource` (`io_tools.dart`) loads skill folders with confined, capped reads. `HarnessTool.readsPrivateData` lets tools that read only host content (skills, handoffs) leave the private-data flag alone.
- **Tool search.** `DeferredTools` (or `HarnessTool.deferLoading`) keeps tools out of the prompt; the run offers `search_tools` (BM25 keyword search, or `select:` exact names, via `ToolSearchIndex` / `ToolSearchTool`) and loaded tools are offered from the next call. `RunConfig.maxLoadedTools`; loaded tools persist in `RunState`.
- **Sandboxes.** `Sandbox` (confined file operations plus running programs), `LocalSandbox` and `DockerSandbox` (a fresh container per command with the program as entrypoint, non-root user, no network by default, capabilities dropped, no-new-privileges, read-only root, memory/CPU/process/file limits, `--pull=never`, removed on timeout or cancel; `pullImage`, `reapOrphans`, `readOnlyGit`). `FileSystemTool`, `GitTool`, `TerminalTool` and `BuildTestTool` take a `sandbox` as an alternative to `workspaceRoot`; their `workspace` getter is deprecated. Credential-file checks also catch Windows stream and trailing-dot names.
- The runner logs a warning when two tools share a name (the first one wins).

## 1.0.0

First release as `agentic_harness`.

- **Loop:** a native tool-use loop (`Runner`). The model can call tools repeatedly until it is done.
  - Every tool use gets exactly one result.
  - Read-only calls run in parallel; destructive calls run in order.
  - Inputs are validated against JSON Schema, with simple values coerced to the declared type.
  - Repeated identical calls are detected.
  - Structured output with one repair attempt, and an empty-response retry.
  - Limits: wall-clock budget, token budget and turn budget.
  - Host-initiated tool calls (`Runner.run(initialToolCalls:)`) go through the same permission pipeline.
- **Model clients:**
  - `OpenAiChatClient`: OpenAI-compatible endpoints and Azure.
  - `AnthropicClient`: adaptive thinking, prompt caching, eager input streaming, refusal fallback.
  - `OllamaClient`: native `/api/chat`, with capabilities probed via `/api/show`.
  - `GeminiClient`: thought signatures stored and replayed (required by Gemini 3 for multi-step tool use), a validator-bypass signature for calls Gemini did not generate, provider call ids echoed in `functionCall`/`functionResponse`, `thinkingLevel` (Gemini 3+) or `thinkingBudget` (2.5), native structured output.
  - `PromptedToolCallingClient`: tool calling for models without native tools.
- **`HttpTransport`:** typed errors, retries that honour `retry-after`, abort on cancel, idle timeouts, no redirects.
- **Tools:**
  - `HarnessTool` and `FunctionTool`.
  - `ToolAnnotations` with per-call classification.
  - `ToolOutput` with separate model-facing and host-facing payloads.
  - `ToolProvider`.
  - Built-ins: `AskUserTool` (including multi-field forms), `TodoWriteTool`, `SubagentTool`.
- **Governance:** `PermissionPolicy` (rules, modes, fail-closed `canUseTool`) and `Hooks` (pre/post tool use).
- **`ContextManager`:** compaction calibrated against reported usage, keeping each tool use together with its result. `RunConfig.contextWindow` can lower a client's window but never raise it.
- **Events:** one sealed, serializable `RunEvent` stream.
- **`package:agentic_harness/io_tools.dart`:** hardened IO tools.
  - Filesystem: symlink-safe workspace, no writes into `.git`.
  - Git: subcommand allow-list, config and hook injection blocked.
  - Terminal and build/test: no shell, allow-lists, kill on timeout or cancel.
  - HTTP: SSRF guard, every redirect re-validated.
  - `loadImageBlock`.
- **`package:agentic_harness/testing.dart`:** `FakeModelClient`.
