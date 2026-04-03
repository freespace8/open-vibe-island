# Architecture Notes

## System Shape

The project will likely split into three layers:

1. `macOS app`
   Renders the notch or top-bar UI, owns state presentation, and handles user interaction.
2. `bridge`
   Receives agent events locally and exposes a stable event stream to the app.
3. `agent adapters`
   Translate tool-specific hooks or config into a shared event model.

## Initial Event Model

The shared model should support:

- session started
- session updated
- permission requested
- question asked
- session completed
- jump target updated

Each event should carry a stable session identifier, tool name, timestamps, and enough metadata to route approvals or focus changes.

## Likely Technologies

- SwiftUI for most UI composition
- AppKit for panel behavior, status item control, and activation policy edge cases
- Unix domain sockets or local stream IPC for app and bridge communication
- JSON event envelopes for debugging and adapter simplicity

## Current Slice

The current bridge server still lives inside the app process for convenience, but the transport boundary is now real:

1. Codex runs in the user’s existing terminal session.
2. Codex invokes a repo-built `OpenIslandHooks` helper from `hooks.json`.
3. The helper forwards hook payloads to the app bridge over a Unix socket.
4. The app consumes normalized `AgentEvent` values from that socket. The same bridge can also carry approval commands back to hook processes when an adapter opts into interactive hooks.
5. A separate setup CLI owns `config.toml` and `hooks.json` edits so installation and rollback stay explicit and reversible.
6. The app persists recent Codex sessions into a local session cache, scans recent `~/.codex/sessions` rollouts on launch for cold-start recovery, and follows `transcriptPath` rollout files to enrich state after the initial hook ingress.

The default managed Codex hook install intentionally stays small to match the original app and keep terminal noise down:

- `SessionStart`
- `UserPromptSubmit`
- `Stop`

`PreToolUse` and `PostToolUse` are still supported by the bridge protocol, but they are not installed by default because they fire on every Bash tool call and create a large amount of hook log output.

The supported surface area is intentionally narrower than the current source tree might suggest:

- supported code agents: `Codex`, `Claude Code`
- supported terminals: `Terminal.app`, `Ghostty`
- currently implemented real adapter: `Codex` only

For the planned Claude adapter runtime model and matching strategy, see [claude-code-runtime-plan.md](./claude-code-runtime-plan.md).

If other terminal or agent-specific code paths exist, treat them as experiments or fallback scaffolding, not committed support.

The hook helper also enriches Codex payloads with local runtime hints from the terminal environment. That allows the app to record a probable terminal app, working directory, and terminal-specific locators such as iTerm session IDs or Terminal TTYs even though Codex hooks do not directly expose a native macOS window handle.

When `PreToolUse` is enabled for an interactive adapter, the hook helper waits for the bridge response. If the island denies the request, the helper writes the blocking JSON shape that Codex already understands. If the app is unavailable, the helper fails open so the terminal flow remains unchanged.

The current Codex slice is now three-stage:

1. startup discovery scans recent local rollout JSONL files to recover existing Codex sessions before any new hook fires
2. hooks bootstrap or refresh the session identity, terminal mapping, and transcript path
3. a local rollout watcher tails the transcript JSONL file to recover richer state such as assistant commentary, current tool, and turn completion

## Suggested Build Order

1. Define the shared event schema
2. Keep Codex terminal entry unchanged and attach through hooks
3. Harden the approval loop for `PreToolUse`
4. Add install automation and terminal focus restoration

## Open Questions

- When should the bridge become a standalone launch agent or helper process?
- How should we install and rollback `hooks.json` safely for users?
- How much terminal-jump accuracy is possible without private APIs?
- Which permissions are required for reliable focus restoration across terminals and IDEs?

## Engineering Rules

- Preserve a clean separation between UI state and transport concerns.
- Version the event schema early so adapters can evolve safely.
- Keep setup reversible when editing third-party tool config files.
- Keep the runtime surface bound to real agent state rather than shipping UI-level demo toggles.
