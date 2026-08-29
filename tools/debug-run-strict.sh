#!/usr/bin/env bash
set -u
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/lib"
cp -R "$ROOT/src" "$tmp/lib/"
printf '%s\n' 'sr_ok() { echo FINE; }' > "$tmp/lib/src/features/zz-strict-probe.sh"
printf '%s\n' 'zz-strict-probe.sh' >> "$tmp/lib/src/features/.load-order"
export SYSTUI_TMP_ROOT="$tmp/work"; mkdir -p "$SYSTUI_TMP_ROOT"
export SYSTUI_CONFIG_DIR="$tmp/cfg"
export SYSTUI_LOGFILE="$tmp/log"
SYSTUI_LIBDIR="$tmp/lib" bash -c '
  . "$SYSTUI_LIBDIR/src/core/config.sh"
  . "$SYSTUI_LIBDIR/src/features/zz-strict-probe.sh"
  set +e
  out=$(run_strict probe sr_ok 2>"$SYSTUI_TMP_ROOT/err")
  rc=$?
  printf "RC=%s\n" "$rc"
  printf "OUT=<%s>\n" "$out"
  printf "%s\n" "--- STDERR ---"
  cat "$SYSTUI_TMP_ROOT/err"
  printf "%s\n" "--- MANIFEST ---"
  cat "$SYSTUI_LIBDIR/src/features/.load-order"
  exit 0
'
