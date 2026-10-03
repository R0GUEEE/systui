#!/usr/bin/env bash
# Guards for the iOS LinuxKit manager feature:
#   * the module is registered and loads before the ARG_MAX cleanup pass;
#   * the System Configuration front door keeps every shipped entry and adds
#     exactly one (so a future base-menu change cannot silently drop a section);
#   * the helpers that decide what to install, what an image is called and what
#     architecture an archive carries behave honestly on partial hosts;
#   * every menu it owns keeps the dialog argument shape (tag/description pairs
#     for tui_menu, triplets for radiolist/checklist) -- the failure mode that
#     has broken these menus more than once.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
module_name='zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-ios-linuxkit-manager.sh'
module="$repo_root/src/features/$module_name"
manifest="$repo_root/src/features/.load-order"
base_file="$repo_root/src/features/96-menu-consolidation-final.sh"

[ -f "$module" ] || { echo "missing $module" >&2; exit 1; }
bash -n "$module"

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf '  ok: %s\n' "$1"; }

###############################################################################
# Manifest wiring
###############################################################################
grep -Fxq "$module_name" "$manifest" || fail 'module is not listed in .load-order'
last=$(grep -vE '^[[:space:]]*(#|$)' "$manifest" | tail -n1)
case "$last" in
    *-rootfs-ish-argmax-cleanup.sh) ;;
    *) fail "ARG_MAX cleanup is no longer last: $last" ;;
esac
mine=$(grep -nFx "$module_name" "$manifest" | cut -d: -f1)
argmax=$(grep -nF "$last" "$manifest" | cut -d: -f1)
[ -n "$mine" ] && [ -n "$argmax" ] && [ "$mine" -lt "$argmax" ] \
    || fail 'module must load before the ARG_MAX cleanup pass'
pass 'manifest ordering'

# The alias helper has to be reachable when the feature is sourced standalone.
grep -Fq 'src/core/alias.sh' "$module" || fail 'missing standalone alias.sh preamble'
pass 'standalone alias preamble'

# Modern features must not export Bash functions.
if grep -nE '^[[:space:]]*export[[:space:]]+-f([[:space:]]|$)' "$module"; then
    fail 'module exports Bash functions'
fi
pass 'no exported functions'

###############################################################################
# System Configuration front door must not drift
###############################################################################
menu_body() { # <file> -> body of menu_sysconfig()
    awk '/^menu_sysconfig\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$1"
}
tags_of() { # stdin -> tag list, one per line (ignores text lines)
    sed -n 's/^[[:space:]]*\([a-z][a-z0-9]*\)[[:space:]]\{1,\}"[^"]*".*/\1/p' | sort
}

base_tags=$(printf '%s\n' "$(menu_body "$base_file")" | tags_of)
mine_tags=$(printf '%s\n' "$(menu_body "$module")" | tags_of)
[ -n "$base_tags" ] || fail 'could not read the shipped System Configuration tags'
[ -n "$mine_tags" ] || fail 'could not read the new System Configuration tags'

# Compare in files rather than process substitution: the regression job runs on
# a shell where /dev/fd may be unavailable, and the comparison is the point.
printf '%s\n' "$base_tags" > "$tmp/base.tags"
printf '%s\n' "$mine_tags" > "$tmp/mine.tags"

missing=$(comm -23 "$tmp/base.tags" "$tmp/mine.tags")
[ -z "$missing" ] || fail "System Configuration dropped entries: $(printf '%s ' $missing)"
added=$(comm -13 "$tmp/base.tags" "$tmp/mine.tags")
[ "$added" = ioskit ] || fail "unexpected new System Configuration entries: $(printf '%s ' $added)"
pass 'System Configuration keeps every shipped entry plus ioskit'

grep -Fq 'menu_ios_linuxkit' "$module" || fail 'ioskit entry is not dispatched'
grep -Fq 'systui_ioskit' "$module" || fail 'manager helpers are missing'
grep -Fq 'rcarmo/ios-linuxkit' "$module" || fail 'upstream reference is missing'
pass 'manager wiring'

###############################################################################
# Helper behaviour (module sourced directly)
###############################################################################
export SYSTUI_IOSKIT_CONF="$tmp/ios-linuxkit.conf"
export SYSTUI_TMP_ROOT="$tmp"
# shellcheck disable=SC1090
. "$module"

# --- configuration round trip -------------------------------------------------
systui_ioskit_conf_set IOSKIT_BRANCH develop || fail 'conf_set rejected a known key'
systui_ioskit_conf_set IOSKIT_SRC_DIR "$tmp/src" || fail 'conf_set rejected a known key'
if systui_ioskit_conf_set NOT_OURS x 2>/dev/null; then fail 'conf_set accepted an unknown key'; fi
if systui_ioskit_conf_set IOSKIT_BRANCH "$(printf 'a\nb')" 2>/dev/null; then
    fail 'conf_set accepted a multi-line value'
fi
unset IOSKIT_BRANCH IOSKIT_SRC_DIR
systui_ioskit_load
[ "$IOSKIT_BRANCH" = develop ] || fail "settings did not reload (branch=$IOSKIT_BRANCH)"
[ "$IOSKIT_SRC_DIR" = "$tmp/src" ] || fail "settings did not reload (src=$IOSKIT_SRC_DIR)"
systui_ioskit_conf_unset IOSKIT_BRANCH
systui_ioskit_load
[ "$IOSKIT_BRANCH" = master ] || fail 'conf_unset did not restore the default'
pass 'settings round trip'

# --- root filesystem pin precedence ------------------------------------------
[ "$(systui_ioskit_rootfs_pin_source)" = 'built-in release pin' ] \
    || fail 'built-in pin is not the last resort'
pin=$(systui_ioskit_rootfs_pin)
case "$pin" in
    https://*' '*[0-9a-f]*) ;;
    *) fail "pin is not url+sha: $pin" ;;
esac
mkdir -p "$IOSKIT_SRC_DIR/app"
cat > "$IOSKIT_SRC_DIR/app/GuestARM64.xcconfig" <<'XCCONFIG'
// ARM64 Guest Architecture Configuration
GUEST_ARCH = arm64
ROOTFS_URL = example.test/alpine/v9/releases/aarch64/minirootfs-9.9-aarch64.tar.gz
ROOTFS_SHA256 = abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789
XCCONFIG
[ "$(systui_ioskit_xcconfig_get ROOTFS_SHA256)" = 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789' ] \
    || fail 'xcconfig parsing failed'
if systui_ioskit_xcconfig_get NOT_A_KEY >/dev/null 2>&1; then
    fail 'xcconfig returned a value for a missing key'
fi
[ "$(systui_ioskit_rootfs_pin_source)" = 'checkout (app/GuestARM64.xcconfig)' ] \
    || fail 'checkout pin did not take precedence over the built-in pin'
IOSKIT_ROOTFS_URL='https://override.test/root.tar.gz'
[ "$(systui_ioskit_rootfs_pin_source)" = 'settings override' ] \
    || fail 'settings did not take precedence over the checkout pin'
unset IOSKIT_ROOTFS_URL
pass 'root filesystem pin precedence'

# --- archive architecture probe (mirrors the app downloader) ------------------
mkdir -p "$tmp/elf/bin"
python3 - "$tmp/elf/bin/busybox" <<'PY'
import struct, sys
h = bytearray()
h += b'\x7fELF' + bytes([2, 1, 1, 0]) + b'\x00' * 8
h += struct.pack('<HHIQQQIHHHHHH', 2, 183, 1, 0, 0, 0, 0, 64, 56, 0, 64, 0, 0)
open(sys.argv[1], 'wb').write(bytes(h))
PY
tar -czf "$tmp/arm.tar.gz" -C "$tmp/elf" ./bin/busybox
[ "$(systui_ioskit_archive_arch "$tmp/arm.tar.gz")" = aarch64 ] \
    || fail 'aarch64 archive was not recognised'
tar -czf "$tmp/empty.tar.gz" -C "$tmp" ioskit-does-not-exist 2>/dev/null || true
[ "$(systui_ioskit_archive_arch "$tmp/empty.tar.gz")" = unknown ] \
    || fail 'an archive without bin/busybox must probe as unknown'
pass 'archive architecture probe'

# --- image names --------------------------------------------------------------
for good in alpine-arm64-fakefs rootfs_v2 a b; do
    systui_ioskit_image_name_ok "$good" || fail "valid image name rejected: $good"
done
for bad in '' '.' '..' '../escape' 'a/b' '/abs'; do
    if systui_ioskit_image_name_ok "$bad"; then fail "unsafe image name accepted: $bad"; fi
done
pass 'image name validation'

# --- package mapping ----------------------------------------------------------
[ "$(systui_ioskit_pkg_for ninja apk)" = ninja-build ] || fail 'Alpine ninja mapping is wrong'
[ "$(systui_ioskit_pkg_for ninja pacman)" = ninja ] || fail 'pacman ninja mapping is wrong'
[ "$(systui_ioskit_pkg_for pkg-config apk)" = pkgconf ] || fail 'Alpine pkg-config mapping is wrong'
[ "$(systui_ioskit_pkg_for pkg-config apt)" = pkg-config ] || fail 'Debian pkg-config mapping is wrong'
[ -z "$(systui_ioskit_pkg_for clang unknownpm)" ] || fail 'unknown managers must not invent package names'
pass 'package name mapping'

# --- honest missing-requirement reporting ------------------------------------
(
    empty="$tmp/emptypath"
    mkdir -p "$empty"
    PATH="$empty"
    PM=apk
    # Every probe now reports missing, not unknown, because nothing is on PATH.
    reqs=$(systui_ioskit_missing_requirements)
    case "$reqs" in
        *'git git'*) ;;
        *) echo "missing git was not reported with its package" >&2; exit 1 ;;
    esac
    case "$reqs" in
        *'sqlite3-dev -'*) ;;
        *) echo "unavailable dev library was not reported honestly" >&2; exit 1 ;;
    esac
    plan=$(systui_ioskit_install_plan)
    case "$plan" in
        *ninja-build*) ;;
        *) echo "install plan omitted the mapped package name" >&2; exit 1 ;;
    esac
    for pkg in $plan; do
        if [ "$pkg" = '-' ]; then
            echo "install plan leaked a placeholder as a package" >&2
            exit 1
        fi
    done
)
pass 'missing requirements are reported honestly'

(
    empty="$tmp/emptypath2"
    mkdir -p "$empty"
    PATH="$empty"
    PM=''
    if systui_ioskit_install_plan >/dev/null 2>&1; then
        echo 'an unknown package manager produced an install plan' >&2
        exit 1
    fi
)
pass 'unknown package manager produces no install plan'

(
    empty="$tmp/emptypath3"
    mkdir -p "$empty"
    # A pkg-config binary that exists but reports nothing: the dev library is
    # "missing", never "unknown".
    cat > "$empty/pkg-config" <<'STUB'
#!/bin/sh
exit 1
STUB
    chmod +x "$empty/pkg-config"
    PATH="$empty"
    [ "$(systui_ioskit_devlib_state sqlite3)" = missing ] || \
        { echo 'dev library state was not missing' >&2; exit 1; }
)
pass 'dev library state distinguishes missing from unknown'

###############################################################################
# Menu argument shape
###############################################################################
(
    # shellcheck disable=SC1090
    . "$module"
    tui_text() { :; }
    tui_msg() { :; }
    tui_yesno() { return 1; }
    tui_input() { return 1; }
    # tui_capture_menu is called as: dest widget title text tag desc tag desc ...
    tui_capture_menu() {
        local dest="$1"
        shift 2
        [ "$#" -ge 2 ] || { echo 'menu without a title and text' >&2; return 9; }
        local rest=$(( $# - 2 ))
        if [ $(( rest % 2 )) -ne 0 ]; then
            echo "tui_capture_menu received $rest entry arguments (expected pairs)" >&2
            return 9
        fi
        printf -v "$dest" '%s' back
    }
    # tui_menu is called as: title text tag desc tag desc ...
    tui_menu() {
        local title="$1"
        shift 2
        if [ $(( $# % 2 )) -ne 0 ]; then
            echo "tui_menu received $# entry arguments (expected pairs)" >&2
            return 9
        fi
        printf '%s\n' "${1:-}"
    }

    for fn in menu_ios_linuxkit systui_ioskit_source_menu systui_ioskit_build_menu \
              systui_ioskit_images_menu systui_ioskit_run_menu \
              systui_ioskit_maintenance_menu systui_ioskit_settings_menu \
              menu_sysconfig; do
        "$fn" || { echo "$fn failed under the stubbed widgets" >&2; exit 1; }
    done

    IOSKIT_IMAGES_DIR="$tmp/images"
    mkdir -p "$IOSKIT_IMAGES_DIR/alpha"
    [ "$(systui_ioskit_choose_image)" = alpha ] || { echo 'image chooser returned the wrong tag' >&2; exit 1; }
    [ "$(systui_ioskit_choose_image allow-host)" = alpha ] || { echo 'image chooser lost the host option shape' >&2; exit 1; }
    mkdir -p "$tmp/no-images"
    IOSKIT_IMAGES_DIR="$tmp/no-images"
    if systui_ioskit_choose_image >/dev/null 2>&1; then
        echo 'empty image list should fail' >&2
        exit 1
    fi
)
pass 'menus keep the dialog argument shape'

###############################################################################
# The shipped System Configuration menu is preserved under an alias
###############################################################################
(
    # shellcheck disable=SC1090
    menu_sysconfig() { :; }
    . "$module"
    declare -F _systui_menu_sysconfig_before_ioskit >/dev/null \
        || { echo 'the shipped System Configuration menu was not preserved' >&2; exit 1; }
)
pass 'shipped menu preserved under an alias'

printf 'PASS: iOS LinuxKit manager\n'
