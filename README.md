# Vibe Island OSS

An open-source macOS notch and top-bar companion for AI coding agents.

The goal is to build a native Swift app that can monitor local agent sessions, surface permission requests and questions, and jump back into the right terminal or editor context without leaving flow.

## Status

Initial native scaffold is in place. The repository now contains a buildable macOS Swift package with:

- `VibeIslandCore` for shared event and session state logic
- `VibeIslandApp` for the SwiftUI and AppKit shell
- `VibeIslandHooks` for Codex hook ingestion over stdin/stdout
- a local Unix-socket bridge between the app and external hook processes
- core tests for session state transitions

## Supported Scope

The repository support boundary is intentionally narrow for now.

- Supported code agents: `Codex`, `Claude Code`
- Supported terminals: `Terminal.app`, `Ghostty`
- Everything else is out of scope until the user explicitly expands the boundary

Current implementation status inside that boundary:

- `Codex` is the only real adapter wired end to end today
- `Ghostty` and `Terminal.app` are the only terminals that count as supported verification targets
- `Claude Code` is still inside the product boundary, but does not have a real adapter yet
- `Claude Code` now has an experimental usage bridge that can install a managed `statusLine.command`, cache `rate_limits` into `/tmp/vibe-island-rl.json`, and surface the cached 5h/7d quotas in the control center

There may be partial or best-effort code paths for other terminals in the codebase. They are not part of the supported scope, are not acceptance targets, and should not drive roadmap decisions right now.

## Product Direction

- Native macOS app built with SwiftUI and AppKit where needed.
- Local-first communication over Unix sockets or equivalent IPC.
- Keep the supported surface narrow until the first Codex workflow is stable.
- Focus on interaction, not just passive monitoring.

## Initial Milestones

1. `v0.1` Single-agent MVP with real Codex hook monitoring and overlay UI.
2. `v0.2` Approval flow hardening, terminal jump, and install automation.
3. `v0.3` Terminal jump, multi-session state, and external display behavior.
4. `v0.4` Multi-agent adapters and install/setup automation.

## Getting Started

```bash
swift test
swift build
open Package.swift
```

Open the package in Xcode to run the macOS app target. On launch, the app now restores its local cache, scans recent `~/.codex/sessions/**/rollout-*.jsonl` files for existing Codex sessions, and then starts the live bridge for new hook events.

The control center now also shows live Codex hook install status from `~/.codex`, and can install or uninstall the managed hook entries directly if it can locate a local `VibeIslandHooks` executable.

## Claude Usage Bridge

This branch adds a narrow Claude-specific slice without pretending Claude is fully integrated yet.

- The app can inspect `~/.claude/settings.json`
- It can install a managed status line script at `~/.vibe-island/bin/vibe-island-statusline`
- That script caches Claude Code `rate_limits` JSON into `/tmp/vibe-island-rl.json`
- The control center reads the cached file and shows the latest 5-hour and 7-day usage percentages

The installer is intentionally conservative. If `Claude Code` already has a custom `statusLine.command`, Vibe Island reports the conflict and does not overwrite it automatically.

## First Acceptance

The current `v0.1` build is ready for a first acceptance pass. The shortest path is:

1. Run the app from Xcode or `swift run VibeIslandApp`.
2. In the left column, make the `v0.1 Acceptance` card reach at least `3/5`.
3. Install Codex hooks from the app if they are not already installed.
4. Show the island overlay once.
5. Start `codex` from your terminal and wait for the first session row to appear.
6. Trigger one approval or one jump-back action and confirm the island responds.

## Codex Hook MVP

Enable the official Codex hook feature flag once:

```toml
[features]
codex_hooks = true
```

Build the helper once:

```bash
swift build -c release --product VibeIslandHooks
```

Then let the setup tool install or remove the managed Codex hook entries:

```bash
swift run VibeIslandSetup install --hooks-binary "$(pwd)/.build/release/VibeIslandHooks"
swift run VibeIslandSetup status --hooks-binary "$(pwd)/.build/release/VibeIslandHooks"
swift run VibeIslandSetup uninstall
```

The installer:

- enables `[features].codex_hooks = true` if needed
- merges Vibe Island hook handlers into `~/.codex/hooks.json` without deleting unrelated hooks
- replaces older Vibe Island hook commands so Codex does not run duplicate Vibe Island hooks for the same event
- writes a small manifest so uninstall can remove only what Vibe Island added
- creates timestamped backups before rewriting `config.toml` or `hooks.json`

If you want to manage the files yourself, a minimal `~/.codex/hooks.json` shape looks like:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|resume",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/you/path/to/vibe-island/.build/release/VibeIslandHooks"
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/you/path/to/vibe-island/.build/release/VibeIslandHooks"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/you/path/to/vibe-island/.build/release/VibeIslandHooks"
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/Users/you/path/to/vibe-island/.build/release/VibeIslandHooks"
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/Users/you/path/to/vibe-island/.build/release/VibeIslandHooks"
          }
        ]
      }
    ]
  }
}
```

The helper reads the Codex hook payload from `stdin`, forwards it to the app bridge over a Unix socket in `/tmp`, and only writes JSON to `stdout` when the island explicitly denies a `PreToolUse` Bash command. If the app or bridge is unavailable, the hook fails open and Codex keeps running unchanged.

The bridge also respects non-interactive Codex permission modes such as `dontAsk` and `bypassPermissions`, so the island does not insert extra approval prompts when Codex itself is configured to run through.

The app now also keeps a small local Codex session cache under `~/Library/Application Support/open-vibe-island/session-terminals.json`, scans recent `~/.codex/sessions` rollout files on launch, and follows `transcriptPath` rollout files when available. That lets the island recover recent Codex sessions even if they started before the app launched, and keep tracking richer state such as the latest assistant message, current tool, and turn completion beyond the narrow hook edge. The island surface and control center now both prioritize that enriched rollout state instead of only showing the last hook summary line.

## Jump Back

Codex hook ingestion now captures terminal hints from the hook process environment, such as `TERM_PROGRAM`, `ITERM_SESSION_ID`, and Ghostty-specific variables. The island uses those hints to power a best-effort `Jump` action:

- store terminal-specific locators such as Ghostty terminal id and Terminal tty when available
- focus the matching Ghostty terminal or Terminal tab before falling back
- reopen the recorded working directory in that terminal as the final fallback
- keep the existing CLI workflow unchanged even when exact pane restoration is not yet available

## Repository Layout

- `Package.swift` Swift package entry point for the app and shared core module.
- `Sources/VibeIslandCore` Shared models, events, mock scenario, and session state reducer.
- `Sources/VibeIslandCore` also contains the wire protocol, local socket clients, Codex hook models, hook installer logic, and bridge server.
- `Sources/VibeIslandHooks` Hook executable for Codex.
- `Sources/VibeIslandSetup` Installer CLI for Codex feature and hook setup.
- `Sources/VibeIslandApp` SwiftUI app shell, menu bar entry, and overlay panel controller.
- `Tests/VibeIslandCoreTests` Core logic tests.
- `docs/product.md` Product scope, MVP boundary, and roadmap.
- `docs/architecture.md` System shape, event flow, and engineering decisions.

## Principles

- Keep the app local-first. No server dependency for core behavior.
- Build narrow slices end to end before adding more integrations.
- Treat `Codex`, `Claude Code`, `Terminal.app`, and `Ghostty` as the only supported surface area for now.
- Prefer native platform APIs over cross-platform abstractions.
- Treat hooks, IPC, and focus-switching behavior as first-class engineering concerns.
- Keep the Terminal entrypoint unchanged for users. The app should attach to Codex, not replace it.

## Next Step

Shift the default experience further toward the island surface, keep the control center as a diagnostic tool, and harden Codex session recovery and jump accuracy.
