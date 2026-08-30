# shellcheck shell=bash
###############################################################################
# ROOTFS — final exec argument sanitizer
#
# Some generic wrapper paths historically duplicated the function name when
# dispatching rootfs_exec_raw. Put a defensive boundary at the shared execution
# choke point so every chroot caller receives a real target path.
###############################################################################

if declare -F rootfs_exec_raw >/dev/null 2>&1 && \
   ! declare -F _systui_base_rootfs_exec_raw_sanitized >/dev/null 2>&1; then
    _systui_rootfs_exec_def=$(declare -f rootfs_exec_raw)
    _systui_rootfs_exec_def=${_systui_rootfs_exec_def/#rootfs_exec_raw ()/_systui_base_rootfs_exec_raw_sanitized ()}
    _systui_rootfs_exec_def=${_systui_rootfs_exec_def/#rootfs_exec_raw()/_systui_base_rootfs_exec_raw_sanitized()}
    eval "$_systui_rootfs_exec_def"
    unset _systui_rootfs_exec_def
fi

rootfs_exec_raw() { # <target> <command> [args...]
    # Defensive compatibility for stale/broken dispatchers that accidentally
    # prepend the function name to its own argv.
    while [ "${1:-}" = rootfs_exec_raw ]; do
        shift
    done

    local target="${1:-}"
    [ -n "$target" ] || {
        warn "rootfs_exec_raw: missing rootfs target"
        return 64
    }
    [ -d "$target" ] || {
        warn "rootfs_exec_raw: rootfs target is not a directory: $target"
        return 66
    }
    [ "$#" -ge 2 ] || {
        warn "rootfs_exec_raw: missing command for target: $target"
        return 64
    }

    _systui_base_rootfs_exec_raw_sanitized "$@"
}

export -n -f rootfs_exec_raw _systui_base_rootfs_exec_raw_sanitized 2>/dev/null || true
