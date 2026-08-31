# shellcheck shell=bash
# PHASE 80 — install/manage alternate init utilities from System Config > Services.
#
# Installing an init provider never switches PID 1 automatically. Switching the
# active init remains an explicit Init Manager operation.

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

sysconfig_pm_command_available() { # <pm>
    case "${1:-}" in
        apt) command -v apt-get >/dev/null 2>&1 ;;
        apk) command -v apk >/dev/null 2>&1 ;;
        dnf) command -v dnf >/dev/null 2>&1 ;;
        yum) command -v yum >/dev/null 2>&1 ;;
        pacman) command -v pacman >/dev/null 2>&1 ;;
        zypper) command -v zypper >/dev/null 2>&1 ;;
        xbps) command -v xbps-install >/dev/null 2>&1 ;;
        emerge) command -v emerge >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

sysconfig_detect_package_manager() {
    # Reuse SystUI's PM only when its executable exists in the CURRENT runtime.
    # Bedrock/chroot/proot transitions can leave PM set to a manager from a
    # different environment, which otherwise results in "command not found".
    case "${PM:-}" in
        apt|apk|dnf|yum|pacman|zypper|xbps|emerge)
            if sysconfig_pm_command_available "$PM"; then
                printf '%s\n' "$PM"
                return 0
            fi
            ;;
    esac

    if command -v apt-get >/dev/null 2>&1; then printf 'apt\n'
    elif command -v apk >/dev/null 2>&1; then printf 'apk\n'
    elif command -v dnf >/dev/null 2>&1; then printf 'dnf\n'
    elif command -v yum >/dev/null 2>&1; then printf 'yum\n'
    elif command -v pacman >/dev/null 2>&1; then printf 'pacman\n'
    elif command -v zypper >/dev/null 2>&1; then printf 'zypper\n'
    elif command -v xbps-install >/dev/null 2>&1; then printf 'xbps\n'
    elif command -v emerge >/dev/null 2>&1; then printf 'emerge\n'
    else return 1
    fi
}

sysconfig_init_install_packages() { # <provider> <package-manager>
    local provider="$1" pm="$2"
    case "$pm:$provider" in
        apt:systemd) printf '%s\n' systemd ;;
        apt:openrc) printf '%s\n' openrc ;;
        apt:runit) printf '%s\n' runit ;;
        apt:sysvinit) printf '%s\n' 'sysvinit-core sysvinit-utils' ;;
        apt:busybox) printf '%s\n' busybox ;;
        apk:systemd) printf '%s\n' systemd ;;
        apk:openrc) printf '%s\n' openrc ;;
        apk:runit) printf '%s\n' runit ;;
        apk:sysvinit) printf '%s\n' sysvinit ;;
        apk:busybox) printf '%s\n' busybox ;;
        dnf:systemd|yum:systemd) printf '%s\n' systemd ;;
        dnf:openrc|yum:openrc) printf '%s\n' openrc ;;
        dnf:runit|yum:runit) printf '%s\n' runit ;;
        dnf:sysvinit|yum:sysvinit) printf '%s\n' initscripts ;;
        dnf:busybox|yum:busybox) printf '%s\n' busybox ;;
        pacman:systemd) printf '%s\n' systemd ;;
        pacman:openrc) printf '%s\n' openrc ;;
        pacman:runit) printf '%s\n' runit ;;
        pacman:sysvinit) printf '%s\n' sysvinit ;;
        pacman:busybox) printf '%s\n' busybox ;;
        zypper:systemd) printf '%s\n' systemd ;;
        zypper:openrc) printf '%s\n' openrc ;;
        zypper:runit) printf '%s\n' runit ;;
        zypper:sysvinit) printf '%s\n' sysvinit-tools ;;
        zypper:busybox) printf '%s\n' busybox ;;
        xbps:systemd) printf '%s\n' systemd ;;
        xbps:openrc) printf '%s\n' openrc ;;
        xbps:runit) printf '%s\n' runit ;;
        xbps:sysvinit) printf '%s\n' sysvinit ;;
        xbps:busybox) printf '%s\n' busybox ;;
        emerge:systemd) printf '%s\n' sys-apps/systemd ;;
        emerge:openrc) printf '%s\n' sys-apps/openrc ;;
        emerge:runit) printf '%s\n' sys-process/runit ;;
        emerge:sysvinit) printf '%s\n' sys-apps/sysvinit ;;
        emerge:busybox) printf '%s\n' sys-apps/busybox ;;
        *) return 1 ;;
    esac
}

sysconfig_init_packages_to_array() { # <provider> <pm> <array-name>
    local provider="$1" pm="$2" array_name="$3" raw
    raw=$(sysconfig_init_install_packages "$provider" "$pm") || return 1
    read -r -a "$array_name" <<< "$raw"
}

sysconfig_init_pm_install() { # <pm> <packages...>
    local pm="$1"
    shift
    [ "$#" -gt 0 ] || return 1

    sysconfig_pm_command_available "$pm" || {
        tui_msg "Init installer" "Package manager '$pm' was selected, but its command is not available in this runtime."
        return 127
    }

    if declare -F pm_install >/dev/null 2>&1; then
        local old_pm="${PM-}" had_pm=0 rc
        [ "${PM+x}" = x ] && had_pm=1
        PM="$pm"
        pm_install "$@"
        rc=$?
        if [ "$had_pm" -eq 1 ]; then PM="$old_pm"; else unset PM; fi
        return "$rc"
    fi

    case "$pm" in
        apt) run_cmd "Install init utilities" apt-get -o Dpkg::Use-Pty=0 install -y -- "$@" ;;
        apk) run_cmd "Install init utilities" apk add -- "$@" ;;
        dnf) run_cmd "Install init utilities" dnf install -y -- "$@" ;;
        yum) run_cmd "Install init utilities" yum install -y -- "$@" ;;
        pacman) run_cmd "Install init utilities" pacman -S --needed --noconfirm -- "$@" ;;
        zypper) run_cmd "Install init utilities" zypper --non-interactive install -- "$@" ;;
        xbps) run_cmd "Install init utilities" xbps-install -Sy -- "$@" ;;
        emerge) run_cmd "Install init utilities" emerge --ask=n -- "$@" ;;
        *) return 1 ;;
    esac
}

sysconfig_init_pm_remove() { # <pm> <packages...>
    local pm="$1"
    shift
    [ "$#" -gt 0 ] || return 1
    sysconfig_pm_command_available "$pm" || {
        tui_msg "Init installer" "Package manager '$pm' is not available in this runtime."
        return 127
    }
    case "$pm" in
        apt) run_cmd "Remove init utilities" apt-get -o Dpkg::Use-Pty=0 remove -y -- "$@" ;;
        apk) run_cmd "Remove init utilities" apk del -- "$@" ;;
        dnf) run_cmd "Remove init utilities" dnf remove -y -- "$@" ;;
        yum) run_cmd "Remove init utilities" yum remove -y -- "$@" ;;
        pacman) run_cmd "Remove init utilities" pacman -R --noconfirm -- "$@" ;;
        zypper) run_cmd "Remove init utilities" zypper --non-interactive remove -- "$@" ;;
        xbps) run_cmd "Remove init utilities" xbps-remove -Ry -- "$@" ;;
        emerge) run_cmd "Remove init utilities" emerge --unmerge --ask=n -- "$@" ;;
        *) return 1 ;;
    esac
}

sysconfig_install_init_provider() { # <provider>
    local provider="$1" pm label packages_text rc
    local -a packages=()
    label=$(sysconfig_init_display_name "$provider")

    pm=$(sysconfig_detect_package_manager) || {
        tui_msg "Init utilities" "No supported package manager command was found in the current runtime."
        return 1
    }
    sysconfig_init_packages_to_array "$provider" "$pm" packages || {
        tui_msg "Init utilities — $label" "No package mapping is available for $label on $pm."
        return 1
    }
    packages_text=$(printf '%s ' "${packages[@]}")
    packages_text=${packages_text% }

    if [ -t 1 ]; then clear 2>/dev/null || true; fi
    printf 'Installing %s init utilities using %s\n' "$label" "$pm"
    printf 'Packages: %s\n\n' "$packages_text"

    sysconfig_init_pm_install "$pm" "${packages[@]}"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        tui_msg "Init utilities — $label" "Installation failed (exit $rc). Package manager: $pm. Packages: $packages_text"
        return "$rc"
    fi

    sysconfig_refresh_init_state 2>/dev/null || true
    if sysconfig_init_provider_available "$provider" 2>/dev/null; then
        tui_msg "Init utilities — $label" "$label utilities were installed successfully. The active init was not changed."
    else
        tui_msg "Init utilities — $label" "Packages installed successfully. $label is not the active/detectable service provider yet; use Init Manager if you want to switch to it."
    fi
}

sysconfig_remove_init_provider() { # <provider>
    local provider="$1" pm label current packages_text
    local -a packages=()
    label=$(sysconfig_init_display_name "$provider")
    current=${SYSTUI_INIT_PROVIDER:-${INIT:-unknown}}
    if [ "$provider" = "$current" ]; then
        tui_msg "Remove $label" "Refusing to remove the currently active init provider. Switch to another init first."
        return 1
    fi
    pm=$(sysconfig_detect_package_manager) || {
        tui_msg "Remove $label" "No supported package manager command was found in the current runtime."
        return 1
    }
    sysconfig_init_packages_to_array "$provider" "$pm" packages || return 1
    packages_text=$(printf '%s ' "${packages[@]}")
    packages_text=${packages_text% }
    tui_yesno "Remove $label" "Remove $label packages?\n\nPackages: $packages_text\n\nOnly use this after confirming the system boots with another init." || return 0
    sysconfig_init_pm_remove "$pm" "${packages[@]}"
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
                        if sysconfig_init_provider_available "$provider" 2>/dev/null; then
                            menu_services_provider "$provider"
                        else
                            if sysconfig_install_init_provider "$provider"; then
                                sysconfig_init_provider_available "$provider" 2>/dev/null && menu_services_provider "$provider"
                            fi
                        fi
                        ;;
                    install) sysconfig_install_init_provider "$provider" || true ;;
                    remove) sysconfig_remove_init_provider "$provider" || true ;;
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
                    if sysconfig_install_init_provider "$c" && sysconfig_init_provider_available "$c"; then
                        menu_services_provider "$c"
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
