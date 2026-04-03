# Open Island

> 我不想在自己的电脑上运行一个闭源、付费的软件来监视我所有的生产过程。<br>
> 所以我 build 了这个开源的版本。<br>
>
> you don’t need to pay for a product you can vibe since you are a vibe coder

The open-source macOS companion for terminal-native AI coding.

`Open Island` puts a lightweight control surface in your notch or top bar so you can keep an eye on live coding agents, follow session progress, and jump back to the right terminal without breaking flow.

## Why This Product Exists

AI coding is becoming part of the daily development loop, but the surrounding control layer still too often means handing your machine over to a closed-source paid app.

`Open Island` takes the opposite approach:

- open source
- local first
- native on macOS
- built to support the terminal workflow, not replace it

## Who It Is For

This is for developers who already live in the terminal and want a better way to work with coding agents on macOS without losing context.

## What You Get

- a small native island for live agent activity
- fast visibility into active Codex sessions
- quicker return to the active terminal context
- a companion experience that stays out of the way until it matters

## Current Product Shape

Right now `Open Island` is focused on one thing: making the Codex-on-macOS workflow feel more native.

Current scope:

- macOS only
- Codex first
- experimental Claude Code usage status
- passive Codex account usage status from local rollout files
- live session visibility
- low-noise Codex hook install
- jump-back behavior

## Available Today

Today the project can already:

- receive Codex hook events locally
- surface session and approval state in the app
- restore recent Codex sessions from local rollout files and cache
- read Codex 5-hour and 7-day account windows from the latest local `token_count` rollout event
- install and uninstall managed Codex hooks from `~/.codex`
- inspect `~/.claude/settings.json` and install a managed Claude usage bridge when no custom status line exists
- read cached Claude 5-hour and 7-day usage windows in the UI
- use terminal hints for best-effort jump back behavior

The managed Codex install keeps the same low-noise footprint and only installs `SessionStart`, `UserPromptSubmit`, and `Stop` hooks by default. The bridge still supports richer interactive hooks, but they are not enabled by default because `PreToolUse` and `PostToolUse` create a lot of terminal noise during normal Codex use.

The Claude bridge is intentionally conservative. It writes a managed `statusLine.command` to `~/.open-island/bin/open-island-statusline`, caches `rate_limits` into `/tmp/open-island-rl.json`, and refuses to overwrite an existing custom Claude status line automatically.

## Quick Start

Build and run locally:

```bash
swift test
swift build
open Package.swift
```

Connect Codex:

Open the package in Xcode to run the macOS app target. On launch, the app restores its local cache, scans recent `~/.codex/sessions/**/rollout-*.jsonl` files for existing Codex sessions, and then starts the live bridge for new hook events.

The control center also shows live Codex hook install status from `~/.codex`, and can install or uninstall the managed hook entries directly if it can locate a local `OpenIslandHooks` executable. Claude usage setup is available from the app and remains opt-in.

```toml
[features]
codex_hooks = true
```

```bash
swift build -c release --product OpenIslandHooks
swift run OpenIslandSetup install --hooks-binary "$(pwd)/.build/release/OpenIslandHooks"
```

That setup enables `codex_hooks = true` and installs a low-noise hook set matching the original app's Codex integration: `SessionStart`, `UserPromptSubmit`, and `Stop`.

Check or remove the setup later:

```bash
swift run OpenIslandSetup status --hooks-binary "$(pwd)/.build/release/OpenIslandHooks"
swift run OpenIslandSetup uninstall
```

## Product Direction

The goal is simple: make AI coding feel native on macOS.

That means:

- less context switching
- less tab hunting
- less friction around session awareness
- a faster path back to the active agent session

## Roadmap

1. Ship a solid single-agent macOS MVP
2. Harden approvals and jump-back behavior
3. Improve multi-session handling
4. Expand to more agent integrations over time

## Contributing

Issues and pull requests are welcome. Small focused changes are preferred.
