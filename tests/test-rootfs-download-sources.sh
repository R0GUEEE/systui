#!/usr/bin/env bash
# Rootfs > Download must never dispatch to a function this build does not
# define. Regression: the "Rootfs download sources" hub referenced
# rootfs_source_debian/ubuntu_base/alpine/arch/void/gentoo/linuxcontainers, none
# of which existed, so selecting a distribution printed "command not found" on
# stderr and redrew the hub menu — the reported "selecting a distribution goes
# straight back to the menu" symptom.
#
# Assertions avoid external text tools: this suite also runs on hosts where a
# piped grep can wedge (iSH), and a hanging test is worse than a failing one.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

export SYSTUI_TMP_ROOT="$tmp"
export SYSTUI_LOGFILE="$tmp/systui.log"
export SYSTUI_LIBDIR="$ROOT"

. "$ROOT/src/core/config.sh"
. "$ROOT/src/core/tui-widgets.sh"
. "$ROOT/src/core/common.sh"
. "$ROOT/src/core/loader.sh"

# Load the whole manifest: the point of this test is the state of the *final*
# function graph. Reduced hosts abort the loader for unrelated features, so the
# load itself is not asserted here (test-final-menu-graph.sh owns that).
set +e
systui_load_features "$ROOT/src/features/.load-order"
set -e

checks=0
failures=0
check() {
    local description="$1"
    shift
    checks=$((checks + 1))
    if "$@" >/dev/null 2>&1; then
        printf 'ok %d - %s\n' "$checks" "$description"
    else
        printf 'not ok %d - %s\n' "$checks" "$description"
        failures=$((failures + 1))
    fi
}

module="$ROOT/src/features/zzzzzzzzzzzzzzzzzzzzzzzzzzzz-rootfs-source-adapters.sh"

defines() { declare -F "$1" >/dev/null 2>&1; }
contains() { # <text> <substring>
    case "$1" in *"$2"*) return 0 ;; esac
    return 1
}
file_contains() { # <file> <substring>
    local content
    content=$(cat "$1") || return 1
    contains "$content" "$2"
}
not_contains() { # <text> <substring>
    ! contains "$1" "$2"
}
file_lacks() { # <file> <substring>
    local content
    content=$(cat "$1") || return 1
    not_contains "$content" "$2"
}

# --- every adapter the hub can route to must exist ---------------------------
adapters=(rootfs_source_debian rootfs_source_ubuntu_base rootfs_source_alpine
          rootfs_source_arch rootfs_source_void rootfs_source_gentoo
          rootfs_source_linuxcontainers rootfs_source_dispatch
          rootfs_download_source_hub rootfs_download_live_catalogue)
for fn in "${adapters[@]}"; do
    check "adapter $fn is defined" defines "$fn"
done

# --- the hub must route through the guarded dispatcher -----------------------
declare -f rootfs_download_source_hub > "$tmp/hub.def"
for fn in rootfs_source_debian rootfs_source_ubuntu_base rootfs_source_alpine \
          rootfs_source_arch rootfs_source_void rootfs_source_gentoo \
          rootfs_source_linuxcontainers; do
    check "hub routes $fn through rootfs_source_dispatch" \
        file_contains "$tmp/hub.def" "rootfs_source_dispatch $fn"
done
check "dispatch reports an unavailable adapter" \
    file_contains "$module" 'not available in this build'

# --- catalogue parsing must not depend on a piped grep ----------------------
code=""
while IFS= read -r line; do
    case "$line" in '#'*) continue ;; esac
    code="$code$line"$'\n'
done < "$module"
check "module has no 'printf ... | grep' pipeline" not_contains "$code" '| grep'
declare -f rootfs_web_dirs > "$tmp/webdirs.def"
declare -f rootfs_web_files > "$tmp/webfiles.def"
check "rootfs_web_dirs filters a scratch file" file_contains "$tmp/webdirs.def" rootfs_source_scratch
check "rootfs_web_files filters a scratch file" file_contains "$tmp/webfiles.def" rootfs_source_scratch
declare -f rootfs_source_filter > "$tmp/filter.def"
declare -f rootfs_source_filter_o > "$tmp/filtero.def"
check "line filter is pure Bash" file_lacks "$tmp/filter.def" grep
check "substring filter is pure Bash" file_lacks "$tmp/filtero.def" grep

# --- version-aware selection ------------------------------------------------
newest_ok() {
    local got
    got=$(rootfs_source_newest "$(printf 'x-3.9.0-aarch64.tar.gz\nx-3.23.0-aarch64.tar.gz\n')")
    [ "$got" = "x-3.23.0-aarch64.tar.gz" ]
}
check "newest entry wins by version, not lexically" newest_ok

# --- adapter resolution, offline -------------------------------------------
rootfs_web_dirs() { # <url>
    case "$1" in
        */alpine) printf 'v3.9\nv3.23\nv3.24\nedge\n' ;;
        *) return 1 ;;
    esac
}
rootfs_web_files() { # <url>
    case "$1" in
        */alpine/edge/releases/aarch64) printf 'alpine-minirootfs-3.9.0-aarch64.tar.gz\nalpine-minirootfs-3.24.0-aarch64.tar.gz\n' ;;
        *) return 1 ;;
    esac
}
rootfs_source_pick_arch() { printf 'arm64\n'; }
rootfs_source_pick() { printf '%s\n' "${3%%$'\n'*}"; }
rootfs_download_import_url() { printf '%s\n' "$1" > "$tmp/imported"; }

rootfs_source_alpine
check "Alpine resolves the newest minirootfs" \
    file_contains "$tmp/imported" 'alpine/edge/releases/aarch64/alpine-minirootfs-3.24.0-aarch64.tar.gz'

# --- a menu that captures no selection must be reported ---------------------
unset -f rootfs_source_pick
. "$module"
rootfs_web_pick() { return 0; }
tui_msg() { printf '%s\n' "$1" > "$tmp/no-selection"; }
if rootfs_source_pick "Title" "Prompt" "$(printf 'one\ntwo\n')" "distribution" > "$tmp/picked" 2>/dev/null; then
    check "uncaptured selection fails" false
else
    check "uncaptured selection fails" true
fi
check "uncaptured selection is explained" \
    file_contains "$tmp/no-selection" 'Selection not captured'

printf '\n%d checks, %d failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
