#!/bin/bash
# Stable internal rootfs API. Legacy feature code may continue to use
# rootfs_exec_raw during migration; new code should call systui_rootfs_exec.

systui_rootfs_validate_target() { # <target>
    local target="${1:-}"
    [ -n "$target" ] || return 64
    case "$target" in /*) ;; *) return 64;; esac
    [ -d "$target" ] || return 66
    # A usable Linux rootfs should have at least one of these anchors.
    [ -d "$target/etc" ] && { [ -d "$target/bin" ] || [ -d "$target/usr/bin" ]; }
}

systui_rootfs_exec() { # <target> <command> [args...]
    local target="${1:-}"
    [ "$#" -ge 2 ] || return 64
    systui_rootfs_validate_target "$target" || {
        declare -F warn >/dev/null 2>&1 && warn "rootfs: invalid target: $target"
        return 66
    }
    declare -F rootfs_exec_raw >/dev/null 2>&1 || return 127
    rootfs_exec_raw "$@"
}

systui_rootfs_exec_guarded() { # <timeout-seconds> <target> <command> [args...]
    local seconds="${1:-}" target="${2:-}"
    [ "$#" -ge 3 ] || return 64
    shift
    systui_rootfs_validate_target "$target" || return 66
    if declare -F systui_guard_exec >/dev/null 2>&1; then
        systui_guard_exec "$seconds" systui_rootfs_exec "$@"
    else
        systui_rootfs_exec "$@"
    fi
}

systui_rootfs_enter() { # <target> [shell]
    local target="$1" shell="${2:-/bin/bash}"
    if [ ! -x "$target$shell" ]; then
        shell=/bin/sh
    fi
    systui_rootfs_exec "$target" "$shell" -l
}

export -n -f systui_rootfs_validate_target systui_rootfs_exec systui_rootfs_exec_guarded systui_rootfs_enter 2>/dev/null || true
