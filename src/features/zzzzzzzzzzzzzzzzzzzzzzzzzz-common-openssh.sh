# shellcheck shell=bash
###############################################################################
# SYSTEM CONFIGURATION > COMMON TASKS > OPENSSH QUICK SETUP
###############################################################################

sysconfig_openssh_package() {
    case "$PM" in
        apt|apk|dnf|yum|xbps) printf '%s\n' openssh-server ;;
        pacman|zypper)        printf '%s\n' openssh ;;
        emerge)               printf '%s\n' net-misc/openssh ;;
        *)                    printf '%s\n' openssh-server ;;
    esac
}

sysconfig_openssh_service() {
    local s
    case "$INIT" in
        openrc) printf '%s\n' sshd; return 0 ;;
    esac
    for s in ssh sshd; do
        case "$INIT" in
            systemd)
                systemctl list-unit-files "$s.service" >/dev/null 2>&1 && { printf '%s\n' "$s"; return 0; }
                ;;
            sysvinit)
                [ -x "/etc/init.d/$s" ] && { printf '%s\n' "$s"; return 0; }
                ;;
            runit)
                [ -d "/etc/sv/$s" ] && { printf '%s\n' "$s"; return 0; }
                ;;
        esac
    done
    command -v rc-service >/dev/null 2>&1 && { printf '%s\n' sshd; return 0; }
    printf '%s\n' ssh
}

sysconfig_openssh_enable_start() {
    local svc="$1"
    case "$INIT" in
        systemd)
            run_cmd "Enable and start OpenSSH" systemctl enable --now "$svc.service"
            ;;
        openrc)
            run_cmd "Enable OpenSSH at boot" rc-update add "$svc" default || return 1
            if rc-service "$svc" status >/dev/null 2>&1; then
                run_cmd "Restart OpenSSH" rc-service "$svc" restart
            else
                run_cmd "Start OpenSSH" rc-service "$svc" start
            fi
            ;;
        sysvinit)
            if command -v update-rc.d >/dev/null 2>&1; then
                run_cmd "Enable OpenSSH at boot" update-rc.d "$svc" defaults || return 1
            elif command -v chkconfig >/dev/null 2>&1; then
                run_cmd "Enable OpenSSH at boot" chkconfig "$svc" on || return 1
            fi
            if command -v service >/dev/null 2>&1; then
                run_cmd "Restart OpenSSH" service "$svc" restart || run_cmd "Start OpenSSH" service "$svc" start
            else
                run_cmd "Start OpenSSH" "/etc/init.d/$svc" start
            fi
            ;;
        runit)
            [ -d "/etc/sv/$svc" ] || { tui_msg "OpenSSH" "runit service directory /etc/sv/$svc was not found."; return 1; }
            mkdir -p /etc/runit/runsvdir/default
            ln -sfn "/etc/sv/$svc" "/etc/runit/runsvdir/default/$svc"
            run_cmd "Start OpenSSH" sv up "$svc"
            ;;
        *)
            if command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1; then
                run_cmd "Enable OpenSSH at boot" rc-update add sshd default || return 1
                run_cmd "Start OpenSSH" rc-service sshd start || run_cmd "Restart OpenSSH" rc-service sshd restart
            elif command -v service >/dev/null 2>&1; then
                run_cmd "Start OpenSSH" service "$svc" start
            else
                tui_msg "OpenSSH" "OpenSSH was installed and configured, but systui could not determine how to enable/start it for init system '$INIT'."
                return 1
            fi
            ;;
    esac
}

sysconfig_openssh_quick_setup() {
    local pkg port auth rootlogin config_dir config_file tmp svc

    pkg=$(sysconfig_openssh_package)
    if ! command -v sshd >/dev/null 2>&1; then
        pm_install "$pkg" || {
            tui_msg "OpenSSH setup" "Could not install $pkg."
            return 1
        }
    fi

    command -v sshd >/dev/null 2>&1 || {
        tui_msg "OpenSSH setup" "The OpenSSH server package was installed, but sshd is not available on PATH."
        return 1
    }

    port=$(tui_input "OpenSSH quick setup" "SSH listening port:" "22") || return 0
    case "$port" in ''|*[!0-9]*) tui_msg "Invalid port" "Port must be a number from 1 to 65535."; return 0 ;; esac
    [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || { tui_msg "Invalid port" "Port must be from 1 to 65535."; return 0; }

    auth=$(tui_radio "OpenSSH quick setup" "Password authentication:" \
        yes "Allow password authentication" on \
        no  "Disable password authentication (keys only)" off) || return 0

    rootlogin=$(tui_radio "OpenSSH quick setup" "Root login policy:" \
        no "Disable root SSH login" on \
        prohibit-password "Allow root with SSH keys only" off \
        yes "Allow root login with password" off) || return 0

    command -v ssh-keygen >/dev/null 2>&1 && run_cmd "Generate missing SSH host keys" ssh-keygen -A || true

    config_dir=/etc/ssh/sshd_config.d
    config_file="$config_dir/10-systui-quick-setup.conf"
    mkdir -p "$config_dir"
    tmp=$(mktemp "${SYSTUI_TMP:-${TMPDIR:-/tmp}}/systui-sshd.XXXXXX") || return 1
    {
        printf 'Port %s\n' "$port"
        printf 'PasswordAuthentication %s\n' "$auth"
        printf 'PubkeyAuthentication yes\n'
        printf 'PermitRootLogin %s\n' "$rootlogin"
    } > "$tmp"

    install -m 0644 "$tmp" "$config_file" || { rm -f "$tmp"; return 1; }
    if ! sshd -t 2>"${SYSTUI_TMP:-/tmp}/sshd-quick.err"; then
        rm -f "$config_file"
        tui_text "OpenSSH validation failed" "${SYSTUI_TMP:-/tmp}/sshd-quick.err"
        rm -f "$tmp"
        return 1
    fi
    rm -f "$tmp"

    svc=$(sysconfig_openssh_service)
    if sysconfig_openssh_enable_start "$svc"; then
        tui_msg "OpenSSH ready" "OpenSSH server is installed and configured.\n\nPort: $port\nPasswordAuthentication: $auth\nPermitRootLogin: $rootlogin\nService: $svc\n\nThe service was started and configured to start at boot."
        return 0
    fi

    tui_msg "OpenSSH partially configured" "OpenSSH was installed and its configuration validated, but enabling or starting service '$svc' failed. Check $LOGFILE."
    return 1
}

menu_sysconfig_common() {
    while true; do
        local c
        c=$(tui_menu_no_tags "Common tasks" \
            "Frequently used settings, without walking the section menus:" \
            install   "Install or remove packages" \
            update    "Update and upgrade all packages" \
            hostname  "Set the system hostname ($(hostname))" \
            timezone  "Set the timezone ($(cat /etc/timezone 2>/dev/null || readlink /etc/localtime 2>/dev/null | sed 's|.*/zoneinfo/||' || echo unknown))" \
            user      "Add a user account" \
            shell     "Set the default login shell" \
            editor    "Install and configure editors" \
            sshsetup  "Install, configure, start and enable OpenSSH server" \
            ssh       "Configure the SSH server" \
            service   "Start, stop or enable a service" \
            scan      "Run a full system scan" \
            back      "Back") || return 0
        case "$c" in
            install)  menu_package_operations ;;
            update)   pm_update || tui_msg "Not supported" "No update command is defined for $PM." ;;
            hostname) sysconfig_set_hostname ;;
            timezone) sysconfig_set_timezone ;;
            user)     menu_users ;;
            shell)    menu_set_default_shell ;;
            editor)   menu_editors ;;
            sshsetup) sysconfig_openssh_quick_setup || true ;;
            ssh)      menu_ssh_server ;;
            service)  menu_services ;;
            scan)     menu_scan_system ;;
            back|"") return 0 ;;
        esac
    done
}

export -f sysconfig_openssh_quick_setup menu_sysconfig_common
