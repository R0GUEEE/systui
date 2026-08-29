# shellcheck shell=bash
###############################################################################
# ROOTFS WORKBENCH — repair failed /sbin/init by reinstalling systemd + init
###############################################################################

rootfs_wb_ish_systemd_target() { # <target>
    local t="$1"
    [ -x "$t/lib/systemd/systemd" ] || [ -x "$t/usr/lib/systemd/systemd" ] && return 0
    if [ -r "$t/var/lib/dpkg/status" ]; then
        awk 'BEGIN{RS=""} $0 ~ /(^|\n)Package: systemd(\n|$)/ && $0 ~ /(^|\n)Status: install ok installed(\n|$)/ {found=1} END{exit found?0:1}' \
            "$t/var/lib/dpkg/status" 2>/dev/null && return 0
    fi
    grep -RqsE '(^|[[:space:]])(INIT|init_choice)=?systemd([[:space:]]|$)' \
        "$t/etc/systui-build.conf" "$t/etc/systui" 2>/dev/null
}

rootfs_wb_ish_reinstall_systemd_init() { # <target>
    local t="$1" mounted_before=0 rc=0

    [ -r "$t/var/lib/dpkg/status" ] || {
        warn "Cannot reinstall systemd/init: $t is not a dpkg-based rootfs."
        return 1
    }

    rootfs_wb_ish_fix_dirs "$t" || return 1
    [ "$(rootfs_wb_mount_count "$t" 2>/dev/null || echo 0)" -gt 0 ] && mounted_before=1
    if [ "$mounted_before" -eq 0 ]; then
        rootfs_wb_mount_persistent "$t" || return 1
    fi

    if declare -F rootfs_ish_activate_gnu_coreutils >/dev/null 2>&1; then
        rootfs_ish_activate_gnu_coreutils "$t" >/dev/null 2>&1 || true
    fi
    if declare -F rootfs_apt_force_ipv4 >/dev/null 2>&1; then
        rootfs_apt_force_ipv4 "$t" >/dev/null 2>&1 || true
    fi

    # systemd-sysv is the package that supplies the systemd /sbin/init wiring on
    # Debian-family systems. Install/reinstall the `init` metapackage as well
    # when the selected suite publishes it; otherwise systemd-sysv is sufficient.
    in_chroot "$t" sh -c '
        set -e
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        dpkg --configure -a || true
        apt-get -f install -y
        if apt-cache show init >/dev/null 2>&1; then
            apt-get install --reinstall -y systemd systemd-sysv init
        else
            apt-get install --reinstall -y systemd systemd-sysv
        fi
    ' || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    # Reinstalling systemd-sysv restores distro init wiring. The iSH-AOK layer
    # then replaces it with Systui's direct executable compatibility PID 1 while
    # preserving the freshly restored distro init for normal Linux handoff.
    if declare -F rootfs_install_ish_systemd_compat >/dev/null 2>&1; then
        SYSTUI_ISH_COMPAT_SKIP_COREUTILS_MIGRATION=1 \
            rootfs_install_ish_systemd_compat "$t" || return 1
    fi

    [ -x "$t/sbin/init" ] || {
        warn "systemd/init reinstall completed, but $t/sbin/init is still not executable."
        return 1
    }

    log "rootfs: reinstalled systemd + init and repaired /sbin/init in $t"
    return 0
}

# Preserve the readiness repair selector and replace a generic compatibility
# refresh with a full package reinstall whenever the report's /sbin/init check
# is a hard failure on a systemd/dpkg rootfs.
if declare -F rootfs_wb_ish_repair_choices >/dev/null 2>&1 && \
   ! declare -F _systui_base_rootfs_wb_ish_repair_choices_init >/dev/null 2>&1; then
    eval "$(declare -f rootfs_wb_ish_repair_choices | sed '1s/^rootfs_wb_ish_repair_choices[[:space:]]*()/_systui_base_rootfs_wb_ish_repair_choices_init ()/')"
fi

rootfs_wb_ish_repair_choices() { # <target>
    local t="$1" line
    local init_failed=0

    if [ ! -x "$t/sbin/init" ] && [ -r "$t/var/lib/dpkg/status" ] && rootfs_wb_ish_systemd_target "$t"; then
        init_failed=1
        printf '%s\n' 'systemd-reinstall|Reinstall systemd + init packages and rebuild /sbin/init|on'
    fi

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ "$init_failed" -eq 1 ]; then
            case "$line" in
                systemd\|*) continue ;;
                continue\|*usable\ init*) continue ;;
            esac
        fi
        printf '%s\n' "$line"
    done <<< "$(_systui_base_rootfs_wb_ish_repair_choices_init "$t")"
}

if declare -F rootfs_wb_ish_apply_repair >/dev/null 2>&1 && \
   ! declare -F _systui_base_rootfs_wb_ish_apply_repair_init >/dev/null 2>&1; then
    eval "$(declare -f rootfs_wb_ish_apply_repair | sed '1s/^rootfs_wb_ish_apply_repair[[:space:]]*()/_systui_base_rootfs_wb_ish_apply_repair_init ()/')"
fi

rootfs_wb_ish_apply_repair() { # <target> <tag>
    case "$2" in
        systemd-reinstall) rootfs_wb_ish_reinstall_systemd_init "$1" ;;
        *) _systui_base_rootfs_wb_ish_apply_repair_init "$@" ;;
    esac
}

export -f rootfs_wb_ish_systemd_target rootfs_wb_ish_reinstall_systemd_init \
    rootfs_wb_ish_repair_choices rootfs_wb_ish_apply_repair
