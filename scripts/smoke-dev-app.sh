#!/bin/zsh

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Open Island smoke runs only on macOS." >&2
    exit 1
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

export OPEN_ISLAND_HARNESS_SCENARIO="${OPEN_ISLAND_HARNESS_SCENARIO:-approvalCard}"
export OPEN_ISLAND_HARNESS_PRESENT_OVERLAY="${OPEN_ISLAND_HARNESS_PRESENT_OVERLAY:-1}"
export OPEN_ISLAND_HARNESS_SHOW_CONTROL_CENTER="${OPEN_ISLAND_HARNESS_SHOW_CONTROL_CENTER:-0}"
export OPEN_ISLAND_HARNESS_START_BRIDGE="${OPEN_ISLAND_HARNESS_START_BRIDGE:-0}"
export OPEN_ISLAND_HARNESS_BOOT_ANIMATION="${OPEN_ISLAND_HARNESS_BOOT_ANIMATION:-0}"
export OPEN_ISLAND_HARNESS_AUTO_EXIT_SECONDS="${OPEN_ISLAND_HARNESS_AUTO_EXIT_SECONDS:-2}"

echo "Launching OpenIslandApp smoke scenario '${OPEN_ISLAND_HARNESS_SCENARIO}' for ${OPEN_ISLAND_HARNESS_AUTO_EXIT_SECONDS}s"
swift run OpenIslandApp
echo "OpenIslandApp smoke passed"
