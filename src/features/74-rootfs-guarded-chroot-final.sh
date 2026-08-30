# shellcheck shell=bash
# PHASE 74 — bridge legacy rootfs post-configuration into the guarded API.
#
# The large legacy builder still calls in_chroot() directly in many places.
# Replacing this one compatibility boundary gives every such call timeout and
# target validation without duplicating rootfs_postconfig().

in_chroot() { # <target> <command> [args...]
    local target="${1:-}" timeout_s
    [ "$#" -ge 2 ] || return 64
    shift
    timeout_s=${SYSTUI_ROOTFS_CHROOT_TIMEOUT:-1800}
    case "$timeout_s" in ''|*[!0-9]*) timeout_s=1800 ;; esac

    if declare -F systui_rootfs_exec_guarded >/dev/null 2>&1; then
        systui_rootfs_exec_guarded "$timeout_s" "$target" "$@" 2>>"${LOGFILE:-/dev/null}"
    elif declare -F rootfs_exec_raw >/dev/null 2>&1; then
        rootfs_exec_raw "$target" "$@" 2>>"${LOGFILE:-/dev/null}"
    else
        return 127
    fi
}

export -n -f in_chroot 2>/dev/null || true
return 0 2>/dev/null || true
