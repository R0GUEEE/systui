# shellcheck shell=bash
###############################################################################
# ROOTFS WORKBENCH — repair or replace init system
###############################################################################

rootfs_wb_init_detect() { # <target>
    local t="$1"
    if [ -x "$t/lib/systemd/systemd" ] || [ -x "$t/usr/lib/systemd/systemd" ]; then printf 'systemd\n'; return; fi
    if [ -x "$t/usr/sbin/runit" ]; then printf 'runit\n'; return; fi
    if [ -x "$t/sbin/openrc-init" ] || [ -x "$t/bin/openrc-init" ]; then printf 'openrc\n'; return; fi
    if [ -x "$t/sbin/init" ] && strings "$t/sbin/init" 2>/dev/null | grep -qi sysvinit; then printf 'sysvinit\n'; return; fi
    printf 'unknown\n'
}

rootfs_wb_init_install_apt() { # <target> <init>
    local t="$1" init="$2" cmd rc=0
    rootfs_wb_ish_fix_dirs "$t" 2>/dev/null || mkdir -p "$t/proc" "$t/sys" "$t/dev" "$t/dev/pts" "$t/run" "$t/tmp"
    if declare -F rootfs_wb_init_mount_required >/dev/null 2>&1; then
        rootfs_wb_init_mount_required "$t" || return 1
    else
        rootfs_mount_chroot_fs "$t" || true
        [ -r "$t/proc/self/status" ] || { tui_msg "Missing /proc" "The init package cannot be configured because /proc is not mounted inside the rootfs."; return 1; }
    fi
    case "$init" in
        systemd) cmd='apt-get update && apt-get -f install -y && apt-get install --reinstall -y systemd systemd-sysv' ;;
        runit) cmd='apt-get update && apt-get -f install -y && apt-get install -y runit runit-services' ;;
        openrc) cmd='apt-get update && apt-get -f install -y && apt-get install -y openrc' ;;
        sysvinit) cmd='apt-get update && apt-get -f install -y && apt-get install -y sysvinit-core sysvinit-utils' ;;
        *) rc=2 ;;
    esac
    if [ "$rc" -eq 0 ]; then
        in_chroot "$t" sh -c "export DEBIAN_FRONTEND=noninteractive; $cmd" || rc=$?
    fi
    if declare -F rootfs_wb_init_unmount_required >/dev/null 2>&1; then
        rootfs_wb_init_unmount_required
    fi
    return "$rc"
}

rootfs_wb_init_wire() { # <target> <init>
    local t="$1" init="$2"
    mkdir -p "$t/sbin" || return 1
    rm -f "$t/sbin/init"
    case "$init" in
        systemd)
            if declare -F rootfs_install_ish_systemd_compat >/dev/null 2>&1; then
                SYSTUI_ISH_COMPAT_SKIP_COREUTILS_MIGRATION=1 rootfs_install_ish_systemd_compat "$t"
            elif [ -x "$t/lib/systemd/systemd" ]; then ln -s ../lib/systemd/systemd "$t/sbin/init"
            elif [ -x "$t/usr/lib/systemd/systemd" ]; then ln -s ../usr/lib/systemd/systemd "$t/sbin/init"
            else return 1; fi ;;
        runit) [ -x "$t/usr/sbin/runit" ] || return 1; ln -s ../usr/sbin/runit "$t/sbin/init" ;;
        openrc)
            [ -x "$t/sbin/openrc-init" ] && ln -s openrc-init "$t/sbin/init" ||
            { [ -x "$t/bin/openrc-init" ] && ln -s ../bin/openrc-init "$t/sbin/init"; } ;;
        sysvinit)
            [ -x "$t/lib/sysvinit/init" ] && ln -s ../lib/sysvinit/init "$t/sbin/init" ||
            [ -x "$t/usr/lib/sysvinit/init" ] && ln -s ../usr/lib/sysvinit/init "$t/sbin/init" || return 1 ;;
        *) return 2 ;;
    esac
}

rootfs_wb_init_repair() { # <target> <init>
    local t="$1" init="$2"
    if [ -r "$t/var/lib/dpkg/status" ]; then
        case "$init" in
            systemd) declare -F rootfs_wb_ish_reinstall_systemd_init >/dev/null 2>&1 && { rootfs_wb_ish_reinstall_systemd_init "$t"; return; } ;;
            runit) declare -F rootfs_wb_ish_reinstall_runit_init >/dev/null 2>&1 && { rootfs_wb_ish_reinstall_runit_init "$t"; return; } ;;
            openrc) declare -F rootfs_wb_ish_reinstall_openrc_init >/dev/null 2>&1 && { rootfs_wb_ish_reinstall_openrc_init "$t"; return; } ;;
        esac
        rootfs_wb_init_install_apt "$t" "$init" || return 1
    fi
    rootfs_wb_init_wire "$t" "$init"
}

rootfs_wb_init_replace() { # <target> <new-init>
    local t="$1" new="$2" old
    old=$(rootfs_wb_init_detect "$t")
    tui_yesno "Replace init system" "Replace '$old' with '$new' in $(basename "$t")?\n\nThe new init is installed and /sbin/init is rewired. The old init packages are left installed initially to avoid destructive dependency removal; you can remove them later after verifying the rootfs." || return 0
    if [ -r "$t/var/lib/dpkg/status" ]; then
        rootfs_wb_init_install_apt "$t" "$new" || { tui_msg "Init replacement failed" "Could not install $new. The existing init was not intentionally removed."; return 1; }
    else
        tui_msg "Unsupported package manager" "Automatic init replacement currently supports dpkg/APT rootfs trees."
        return 1
    fi
    rootfs_wb_init_wire "$t" "$new" || { tui_msg "Init replacement incomplete" "$new was installed, but /sbin/init could not be wired."; return 1; }
    mkdir -p "$t/etc/systui"
    printf 'init=%s\nprevious=%s\n' "$new" "$old" > "$t/etc/systui/init-selection.conf"
    tui_msg "Init replaced" "Current init: $new\nPrevious init: $old\n\nRun the iSH-AOK readiness analyzer before booting the rootfs."
}

rootfs_wb_init_manager() { # <target>
    local t="$1" current c new
    while true; do
        current=$(rootfs_wb_init_detect "$t")
        c=$(tui_menu "Init system: $(basename "$t")" "Detected init: $current\n/sbin/init: $([ -x "$t/sbin/init" ] && echo ready || echo missing/broken)" \
            repair "Repair/reinstall current init ($current)" \
            replace "Replace current init system" \
            readiness "Run iSH-AOK boot readiness analyzer" \
            back "Back") || return 0
        case "$c" in
            repair)
                [ "$current" != unknown ] || { tui_msg "Init unknown" "Systui could not identify the current init. Use Replace current init system instead."; continue; }
                if rootfs_wb_init_repair "$t" "$current"; then tui_msg "Init repaired" "$current was reinstalled/repaired and /sbin/init was refreshed."; else tui_msg "Repair failed" "Could not repair $current. See $LOGFILE."; fi ;;
            replace)
                new=$(tui_radio "Replace init system" "Select the new init system (SPACE selects):" \
                    systemd "systemd" "$(_rootfs_radio_state "$current" systemd)" \
                    runit "runit" "$(_rootfs_radio_state "$current" runit)" \
                    openrc "OpenRC" "$(_rootfs_radio_state "$current" openrc)" \
                    sysvinit "SysVinit" "$(_rootfs_radio_state "$current" sysvinit)") || continue
                [ -n "$new" ] || continue
                [ "$new" = "$current" ] && { rootfs_wb_init_repair "$t" "$current" || true; continue; }
                rootfs_wb_init_replace "$t" "$new" || true ;;
            readiness) rootfs_wb_ish_boot_analyze "$t" ;;
            back|"") return 0 ;;
        esac
    done
}

# Add the init manager directly to Workbench > Config without rewriting the
# large base configuration function. The wrapper gives the user a small front
# door and preserves every existing configuration option unchanged.
if declare -F rootfs_cfg_menu >/dev/null 2>&1 && ! declare -F _systui_base_rootfs_cfg_menu_initmgr >/dev/null 2>&1; then
    eval "$(declare -f rootfs_cfg_menu | sed '1s/^rootfs_cfg_menu[[:space:]]*()/_systui_base_rootfs_cfg_menu_initmgr ()/')"
fi

rootfs_cfg_menu() { # <target>
    local t="$1" c
    while true; do
        c=$(tui_menu "Rootfs configuration: $(basename "$t")" "Choose configuration area:" \
            init "Repair or replace the current init system" \
            existing "Other in-rootfs configuration options" \
            back "Back") || return 0
        case "$c" in
            init) rootfs_wb_init_manager "$t" ;;
            existing) _systui_base_rootfs_cfg_menu_initmgr "$t" ;;
            back|"") return 0 ;;
        esac
    done
}

export -f rootfs_wb_init_detect rootfs_wb_init_install_apt rootfs_wb_init_wire \
    rootfs_wb_init_repair rootfs_wb_init_replace rootfs_wb_init_manager rootfs_cfg_menu