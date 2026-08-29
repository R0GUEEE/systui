# shellcheck shell=bash
###############################################################################
# ROOTFS WORKBENCH — readiness-driven init repairs
###############################################################################

rootfs_wb_ish_systemd_target() { # <target>
    local t="$1"
    { [ -x "$t/lib/systemd/systemd" ] || [ -x "$t/usr/lib/systemd/systemd" ]; } && return 0
    if [ -r "$t/var/lib/dpkg/status" ]; then
        awk 'BEGIN{RS=""} $0 ~ /(^|\n)Package: systemd(\n|$)/ {found=1} END{exit found?0:1}' \
            "$t/var/lib/dpkg/status" 2>/dev/null && return 0
    fi
    grep -RqsE '(^|[[:space:]])(INIT|init_choice)=?systemd([[:space:]]|$)' \
        "$t/etc/systui-build.conf" "$t/etc/systui" 2>/dev/null
}

rootfs_wb_ish_reinstall_systemd_init() { # <target>
    local t="$1" rc=0
    [ -r "$t/var/lib/dpkg/status" ] || return 1
    rootfs_wb_ish_fix_dirs "$t" || return 1
    [ "$(rootfs_wb_mount_count "$t" 2>/dev/null || echo 0)" -gt 0 ] || rootfs_wb_mount_persistent "$t" || return 1

    declare -F rootfs_ish_activate_gnu_coreutils >/dev/null 2>&1 && \
        rootfs_ish_activate_gnu_coreutils "$t" >/dev/null 2>&1 || true
    declare -F rootfs_apt_force_ipv4 >/dev/null 2>&1 && rootfs_apt_force_ipv4 "$t" >/dev/null 2>&1 || true

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

    if declare -F rootfs_install_ish_systemd_compat >/dev/null 2>&1; then
        SYSTUI_ISH_COMPAT_SKIP_COREUTILS_MIGRATION=1 rootfs_install_ish_systemd_compat "$t" || return 1
    fi
    [ -x "$t/sbin/init" ] || return 1
    log "rootfs: reinstalled systemd/init and repaired /sbin/init in $t"
}

rootfs_wb_ish_reinstall_runit_init() { # <target>
    local t="$1"
    [ -r "$t/var/lib/dpkg/status" ] || return 1
    rootfs_wb_ish_fix_dirs "$t" || return 1
    [ "$(rootfs_wb_mount_count "$t" 2>/dev/null || echo 0)" -gt 0 ] || rootfs_wb_mount_persistent "$t" || return 1
    in_chroot "$t" sh -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get -f install -y && apt-get install --reinstall -y runit runit-services' || return $?
    [ -x "$t/usr/sbin/runit" ] || return 1
    rm -f "$t/sbin/init"
    ln -s ../usr/sbin/runit "$t/sbin/init"
}

rootfs_wb_ish_reinstall_openrc_init() { # <target>
    local t="$1"
    [ -r "$t/var/lib/dpkg/status" ] || return 1
    rootfs_wb_ish_fix_dirs "$t" || return 1
    [ "$(rootfs_wb_mount_count "$t" 2>/dev/null || echo 0)" -gt 0 ] || rootfs_wb_mount_persistent "$t" || return 1
    in_chroot "$t" sh -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get -f install -y && apt-get install --reinstall -y openrc' || return $?
    [ -x "$t/sbin/openrc-init" ] || return 1
    rm -f "$t/sbin/init"
    ln -s openrc-init "$t/sbin/init"
}

if declare -F rootfs_wb_ish_repair_choices >/dev/null 2>&1 && \
   ! declare -F _systui_base_rootfs_wb_ish_repair_choices_init >/dev/null 2>&1; then
    eval "$(declare -f rootfs_wb_ish_repair_choices | sed '1s/^rootfs_wb_ish_repair_choices[[:space:]]*()/_systui_base_rootfs_wb_ish_repair_choices_init ()/')"
fi

# Build the repair selector from the same conditions represented by the
# readiness report. A failed check should expose its concrete repair instead of
# collapsing everything into Continue/recover generation.
rootfs_wb_ish_repair_choices() { # <target>
    local t="$1" line init_failed=0 has_runit=0 has_openrc=0
    [ -x "$t/usr/sbin/runit" ] && has_runit=1
    [ -x "$t/sbin/openrc-init" ] && has_openrc=1

    if [ ! -x "$t/sbin/init" ]; then
        init_failed=1
        if [ -r "$t/var/lib/dpkg/status" ] && rootfs_wb_ish_systemd_target "$t"; then
            printf '%s\n' 'systemd-reinstall|[FAIL] /sbin/init — reinstall systemd + init and rebuild PID 1|on'
        elif [ "$has_runit" -eq 1 ]; then
            if [ -r "$t/var/lib/dpkg/status" ]; then
                printf '%s\n' 'runit-reinstall|[FAIL] /sbin/init — reinstall runit and rebuild PID 1|on'
            else
                printf '%s\n' 'runit-init|[FAIL] /sbin/init — wire installed runit as PID 1|on'
            fi
        elif [ "$has_openrc" -eq 1 ]; then
            if [ -r "$t/var/lib/dpkg/status" ]; then
                printf '%s\n' 'openrc-reinstall|[FAIL] /sbin/init — reinstall OpenRC and rebuild PID 1|on'
            else
                printf '%s\n' 'openrc-init|[FAIL] /sbin/init — wire installed OpenRC as PID 1|on'
            fi
        else
            printf '%s\n' 'continue|[FAIL] /sbin/init — resume build to install the selected init system|on'
        fi
    fi

    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ "$init_failed" -eq 1 ]; then
            case "$line" in
                systemd\|*|runit-init\|*|openrc-init\|*|continue\|*usable\ init*) continue ;;
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
        runit-reinstall) rootfs_wb_ish_reinstall_runit_init "$1" ;;
        openrc-reinstall) rootfs_wb_ish_reinstall_openrc_init "$1" ;;
        *) _systui_base_rootfs_wb_ish_apply_repair_init "$@" ;;
    esac
}

export -f rootfs_wb_ish_systemd_target rootfs_wb_ish_reinstall_systemd_init \
    rootfs_wb_ish_reinstall_runit_init rootfs_wb_ish_reinstall_openrc_init \
    rootfs_wb_ish_repair_choices rootfs_wb_ish_apply_repair
