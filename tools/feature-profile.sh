#!/usr/bin/env bash
###############################################################################
# systui feature load profiler
#
# Times every feature in src/features/.load-order while loading it exactly the
# way the loader does, so startup optimizations can be measured instead of
# guessed. Uses $EPOCHREALTIME (bash 5) to avoid one fork per feature, which
# would otherwise dominate the measurement on constrained hosts.
#
# Usage:
#   tools/feature-profile.sh [--top N] [--csv FILE] [--manifest FILE]
#   SYSTUI_SCRUB_FUNCTION_EXPORTS=0 tools/feature-profile.sh
###############################################################################

set -u

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
MANIFEST="$ROOT/src/features/.load-order"
TOP=20
CSV=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --top) TOP="$2"; shift 2 ;;
        --csv) CSV="$2"; shift 2 ;;
        --manifest) MANIFEST="$2"; shift 2 ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[ -r "$MANIFEST" ] || { printf 'missing manifest: %s\n' "$MANIFEST" >&2; exit 1; }

if [ -z "${EPOCHREALTIME:-}" ]; then
    printf 'warning: bash 5 EPOCHREALTIME is unavailable; falling back to SECONDS\n' >&2
fi

now() {
    if [ -n "${EPOCHREALTIME:-}" ]; then
        printf '%s\n' "${EPOCHREALTIME/./}"
    else
        printf '%s000000\n' "$SECONDS"
    fi
}

export SYSTUI_LIBDIR="$ROOT"
export SYSTUI_TMP="${SYSTUI_TMP:-$(mktemp -d)}"
export LOGFILE="$SYSTUI_TMP/profile.log"
export DIALOG="${DIALOG:-true}"
export BACKTITLE="systui profile"
export PATH="$SYSTUI_TMP/bin:$PATH"
mkdir -p "$SYSTUI_TMP/bin"
# Keep external probes inside the profile env (systemctl, brl, pm tools, ...).
for stub in systemctl brl systemd-run pacman apt-get apk dnf zypper xbps-install emerge rcd status; do
    [ -e "$SYSTUI_TMP/bin/$stub" ] || {
        printf '#!/bin/sh\nexit 1\n' > "$SYSTUI_TMP/bin/$stub"
        chmod +x "$SYSTUI_TMP/bin/$stub"
    }
done

. "$ROOT/src/core/config.sh" >/dev/null 2>&1
. "$ROOT/src/core/tui-widgets.sh" >/dev/null 2>&1
. "$ROOT/src/core/common.sh" >/dev/null 2>&1
. "$ROOT/src/core/loader.sh" >/dev/null 2>&1

report="$SYSTUI_TMP/profile.txt"
: > "$report"
[ -z "$CSV" ] || : > "$CSV"

total_start=$(now)
count=0
while IFS= read -r rel || [ -n "$rel" ]; do
    case "$rel" in ''|'#'*) continue ;; esac
    feature="$ROOT/src/features/$rel"
    [ -f "$feature" ] || continue
    start=$(now)
    # shellcheck disable=SC1090
    . "$feature" >/dev/null 2>&1
    end=$(now)
    cost=$(( (end - start) / 1000 ))
    printf '%8s  %s\n' "$cost" "$rel" >> "$report"
    [ -z "$CSV" ] || printf '%s;%s\n' "$cost" "$rel" >> "$CSV"
    count=$((count + 1))
done < "$MANIFEST"
total_end=$(now)
total_ms=$(( (total_end - total_start) / 1000 ))

printf 'features: %s   total: %s ms\n' "$count" "$total_ms"
printf '\nslowest %s features (ms):\n' "$TOP"
sort -rn "$report" | head -n "$TOP"
printf '\nall feature times: %s\n' "$report"
[ -z "$CSV" ] || printf 'csv: %s\n' "$CSV"
