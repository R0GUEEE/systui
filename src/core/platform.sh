#!/bin/bash
# Unified platform/capability detection for systui.
# Safe to source from the interactive TUI, provisioning helpers, and tests.

systui_is_ish() {
    case "${SYSTUI_ISH_AOK:-}" in 1|yes|true) return 0 ;; esac
    case "${container:-}" in *ish*|*iSH*) return 0 ;; esac
    case "$(uname -r 2>/dev/null) $(uname -a 2>/dev/null)" in
        *-ish*|*ish_aok*|*iSH-AOK*|*iSH*) return 0 ;;
    esac
    return 1
}

systui_is_container() {
    [ -f /.dockerenv ] || [ -f /run/.containerenv ] ||
        grep -qaE '(docker|containerd|lxc|podman|kubepods)' /proc/1/cgroup 2>/dev/null
}

systui_pid1_name() { cat /proc/1/comm 2>/dev/null || printf 'unknown\n'; }

systui_systemd_state() {
    command -v systemctl >/dev/null 2>&1 || { printf 'absent\n'; return 1; }
    local s
    s=$(systemctl is-system-running 2>/dev/null || true)
    [ -n "$s" ] || s=unknown
    printf '%s\n' "$s"
}

systui_systemd_online() {
    local s
    s=$(systui_systemd_state)
    case "$s" in running|degraded|starting|maintenance) return 0 ;; esac
    return 1
}

systui_runtime_profile() {
    if systui_is_ish; then printf 'ish-aok\n'
    elif [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then printf 'wsl\n'
    elif systui_is_container; then printf 'container\n'
    elif [ -n "${PROOT_TMP_DIR:-}" ] || [ -n "${PROOT_LOADER:-}" ]; then printf 'proot\n'
    else printf 'native-linux\n'
    fi
}

# Capability checks are deliberately conservative. A capability should only be
# reported when Systui can reasonably attempt the operation on this runtime.
systui_capability() { # <name>
    local cap="${1:-}" profile
    profile=$(systui_runtime_profile)
    case "$cap" in
        chroot)
            command -v chroot >/dev/null 2>&1
            ;;
        mount)
            command -v mount >/dev/null 2>&1 && [ "$profile" != proot ]
            ;;
        namespaces)
            [ "$profile" != ish-aok ] && [ "$profile" != proot ] && command -v unshare >/dev/null 2>&1
            ;;
        proc)
            [ -d /proc ] && [ -r /proc/1/stat ]
            ;;
        sysfs)
            [ -d /sys ] && [ -r /sys/kernel/uevent_seqnum -o -d /sys/devices ]
            ;;
        systemd-runtime)
            systui_systemd_online
            ;;
        fuse)
            grep -qw fuse /proc/filesystems 2>/dev/null || [ -c /dev/fuse ]
            ;;
        binfmt)
            [ -d /proc/sys/fs/binfmt_misc ]
            ;;
        qemu)
            command -v qemu-aarch64-static >/dev/null 2>&1 || command -v qemu-x86_64-static >/dev/null 2>&1 || command -v qemu-arm-static >/dev/null 2>&1
            ;;
        netlink)
            [ "$profile" != ish-aok ] && command -v ip >/dev/null 2>&1
            ;;
        argmax-constrained)
            [ "$profile" = ish-aok ]
            ;;
        *) return 2 ;;
    esac
}

systui_capability_summary() {
    local cap
    for cap in chroot mount namespaces proc sysfs systemd-runtime fuse binfmt qemu netlink argmax-constrained; do
        if systui_capability "$cap"; then printf '%-20s yes\n' "$cap"; else printf '%-20s no\n' "$cap"; fi
    done
}

systui_detect_init() {
    local pid1 init_target sd_state
    pid1=$(systui_pid1_name)
    init_target=$(readlink -f /sbin/init 2>/dev/null || true)
    sd_state=$(systui_systemd_state 2>/dev/null || true)

    SYSTUI_ENVIRONMENT=$(systui_runtime_profile)
    SYSTUI_SYSTEMD_STATE=${sd_state:-absent}
    SYSTUI_INIT_PROVIDER=''
    SYSTUI_SERVICE_RUNTIME=''

    if [ "$pid1" = systemd ] || [ -d /run/systemd/system ] || [[ "$init_target" == */systemd ]]; then
        SYSTUI_INIT_PROVIDER=systemd
        if systui_systemd_online; then
            INIT=systemd; SYSTUI_SERVICE_RUNTIME=systemd
        elif systui_is_ish; then
            INIT=ish-systemd-compat; SYSTUI_SERVICE_RUNTIME=init-script
        else
            INIT=systemd-offline; SYSTUI_SERVICE_RUNTIME=offline
        fi
    elif [ "$pid1" = runit ] || [[ "$init_target" == *runit* ]] || { command -v sv >/dev/null 2>&1 && { [ -d /etc/sv ] || [ -d /var/service ] || [ -d /service ]; }; }; then
        INIT=runit; SYSTUI_INIT_PROVIDER=runit; SYSTUI_SERVICE_RUNTIME=runit
    elif [[ "$pid1" == *openrc* ]] || [[ "$init_target" == *openrc* ]] || command -v rc-service >/dev/null 2>&1; then
        INIT=openrc; SYSTUI_INIT_PROVIDER=openrc; SYSTUI_SERVICE_RUNTIME=openrc
    elif [[ "$init_target" == *sysv* ]] || { command -v service >/dev/null 2>&1 && [ -d /etc/init.d ]; }; then
        INIT=sysvinit; SYSTUI_INIT_PROVIDER=sysvinit; SYSTUI_SERVICE_RUNTIME=sysvinit
    else
        INIT=''; SYSTUI_INIT_PROVIDER=unknown; SYSTUI_SERVICE_RUNTIME=none
    fi

    export INIT SYSTUI_ENVIRONMENT SYSTUI_SYSTEMD_STATE SYSTUI_INIT_PROVIDER SYSTUI_SERVICE_RUNTIME
}

systui_rootfs_init_detect() {
    local t="$1" target base selected
    [ -d "$t" ] || { printf 'unknown\n'; return 1; }

    target=$(readlink -f "$t/sbin/init" 2>/dev/null || true)
    if [ -n "$target" ]; then
        base=${target#"$t"}
        case "$base" in
            */systui-ish-init|*/systemd) printf 'systemd\n'; return 0 ;;
            *runit*) printf 'runit\n'; return 0 ;;
            *openrc*) printf 'openrc\n'; return 0 ;;
            *sysv*) printf 'sysvinit\n'; return 0 ;;
        esac
    fi

    if [ -r "$t/etc/systui/rootfs.conf" ]; then
        while IFS='=' read -r _k _v; do
            [ "$_k" = init ] || continue
            case "$_v" in systemd|runit|openrc|sysvinit) printf '%s\n' "$_v"; return 0;; esac
        done < "$t/etc/systui/rootfs.conf"
    fi
    if [ -r "$t/etc/systui/init-selection.conf" ]; then
        selected=$(sed -n 's/^init=//p' "$t/etc/systui/init-selection.conf" | head -n1)
        case "$selected" in systemd|runit|openrc|sysvinit) printf '%s\n' "$selected"; return 0;; esac
    fi
    if [ -x "$t/usr/local/sbin/systui-ish-init" ]; then printf 'systemd\n'; return 0; fi
    if [ -x "$t/usr/sbin/runit" ]; then printf 'runit\n'; return 0; fi
    if [ -x "$t/sbin/openrc-init" ] || [ -x "$t/bin/openrc-init" ]; then printf 'openrc\n'; return 0; fi
    if [ -x "$t/lib/sysvinit/init" ] || [ -x "$t/usr/lib/sysvinit/init" ]; then printf 'sysvinit\n'; return 0; fi
    if [ -x "$t/lib/systemd/systemd" ] || [ -x "$t/usr/lib/systemd/systemd" ]; then printf 'systemd\n'; return 0; fi
    printf 'unknown\n'
}
