#!/usr/bin/env bash
# Static menu audit: every menu option must have a dispatch arm, every dispatch
# arm must come from a menu, and every tui_call_menu target must exist.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TOOL="$ROOT/tools/menu-audit.py"

[ -f "$TOOL" ] || { echo 'menu-audit.py is missing' >&2; exit 1; }

if ! command -v python3 >/dev/null 2>&1; then
    echo 'skip: python3 is not available'
    exit 0
fi

out=$(python3 "$TOOL" --check) || {
    printf '%s\n' "$out" >&2
    echo 'menu audit found errors (dead entries / unreachable arms / missing targets)' >&2
    exit 1
}

printf '%s\n' "$out" | grep -q 'dead entries: 0'
printf '%s\n' "$out" | grep -q 'unreachable handlers: 0'
printf '%s\n' "$out" | grep -q 'missing dispatch targets: 0'

echo 'ok - every menu option has a handler and every dispatch target exists'
