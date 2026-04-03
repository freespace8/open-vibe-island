# Quality And Harness

## Purpose

The repository harness exists to make a round of work mechanically checkable. The current baseline is intentionally small: document structure, package tests, package build, and an opt-in local app smoke path.

## Commands

- `scripts/harness.sh` runs the baseline checks. With no arguments it runs `docs`, `test`, and `build`.
- `scripts/harness.sh ci` is the non-GUI path used by CI.
- `scripts/harness.sh smoke` launches the macOS app in harness mode, loads a deterministic debug scenario, captures local artifacts, and auto-exits after a short timeout.
- `scripts/check-docs.sh` enforces the minimum doc map and required links.

## Current Guarantees

- Core docs remain present and indexed from [docs/index.md](./index.md).
- Markdown files under `docs/` keep a visible top-level heading.
- `swift test` stays green for the package targets.
- `swift build` stays green for the package products.
- The app can be launched locally in a deterministic harness mode without requiring live hook traffic.
- The smoke path produces a machine-readable report plus PNG and accessibility evidence for the rendered window surface.

## Smoke Mode

`scripts/smoke-dev-app.sh` sets harness environment variables before launching `OpenIslandApp`.

The smoke path is intentionally aimed at the repository executable, not `~/Applications/Open Island Dev.app`. The dev bundle remains useful for manual end-to-end OSS verification, but harness automation should target the current branch's `OpenIslandApp` binary so the verification result matches the checked-out code exactly.

- `OPEN_ISLAND_HARNESS_SCENARIO` selects a case from `IslandDebugScenario`
- `OPEN_ISLAND_HARNESS_PRESENT_OVERLAY` mirrors the scenario onto the real island overlay
- `OPEN_ISLAND_HARNESS_SHOW_CONTROL_CENTER` controls whether the debug window is frontmost
- `OPEN_ISLAND_HARNESS_START_BRIDGE` skips live socket setup when disabled
- `OPEN_ISLAND_HARNESS_BOOT_ANIMATION` disables the normal boot animation for deterministic runs
- `OPEN_ISLAND_HARNESS_CAPTURE_DELAY_SECONDS` controls when artifact capture runs after launch
- `OPEN_ISLAND_HARNESS_AUTO_EXIT_SECONDS` terminates the app automatically after the selected duration
- `OPEN_ISLAND_HARNESS_ARTIFACT_DIR` selects the output directory for `report.json`, PNG captures, and `.ax.json` accessibility snapshots

The default smoke path writes artifacts under `output/harness/`.

For the default `approvalCard` smoke scenario, the harness now performs a minimal semantic check against the accessibility snapshot:

- overlay artifact exists
- notch stays open
- active surface is an approval card
- accessibility tree contains `Deny` plus an allow-style button label

## Evidence Expectations

Every meaningful round should leave behind:

- passing `scripts/harness.sh ci`
- any additional targeted verification for the changed subsystem
- a short summary of remaining gaps, especially when a GUI-only path was not exercised

## Current Gaps

- CI does not run the GUI smoke step yet because the current baseline avoids depending on a window-server-backed runner path.
- The harness does not yet capture performance traces, and the current accessibility assertions are still scenario-specific rather than full golden snapshots.
- We do not yet have execution-plan lifecycle automation beyond the directory conventions defined in [docs/exec-plans/README.md](./exec-plans/README.md).
