# shellcheck shell=bash
# PHASE 80 — install/manage alternate init utilities from System Config > Services.
#
# This phase intentionally installs service-management utilities without
# automatically replacing PID 1. Switching the active init remains an explicit
# Init Manager operation.

sysconfig_init_display_name() {
    case "${1:-}" in
        systemd) printf 'systemd\n' ;;
        openrc) printf 'OpenRC\n' ;;
        runit) printf 'runit\n' ;;
        sysvinit) printf 'SysVinit\n' ;;
        busybox) printf 'BusyBox init\n' ;;
        *) printf '%s\n' "${1:-unknown}" ;;
    esac
}

sysconfig_init_install_packages() { # <provider> <package-manager>
    local provider="$1" pm="$2"
    case "$pm:$provider" in
        apt:systemd) printf 'systemd\n' ;;
        apt:openrc) printf 'openrc\n' ;;
        apt:runit) printf 'runit\n' ;;
        apt:sysvinit) printf 'sysvinit-core sysvinit-utils\n' ;;
        apt:busybox) printf 'busybox\n' ;;

        apk:systemd) printf 'systemd\n' ;;
        apk:openrc) printf 'openrc\n' ;;
        apk:runit) printf 'runit\n' ;;
        apk:sysvinit) printf 'sysvinit\n' ;;
        apk:busybox) printf 'busybox\n' ;;

        dnf:systemd|yum:systemd) printf 'systemd\n' ;;
        dnf:openrc|yum:openrc) printf 'openrc\n' ;;
        dnf:runit|yum:runit) printf 'runit\n' ;;
        dnf:sysvinit|yum:sysvinit) printf 'initscripts\n' ;;
        dnf:busybox|yum:busybox) printf 'busybox\n' ;;

        pacman:systemd) printf 'systemd\n' ;;
        pacman:openrc) printf 'openrc\n' ;;
        pacman:runit) printf 'runit\n' ;;
        pacman:sysvinit) printf 'sysvinit\n' ;;
        pacman:busybox) printf 'busybox\n' ;;

        zypper:systemd) printf 'systemd\n' ;;
        zypper:openrc) printf 'openrc\n' ;;
        zypper:runit) printf 'runit\n' ;;
        zypper:sysvinit) printf 'sysvinit-tools\n' ;;
        zypper:busybox) printf 'busybox\n' ;;

        xbps:systemd) printf 'systemd\n' ;;
        xbps:openrc) printf 'openrc\n' ;;
        xbps:runit) printf 'runit\n' ;;
        xbps:sysvinit) printf 'sysvinit\n' ;;
        xbps:busybox) printf 'busybox\n' ;;
        *) return 1 ;;
    esac
}

sysconfig_detect_package_manager() {
    if command -v apt-get >/dev/null 2>&1; then printf 'apt\n'
    elif command -v apk >/dev/null 2>&1; then printf 'apk\n'
    elif command -v dnf >/dev/null 2>&1; then printf 'dnf\n'
    elif command -v yum >/dev/null 2>&1; then printf 'yum\n'
    elif command -v pacman >/dev/null 2>&1; then printf 'pacman\n'
    elif command -v zypper >/dev/null 2>&1; then printf 'zypper\n'
    elif command -v xbps-install >/dev/null 2>&1; then printf 'xbps\n'
    else return 1
    fi
}

sysconfig_install_init_provider() { # <provider>
    local provider="$1" pm packages label
    label=$(sysconfig_init_display_name "$provider")

    if sysconfig_init_provider_available "$provider" 2>/dev/null; then
        tui_msg "Init utilities — $label" "$label is already installed/detected."
        return 0
    fi

    pm=$(sysconfig_detect_package_manager) || {
        tui_msg "Init utilities" "No supported package manager was detected. Supported: apt, apk, dnf, yum, pacman, zypper, xbps."
        return 1
    }
    packages=$(sysconfig_init_install_packages "$provider" "$pm") || {
        tui_msg "Init utilities — $label" "No package mapping is available for $label on $pm."
        return 1
    }

    if declare -F tui_yesno >/dev/null 2>&1; then
        tui_yesno "Install $label" "Install $label service/init utilities using $pm?\n\nPackages: $packages\n\nThis does NOT switch PID 1 or make $label the active init." || return 0
    fi

    case "$pm" in
        apt) run_cmd "Install $label" apt-get -o Dpkg::Use-Pty=0 install -y -- $packages ;;
        apk) run_cmd "Install $label" apk add $packages ;;
        dnf) run_cmd "Install $label" dnf install -y -- $packages ;;
        yum) run_cmd "Install $label" yum install -y -- $packages ;;
        pacman) run_cmd "Install $label" pacman -S --needed --noconfirm $packages ;;
        zypper) run_cmd "Install $label" zypper --non-interactive install $packages ;;
        xbps) run_cmd "Install $label" xbps-install -Sy $packages ;;
        *) return 1 ;;
    esac || return $?

    sysconfig_refresh_init_state 2>/dev/null || true
    if sysconfig_init_provider_available "$provider" 2>/dev/null; then
        tui_msg "Init utilities — $label" "$label was installed successfully. The active init was not changed."
    else
        tui_msg "Init utilities — $label" "Package installation completed, but SystUI could not detect $label's management utilities yet."
    fi
}

sysconfig_remove_init_provider() { # <provider>
    local provider="$1" pm packages label current
    label=$(sysconfig_init_display_name "$provider")
    current=${SYSTUI_INIT_PROVIDER:-${INIT:-unknown}}
    if [ "$provider" = "$current" ]; then
        tui_msg "Remove $label" "Refusing to remove the currently active init provider. Switch to another init first."
        return 1
    fi
    pm=$(sysconfig_detect_package_manager) || return 1
    packages=$(sysconfig_init_install_packages "$provider" "$pm") || return 1
    tui_yesno "Remove $label" "Remove $label packages?\n\nPackages: $packages\n\nOnly use this after confirming the system boots with another init." || return 0
    case "$pm" in
        apt) run_cmd "Remove $label" apt-get -o Dpkg::Use-Pty=0 remove -y -- $packages ;;
        apk) run_cmd "Remove $label" apk del $packages ;;
        dnf) run_cmd "Remove $label" dnf remove -y -- $packages ;;
        yum) run_cmd "Remove $label" yum remove -y -- $packages ;;
        pacman) run_cmd "Remove $label" pacman -R --noconfirm $packages ;;
        zypper) run_cmd "Remove $label" zypper --non-interactive remove $packages ;;
        xbps) run_cmd "Remove $label" xbps-remove -Ry $packages ;;
    esac
}

menu_init_utilities() {
    local c provider action label state
    while true; do
        sysconfig_refresh_init_state 2>/dev/null || true
        c=$(tui_menu "Init utilities" "Install and manage alternate init/service utilities. Installation never changes PID 1 automatically." \
            systemd "systemd — install/manage utilities" \
            openrc "OpenRC — install/manage utilities" \
            runit "runit — install/manage utilities" \
            sysvinit "SysVinit — install/manage utilities" \
            busybox "BusyBox init — install/manage utilities" \
            status "Show installed init providers" \
            switch "Switch active init (Init Manager)" \
            back "Back") || return 0
        case "$c" in
            systemd|openrc|runit|sysvinit|busybox)
                provider="$c"; label=$(sysconfig_init_display_name "$provider")
                if sysconfig_init_provider_available "$provider" 2>/dev/null; then state=installed; else state='not installed'; fi
                action=$(tui_menu "$label  [$state]" "Choose an action. Current active init: ${SYSTUI_INIT_PROVIDER:-${INIT:-unknown}}" \
                    manage "Manage $label services" \
                    install "Install/reinstall $label utilities" \
                    remove "Remove $label utilities" \
                    back "Back") || continue
                case "$action" in
                    manage)
                        if sysconfig_init_provider_available "$provider" 2>/dev/null; then menu_services_provider "$provider"
                        else tui_yesno "$label not installed" "Install $label utilities now?" && sysconfig_install_init_provider "$provider"; fi
                        ;;
                    install) sysconfig_install_init_provider "$provider" ;;
                    remove) sysconfig_remove_init_provider "$provider" ;;
                esac
                ;;
            status)
                {
                    printf 'Active init: %s\n\n' "${SYSTUI_INIT_PROVIDER:-${INIT:-unknown}}"
                    for provider in systemd openrc runit sysvinit busybox; do
                        label=$(sysconfig_init_display_name "$provider")
                        if sysconfig_init_provider_available "$provider" 2>/dev/null; then printf '%-12s installed\n' "$label"
                        else printf '%-12s not installed\n' "$label"; fi
                    done
                } > "$SYSTUI_TMP/init-utilities"
                tui_text "Init utilities" "$SYSTUI_TMP/init-utilities"
                ;;
            switch) menu_init_manager ;;
            back|'') return 0 ;;
        esac
    done
}

# Final Services front door. This intentionally supersedes phases 69/76/79.
menu_services() {
    local c current label
    while true; do
        sysconfig_refresh_init_state
        current=${SYSTUI_INIT_PROVIDER:-${INIT:-unknown}}
        c=$(tui_menu "Services  [current: $current]" "Manage services and install alternate init/service utilities:" \
            current "Manage current provider ($current)" \
            initutils "Install / manage init utilities" \
            systemd "systemd services / units" \
            openrc "OpenRC services" \
            runit "runit services" \
            sysvinit "SysVinit services" \
            busybox "BusyBox init / inittab services" \
            initmgr "Init Manager / switch provider" \
            advanced "Advanced service settings" \
            back "Back") || return 0
        case "$c" in
            current)
                case "$current" in
                    systemd|openrc|runit|sysvinit|busybox) menu_services_provider "$current" ;;
                    *) tui_msg "Services" "No supported active provider detected." ;;
                esac
                ;;
            initutils) menu_init_utilities ;;
            systemd|openrc|runit|sysvinit|busybox)
                if sysconfig_init_provider_available "$c"; then
                    menu_services_provider "$c"
                else
                    label=$(sysconfig_init_display_name "$c")
                    if tui_yesno "Services — $label" "$label is not installed/detected. Install its utilities now?"; then
                        sysconfig_install_init_provider "$c" && sysconfig_init_provider_available "$c" && menu_services_provider "$c"
                    fi
                fi
                ;;
            initmgr) menu_init_manager ;;
            advanced) sysconfig_call_menu menu_svc_advanced "Advanced services" ;;
            back|'') return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
