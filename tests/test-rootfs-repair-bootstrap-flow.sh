#!/usr/bin/env bash
# Workbench essential-base repair. Regressions covered:
#   * an Alpine/Arch rootfs was reported as an "incomplete Debian bootstrap" and
#     offered a repair that cannot apply to it;
#   * a checklist that captured no selection silently did nothing and ended in
#     the circular message "apt-get and/or libc6 are still missing. Restore the
#     bootstrap base before running dpkg/APT repair", which is what the reported
#     "repair just goes back to the menu" symptom looked like;
#   * recovery refused to run when only MIRROR was absent from the build state;
#   * recovery assigned to the readonly SYSTUI_UNSHARE_SUPPORTED flag, so the
#     forced no-unshare path never took effect and printed "readonly variable".
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

# The readiness scan shells out to mount inspection; these tests are about the
# repair decision, and the real helpers can wedge on hosts whose text tools
# misbehave. Keep them inert so the assertions stay deterministic.
rootfs_wb_mount_count() { printf '0\n'; }
rootfs_wb_detach_all() { return 0; }

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
is_true() { "$@" ; }
is_false() { ! "$@" ; }
text_has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

# --- fixtures ---------------------------------------------------------------
mk_debian_tree() { # <dir> [state-mirror|none] [sources.list-mirror|none]
    local t="$1" state_mirror="${2:-http://deb.debian.org/debian}" sources="${3:-none}"
    rm -rf -- "$t"
    mkdir -p "$t/bin" "$t/usr/bin" "$t/etc/apt" "$t/var/lib/dpkg" "$t/proc" "$t/sys" "$t/dev/pts" "$t/run" "$t/tmp"
    : > "$t/bin/sh"
    : > "$t/usr/bin/dpkg"
    chmod +x "$t/bin/sh" "$t/usr/bin/dpkg"
    printf 'ID=debian\nVERSION_CODENAME=trixie\nPRETTY_NAME="Debian GNU/Linux trixie"\n' > "$t/etc/os-release"
    printf 'Package: libc6\nStatus: install ok unpacked\nArchitecture: arm64\n' > "$t/var/lib/dpkg/status"
    {
        printf 'DISTRO=debian\nRELEASE=trixie\nARCH=arm64\nBACKEND=mmdebstrap\nUSE_QEMU=0\nPACKAGES=git curl\nSTAGE=bootstrap-failed\n'
        [ "$state_mirror" = none ] || printf 'MIRROR=%s\n' "$state_mirror"
    } > "$t/.systui-build-state"
    [ "$sources" = none ] || printf 'deb %s trixie main\n' "$sources" > "$t/etc/apt/sources.list"
    return 0
}

mk_other_tree() { # <dir> <release-marker> <os-id>
    local t="$1" marker="$2" id="$3"
    rm -rf -- "$t"
    mkdir -p "$t/bin" "$t/usr/bin" "$t/etc" "$t/sbin"
    : > "$t/bin/sh"
    chmod +x "$t/bin/sh"
    : > "$t$marker"
    printf 'ID=%s\nPRETTY_NAME="%s"\n' "$id" "$id" > "$t/etc/os-release"
    return 0
}

debian="$ROOTFS_BASE/broken-debian"
nomirror="$ROOTFS_BASE/debian-no-mirror"
tree_mirror="$ROOTFS_BASE/debian-tree-mirror"
alpine="$ROOTFS_BASE/alpine"
arch="$ROOTFS_BASE/arch"

mk_debian_tree "$debian"
mk_debian_tree "$nomirror" none
mk_debian_tree "$tree_mirror" none "http://ftp.debian.org/debian"
mk_other_tree "$alpine" /etc/alpine-release alpine
mk_other_tree "$arch" /etc/arch-release arch

# --- Debian-family detection ------------------------------------------------
check "Debian tree is Debian-family" is_true rootfs_tree_is_deb_family "$debian"
check "Alpine tree is not Debian-family" is_false rootfs_tree_is_deb_family "$alpine"
check "Arch tree is not Debian-family" is_false rootfs_tree_is_deb_family "$arch"

check "Debian tree reports an incomplete base" is_true rootfs_deb_base_incomplete "$debian"
check "Alpine tree does not report a Debian base" is_false rootfs_deb_base_incomplete "$alpine"
check "Arch tree does not report a Debian base" is_false rootfs_deb_base_incomplete "$arch"
check "missing components are named" \
    is_true text_has "$(rootfs_deb_base_gaps "$debian")" "apt-get"
check "missing components include libc6" \
    is_true text_has "$(rootfs_deb_base_gaps "$debian")" "libc6"

# --- readiness repair offers -----------------------------------------------
debian_choices=$(rootfs_wb_ish_repair_choices "$debian")
alpine_choices=$(rootfs_wb_ish_repair_choices "$alpine")
check "Debian tree is offered the bootstrap repair" \
    is_true text_has "$debian_choices" 'bootstrap|Restore missing Debian-family bootstrap base'
check "Alpine tree is not offered the Debian bootstrap repair" \
    is_false text_has "$alpine_choices" 'bootstrap|Restore missing Debian-family bootstrap base'

# --- recovery metadata ------------------------------------------------------
meta=$(rootfs_deb_recovery_metadata "$nomirror")
IFS='|' read -r m_distro m_release m_arch m_mirror m_pkgs m_qemu m_backend <<< "$meta"
check "metadata keeps the recorded distribution" is_true text_has "$m_distro" debian
check "metadata resolves the backend" is_true text_has "$m_backend" mmdebstrap
check "missing MIRROR falls back to the distribution default" \
    is_true text_has "$m_mirror" "deb.debian.org"
tree_meta=$(rootfs_deb_recovery_metadata "$tree_mirror")
IFS='|' read -r _t_distro _t_release _t_arch t_mirror _t_pkgs _t_qemu _t_backend <<< "$tree_meta"
check "MIRROR is derived from the tree's APT sources" \
    is_true text_has "$t_mirror" "ftp.debian.org"

# --- widget capture ---------------------------------------------------------
# The widget helper runs each tui_check inside a subshell, so the counter has
# to live in a file to be observable (and to make the second call behave
# differently from the first).
tui_check_counter="$tmp/tui-check-count"
printf '0' > "$tui_check_counter"
tui_check() { # <title> <text> <items...>
    local n
    n=$(( $(cat "$tui_check_counter") + 1 ))
    printf '%s' "$n" > "$tui_check_counter"
    if [ "$n" -eq 1 ]; then
        return 0            # success, but no selection captured
    fi
    printf '"bootstrap"\n'
}
selected=$(rootfs_ui_check_required "Title" "Text" bootstrap "desc" on)
check "an uncaptured checklist is re-asked" \
    is_true text_has "$(cat "$tui_check_counter")" 2
check "the re-asked selection is returned" \
    is_true text_has "${selected//\"/}" bootstrap
unset -f tui_check

# --- the reported dead end --------------------------------------------------
tui_msg() { printf '%s\n' "$2" > "$tmp/message"; }
rootfs_deb_report_incomplete "$debian" declined
check "deferred repair names the missing components" \
    is_true text_has "$(cat "$tmp/message")" "apt-get"
rootfs_deb_report_incomplete "$alpine" declined
check "non-Debian tree is not told to restore a Debian base" \
    is_true text_has "$(cat "$tmp/message")" "not Debian-family"
unset -f tui_msg

# --- static invariants ------------------------------------------------------
# Only the recovery-related modules can reintroduce these patterns, so scan
# those instead of every feature (and never build one giant string).
circular_found=0
unshare_assign_found=0
no_unshare_flag_found=0
for f in "$ROOT"/src/features/*rootfs*.sh "$ROOT"/src/features/*repair*.sh \
         "$ROOT"/src/features/*bootstrap*.sh "$ROOT"/src/features/*mmdebstrap*.sh; do
    [ -f "$f" ] || continue
    content=$(cat "$f") || continue
    case "$content" in
        *"Restore the bootstrap base before running dpkg/APT repair"*) circular_found=1 ;;
    esac
    case "$content" in
        *"SYSTUI_UNSHARE_SUPPORTED=0 "*)
            # Only a command-prefix assignment (the readonly flag) counts as the
            # bug; the probe's own `SYSTUI_UNSHARE_SUPPORTED=0` assignment is fine.
            unshare_assign_found=1 ;;
    esac
    case "$content" in
        *"SYSTUI_RECOVERY_NO_UNSHARE"*) no_unshare_flag_found=1 ;;
    esac
done
check "the circular deferred-repair message is gone" [ "$circular_found" -eq 0 ]
check "nothing assigns to the readonly unshare flag" [ "$unshare_assign_found" -eq 0 ]
check "recovery requests no-unshare through the writable flag" \
    [ "$no_unshare_flag_found" -eq 1 ]

printf '\n%d checks, %d failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
