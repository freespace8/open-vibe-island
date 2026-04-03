# Quality And Harness

## Purpose

The repository harness exists to make a round of work mechanically checkable. The current baseline is intentionally small: document structure, package tests, package build, and an opt-in local app smoke path.

## Commands

- `scripts/harness.sh` runs the baseline checks. With no arguments it runs `docs`, `test`, and `build`.
- `scripts/harness.sh ci` is the non-GUI path used by CI.
- `scripts/harness.sh smoke` launches the macOS app in harness mode, loads a deterministic debug scenario, and auto-exits after a short timeout.
- `scripts/check-docs.sh` enforces the minimum doc map and required links.

## Current Guarantees

- Core docs remain present and indexed from [docs/index.md](./index.md).
- Markdown files under `docs/` keep a visible top-level heading.
- `swift test` stays green for the package targets.
- `swift build` stays green for the package products.
- The app can be launched locally in a deterministic harness mode without requiring live hook traffic.

## Smoke Mode

`scripts/smoke-dev-app.sh` sets harness environment variables before launching `OpenIslandApp`.

- `OPEN_ISLAND_HARNESS_SCENARIO` selects a case from `IslandDebugScenario`
- `OPEN_ISLAND_HARNESS_PRESENT_OVERLAY` mirrors the scenario onto the real island overlay
- `OPEN_ISLAND_HARNESS_SHOW_CONTROL_CENTER` controls whether the debug window is frontmost
- `OPEN_ISLAND_HARNESS_START_BRIDGE` skips live socket setup when disabled
- `OPEN_ISLAND_HARNESS_BOOT_ANIMATION` disables the normal boot animation for deterministic runs
- `OPEN_ISLAND_HARNESS_AUTO_EXIT_SECONDS` terminates the app automatically after the selected duration

## Evidence Expectations

Every meaningful round should leave behind:

- passing `scripts/harness.sh ci`
- any additional targeted verification for the changed subsystem
- a short summary of remaining gaps, especially when a GUI-only path was not exercised

## Current Gaps

- CI does not run the GUI smoke step yet because the current baseline avoids depending on a window-server-backed runner path.
- The harness does not yet capture screenshots, accessibility snapshots, or performance traces.
- We do not yet have execution-plan lifecycle automation beyond the directory conventions defined in [docs/exec-plans/README.md](./exec-plans/README.md).
