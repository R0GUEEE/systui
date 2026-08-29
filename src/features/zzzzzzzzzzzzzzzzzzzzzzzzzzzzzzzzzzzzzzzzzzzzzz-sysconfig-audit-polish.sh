# shellcheck shell=bash
###############################################################################
# SYSTEM CONFIGURATION — final audit polish
###############################################################################

sysconfig_quote_profile_value() { # <value>
    local v="$1"
    v=${v//\\/\\\\}; v=${v//\"/\\\"}; v=${v//\$/\\$}; v=${v//\`/\\`}
    printf '%s' "$v"
}

sysconfig_valid_ip_or_host() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9:.%-]{0,253}$ ]]
}

sysconfig_user_defaults() {
    command -v useradd >/dev/null 2>&1 || { tui_msg "N/A" "useradd defaults are unavailable on this system."; return 0; }
    local sh_ current
    current=$(useradd -D 2>/dev/null | awk -F= '$1=="SHELL"{print $2}')
    sh_=$(tui_radio "New-user defaults" "Default login shell for NEW users:" \
        /bin/bash "Bash" "$([ "$current" = /bin/bash ] && echo on || echo off)" \
        /bin/sh "sh" "$([ "$current" = /bin/sh ] && echo on || echo off)" \
        /bin/zsh "Zsh" "$([ "$current" = /bin/zsh ] && echo on || echo off)") || return 0
    [ -n "$sh_" ] || return 0
    [ -x "$sh_" ] || { tui_msg "Missing shell" "$sh_ is not installed."; return 0; }
    run_cmd "Set new-user default shell to $sh_" useradd -D -s "$sh_"
}

# Preserve the hardened user menu while restoring the dedicated default-shell
# action that existed before the first audit override.
if declare -F menu_users >/dev/null 2>&1 && ! declare -F _systui_audit_menu_users_polish >/dev/null 2>&1; then
    eval "$(declare -f menu_users | sed '1s/^menu_users[[:space:]]*()/_systui_audit_menu_users_polish ()/')"
fi
menu_users() {
    # The audited menu is intentionally kept, but its "defaults" branch called
    # Advanced. Reproduce it with a small routing shim by temporarily replacing
    # the advanced target only while the audited function runs is too fragile;
    # expose the correct action through a front menu instead.
    while true; do
        local c
        c=$(tui_menu "Users" "User management:" \
            manage "Accounts, passwords, sudo, groups, SSH keys" \
            defaults "Defaults for NEW users (shell, /etc/skel)" \
            advanced "Advanced password policy and login audit" \
            list "List human users" back "Back") || return 0
        case "$c" in
            manage) _systui_audit_menu_users_polish ;;
            defaults) sysconfig_user_defaults; tui_msg "New-user defaults" "Default shell updated. Files under /etc/skel are copied into new home directories." ;;
            advanced) sysconfig_call_menu menu_user_advanced "Advanced user settings" ;;
            list) awk -F: '$3>=1000 && $3<65534 {printf "%-16s uid=%-6s %s\n",$1,$3,$7}' /etc/passwd > "$SYSTUI_TMP/usr"; tui_text "Human users" "$SYSTUI_TMP/usr" ;;
            back|"") return 0 ;;
        esac
    done
}

sysconfig_apt_key_menu() {
    local a url name tmp
    while true; do
        a=$(tui_menu "APT Keys" "Signing-key tools:" \
            missing "Download missing distro archive keyrings" \
            import "Import a signing key from HTTPS URL" \
            list "List installed keyrings" back "Back") || return 0
        case "$a" in
            missing) sysconfig_call_menu apt_missing_keyrings_menu "Missing archive keyrings" ;;
            list) find /etc/apt/keyrings /usr/share/keyrings -maxdepth 1 -type f 2>/dev/null | sort > "$SYSTUI_TMP/keys"; [ -s "$SYSTUI_TMP/keys" ] || echo '(none)' > "$SYSTUI_TMP/keys"; tui_text "APT keyrings" "$SYSTUI_TMP/keys" ;;
            import)
                url=$(tui_input "APT signing key" "HTTPS key URL (.gpg/.asc/.key):" "") || continue
                [[ "$url" =~ ^https://[^[:space:]]+$ ]] || { tui_msg "Invalid URL" "Only single-line HTTPS URLs are accepted."; continue; }
                name=$(tui_input "APT signing key" "Keyring name (without extension):" "custom") || continue
                sysconfig_valid_repo_name "$name" || { tui_msg "Invalid name" "Use letters, digits, dots, underscores and dashes only."; continue; }
                mkdir -p /etc/apt/keyrings
                tmp=$(mktemp "$SYSTUI_TMP/aptkey.XXXXXX") || continue
                if ! _sys_fetch_text "$url" > "$tmp" || [ ! -s "$tmp" ]; then rm -f "$tmp"; tui_msg "Key download failed" "Could not download the key."; continue; fi
                if grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$tmp"; then
                    command -v gpg >/dev/null 2>&1 || pm_install gnupg || { rm -f "$tmp"; continue; }
                    if gpg --dearmor --yes -o "/etc/apt/keyrings/$name.gpg" "$tmp" 2>>"$LOGFILE"; then chmod 0644 "/etc/apt/keyrings/$name.gpg"; else tui_msg "Key import failed" "gpg could not decode the key."; fi
                else
                    install -m 0644 "$tmp" "/etc/apt/keyrings/$name.gpg"
                fi
                rm -f "$tmp"
                ;;
            back|"") return 0 ;;
        esac
    done
}

# Extend the audited repository menu rather than reverting to the unsafe base
# implementation just to recover APT import/list functionality.
if declare -F menu_repos >/dev/null 2>&1 && ! declare -F _systui_audit_menu_repos_polish >/dev/null 2>&1; then
    eval "$(declare -f menu_repos | sed '1s/^menu_repos[[:space:]]*()/_systui_audit_menu_repos_polish ()/')"
fi
menu_repos() {
    while true; do
        local c
        c=$(tui_menu "Repositories  [manager: ${PM:-unknown}]" "Repository management:" \
            standard "Repository sources, official/popular repos, refresh and removal" \
            keys "Signing keys / archive keyrings" back "Back") || return 0
        case "$c" in
            standard) _systui_audit_menu_repos_polish ;;
            keys) [ "${PM:-}" = apt ] && sysconfig_apt_key_menu || tui_msg "Signing keys" "Use the native $PM repository/key tooling for this package manager." ;;
            back|"") return 0 ;;
        esac
    done
}

sysconfig_service_output() { # <action> <service> <outfile>
    local action="$1" s="$2" out="$3"
    sysconfig_valid_token "$s" || { printf 'Invalid service name: %s\n' "$s" > "$out"; return 2; }
    case "$action" in
        status) svc status "$s" > "$out" 2>&1 ;;
        logs)
            if sysconfig_systemd_usable && command -v journalctl >/dev/null 2>&1; then
                journalctl -u "$s" -n 100 --no-pager > "$out" 2>&1
            else
                { tail -100 "/var/log/$s.log" 2>/dev/null || grep -hF "$s" /var/log/messages /var/log/syslog 2>/dev/null | tail -100; } > "$out"
                [ -s "$out" ] || echo '(no logs found)' > "$out"
            fi ;;
        unit)
            case "${INIT:-}" in
                systemd) systemctl cat "$s" > "$out" 2>&1 ;;
                openrc|sysvinit) cat -- "/etc/init.d/$s" > "$out" 2>&1 ;;
                runit)
                    if [ -f "/etc/sv/$s/run" ]; then cat -- "/etc/sv/$s/run" > "$out" 2>&1
                    elif [ -f "/etc/runit/sv/$s/run" ]; then cat -- "/etc/runit/sv/$s/run" > "$out" 2>&1
                    else echo '(service run file not found)' > "$out"; fi ;;
                *) echo '(unknown init system)' > "$out" ;;
            esac ;;
    esac
}

menu_services() {
    while true; do
        local c s a
        c=$(tui_menu "Services  [init: ${INIT:-unknown}]" "Service management:" \
            list "List services" failed "Show failed services" enable "Enable service" disable "Disable service" \
            start "Start service" stop "Stop service" restart "Restart service" status "Show status" logs "Show logs" unit "View unit/init file" \
            mask "Mask/unmask service (systemd)" create "Create simple systemd service" analyze "Boot analysis" initswap "Switch init system" advanced "Advanced service settings" back "Back") || return 0
        case "$c" in
            list)
                case "${INIT:-}" in
                    systemd) if sysconfig_systemd_usable; then systemctl list-units --type=service --no-pager; else echo 'systemd is installed but the system manager is not usable in this environment.'; fi ;;
                    openrc) rc-status -a 2>&1 ;;
                    runit) find /var/service /run/runit/service /service -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null ;;
                    sysvinit) service --status-all 2>&1 ;;
                    *) echo 'No supported init system detected.' ;;
                esac > "$SYSTUI_TMP/svc"; tui_text "Services (${INIT:-unknown})" "$SYSTUI_TMP/svc" ;;
            failed)
                if sysconfig_systemd_usable; then systemctl --failed --no-pager > "$SYSTUI_TMP/svc" 2>&1
                elif [ "${INIT:-}" = openrc ]; then rc-status -c > "$SYSTUI_TMP/svc" 2>&1
                else echo 'Failed-service listing is unavailable for this init/runtime.' > "$SYSTUI_TMP/svc"; fi
                tui_text "Failed services" "$SYSTUI_TMP/svc" ;;
            status|logs|unit)
                s=$(tui_input "Service" "Service name:" "") || continue
                sysconfig_valid_token "$s" || { tui_msg "Invalid service" "Use a simple service/unit name without slashes or whitespace."; continue; }
                sysconfig_service_output "$c" "$s" "$SYSTUI_TMP/svc" || true
                tui_text "$c: $s" "$SYSTUI_TMP/svc" ;;
            enable|disable|start|stop|restart)
                s=$(tui_input "Service" "Service name:" "") || continue
                sysconfig_valid_token "$s" || { tui_msg "Invalid service" "Use a simple service/unit name."; continue; }
                if [ "${INIT:-}" = systemd ] && ! sysconfig_systemd_usable; then tui_msg "systemd unavailable" "systemctl cannot control services in this runtime."; continue; fi
                run_cmd "$c $s (${INIT:-unknown})" svc "$c" "$s" ;;
            mask)
                sysconfig_systemd_usable || { tui_msg "N/A" "Masking requires a running systemd manager."; continue; }
                a=$(tui_radio "Mask service" "Action:" mask Mask on unmask Unmask off) || continue
                s=$(tui_input "Mask service" "Service name:" "") || continue
                sysconfig_valid_token "$s" || { tui_msg "Invalid service" "Unsafe service name."; continue; }
                run_cmd "systemctl $a $s" systemctl "$a" "$s" ;;
            create)
                sysconfig_systemd_usable || { tui_msg "N/A" "Unit creation/activation requires a usable systemd manager."; continue; }
                # Retain the mature validated unit creator from the previous menu
                # by directing the user to Advanced rather than duplicating it.
                tui_msg "Create service" "Use Services → Advanced for unit/service creation tools on this system." ;;
            analyze)
                sysconfig_systemd_usable && command -v systemd-analyze >/dev/null 2>&1 || { tui_msg "N/A" "Boot analysis requires a running systemd manager."; continue; }
                { systemd-analyze; echo; systemd-analyze blame | head -25; } > "$SYSTUI_TMP/svc" 2>&1; tui_text "Boot analysis" "$SYSTUI_TMP/svc" ;;
            initswap) initswap_current ;;
            advanced) sysconfig_call_menu menu_svc_advanced "Advanced services" ;;
            back|"") return 0 ;;
        esac
    done
}

sysconfig_scan_owner() {
    local f="$1"
    case "${PM:-}" in
        apt) dpkg -S -- "$f" ;;
        apk) apk info --who-owns "$f" ;;
        pacman) pacman -Qo -- "$f" ;;
        dnf|yum|zypper) rpm -qf -- "$f" ;;
        xbps) xbps-query -o "$f" ;;
        emerge) command -v qfile >/dev/null 2>&1 && qfile "$f" || echo 'Install app-portage/portage-utils for qfile.' ;;
        *) echo 'Unsupported package manager.' ;;
    esac
}

sysconfig_scan_files() {
    local p="$1"
    case "${PM:-}" in
        apt) dpkg -L -- "$p" ;;
        apk) apk info -L "$p" ;;
        pacman) pacman -Ql -- "$p" ;;
        dnf|yum|zypper) rpm -ql -- "$p" ;;
        xbps) xbps-query -f "$p" ;;
        emerge) command -v qlist >/dev/null 2>&1 && qlist "$p" || echo 'Install app-portage/portage-utils for qlist.' ;;
        *) echo 'Unsupported package manager.' ;;
    esac
}

menu_scan_queries() {
    while true; do
        local c f p n d
        c=$(tui_menu "Package & file queries" "Inspect installed files & packages:" \
            owns "Which package owns a file?" files "List files installed by a package" findfile "Find a file by name" \
            orphans "Orphaned / auto-removable packages" back "Back") || return 0
        case "$c" in
            owns) f=$(tui_input "File owner" "Absolute file path:" "") || continue; sysconfig_valid_abs_path "$f" || { tui_msg "Invalid path" "Enter an absolute single-line path."; continue; }; sysconfig_scan_owner "$f" > "$SYSTUI_TMP/scan" 2>&1; tui_text "Owner of $f" "$SYSTUI_TMP/scan" ;;
            files) p=$(tui_input "Package files" "Package name:" "") || continue; valid_pkg_name "$p" || { tui_msg "Invalid package" "Unsafe package name."; continue; }; sysconfig_scan_files "$p" > "$SYSTUI_TMP/scan" 2>&1; tui_text "Files in $p" "$SYSTUI_TMP/scan" ;;
            findfile) n=$(tui_input "Find file" "Filename or glob:" "") || continue; [ -n "$n" ] || continue; d=$(tui_input "Find file" "Search under absolute directory:" "/etc") || continue; sysconfig_valid_abs_path "$d" && [ -d "$d" ] || { tui_msg "Invalid directory" "Directory must be an existing absolute path."; continue; }; find "$d" -xdev -name "$n" -print 2>/dev/null | head -200 > "$SYSTUI_TMP/scan"; [ -s "$SYSTUI_TMP/scan" ] || echo '(no matches)' > "$SYSTUI_TMP/scan"; tui_text "Find results" "$SYSTUI_TMP/scan" ;;
            orphans)
                case "${PM:-}" in
                    apt) apt-get autoremove --dry-run 2>/dev/null | grep -E '^Remv|^  ' ;;
                    pacman) pacman -Qtdq 2>/dev/null || echo '(none)' ;;
                    dnf) dnf repoquery --unneeded 2>/dev/null ;;
                    yum) package-cleanup --leaves 2>/dev/null || echo 'Install yum-utils/package-cleanup for orphan queries.' ;;
                    zypper) zypper --non-interactive packages --orphaned 2>/dev/null ;;
                    xbps) xbps-query -O 2>/dev/null || echo 'XBPS orphan query is unavailable in this version.' ;;
                    apk) echo "apk dependency cleanup is normally handled by 'apk del' and world dependencies." ;;
                    emerge) emerge -pc 2>/dev/null ;;
                    *) echo 'Unsupported package manager.' ;;
                esac > "$SYSTUI_TMP/scan" 2>&1
                [ -s "$SYSTUI_TMP/scan" ] || echo '(none)' > "$SYSTUI_TMP/scan"
                tui_text "Orphaned packages" "$SYSTUI_TMP/scan" ;;
            back|"") return 0 ;;
        esac
    done
}

# Safe network front-end for the branches that accepted values into paths or
# shell snippets. Feature-specific submenus such as SSH remain delegated.
menu_network() {
    while true; do
        local c iface addr gw px npx d ns1 ns2 f p n a
        c=$(tui_menu "Network" "Network services & settings:" \
            ssh "OpenSSH server" fail2ban "fail2ban" vnc "VNC server" firewall "Firewall (ufw)" dns "Configure DNS resolvers" \
            staticip "Static IP configuration" proxy "System-wide HTTP(S) proxy" time "Timezone & NTP" hostname "Change hostname" \
            hosts "View /etc/hosts" ports "Show listening ports" info "Show network interfaces" advanced "Advanced network settings" back "Back") || return 0
        case "$c" in
            ssh) sysconfig_call_menu menu_ssh_server "OpenSSH server" ;;
            fail2ban)
                a=$(tui_menu "fail2ban" "Action:" install "Install & enable sshd jail" status "Show status" unban "Unban IP" back "Back") || continue
                case "$a" in
                    install) pm_install fail2ban || continue; mkdir -p /etc/fail2ban; cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
[sshd]
enabled = true
EOF
                        svc enable fail2ban 2>/dev/null || true; svc restart fail2ban 2>/dev/null || true ;;
                    status) { fail2ban-client status; echo; fail2ban-client status sshd; } > "$SYSTUI_TMP/net" 2>&1; tui_text "fail2ban status" "$SYSTUI_TMP/net" ;;
                    unban) p=$(tui_input "Unban" "IP address:" "") || continue; sysconfig_valid_ip_or_host "$p" && run_cmd "Unban $p" fail2ban-client set sshd unbanip "$p" ;;
                esac ;;
            vnc) tui_msg "VNC" "Use the package catalogue to install TigerVNC/x11vnc, then configure it for the graphical session you actually run. iSH-AOK itself does not provide a native X server." ;;
            firewall)
                command -v ufw >/dev/null 2>&1 || pm_install ufw || continue
                f=$(tui_menu "ufw" "Action:" enable Enable disable Disable allow "Allow port" deny "Deny port" delete "Delete numbered rule" status Status back Back) || continue
                case "$f" in
                    enable) ufw allow OpenSSH >/dev/null 2>&1 || true; run_cmd "ufw enable" ufw --force enable ;;
                    disable) run_cmd "ufw disable" ufw disable ;;
                    allow|deny) p=$(tui_input "$f port" "Port or service (e.g. 8080/tcp):" "") || continue; [[ "$p" =~ ^([0-9]{1,5}(/(tcp|udp))?|[A-Za-z0-9._-]+)$ ]] || { tui_msg "Invalid rule" "Use a port[/tcp|udp] or simple service name."; continue; }; run_cmd "ufw $f $p" ufw "$f" "$p" ;;
                    delete) n=$(tui_input "Delete rule" "Rule number:" "") || continue; [[ "$n" =~ ^[0-9]+$ ]] || { tui_msg "Invalid rule" "Rule number must be numeric."; continue; }; run_cmd "ufw delete $n" ufw --force delete "$n" ;;
                    status) ufw status numbered > "$SYSTUI_TMP/net" 2>&1; tui_text "ufw status" "$SYSTUI_TMP/net" ;;
                esac ;;
            dns)
                d=$(tui_radio "DNS" "Resolver set:" cloudflare "1.1.1.1 / 1.0.0.1" on google "8.8.8.8 / 8.8.4.4" off quad9 "9.9.9.9 / 149.112.112.112" off custom Custom off) || continue
                case "$d" in cloudflare) ns1=1.1.1.1; ns2=1.0.0.1;; google) ns1=8.8.8.8; ns2=8.8.4.4;; quad9) ns1=9.9.9.9; ns2=149.112.112.112;; custom) ns1=$(tui_input "DNS" "Primary resolver:" "") || continue; ns2=$(tui_input "DNS" "Secondary resolver (optional):" "") || continue;; esac
                sysconfig_valid_ip_or_host "$ns1" && { [ -z "$ns2" ] || sysconfig_valid_ip_or_host "$ns2"; } || { tui_msg "Invalid resolver" "Resolver contains unsupported characters."; continue; }
                cp -p /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%s)" 2>/dev/null || true; { printf 'nameserver %s\n' "$ns1"; [ -n "$ns2" ] && printf 'nameserver %s\n' "$ns2"; } > /etc/resolv.conf ;;
            staticip)
                iface=$(tui_input "Static IP" "Interface:" "eth0") || continue; sysconfig_valid_iface "$iface" || { tui_msg "Invalid interface" "Unsafe interface name."; continue; }
                addr=$(tui_input "Static IP" "Address with CIDR:" "") || continue; gw=$(tui_input "Static IP" "Gateway (optional):" "") || continue
                [[ "$addr" =~ ^[A-Fa-f0-9:.]+/[0-9]{1,3}$ ]] || { tui_msg "Invalid address" "Enter an IPv4/IPv6 address with CIDR prefix."; continue; }
                [ -z "$gw" ] || sysconfig_valid_ip_or_host "$gw" || { tui_msg "Invalid gateway" "Gateway is malformed."; continue; }
                if [ "${INIT:-}" = systemd ] && command -v networkctl >/dev/null 2>&1; then mkdir -p /etc/systemd/network; { printf '[Match]\nName=%s\n\n[Network]\nAddress=%s\n' "$iface" "$addr"; [ -n "$gw" ] && printf 'Gateway=%s\n' "$gw"; } > "/etc/systemd/network/90-systui-$iface.network"; tui_msg "Static IP" "Configuration written. Activate it only if systemd-networkd owns this interface."
                elif [ -d /etc/network ]; then mkdir -p /etc/network/interfaces.d; { printf 'auto %s\niface %s inet static\n    address %s\n' "$iface" "$iface" "$addr"; [ -n "$gw" ] && printf '    gateway %s\n' "$gw"; } > "/etc/network/interfaces.d/systui-$iface"; tui_msg "Static IP" "Configuration written to interfaces.d."
                else tui_msg "N/A" "No supported persistent network configuration backend was found."; fi ;;
            proxy)
                a=$(tui_radio "Proxy" "Action:" set Set on unset Remove off) || continue
                if [ "$a" = unset ]; then rm -f /etc/profile.d/92-systui-proxy.sh /etc/apt/apt.conf.d/95systui-proxy; continue; fi
                px=$(tui_input "Proxy" "Proxy URL:" "") || continue; [[ "$px" =~ ^https?://[^[:space:]\"\047]+$ ]] || { tui_msg "Invalid proxy" "Use a single-line HTTP(S) URL without quotes."; continue; }
                npx=$(tui_input "Proxy" "No-proxy list:" "localhost,127.0.0.1,.local") || continue; [ "$npx" != *$'\n'* ] && [ "$npx" != *$'\r'* ] || continue
                px=$(sysconfig_quote_profile_value "$px"); npx=$(sysconfig_quote_profile_value "$npx")
                cat > /etc/profile.d/92-systui-proxy.sh <<EOF
export http_proxy="$px" https_proxy="$px" ftp_proxy="$px"
export HTTP_PROXY="$px" HTTPS_PROXY="$px" FTP_PROXY="$px"
export no_proxy="$npx" NO_PROXY="$npx"
EOF
                [ "${PM:-}" = apt ] && printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$px" "$px" > /etc/apt/apt.conf.d/95systui-proxy ;;
            time)
                a=$(tui_menu "Time" "Timezone & NTP:" tz "Set timezone" ntp "Enable NTP sync" show "Show time status" back Back) || continue
                case "$a" in tz) sysconfig_set_timezone;; ntp) if sysconfig_systemd_usable && command -v timedatectl >/dev/null 2>&1; then run_cmd "Enable systemd NTP" timedatectl set-ntp true; else pm_install chrony || continue; svc enable chronyd 2>/dev/null || svc enable chrony 2>/dev/null || true; svc start chronyd 2>/dev/null || svc start chrony 2>/dev/null || true; fi;; show) { sysconfig_systemd_usable && timedatectl 2>/dev/null || date; } > "$SYSTUI_TMP/net"; tui_text "Time status" "$SYSTUI_TMP/net";; esac ;;
            hostname) sysconfig_set_hostname ;;
            hosts) tui_text "/etc/hosts" /etc/hosts ;;
            ports) { ss -tulnp 2>/dev/null || netstat -tulnp 2>/dev/null || echo 'ss/netstat unavailable'; } > "$SYSTUI_TMP/net"; tui_text "Listening ports" "$SYSTUI_TMP/net" ;;
            info) { ip addr 2>/dev/null || ifconfig -a 2>/dev/null || echo 'ip/ifconfig unavailable'; } > "$SYSTUI_TMP/net"; tui_text "Interfaces" "$SYSTUI_TMP/net" ;;
            advanced) sysconfig_call_menu menu_net_advanced "Advanced network settings" ;;
            back|"") return 0 ;;
        esac
    done
}

# Gate Ubuntu-only PPAs instead of offering Launchpad repositories on every APT
# distribution. The base installers remain available through package manager,
# GitHub, Homebrew, etc.
if declare -F menu_fish_install >/dev/null 2>&1 && ! declare -F _systui_base_menu_fish_install_polish >/dev/null 2>&1; then
    eval "$(declare -f menu_fish_install | sed '1s/^menu_fish_install[[:space:]]*()/_systui_base_menu_fish_install_polish ()/')"
fi
if declare -F menu_neovim_install >/dev/null 2>&1 && ! declare -F _systui_base_menu_neovim_install_polish >/dev/null 2>&1; then
    eval "$(declare -f menu_neovim_install | sed '1s/^menu_neovim_install[[:space:]]*()/_systui_base_menu_neovim_install_polish ()/')"
fi
sysconfig_host_is_ubuntu() {
    case " ${DISTRO:-} ${DISTRO_ID_LIKE:-} " in *' ubuntu '*) return 0;; esac
    return 1
}
# The base menus cannot be parameterized to hide just one choice. On non-Ubuntu
# APT hosts, temporarily present PM/GitHub/Homebrew choices through dedicated
# compact installers rather than exposing a dangerous PPA option.
menu_fish_install() {
    if [ "${PM:-}" != apt ] || sysconfig_host_is_ubuntu; then _systui_base_menu_fish_install_polish "$@"; return; fi
    local m opts=(pm "APT package (fish)"); command -v brew >/dev/null 2>&1 && opts+=(brew "Homebrew"); opts+=(back Back)
    m=$(tui_menu "Install Fish" "Launchpad PPAs are hidden on non-Ubuntu APT systems:" "${opts[@]}") || return 0
    case "$m" in pm) pm_install fish;; brew) run_cmd "Install Fish via Homebrew" brew install fish;; esac
}
menu_neovim_install() {
    if [ "${PM:-}" != apt ] || sysconfig_host_is_ubuntu; then _systui_base_menu_neovim_install_polish "$@"; return; fi
    local m opts=(pm "APT package (neovim)" github "GitHub release binary"); command -v brew >/dev/null 2>&1 && opts+=(brew Homebrew); opts+=(back Back)
    m=$(tui_menu "Install Neovim" "Ubuntu PPA hidden on this distribution:" "${opts[@]}") || return 0
    case "$m" in pm) pm_install neovim;; github) neovim_github_install;; brew) run_cmd "Install Neovim via Homebrew" brew install neovim;; esac
}

export -f sysconfig_quote_profile_value sysconfig_valid_ip_or_host sysconfig_user_defaults menu_users \
    sysconfig_apt_key_menu menu_repos sysconfig_service_output menu_services sysconfig_scan_owner \
    sysconfig_scan_files menu_scan_queries menu_network sysconfig_host_is_ubuntu menu_fish_install menu_neovim_install
