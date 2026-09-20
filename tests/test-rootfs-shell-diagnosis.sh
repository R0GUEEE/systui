#!/usr/bin/env bash
# Rootfs shell entry diagnosis and repair.
#
# Regressions covered:
#   * "/bin/sh -> /usr/bin/dash" (an absolute target INSIDE the rootfs) was
#     resolved against the HOST root, so a healthy tree was reported as having
#     no executable /bin/sh — and the same expression gates the
#     incomplete-bootstrap predicate, which could send it to base recovery;
#   * a file without an execute bit is reported as executable on iSH when
#     running as root, so a tree that cannot actually be entered passed the old
#     check;
#   * the old message was a dead end: it never said whether the entry was
#     missing, dangling or merely stripped of its mode bits, and offered no fix.
#
# Assertions avoid external text tools (a piped grep can wedge on iSH).
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

export SYSTUI_TMP_ROOT="$tmp"
export SYSTUI_LOGFILE="$tmp/systui.log"
export SYSTUI_LIBDIR="$ROOT"
ROOTFS_BASE="$tmp/rootfs"
export ROOTFS_BASE

. "$ROOT/src/core/config.sh"
. "$ROOT/src/core/tui-widgets.sh"
. "$ROOT/src/core/common.sh"
. "$ROOT/src/core/loader.sh"

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
is_true() { "$@"; }
is_false() { ! "$@"; }
text_has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# --- fixtures ---------------------------------------------------------------
mk_tree() { # <name> -> path
    local d="$ROOTFS_BASE/$1"
    rm -rf -- "$d"
    mkdir -p "$d/bin" "$d/usr/bin" "$d/etc" "$d/proc" "$d/sys" "$d/dev/pts" "$d/run" "$d/tmp"
    printf '%s\n' "$d"
}

rel_ok=$(mk_tree rel-ok)
: > "$rel_ok/bin/dash"; chmod +x "$rel_ok/bin/dash"; ln -s dash "$rel_ok/bin/sh"

abs_link=$(mk_tree abs-link)
: > "$abs_link/usr/bin/dash"; chmod +x "$abs_link/usr/bin/dash"; ln -s /usr/bin/dash "$abs_link/bin/sh"

usrmerge=$(mk_tree usrmerge)
rmdir "$usrmerge/bin"; ln -s usr/bin "$usrmerge/bin"
: > "$usrmerge/usr/bin/dash"; chmod +x "$usrmerge/usr/bin/dash"; ln -s dash "$usrmerge/usr/bin/sh"

dangling=$(mk_tree dangling)
ln -s dash "$dangling/bin/sh"

dangling_bash=$(mk_tree dangling-bash)
: > "$dangling_bash/bin/bash"; chmod +x "$dangling_bash/bin/bash"; ln -s dash "$dangling_bash/bin/sh"

noexec=$(mk_tree noexec)
printf '#!/bin/sh\necho hello\n' > "$noexec/bin/sh"; chmod 644 "$noexec/bin/sh"

missing_entry=$(mk_tree missing-entry)
: > "$missing_entry/bin/dash"; chmod +x "$missing_entry/bin/dash"

no_bin=$(mk_tree no-bin)
rmdir "$no_bin/bin"
: > "$no_bin/usr/bin/dash"; chmod +x "$no_bin/usr/bin/dash"

noshell=$(mk_tree noshell)

loop_tree=$(mk_tree link-loop)
ln -s dash "$loop_tree/bin/sh"; ln -s sh "$loop_tree/bin/dash"

# --- state detection --------------------------------------------------------
status_of() { # <target>
    local state
    state=$(rootfs_wb_shell_state "$1") || true
    printf '%s\n' "${state%%|*}"
}

check "relative link is ok" \
    is_true text_has "$(status_of "$rel_ok")" ok
check "absolute in-tree link is ok (host -x would say no)" \
    is_true text_has "$(status_of "$abs_link")" ok
check "usrmerge tree is ok" \
    is_true text_has "$(status_of "$usrmerge")" ok
check "dangling link is reported as dangling" \
    is_true text_has "$(status_of "$dangling")" dangling
check "missing entry is reported as missing" \
    is_true text_has "$(status_of "$missing_entry")" missing
check "missing /bin is reported" \
    is_true text_has "$(status_of "$no_bin")" missing
check "a file without an execute bit is reported as noexec" \
    is_true text_has "$(status_of "$noexec")" noexec
check "a tree with no shell at all is reported as noshell" \
    is_true text_has "$(status_of "$noshell")" noshell
check "a symlink cycle is reported as a loop" \
    is_true text_has "$(status_of "$loop_tree")" loop
check "a symlink cycle is not usable" is_false rootfs_wb_shell_usable "$loop_tree"

check "healthy tree is usable" is_true rootfs_wb_shell_usable "$rel_ok"
check "absolute in-tree link is usable" is_true rootfs_wb_shell_usable "$abs_link"
check "non-executable entry is not usable" is_false rootfs_wb_shell_usable "$noexec"
check "dangling entry is not usable" is_false rootfs_wb_shell_usable "$dangling"

# The host's own [ -x ] disagrees for the absolute-link tree: that mismatch is
# exactly what used to be reported to the user as "no executable /bin/sh".
if [ -x "$abs_link/bin/sh" ]; then
    check "host -x is unreliable here (documented)" true
else
    check "in-tree resolution disagrees with host -x as expected" \
        is_true rootfs_wb_shell_usable "$abs_link"
fi

# --- explanations -----------------------------------------------------------
check "noexec explanation names the execute bit" \
    is_true text_has "$(rootfs_wb_shell_explain "$noexec")" "not executable"
check "dangling explanation names the broken link" \
    is_true text_has "$(rootfs_wb_shell_explain "$dangling")" "broken link"
check "noshell explanation says the tree is incomplete" \
    is_true text_has "$(rootfs_wb_shell_explain "$noshell")" "incomplete"

# --- repair -----------------------------------------------------------------
check "repair fixes the execute bit" is_true rootfs_wb_shell_repair "$noexec"
check "repaired entry is usable" is_true rootfs_wb_shell_usable "$noexec"

check "repair creates a missing entry" is_true rootfs_wb_shell_repair "$missing_entry"
check "created entry is usable" is_true rootfs_wb_shell_usable "$missing_entry"
check "created entry is a relative link to the shell" \
    is_true text_has "$(readlink "$missing_entry/bin/sh")" dash

check "repair re-points a dangling link" is_true rootfs_wb_shell_repair "$dangling_bash"
check "re-pointed entry is usable" is_true rootfs_wb_shell_usable "$dangling_bash"

check "repair restores a dropped usrmerge /bin link" is_true rootfs_wb_shell_repair "$no_bin"
check "usrmerge entry is usable after repair" is_true rootfs_wb_shell_usable "$no_bin"

check "repair leaves a healthy tree alone" is_true rootfs_wb_shell_repair "$rel_ok"
check "healthy tree still resolves to /bin/dash" \
    is_true text_has "$(rootfs_wb_shell_state "$rel_ok")" "/bin/dash"

check "repair refuses when no shell exists" is_false rootfs_wb_shell_repair "$noshell"
check "nothing was invented for the shell-less tree" \
    is_false test -e "$noshell/bin/sh"

# --- the prompt path --------------------------------------------------------
tui_msg() { printf '%s\n' "$2" > "$tmp/msg"; }
tui_yesno() { return 0; }
check "prompt repairs an unusable tree" is_true rootfs_wb_shell_check_prompt "$dangling_bash"
unset -f tui_yesno
tui_yesno() { return 1; }
check "prompt does not claim success when declined on a shell-less tree" \
    is_false rootfs_wb_shell_check_prompt "$noshell"
unset -f tui_msg tui_yesno

# --- the bootstrap predicate must not fire for a healthy tree ---------------
debian_tree=$(mk_tree debian-abs-link)
: > "$debian_tree/bin/dpkg"; chmod +x "$debian_tree/bin/dpkg"
: > "$debian_tree/usr/bin/dash"; chmod +x "$debian_tree/usr/bin/dash"
: > "$debian_tree/usr/bin/apt-get"; chmod +x "$debian_tree/usr/bin/apt-get"
mkdir -p "$debian_tree/usr/lib/aarch64-linux-gnu"
: > "$debian_tree/usr/lib/aarch64-linux-gnu/libc.so.6"
rm -f "$debian_tree/bin/sh"; ln -s /usr/bin/dash "$debian_tree/bin/sh"
printf 'ID=debian\nVERSION_CODENAME=trixie\n' > "$debian_tree/etc/os-release"
check "a healthy Debian tree with an absolute /bin/sh link is not 'incomplete'" \
    is_false rootfs_deb_base_incomplete "$debian_tree"

broken_tree=$(mk_tree debian-broken)
: > "$broken_tree/bin/dpkg"; chmod +x "$broken_tree/bin/dpkg"
: > "$broken_tree/bin/sh"; chmod +x "$broken_tree/bin/sh"
printf 'ID=debian\nVERSION_CODENAME=trixie\n' > "$broken_tree/etc/os-release"
check "a tree that really lost apt-get/libc is still 'incomplete'" \
    is_true rootfs_deb_base_incomplete "$broken_tree"

# --- wiring -----------------------------------------------------------------
file_contains() { # <file> <substring>
    local content
    content=$(cat "$1") || return 1
    text_has "$content" "$2"
}
declare -f rootfs_wb_menu_for > "$tmp/menu.def"
check "the workbench menu diagnoses instead of warning blindly" \
    file_contains "$tmp/menu.def" rootfs_wb_shell_check_prompt
# The iSH layer wraps rootfs_wb_enter, so the check lives in the preserved base
# implementation; assert across the whole chain.
{
    declare -f rootfs_wb_enter
    declare -f _systui_base_rootfs_wb_enter 2>/dev/null || true
} > "$tmp/enter.def"
check "entering a rootfs diagnoses too" \
    file_contains "$tmp/enter.def" rootfs_wb_shell_check_prompt
declare -f rootfs_shell_path > "$tmp/shellpath.def"
check "the interactive shell path is resolved inside the tree" \
    file_contains "$tmp/shellpath.def" rootfs_tree_path_usable

printf '\n%d checks, %d failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
