# shellcheck shell=bash
###############################################################################
# ROOTFS + SYSTEM CONFIG — systemd-by-default rootfs and comprehensive init UI
###############################################################################

# Install systemd into a freshly-built rootfs whenever its package manager
# supports systemd. Alpine, Void and Devuan intentionally keep their native
# init because replacing it with an unsupported foreign package set would make
# the image less usable. The iSH-AOK compatibility launcher is then installed
# by rootfs_install_ish_systemd_compat(), which remains transparent on normal
# Linux and becomes the PID 1 supervisor on iSH-AOK.
rootfs_ensure_systemd_manager() { # <target>
    local t="$1" id="" rc=0
    [ -d "$t" ] || return 1

    if [ -r "$t/etc/os-release" ]; then
        id=$(sed -n 's/^ID=["'"']\?\([^"'"']*\)["'"']\?$/\1/p' "$t/etc/os-release" | head -n1)
    fi

    if [ -x "$t/lib/systemd/systemd" ] || [ -x "$t/usr/lib/systemd/systemd" ]; then
        :
    else
        case "$id" in
            alpine|void|devuan)
                log "rootfs: $id uses a native non-systemd init; skipping forced systemd package installation"
                return 2
                ;;
            debian|ubuntu|kali|'')
                if [ -x "$t/usr/bin/apt-get" ]; then
                    rootfs_apt_force_ipv4 "$t" 2>/dev/null || true
                    in_chroot "$t" sh -c 'export DEBIAN_FRONTEND=noninteractive; apt-get update >/dev/null 2>&1 && apt-get install -y systemd systemd-sysv dbus >/dev/null 2>&1' || rc=$?
                else rc=127; fi
                ;;
            fedora|rhel|centos|rocky|almalinux)
                if [ -x "$t/usr/bin/dnf" ]; then
                    in_chroot "$t" dnf install -y systemd systemd-libs dbus >/dev/null 2>&1 || rc=$?
                elif [ -x "$t/usr/bin/yum" ]; then
                    in_chroot "$t" yum install -y systemd systemd-libs dbus >/dev/null 2>&1 || rc=$?
                else rc=127; fi
                ;;
            arch|archlinux)
                [ -x "$t/usr/bin/pacman" ] && in_chroot "$t" pacman -S --noconfirm --needed systemd dbus >/dev/null 2>&1 || rc=$?
                ;;
            opensuse*|sles)
                [ -x "$t/usr/bin/zypper" ] && in_chroot "$t" zypper --non-interactive install systemd dbus-1 >/dev/null 2>&1 || rc=$?
                ;;
            gentoo)
                # Gentoo profiles may deliberately be OpenRC-only. Do not
                # mutate profile USE flags automatically.
                return 2
                ;;
            *)
                return 2
                ;;
        esac
    fi

    if [ "$rc" -ne 0 ] || { [ ! -x "$t/lib/systemd/systemd" ] && [ ! -x "$t/usr/lib/systemd/systemd" ]; }; then
        warn "Could not install a systemd manager in $t; preserving the distro's native init."
        return 2
    fi

    if declare -F rootfs_install_ish_systemd_compat >/dev/null 2>&1; then
        SYSTUI_ISH_COMPAT_SKIP_COREUTILS_MIGRATION=1 rootfs_install_ish_systemd_compat "$t" || return 1
    fi

    mkdir -p "$t/etc/systui"
    cat > "$t/etc/systui/systemd-manager.conf" <<'EOF'
SYSTEMD_MANAGER=installed
ISH_AOK_COMPAT=enabled
MODE=automatic
NORMAL_LINUX=real-systemd
ISH_AOK=systui-compat-supervisor
EOF
    return 0
}

# Wrap the final postconfig function after all older rootfs compatibility
# layers have loaded. This makes systemd + iSH compatibility a build invariant
# for systemd-capable distributions without clobbering native-only distros.
if declare -F rootfs_postconfig >/dev/null 2>&1 && ! declare -F _systui_systemd_default_rootfs_postconfig >/dev/null 2>&1; then
    eval "$(declare -f rootfs_postconfig | sed '1s/^rootfs_postconfig[[:space:]]*()/_systui_systemd_default_rootfs_postconfig ()/')"
fi
rootfs_postconfig() {
    local target="$1" rc=0 ensure_rc=0
    _systui_systemd_default_rootfs_postconfig "$@" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"

    rootfs_ensure_systemd_manager "$target" || ensure_rc=$?
    case "$ensure_rc" in
        0) log "rootfs: systemd manager + iSH-AOK compatibility layer verified in $target" ;;
        2) log "rootfs: systemd unavailable/unsupported for this image; native init retained" ;;
        *) return "$ensure_rc" ;;
    esac
}

# ---------------------------------------------------------------------------
# Comprehensive current-system init configuration utility
# ---------------------------------------------------------------------------

sysconfig_init_detect_all() {
    {
        printf 'Detected INIT variable: %s\n\n' "${INIT:-unknown}"
        printf '%-12s %-10s %s\n' "Manager" "Available" "Evidence"
        printf '%-12s %-10s %s\n' "systemd"  "$(command -v systemctl >/dev/null 2>&1 && echo yes || echo no)" "$(command -v systemctl 2>/dev/null || true)"
        printf '%-12s %-10s %s\n' "OpenRC"   "$(command -v rc-service >/dev/null 2>&1 && echo yes || echo no)" "$(command -v rc-service 2>/dev/null || true)"
        printf '%-12s %-10s %s\n' "runit"    "$(command -v sv >/dev/null 2>&1 && echo yes || echo no)" "$(command -v sv 2>/dev/null || true)"
        printf '%-12s %-10s %s\n' "SysV"     "$(command -v service >/dev/null 2>&1 && echo yes || echo no)" "$(command -v service 2>/dev/null || true)"
        printf '\nPID 1: '; ps -p 1 -o comm= 2>/dev/null || true
        printf 'Kernel: '; uname -sr 2>/dev/null || true
        printf '/sbin/init: '; readlink -f /sbin/init 2>/dev/null || ls -l /sbin/init 2>/dev/null || true
        [ -r /etc/systui/ish-systemd-compat.conf ] && { printf '\n--- iSH-AOK systemd compatibility ---\n'; cat /etc/systui/ish-systemd-compat.conf; }
    } > "$SYSTUI_TMP/init-report"
    tui_text "Init manager inventory" "$SYSTUI_TMP/init-report"
}

sysconfig_init_service_list() {
    case "${INIT:-unknown}" in
        systemd) systemctl list-unit-files --type=service --no-pager 2>&1 > "$SYSTUI_TMP/init-list" ;;
        openrc)  rc-status -a > "$SYSTUI_TMP/init-list" 2>&1 ;;
        runit)   { echo "Enabled services:"; find /var/service /run/runit/service -mindepth 1 -maxdepth 1 -type l -o -type d 2>/dev/null; echo; echo "Definitions:"; find /etc/sv /etc/runit/sv -mindepth 1 -maxdepth 1 -type d 2>/dev/null; } > "$SYSTUI_TMP/init-list" ;;
        sysvinit) { service --status-all 2>&1; echo; ls -1 /etc/init.d 2>/dev/null; } > "$SYSTUI_TMP/init-list" ;;
        *) printf 'No supported active init manager detected.\n' > "$SYSTUI_TMP/init-list" ;;
    esac
    tui_text "Services — ${INIT:-unknown}" "$SYSTUI_TMP/init-list"
}

sysconfig_init_service_action() {
    local action="$1" s
    s=$(tui_input "Service $action" "Service/unit name:" "") || return 0
    [ -n "$s" ] || return 0
    if declare -F valid_safe_name >/dev/null 2>&1; then
        valid_safe_name "${s%.service}" || { tui_msg "Invalid service" "Use letters, digits, dots, dashes and underscores only."; return 0; }
    fi
    run_cmd "$action $s" svc "$action" "$s"
}

sysconfig_init_logs() {
    local s
    s=$(tui_input "Service logs" "Service/unit name (blank for manager logs):" "") || return 0
    case "${INIT:-unknown}" in
        systemd)
            if [ -n "$s" ]; then journalctl -u "$s" -n 250 --no-pager > "$SYSTUI_TMP/init-log" 2>&1
            else journalctl -b -n 400 --no-pager > "$SYSTUI_TMP/init-log" 2>&1; fi ;;
        openrc)
            { rc-status -a; echo; [ -n "$s" ] && rc-service "$s" status; echo; tail -n 250 /var/log/messages /var/log/syslog 2>/dev/null; } > "$SYSTUI_TMP/init-log" 2>&1 ;;
        runit)
            { [ -n "$s" ] && sv status "$s"; echo; find "/var/log/$s" -type f -maxdepth 2 -exec tail -n 100 {} \; 2>/dev/null; } > "$SYSTUI_TMP/init-log" 2>&1 ;;
        sysvinit)
            { [ -n "$s" ] && service "$s" status; echo; tail -n 250 /var/log/messages /var/log/syslog 2>/dev/null; } > "$SYSTUI_TMP/init-log" 2>&1 ;;
        *) printf 'No supported init manager detected.\n' > "$SYSTUI_TMP/init-log" ;;
    esac
    tui_text "Init/service logs" "$SYSTUI_TMP/init-log"
}

sysconfig_init_edit_config() {
    local c f=""
    c=$(tui_menu "Init configuration" "Choose configuration to edit:" \
        manager "Manager configuration" \
        boot "Boot/default target or runlevel configuration" \
        local "Local startup (/etc/rc.local)" \
        back "Back") || return 0
    case "${INIT:-unknown}:$c" in
        systemd:manager) f=/etc/systemd/system.conf ;;
        systemd:boot)    f=/etc/systemd/system/default.target ;;
        openrc:manager)  f=/etc/rc.conf ;;
        openrc:boot)     f=/etc/inittab ;;
        runit:manager)   f=/etc/runit/1 ;;
        runit:boot)      f=/etc/runit/2 ;;
        sysvinit:manager|sysvinit:boot) f=/etc/inittab ;;
        *:local) f=/etc/rc.local ;;
        *:back|*:"") return 0 ;;
        *) tui_msg "Unavailable" "No known configuration path for this init manager/action."; return 0 ;;
    esac
    [ -e "$f" ] || { mkdir -p "$(dirname "$f")"; : > "$f"; }
    safe_edit "$f"
    [ "${INIT:-}" = systemd ] && command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload 2>/dev/null || true
}

sysconfig_systemd_controls() {
    local c unit target
    command -v systemctl >/dev/null 2>&1 || { tui_msg "systemd" "systemctl is not installed."; return 0; }
    while true; do
        c=$(tui_menu "systemd advanced" "Units, targets and manager controls:" \
            failed "Show failed units" \
            deps "Show unit dependencies" \
            cat "Show unit file + drop-ins" \
            edit "Edit unit override (systemctl edit)" \
            mask "Mask a unit" \
            unmask "Unmask a unit" \
            target "Set default target" \
            reload "Daemon reload" \
            analyze "Boot/service timing analysis" \
            compat "Show iSH-AOK compatibility configuration" \
            back "Back") || return 0
        case "$c" in
            failed) systemctl --failed --no-pager > "$SYSTUI_TMP/systemd" 2>&1; tui_text "Failed units" "$SYSTUI_TMP/systemd" ;;
            deps) unit=$(tui_input "Dependencies" "Unit:" "") || continue; systemctl list-dependencies "$unit" --no-pager > "$SYSTUI_TMP/systemd" 2>&1; tui_text "Dependencies: $unit" "$SYSTUI_TMP/systemd" ;;
            cat) unit=$(tui_input "Show unit" "Unit:" "") || continue; systemctl cat "$unit" > "$SYSTUI_TMP/systemd" 2>&1; tui_text "Unit: $unit" "$SYSTUI_TMP/systemd" ;;
            edit) unit=$(tui_input "Edit override" "Unit:" "") || continue; SYSTEMD_EDITOR="${EDITOR:-nano}" systemctl edit "$unit" ;;
            mask) sysconfig_init_service_action mask ;;
            unmask) sysconfig_init_service_action unmask ;;
            target) target=$(tui_input "Default target" "Target:" "multi-user.target") || continue; run_cmd "Set default target" systemctl set-default "$target" ;;
            reload) run_cmd "systemd daemon-reload" systemctl daemon-reload ;;
            analyze) { systemd-analyze 2>&1; echo; systemd-analyze blame 2>&1 | head -100; } > "$SYSTUI_TMP/systemd"; tui_text "systemd analyze" "$SYSTUI_TMP/systemd" ;;
            compat) if [ -r /etc/systui/ish-systemd-compat.conf ]; then cp /etc/systui/ish-systemd-compat.conf "$SYSTUI_TMP/systemd"; else echo "iSH-AOK compatibility layer is not installed on this root." > "$SYSTUI_TMP/systemd"; fi; tui_text "iSH-AOK compatibility" "$SYSTUI_TMP/systemd" ;;
            back|"") return 0 ;;
        esac
    done
}

sysconfig_init_install_manager() {
    local mgr pkgs=""
    mgr=$(tui_radio "Install init manager" "Choose an init/service manager:" \
        systemd "systemd + D-Bus" on \
        openrc "OpenRC" off \
        runit "runit" off \
        sysvinit "SysV init" off) || return 0
    case "$mgr" in
        systemd) case "$PM" in apt) pkgs="systemd systemd-sysv dbus" ;; apk) tui_msg "Unsupported" "Alpine does not natively support systemd; use OpenRC."; return 0 ;; *) pkgs="systemd dbus" ;; esac ;;
        openrc) pkgs="openrc" ;;
        runit) case "$PM" in apt) pkgs="runit runit-init" ;; *) pkgs="runit" ;; esac ;;
        sysvinit) case "$PM" in apt) pkgs="sysvinit-core sysvinit-utils" ;; *) pkgs="sysvinit" ;; esac ;;
    esac
    # shellcheck disable=SC2086
    pm_install $pkgs || return 0
    detect_init 2>/dev/null || true
    tui_msg "Init manager" "$mgr packages installed. A reboot/rootfs restart may be required before PID 1 changes."
}

sysconfig_init_manager_menu() {
    local c
    detect_init 2>/dev/null || true
    while true; do
        c=$(tui_menu "Init configuration  [active: ${INIT:-unknown}]" "Configure init, boot and services:" \
            inventory "Detect installed init managers and PID 1" \
            list "List services/units" \
            status "Service status" \
            start "Start service" \
            stop "Stop service" \
            restart "Restart service" \
            enable "Enable service at boot" \
            disable "Disable service at boot" \
            logs "Service / manager logs" \
            config "Edit init boot/manager configuration" \
            systemd "systemd advanced units, targets, masks and analysis" \
            install "Install/switch init manager packages" \
            create "Create a validated systemd service" \
            refresh "Re-detect active init manager" \
            back "Back") || return 0
        case "$c" in
            inventory) sysconfig_init_detect_all ;;
            list) sysconfig_init_service_list ;;
            status|start|stop|restart|enable|disable) sysconfig_init_service_action "$c" ;;
            logs) sysconfig_init_logs ;;
            config) sysconfig_init_edit_config ;;
            systemd) sysconfig_systemd_controls ;;
            install) sysconfig_init_install_manager ;;
            create) declare -F sysconfig_create_systemd_service >/dev/null 2>&1 && sysconfig_create_systemd_service ;;
            refresh) detect_init; tui_msg "Init manager" "Detected: ${INIT:-unknown}" ;;
            back|"") return 0 ;;
        esac
    done
}

# Replace Services > Manage with the comprehensive init utility while keeping
# the existing create-service path intact.
menu_services() {
    local c
    while true; do
        c=$(tui_menu "Services  [init: ${INIT:-unknown}]" "Service and init management:" \
            manage "Comprehensive init configuration and service manager" \
            create "Create a validated simple systemd service" \
            back "Back") || return 0
        case "$c" in
            manage) sysconfig_init_manager_menu ;;
            create) declare -F sysconfig_create_systemd_service >/dev/null 2>&1 && sysconfig_create_systemd_service ;;
            back|"") return 0 ;;
        esac
    done
}

export -f rootfs_ensure_systemd_manager rootfs_postconfig \
    sysconfig_init_detect_all sysconfig_init_service_list sysconfig_init_service_action \
    sysconfig_init_logs sysconfig_init_edit_config sysconfig_systemd_controls \
    sysconfig_init_install_manager sysconfig_init_manager_menu menu_services
