# shellcheck shell=bash
###############################################################################
# ROOTFS WORKBENCH — iSH/AOK engine compatibility
###############################################################################

rootfs_wb_is_ish_kernel() {
    case "$(uname -r 2>/dev/null)" in
        *-ish*|*ish_aok*|*ish-aok*) return 0 ;;
    esac
    grep -qiE 'ish[_-]?aok|[- ]ish([._ -]|$)' /proc/version 2>/dev/null
}

# Override engine availability with kernel capability awareness. iSH/AOK does
# not implement the ptrace event-message behavior PRoot relies on, and it does
# not provide the process/resource-limit interfaces systemd-nspawn expects.
# Its namespace support is also incomplete, so plain chroot is the reliable
# workbench engine there.
rootfs_wb_engine_available() { # <engine>
    local engine="$1"
    if rootfs_wb_is_ish_kernel; then
        case "$engine" in
            chroot)  command -v chroot >/dev/null 2>&1 ;;
            proot|nspawn|unshare) return 1 ;;
            *) return 1 ;;
        esac
        return
    fi

    case "$engine" in
        chroot)  command -v chroot >/dev/null 2>&1 ;;
        proot)   command -v proot >/dev/null 2>&1 ;;
        nspawn)
            command -v systemd-nspawn >/dev/null 2>&1 || return 1
            # nspawn needs a substantially complete procfs/cgroup environment.
            [ -r /proc/1/status ] && [ -r /proc/1/limits ] || return 1
            [ -d /sys/fs/cgroup ] || return 1
            ;;
        unshare)
            command -v unshare >/dev/null 2>&1 && command -v chroot >/dev/null 2>&1 || return 1
            # A binary existing is not enough; require a successful namespace
            # probe so kernels returning ENOSYS are filtered before the menu.
            unshare --mount -- true >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

rootfs_wb_engine_status() { # <engine>
    if rootfs_wb_is_ish_kernel; then
        case "$1" in
            proot)   printf '%s\n' 'unsupported by iSH ptrace implementation'; return ;;
            nspawn)  printf '%s\n' 'unsupported by iSH process/resource APIs'; return ;;
            unshare) printf '%s\n' 'unsupported by iSH namespaces'; return ;;
        esac
    fi
    if ! rootfs_wb_engine_available "$1"; then
        printf '%s\n' 'not available on this host'
    elif rootfs_wb_engine_needs_root "$1" && [ "$(id -u)" != 0 ]; then
        printf '%s\n' 'installed, needs root'
    else
        printf '%s\n' 'ready'
    fi
}

# If a rootfs previously saved proot/nspawn/unshare as its engine, silently
# migrate it to the first compatible engine rather than repeatedly launching a
# known-broken engine.
rootfs_wb_engine_get() { # <target>
    local t="$1" e
    e=$(rootfs_chroot_option_get "$t" ENGINE "")
    if [ -z "$e" ] || ! rootfs_wb_engine_available "$e"; then
        e=$(rootfs_wb_engine_default "$t")
        [ -n "$e" ] && rootfs_chroot_option_set "$t" ENGINE "$e" >/dev/null 2>&1 || true
    fi
    printf '%s\n' "$e"
}

export -f rootfs_wb_is_ish_kernel rootfs_wb_engine_available rootfs_wb_engine_status rootfs_wb_engine_get
