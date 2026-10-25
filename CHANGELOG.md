# Changelog

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
