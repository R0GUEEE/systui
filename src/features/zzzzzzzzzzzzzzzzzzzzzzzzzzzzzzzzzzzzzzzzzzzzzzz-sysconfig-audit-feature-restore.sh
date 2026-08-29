# shellcheck shell=bash
###############################################################################
# SYSTEM CONFIGURATION — preserve audited feature parity
###############################################################################

if declare -F menu_network >/dev/null 2>&1 && ! declare -F _systui_audited_menu_network_core >/dev/null 2>&1; then
    eval "$(declare -f menu_network | sed '1s/^menu_network[[:space:]]*()/_systui_audited_menu_network_core ()/')"
fi

sysconfig_fail2ban_menu() {
    local a ip
    while true; do
        a=$(tui_menu "fail2ban" "SSH brute-force protection:" \
            install "Install and configure sshd jail" status "Show jail status" unban "Unban an IP address" back "Back") || return 0
        case "$a" in
            install)
                pm_install fail2ban || continue
                mkdir -p /etc/fail2ban
                cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5

[sshd]
enabled = true
EOF
                svc enable fail2ban 2>/dev/null || true
                svc restart fail2ban 2>/dev/null || true
                tui_msg "fail2ban" "sshd jail configured: 5 failures in 10 minutes gives a 1-hour ban." ;;
            status)
                { fail2ban-client status; echo; fail2ban-client status sshd; } > "$SYSTUI_TMP/net" 2>&1
                tui_text "fail2ban status" "$SYSTUI_TMP/net" ;;
            unban)
                ip=$(tui_input "Unban" "IP address:" "") || continue
                [[ "$ip" =~ ^[A-Fa-f0-9:.]+$ ]] || { tui_msg "Invalid IP" "Enter an IPv4 or IPv6 address."; continue; }
                run_cmd "Unban $ip" fail2ban-client set sshd unbanip "$ip" ;;
            back|"") return 0 ;;
        esac
    done
}

sysconfig_vnc_menu() {
    local v
    v=$(tui_radio "VNC server" "Choose a server:" \
        tigervnc "TigerVNC — own X session" on \
        x11vnc "x11vnc — mirror an existing X display" off) || return 0
    case "$v" in
        tigervnc)
            case "${PM:-}" in apt) pm_install tigervnc-standalone-server ;; *) pm_install tigervnc ;; esac || return 0
            tui_msg "TigerVNC" "Installed. Configure it as the target user with vncpasswd, then start a display such as vncserver :1." ;;
        x11vnc)
            pm_install x11vnc || return 0
            tui_msg "x11vnc" "Installed. Run it from the graphical user's session, for example: x11vnc -display :0 -usepw" ;;
    esac
}

menu_network() {
    local c
    while true; do
        c=$(tui_menu "Network" "Network configuration and services:" \
            settings "Addresses, DNS, proxy, firewall, SSH, time, hostname and diagnostics" \
            fail2ban "fail2ban brute-force protection" \
            vnc "VNC server installation" \
            back "Back") || return 0
        case "$c" in
            settings) _systui_audited_menu_network_core ;;
            fail2ban) sysconfig_fail2ban_menu ;;
            vnc) sysconfig_vnc_menu ;;
            back|"") return 0 ;;
        esac
    done
}

if declare -F menu_services >/dev/null 2>&1 && ! declare -F _systui_audited_menu_services_core >/dev/null 2>&1; then
    eval "$(declare -f menu_services | sed '1s/^menu_services[[:space:]]*()/_systui_audited_menu_services_core ()/')"
fi

sysconfig_create_systemd_service() {
    sysconfig_systemd_usable || { tui_msg "N/A" "Creating and activating a unit requires a usable systemd manager."; return 0; }
    local n d x u tmp
    n=$(tui_input "New service 1/4" "Service name (without .service):" "myapp") || return 0
    [[ "$n" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]{0,126}$ ]] || { tui_msg "Invalid name" "Use letters, digits, dots, @, dashes and underscores only."; return 0; }
    d=$(tui_input "New service 2/4" "Description:" "My application") || return 0
    x=$(tui_input "New service 3/4" "ExecStart (absolute executable path plus optional arguments):" "/usr/local/bin/myapp") || return 0
    u=$(tui_input "New service 4/4" "Run as user:" "root") || return 0
    sysconfig_require_existing_user "$u" || { tui_msg "Invalid user" "The service user does not exist."; return 0; }
    case "$x" in /*) ;; *) tui_msg "Invalid ExecStart" "ExecStart must begin with an absolute path."; return 0;; esac
    case "$x" in *$'\n'*|*$'\r'*) tui_msg "Invalid ExecStart" "ExecStart must be one line."; return 0;; esac
    case "$d" in *$'\n'*|*$'\r'*) tui_msg "Invalid description" "Description must be one line."; return 0;; esac
    mkdir -p /etc/systemd/system
    tmp=$(mktemp "$SYSTUI_TMP/unit.XXXXXX") || return 1
    cat > "$tmp" <<EOF
[Unit]
Description=$d
After=network.target

[Service]
Type=simple
User=$u
ExecStart=$x
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    if systemd-analyze verify "$tmp" >/dev/null 2>"$SYSTUI_TMP/unit.err"; then
        install -m 0644 "$tmp" "/etc/systemd/system/$n.service"
        systemctl daemon-reload
        if tui_yesno "Enable service" "Unit validated and installed. Enable and start $n.service now?"; then
            run_cmd "Enable $n.service" systemctl enable --now "$n.service"
        fi
    else
        tui_text "Unit validation failed" "$SYSTUI_TMP/unit.err"
    fi
    rm -f "$tmp"
}

menu_services() {
    local c
    while true; do
        c=$(tui_menu "Services  [init: ${INIT:-unknown}]" "Service management:" \
            manage "List, status, start/stop, logs, units, masking and advanced controls" \
            create "Create a validated simple systemd service" \
            back "Back") || return 0
        case "$c" in
            manage) _systui_audited_menu_services_core ;;
            create) sysconfig_create_systemd_service ;;
            back|"") return 0 ;;
        esac
    done
}

export -f sysconfig_fail2ban_menu sysconfig_vnc_menu menu_network sysconfig_create_systemd_service menu_services
