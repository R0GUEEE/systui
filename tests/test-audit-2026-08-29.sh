#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
checks=0
failures=0
check() {
    local desc="$1"; shift
    checks=$((checks + 1))
    if "$@"; then
        printf 'ok %d - %s\n' "$checks" "$desc"
    else
        printf 'not ok %d - %s\n' "$checks" "$desc"
        failures=$((failures + 1))
    fi
}

check "run_cmd preserves errexit=off" bash -c '
    set +e
    LOGFILE=$(mktemp); trap '\''rm -f "$LOGFILE"'\'' EXIT
    log(){ :; }; clear(){ :; }; tee(){ command tee "$@"; }
    . "$1/src/core/tui-widgets.sh"
    run_cmd ok true >/dev/null
    case $- in *e*) exit 1;; *) exit 0;; esac
' _ "$PROJECT_DIR"

check "run_cmd preserves errexit=on" bash -c '
    set -e
    LOGFILE=$(mktemp); trap '\''rm -f "$LOGFILE"'\'' EXIT
    log(){ :; }; clear(){ :; }
    . "$1/src/core/tui-widgets.sh"
    run_cmd ok true >/dev/null
    case $- in *e*) exit 0;; *) exit 1;; esac
' _ "$PROJECT_DIR"

check "no pacman partial-upgrade refresh remains" bash -c '
    hits=$(grep -RInE --include="*.sh" --exclude-dir=tests --exclude-dir=.git \
      "pacman[[:space:]]+-Sy([[:space:]]|$)" \
      "$1/install.sh" "$1/update.sh" "$1/src" "$1/share" 2>/dev/null \
      | grep -vE "pacman[[:space:]]+-Syu([[:space:]]|$)" || true)
    [ -z "$hits" ]
' _ "$PROJECT_DIR"

check "Homebrew no longer uses LD_PRELOAD fake UID shim" bash -c '
    ! grep -Eq "LD_PRELOAD|fakeuid|getresuid|getresgid" "$1/share/homebrew/install-homebrew-root.sh"
' _ "$PROJECT_DIR"

check "Homebrew wrapper drops root privileges" bash -c '
    grep -Eq "runuser -u|sudo -H -u" "$1/share/homebrew/install-homebrew-root.sh"
' _ "$PROJECT_DIR"

check "updater uses fixed root-owned cache" bash -c '
    grep -Fq '\''CACHE_DIR="/var/lib/systui/source"'\'' "$1/update.sh" &&
    ! grep -Fq '\''SYSTUI_UPDATE_CACHE'\'' "$1/update.sh" &&
    grep -Fq '\''.systui-update-cache'\'' "$1/update.sh" &&
    grep -Fq '\''Refusing to recursively remove untrusted update cache'\'' "$1/update.sh" &&
    grep -Fq '\''chown -R root:root "$CACHE_DIR"'\'' "$1/update.sh"
' _ "$PROJECT_DIR"

check "updater never executes install.sh from recorded user checkout" bash -c '
    ! grep -Fq '\''"$SOURCE_DIR/install.sh"'\'' "$1/update.sh"
' _ "$PROJECT_DIR"

check "CI workflow exists" test -f "$PROJECT_DIR/.github/workflows/ci.yml"

printf '%s checks, %s failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
