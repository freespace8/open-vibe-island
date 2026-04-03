#!/bin/zsh

set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Open Island smoke runs only on macOS." >&2
    exit 1
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

timestamp="$(date +%Y%m%d-%H%M%S)"
artifact_dir="${OPEN_ISLAND_HARNESS_ARTIFACT_DIR:-$repo_root/output/harness/smoke-$timestamp}"

export OPEN_ISLAND_HARNESS_SCENARIO="${OPEN_ISLAND_HARNESS_SCENARIO:-approvalCard}"
export OPEN_ISLAND_HARNESS_PRESENT_OVERLAY="${OPEN_ISLAND_HARNESS_PRESENT_OVERLAY:-1}"
export OPEN_ISLAND_HARNESS_SHOW_CONTROL_CENTER="${OPEN_ISLAND_HARNESS_SHOW_CONTROL_CENTER:-0}"
export OPEN_ISLAND_HARNESS_START_BRIDGE="${OPEN_ISLAND_HARNESS_START_BRIDGE:-0}"
export OPEN_ISLAND_HARNESS_BOOT_ANIMATION="${OPEN_ISLAND_HARNESS_BOOT_ANIMATION:-0}"
export OPEN_ISLAND_HARNESS_CAPTURE_DELAY_SECONDS="${OPEN_ISLAND_HARNESS_CAPTURE_DELAY_SECONDS:-1}"
export OPEN_ISLAND_HARNESS_AUTO_EXIT_SECONDS="${OPEN_ISLAND_HARNESS_AUTO_EXIT_SECONDS:-2}"
export OPEN_ISLAND_HARNESS_ARTIFACT_DIR="$artifact_dir"

mkdir -p "$artifact_dir"

echo "Launching OpenIslandApp smoke scenario '${OPEN_ISLAND_HARNESS_SCENARIO}' for ${OPEN_ISLAND_HARNESS_AUTO_EXIT_SECONDS}s"
swift run OpenIslandApp

report_path="$artifact_dir/report.json"
if [[ ! -f "$report_path" ]]; then
    echo "Smoke failed: missing harness report at $report_path" >&2
    exit 1
fi

png_count="$(find "$artifact_dir" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')"
if [[ "$png_count" -eq 0 ]]; then
    echo "Smoke failed: no PNG artifacts captured in $artifact_dir" >&2
    exit 1
fi

ax_count="$(find "$artifact_dir" -maxdepth 1 -name '*.ax.json' | wc -l | tr -d ' ')"
if [[ "$ax_count" -eq 0 ]]; then
    echo "Smoke failed: no accessibility artifacts captured in $artifact_dir" >&2
    exit 1
fi

python3 - "$report_path" <<'PY'
import json
import pathlib
import sys

report_path = pathlib.Path(sys.argv[1])
report = json.loads(report_path.read_text())
scenario = (report.get("scenario") or "").lower()
windows = report.get("windows") or []
overlay = next((window for window in windows if window.get("kind") == "overlay"), None)

if overlay is None:
    raise SystemExit("Smoke failed: report is missing an overlay window artifact")

accessibility_path = overlay.get("accessibilityPath")
if not accessibility_path:
    raise SystemExit("Smoke failed: overlay window is missing accessibilityPath")

ax_path = report_path.parent / accessibility_path
if not ax_path.exists():
    raise SystemExit(f"Smoke failed: missing accessibility artifact at {ax_path}")

ax_tree = json.loads(ax_path.read_text())

labels = set()
button_labels = set()

def walk(node):
    label = node.get("label")
    if label:
        labels.add(label)
        role = (node.get("role") or "").lower()
        if "button" in role:
            button_labels.add(label)

    value = node.get("value")
    if isinstance(value, str) and value:
        labels.add(value)

    for child in node.get("children") or []:
        walk(child)

walk(ax_tree)

notch_status = report.get("notchStatus")
if scenario == "approvalcard":
    if notch_status != "opened":
        raise SystemExit(f"Smoke failed: expected opened notch for approvalCard, got {notch_status!r}")

    island_surface = report.get("islandSurface") or ""
    if not island_surface.startswith("approvalCard:"):
        raise SystemExit(f"Smoke failed: expected approvalCard surface, got {island_surface!r}")

    required_buttons = {"Deny"}
    if not required_buttons.issubset(button_labels):
        raise SystemExit(f"Smoke failed: missing required approval button labels {sorted(required_buttons - button_labels)}")

    if not ({"Allow", "Allow Once"} & button_labels):
        raise SystemExit("Smoke failed: missing allow-style approval button label")

print(f"AX labels: {len(labels)} total, buttons: {sorted(button_labels)}")
PY

echo "Artifacts written to $artifact_dir"
echo "OpenIslandApp smoke passed"
