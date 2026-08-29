# shellcheck shell=bash
###############################################################################
# SYSTEM CONFIGURATION — final audit polish (parser-safe)
###############################################################################

sysconfig_valid_ip_or_host() {
    [[ "${1:-}" =~ ^[A-Za-z0-9][A-Za-z0-9:.%-]{0,253}$ ]]
}

sysconfig_user_defaults() {
    command -v useradd >/dev/null 2>&1 || { tui_msg "N/A" "useradd defaults are unavailable on this system."; return 0; }
    local sh_ current bstate=off sstate=off zstate=off
    current=$(useradd -D 2>/dev/null | awk -F= '$1=="SHELL"{print $2}')
    [ "$current" = /bin/bash ] && bstate=on
    [ "$current" = /bin/sh ] && sstate=on
    [ "$current" = /bin/zsh ] && zstate=on
    sh_=$(tui_radio "New-user defaults" "Default login shell for NEW users:" \
        /bin/bash "Bash" "$bstate" /bin/sh "sh" "$sstate" /bin/zsh "Zsh" "$zstate") || return 0
    [ -n "$sh_" ] || return 0
    [ -x "$sh_" ] || { tui_msg "Missing shell" "$sh_ is not installed."; return 0; }
    run_cmd "Set new-user default shell to $sh_" useradd -D -s "$sh_"
}

if declare -F menu_user_advanced >/dev/null 2>&1 && ! declare -F _systui_base_menu_user_advanced_polish >/dev/null 2>&1; then
    eval "$(declare -f menu_user_advanced | sed '1s/^menu_user_advanced[[:space:]]*()/_systui_base_menu_user_advanced_polish ()/')"
fi
menu_user_advanced() {
    local c
    c=$(tui_menu "Users — Advanced" "User defaults and advanced policy:" \
        defaults "Defaults for NEW users (login shell; /etc/skel remains system template)" \
        policy "Password policy, sessions and login audit" back "Back") || return 0
    case "$c" in
        defaults) sysconfig_user_defaults ;;
        policy) _systui_base_menu_user_advanced_polish ;;
    esac
}

sysconfig_apt_key_menu() {
    local a url name tmp
    while true; do
        a=$(tui_menu "APT Keys" "Signing-key tools:" \
            missing "Download missing distro archive keyrings" \
            import "Import a signing key from an HTTPS URL" \
            list "List installed keyrings" back "Back") || return 0
        case "$a" in
            missing) sysconfig_call_menu apt_missing_keyrings_menu "Missing archive keyrings" ;;
            list)
                find /etc/apt/keyrings /usr/share/keyrings -maxdepth 1 -type f 2>/dev/null | sort > "$SYSTUI_TMP/keys"
                [ -s "$SYSTUI_TMP/keys" ] || echo '(none)' > "$SYSTUI_TMP/keys"
                tui_text "APT keyrings" "$SYSTUI_TMP/keys" ;;
            import)
                url=$(tui_input "APT signing key" "HTTPS key URL:" "") || continue
                case "$url" in https://*) ;; *) tui_msg "Invalid URL" "Only HTTPS key URLs are accepted."; continue;; esac
                case "$url" in *[[:space:]]*) tui_msg "Invalid URL" "URL must be one line without whitespace."; continue;; esac
                name=$(tui_input "APT signing key" "Keyring name (without extension):" "custom") || continue
                sysconfig_valid_repo_name "$name" || { tui_msg "Invalid name" "Use letters, digits, dots, underscores and dashes only."; continue; }
                mkdir -p /etc/apt/keyrings
                tmp=$(mktemp "$SYSTUI_TMP/aptkey.XXXXXX") || continue
                if ! _sys_fetch_text "$url" > "$tmp" || [ ! -s "$tmp" ]; then
                    rm -f "$tmp"; tui_msg "Key download failed" "Could not download the key."; continue
                fi
                if grep -q 'BEGIN PGP PUBLIC KEY BLOCK' "$tmp"; then
                    command -v gpg >/dev/null 2>&1 || pm_install gnupg || { rm -f "$tmp"; continue; }
                    gpg --dearmor --yes -o "/etc/apt/keyrings/$name.gpg" "$tmp" 2>>"$LOGFILE" || { rm -f "$tmp"; tui_msg "Key import failed" "gpg could not decode the key."; continue; }
                    chmod 0644 "/etc/apt/keyrings/$name.gpg"
                else
                    install -m 0644 "$tmp" "/etc/apt/keyrings/$name.gpg"
                fi
                rm -f "$tmp"
                ;;
            back|"") return 0 ;;
        esac
    done
}

if declare -F menu_repos >/dev/null 2>&1 && ! declare -F _systui_base_menu_repos_polish >/dev/null 2>&1; then
    eval "$(declare -f menu_repos | sed '1s/^menu_repos[[:space:]]*()/_systui_base_menu_repos_polish ()/')"
fi
menu_repos() {
    local c
    while true; do
        c=$(tui_menu "Repositories  [manager: ${PM:-unknown}]" "Repository management:" \
            sources "Sources, official/popular repos, refresh and removal" \
            keys "Signing keys / archive keyrings" back "Back") || return 0
        case "$c" in
            sources) _systui_base_menu_repos_polish ;;
            keys) [ "${PM:-}" = apt ] && sysconfig_apt_key_menu || tui_msg "Signing keys" "Use the native ${PM:-package-manager} key/repository tooling." ;;
            back|"") return 0 ;;
        esac
    done
}

sysconfig_service_output() {
    local action="$1" s="$2" out="$3"
    sysconfig_valid_token "$s" || { echo "Invalid service name: $s" > "$out"; return 2; }
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
            mask "Mask/unmask service (systemd)" analyze "Boot analysis" initswap "Switch init system" advanced "Advanced service settings" back "Back") || return 0
        case "$c" in
            list)
                case "${INIT:-}" in
                    systemd) if sysconfig_systemd_usable; then systemctl list-units --type=service --no-pager; else echo 'systemd manager is not usable in this runtime.'; fi ;;
                    openrc) rc-status -a 2>&1 ;;
                    runit) for s in /var/service/* /run/runit/service/* /service/*; do [ -d "$s" ] && basename "$s"; done ;;
                    sysvinit) service --status-all 2>&1 ;;
                    *) echo 'No supported init system detected.' ;;
                esac > "$SYSTUI_TMP/svc"
                tui_text "Services (${INIT:-unknown})" "$SYSTUI_TMP/svc" ;;
            failed)
                if sysconfig_systemd_usable; then systemctl --failed --no-pager > "$SYSTUI_TMP/svc" 2>&1
                elif [ "${INIT:-}" = openrc ]; then rc-status -c > "$SYSTUI_TMP/svc" 2>&1
                else echo 'Failed-service listing is unavailable for this init/runtime.' > "$SYSTUI_TMP/svc"; fi
                tui_text "Failed services" "$SYSTUI_TMP/svc" ;;
            status|logs|unit)
                s=$(tui_input "Service" "Service name:" "") || continue
                sysconfig_valid_token "$s" || { tui_msg "Invalid service" "Service names cannot contain slashes or whitespace."; continue; }
                sysconfig_service_output "$c" "$s" "$SYSTUI_TMP/svc" || true
                tui_text "$c: $s" "$SYSTUI_TMP/svc" ;;
            enable|disable|start|stop|restart)
                s=$(tui_input "Service" "Service name:" "") || continue
                sysconfig_valid_token "$s" || { tui_msg "Invalid service" "Unsafe service name."; continue; }
                if [ "${INIT:-}" = systemd ] && ! sysconfig_systemd_usable; then tui_msg "systemd unavailable" "systemctl cannot control services in this runtime."; continue; fi
                run_cmd "$c $s (${INIT:-unknown})" svc "$c" "$s" ;;
            mask)
                sysconfig_systemd_usable || { tui_msg "N/A" "Masking requires a running systemd manager."; continue; }
                a=$(tui_radio "Mask service" "Action:" mask Mask on unmask Unmask off) || continue
                s=$(tui_input "Mask service" "Service name:" "") || continue
                sysconfig_valid_token "$s" || { tui_msg "Invalid service" "Unsafe service name."; continue; }
                run_cmd "systemctl $a $s" systemctl "$a" "$s" ;;
            analyze)
                sysconfig_systemd_usable && command -v systemd-analyze >/dev/null 2>&1 || { tui_msg "N/A" "Boot analysis requires a running systemd manager."; continue; }
                { systemd-analyze; echo; systemd-analyze blame | head -25; } > "$SYSTUI_TMP/svc" 2>&1
                tui_text "Boot analysis" "$SYSTUI_TMP/svc" ;;
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
            owns "Which package owns a file?" files "List files installed by a package" findfile "Find a file by name" orphans "Orphaned / auto-removable packages" back "Back") || return 0
        case "$c" in
            owns) f=$(tui_input "File owner" "Absolute file path:" "") || continue; sysconfig_valid_abs_path "$f" || { tui_msg "Invalid path" "Enter an absolute single-line path."; continue; }; sysconfig_scan_owner "$f" > "$SYSTUI_TMP/scan" 2>&1; tui_text "Owner of $f" "$SYSTUI_TMP/scan" ;;
            files) p=$(tui_input "Package files" "Package name:" "") || continue; valid_pkg_name "$p" || { tui_msg "Invalid package" "Unsafe package name."; continue; }; sysconfig_scan_files "$p" > "$SYSTUI_TMP/scan" 2>&1; tui_text "Files in $p" "$SYSTUI_TMP/scan" ;;
            findfile) n=$(tui_input "Find file" "Filename or glob:" "") || continue; [ -n "$n" ] || continue; d=$(tui_input "Find file" "Search under absolute directory:" "/etc") || continue; sysconfig_valid_abs_path "$d" && [ -d "$d" ] || { tui_msg "Invalid directory" "Directory must be an existing absolute path."; continue; }; find "$d" -xdev -name "$n" -print 2>/dev/null | head -200 > "$SYSTUI_TMP/scan"; [ -s "$SYSTUI_TMP/scan" ] || echo '(no matches)' > "$SYSTUI_TMP/scan"; tui_text "Find results" "$SYSTUI_TMP/scan" ;;
            orphans)
                case "${PM:-}" in
                    apt) apt-get autoremove --dry-run 2>/dev/null | grep -E '^Remv|^  ' ;;
                    pacman) pacman -Qtdq 2>/dev/null || echo '(none)' ;;
                    dnf) dnf repoquery --unneeded 2>/dev/null ;;
                    zypper) zypper --non-interactive packages --orphaned 2>/dev/null ;;
                    apk) echo "apk dependency cleanup is normally handled by apk del/world dependencies." ;;
                    xbps) echo "Use xbps-remove -Oo for orphan cleanup." ;;
                    emerge) emerge -pc 2>/dev/null ;;
                    *) echo 'Unsupported package manager.' ;;
                esac > "$SYSTUI_TMP/scan" 2>&1
                [ -s "$SYSTUI_TMP/scan" ] || echo '(none)' > "$SYSTUI_TMP/scan"
                tui_text "Orphaned packages" "$SYSTUI_TMP/scan" ;;
            back|"") return 0 ;;
        esac
    done
}

sysconfig_proxy_url_valid() {
    local p="$1"
    case "$p" in http://*|https://*) ;; *) return 1;; esac
    case "$p" in *[[:space:]]*|*\"*|*\'*|*\`*|*\$*|*\\*) return 1;; esac
    return 0
}

menu_network() {
    while true; do
        local c iface addr gw px npx f p n a d ns1 ns2
        c=$(tui_menu "Network" "Network services & settings:" \
            ssh "OpenSSH server" firewall "Firewall (ufw)" dns "Configure DNS resolvers" staticip "Static IP configuration" \
            proxy "System-wide HTTP(S) proxy" time "Timezone & NTP" hostname "Change hostname" hosts "View /etc/hosts" \
            ports "Show listening ports" info "Show network interfaces" advanced "Advanced network settings" back "Back") || return 0
        case "$c" in
            ssh) sysconfig_call_menu menu_ssh_server "OpenSSH server" ;;
            firewall)
                command -v ufw >/dev/null 2>&1 || pm_install ufw || continue
                f=$(tui_menu "ufw" "Action:" enable Enable disable Disable allow "Allow port" deny "Deny port" delete "Delete numbered rule" status Status back Back) || continue
                case "$f" in
                    enable) ufw allow OpenSSH >/dev/null 2>&1 || true; run_cmd "ufw enable" ufw --force enable ;;
                    disable) run_cmd "ufw disable" ufw disable ;;
                    allow|deny) p=$(tui_input "$f port" "Port or service:" "") || continue; [[ "$p" =~ ^([0-9]{1,5}(/(tcp|udp))?|[A-Za-z0-9._-]+)$ ]] || { tui_msg "Invalid rule" "Use port[/tcp|udp] or a simple service name."; continue; }; run_cmd "ufw $f $p" ufw "$f" "$p" ;;
                    delete) n=$(tui_input "Delete rule" "Rule number:" "") || continue; [[ "$n" =~ ^[0-9]+$ ]] || { tui_msg "Invalid rule" "Rule number must be numeric."; continue; }; run_cmd "ufw delete $n" ufw --force delete "$n" ;;
                    status) ufw status numbered > "$SYSTUI_TMP/net" 2>&1; tui_text "ufw status" "$SYSTUI_TMP/net" ;;
                esac ;;
            dns)
                d=$(tui_radio "DNS" "Resolver set:" cloudflare "1.1.1.1 / 1.0.0.1" on google "8.8.8.8 / 8.8.4.4" off quad9 "9.9.9.9 / 149.112.112.112" off custom Custom off) || continue
                case "$d" in cloudflare) ns1=1.1.1.1; ns2=1.0.0.1;; google) ns1=8.8.8.8; ns2=8.8.4.4;; quad9) ns1=9.9.9.9; ns2=149.112.112.112;; custom) ns1=$(tui_input "DNS" "Primary resolver:" "") || continue; ns2=$(tui_input "DNS" "Secondary resolver (optional):" "") || continue;; esac
                sysconfig_valid_ip_or_host "$ns1" && { [ -z "$ns2" ] || sysconfig_valid_ip_or_host "$ns2"; } || { tui_msg "Invalid resolver" "Resolver is malformed."; continue; }
                cp -p /etc/resolv.conf "/etc/resolv.conf.bak.$(date +%s)" 2>/dev/null || true
                { printf 'nameserver %s\n' "$ns1"; [ -n "$ns2" ] && printf 'nameserver %s\n' "$ns2"; } > /etc/resolv.conf ;;
            staticip)
                iface=$(tui_input "Static IP" "Interface:" "eth0") || continue
                sysconfig_valid_iface "$iface" || { tui_msg "Invalid interface" "Unsafe interface name."; continue; }
                addr=$(tui_input "Static IP" "Address with CIDR:" "") || continue
                gw=$(tui_input "Static IP" "Gateway (optional):" "") || continue
                [[ "$addr" =~ ^[A-Fa-f0-9:.]+/[0-9]{1,3}$ ]] || { tui_msg "Invalid address" "Enter an IP address with CIDR prefix."; continue; }
                [ -z "$gw" ] || sysconfig_valid_ip_or_host "$gw" || { tui_msg "Invalid gateway" "Gateway is malformed."; continue; }
                if [ "${INIT:-}" = systemd ] && command -v networkctl >/dev/null 2>&1; then
                    mkdir -p /etc/systemd/network
                    { printf '[Match]\nName=%s\n\n[Network]\nAddress=%s\n' "$iface" "$addr"; [ -n "$gw" ] && printf 'Gateway=%s\n' "$gw"; } > "/etc/systemd/network/90-systui-$iface.network"
                    tui_msg "Static IP" "Configuration written. Activate only if systemd-networkd owns this interface."
                elif [ -d /etc/network ]; then
                    mkdir -p /etc/network/interfaces.d
                    { printf 'auto %s\niface %s inet static\n    address %s\n' "$iface" "$iface" "$addr"; [ -n "$gw" ] && printf '    gateway %s\n' "$gw"; } > "/etc/network/interfaces.d/systui-$iface"
                    tui_msg "Static IP" "Configuration written to interfaces.d."
                else tui_msg "N/A" "No supported persistent network backend was found."; fi ;;
            proxy)
                a=$(tui_radio "Proxy" "Action:" set Set on unset Remove off) || continue
                if [ "$a" = unset ]; then rm -f /etc/profile.d/92-systui-proxy.sh /etc/apt/apt.conf.d/95systui-proxy; continue; fi
                px=$(tui_input "Proxy" "Proxy URL:" "") || continue
                sysconfig_proxy_url_valid "$px" || { tui_msg "Invalid proxy" "Use a simple HTTP(S) URL without whitespace, quotes, backticks, dollar signs or backslashes."; continue; }
                npx=$(tui_input "Proxy" "No-proxy list:" "localhost,127.0.0.1,.local") || continue
                [[ "$npx" =~ ^[A-Za-z0-9.,:_-]+$ ]] || { tui_msg "Invalid no_proxy" "Use comma-separated host/IP tokens only."; continue; }
                cat > /etc/profile.d/92-systui-proxy.sh <<EOF
export http_proxy="$px" https_proxy="$px" ftp_proxy="$px"
export HTTP_PROXY="$px" HTTPS_PROXY="$px" FTP_PROXY="$px"
export no_proxy="$npx" NO_PROXY="$npx"
EOF
                [ "${PM:-}" = apt ] && printf 'Acquire::http::Proxy "%s";\nAcquire::https::Proxy "%s";\n' "$px" "$px" > /etc/apt/apt.conf.d/95systui-proxy ;;
            time)
                a=$(tui_menu "Time" "Timezone & NTP:" tz "Set timezone" ntp "Enable NTP sync" show "Show time status" back Back) || continue
                case "$a" in
                    tz) sysconfig_set_timezone ;;
                    ntp) if sysconfig_systemd_usable && command -v timedatectl >/dev/null 2>&1; then run_cmd "Enable systemd NTP" timedatectl set-ntp true; else pm_install chrony || continue; svc enable chronyd 2>/dev/null || svc enable chrony 2>/dev/null || true; svc start chronyd 2>/dev/null || svc start chrony 2>/dev/null || true; fi ;;
                    show) { if sysconfig_systemd_usable && command -v timedatectl >/dev/null 2>&1; then timedatectl; else date; fi; } > "$SYSTUI_TMP/net" 2>&1; tui_text "Time status" "$SYSTUI_TMP/net" ;;
                esac ;;
            hostname) sysconfig_set_hostname ;;
            hosts) tui_text "/etc/hosts" /etc/hosts ;;
            ports) { ss -tulnp 2>/dev/null || netstat -tulnp 2>/dev/null || echo 'ss/netstat unavailable'; } > "$SYSTUI_TMP/net"; tui_text "Listening ports" "$SYSTUI_TMP/net" ;;
            info) { ip addr 2>/dev/null || ifconfig -a 2>/dev/null || echo 'ip/ifconfig unavailable'; } > "$SYSTUI_TMP/net"; tui_text "Interfaces" "$SYSTUI_TMP/net" ;;
            advanced) sysconfig_call_menu menu_net_advanced "Advanced network settings" ;;
            back|"") return 0 ;;
        esac
    done
}

export -f sysconfig_valid_ip_or_host sysconfig_user_defaults menu_user_advanced sysconfig_apt_key_menu menu_repos \
    sysconfig_service_output menu_services sysconfig_scan_owner sysconfig_scan_files menu_scan_queries \
    sysconfig_proxy_url_valid menu_network
