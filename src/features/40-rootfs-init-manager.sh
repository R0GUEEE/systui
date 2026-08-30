# shellcheck shell=bash
###############################################################################
# PHASE 40 — ROOTFS init manager
# Transactional init repair/replacement with metadata updates.
###############################################################################

rootfs_wb_init_detect() { # <target>
    if declare -F systui_rootfs_init_detect >/dev/null 2>&1; then
        systui_rootfs_init_detect "$1"
        return
    fi
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
        systui_rootfs_exec "$t" sh -c "export DEBIAN_FRONTEND=noninteractive; $cmd" || rc=$?
    fi
    if declare -F rootfs_wb_init_unmount_required >/dev/null 2>&1; then
        rootfs_wb_init_unmount_required
    fi
    return "$rc"
}

rootfs_wb_init_link_target() { # <target> <init>
    local t="$1" init="$2"
    case "$init" in
        runit) [ -x "$t/usr/sbin/runit" ] && printf '../usr/sbin/runit\n' ;;
        openrc)
            if [ -x "$t/sbin/openrc-init" ]; then printf 'openrc-init\n'
            elif [ -x "$t/bin/openrc-init" ]; then printf '../bin/openrc-init\n'
            else return 1; fi ;;
        sysvinit)
            if [ -x "$t/lib/sysvinit/init" ]; then printf '../lib/sysvinit/init\n'
            elif [ -x "$t/usr/lib/sysvinit/init" ]; then printf '../usr/lib/sysvinit/init\n'
            else return 1; fi ;;
        systemd)
            if [ -x "$t/lib/systemd/systemd" ]; then printf '../lib/systemd/systemd\n'
            elif [ -x "$t/usr/lib/systemd/systemd" ]; then printf '../usr/lib/systemd/systemd\n'
            else return 1; fi ;;
        *) return 2 ;;
    esac
}

rootfs_wb_init_wire() { # <target> <init>
    local t="$1" init="$2" link tmp
    mkdir -p "$t/sbin" || return 1

    if [ "$init" = systemd ] && declare -F rootfs_install_ish_systemd_compat >/dev/null 2>&1 && systui_is_ish; then
        SYSTUI_ISH_COMPAT_SKIP_COREUTILS_MIGRATION=1 rootfs_install_ish_systemd_compat "$t"
        return $?
    fi

    link=$(rootfs_wb_init_link_target "$t" "$init") || return $?
    tmp="$t/sbin/.init.systui-new.$$"
    rm -f "$tmp"
    ln -s "$link" "$tmp" || return 1
    mv -f "$tmp" "$t/sbin/init" || { rm -f "$tmp"; return 1; }
}

rootfs_wb_init_backup() { # <target> -> backup path or "none"
    local t="$1" dir backup
    dir="$t/etc/systui/transactions"
    mkdir -p "$dir" || return 1
    backup="$dir/init.$$.backup"
    if [ -e "$t/sbin/init" ] || [ -L "$t/sbin/init" ]; then
        cp -a "$t/sbin/init" "$backup" || return 1
        printf '%s\n' "$backup"
    else
        printf 'none\n'
    fi
}

rootfs_wb_init_restore() { # <target> <backup|none>
    local t="$1" backup="$2"
    rm -f "$t/sbin/init"
    [ "$backup" = none ] && return 0
    [ -e "$backup" ] || [ -L "$backup" ] || return 1
    mv -f "$backup" "$t/sbin/init"
}

rootfs_wb_init_commit_metadata() { # <target> <new> <old>
    local t="$1" new="$2" old="$3" runtime
    runtime="$new"
    mkdir -p "$t/etc/systui" || return 1
    printf 'init=%s\nprevious=%s\n' "$new" "$old" > "$t/etc/systui/init-selection.conf" || return 1
    if [ "$new" = systemd ] && systui_is_ish; then runtime=ish-systemd-compat; fi
    if declare -F systui_rootfs_metadata_set >/dev/null 2>&1; then
        [ -n "$(systui_rootfs_metadata_get "$t" schema)" ] || systui_rootfs_metadata_set "$t" schema "${SYSTUI_ROOTFS_SCHEMA:-1}" || return 1
        systui_rootfs_metadata_set "$t" init "$new" || return 1
        systui_rootfs_metadata_set "$t" runtime "$runtime" || return 1
    fi
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
    local t="$1" new="$2" old backup
    old=$(rootfs_wb_init_detect "$t")
    tui_yesno "Replace init system" "Replace '$old' with '$new' in $(basename "$t")?\n\nSystui installs the new init first, backs up /sbin/init, then performs an atomic switch. If wiring fails, the previous /sbin/init is restored." || return 0

    [ -r "$t/var/lib/dpkg/status" ] || {
        tui_msg "Unsupported package manager" "Automatic init replacement currently supports dpkg/APT rootfs trees."
        return 1
    }

    rootfs_wb_init_install_apt "$t" "$new" || {
        tui_msg "Init replacement failed" "Could not install $new. The existing /sbin/init was left unchanged."
        return 1
    }

    backup=$(rootfs_wb_init_backup "$t") || {
        tui_msg "Init replacement failed" "Could not back up the existing /sbin/init. No switch was attempted."
        return 1
    }

    if ! rootfs_wb_init_wire "$t" "$new"; then
        rootfs_wb_init_restore "$t" "$backup" || true
        tui_msg "Init replacement rolled back" "$new was installed, but /sbin/init could not be wired. The previous /sbin/init was restored."
        return 1
    fi

    if ! rootfs_wb_init_commit_metadata "$t" "$new" "$old"; then
        rootfs_wb_init_restore "$t" "$backup" || true
        tui_msg "Init replacement rolled back" "Metadata could not be committed. The previous /sbin/init was restored."
        return 1
    fi

    [ "$backup" = none ] || rm -f "$backup"
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

if declare -F rootfs_cfg_menu >/dev/null 2>&1 && ! declare -F _systui_base_rootfs_cfg_menu_initmgr >/dev/null 2>&1; then
    _systui_cfg_def=$(declare -f rootfs_cfg_menu)
    _systui_cfg_def=${_systui_cfg_def/#rootfs_cfg_menu ()/_systui_base_rootfs_cfg_menu_initmgr ()}
    _systui_cfg_def=${_systui_cfg_def/#rootfs_cfg_menu()/_systui_base_rootfs_cfg_menu_initmgr()}
    eval "$_systui_cfg_def"
    unset _systui_cfg_def
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

export -n -f rootfs_wb_init_detect rootfs_wb_init_install_apt rootfs_wb_init_link_target \
    rootfs_wb_init_wire rootfs_wb_init_backup rootfs_wb_init_restore rootfs_wb_init_commit_metadata \
    rootfs_wb_init_repair rootfs_wb_init_replace rootfs_wb_init_manager rootfs_cfg_menu 2>/dev/null || true
