#!/bin/bash
# systui — System Health Scanner

health_tmp() {
    local name="${1:-report}"
    case "$name" in *[!A-Za-z0-9_.-]*) return 1 ;; esac
    printf '%s/health-%s' "${SYSTUI_TMP:?private workspace is not initialized}" "$name"
}
health_has() { command -v "$1" >/dev/null 2>&1; }

health_os_name() {
    if [ -r /etc/os-release ]; then
        ( . /etc/os-release; printf '%s' "${PRETTY_NAME:-${NAME:-Linux}}" )
    else
        uname -s
    fi
}

health_mem_percent() {
    awk '/MemTotal:/{t=$2}/MemAvailable:/{a=$2} END{if(t>0) printf "%d", ((t-a)*100)/t; else print 0}' /proc/meminfo 2>/dev/null
}

health_root_percent() {
    df -P / 2>/dev/null | awk 'NR==2 {gsub(/%/,"",$5); print $5+0}'
}

health_load_state() {
    local load cores
    load=$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)
    cores=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    awk -v l="$load" -v c="$cores" 'BEGIN { if (c<1)c=1; p=(l/c)*100; if(p>=150)print "critical"; else if(p>=80)print "warning"; else print "healthy" }'
}

health_status_word() {
    case "$1" in
        healthy|ok|0) echo "OK" ;;
        warning|warn|1) echo "WARNING" ;;
        *) echo "CRITICAL" ;;
    esac
}

health_package_issues() {
    local out="$1" check
    : > "$out"
    case "$PM" in
        apt)
            dpkg --audit >>"$out" 2>&1 || true
            check=$(health_tmp apt-check)
            if ! apt-get check >"$check" 2>&1; then
                cat "$check" >>"$out"
            fi
            rm -f -- "$check"
            ;;
        apk)
            apk audit --system >>"$out" 2>&1 || apk verify >>"$out" 2>&1 || true
            ;;
        pacman)
            pacman -Dk >>"$out" 2>&1 || true
            pacman -Qk 2>/dev/null | grep -v '0 altered files' >>"$out" || true
            ;;
        dnf)
            dnf check >>"$out" 2>&1 || true
            rpm -Va >>"$out" 2>&1 || true
            ;;
        *) echo "Unsupported package manager: $PM" >>"$out" ;;
    esac
    [ -s "$out" ] || echo "No package integrity problems detected." > "$out"
}

health_service_issues() {
    local out="$1"
    : > "$out"
    case "$INIT" in
        systemd)
            systemctl --failed --no-legend --plain --no-pager >>"$out" 2>&1 || true
            ;;
        openrc)
            rc-status --crashed >>"$out" 2>&1 || true
            ;;
        runit)
            local s
            for s in /var/service/* /run/runit/service/*; do
                [ -d "$s" ] || continue
                sv status "$s" 2>/dev/null | grep -Ev '^run:' >>"$out" || true
            done
            ;;
        sysvinit)
            service --status-all 2>&1 | grep '\[ - \]' >>"$out" || true
            ;;
        *) echo "Init system could not be identified." >>"$out" ;;
    esac
    [ -s "$out" ] || echo "No failed or crashed services detected." > "$out"
}

health_storage_report() {
    local out="$1"
    {
        echo "SYSTEM STORAGE HEALTH"
        echo "Generated: $(date '+%F %T')"
        echo
        echo "--- Filesystem usage ---"
        df -hT 2>/dev/null || df -h
        echo
        echo "--- Inode usage ---"
        df -hi 2>/dev/null || true
        echo
        echo "--- Filesystems above 85% ---"
        df -P 2>/dev/null | awk 'NR>1 {gsub(/%/,"",$5); if($5>=85) print $0}'
        echo
        echo "--- Mount warnings ---"
        mount 2>/dev/null | grep -E ' ro[,$)]|errors=' || echo "No read-only/error-policy mounts detected."
        echo
        echo "--- Largest top-level directories ---"
        du -x -h -d 1 / 2>/dev/null | sort -h | tail -15 || true
        if health_has smartctl; then
            echo
            echo "--- SMART summary ---"
            local dev
            for dev in /dev/sd? /dev/nvme?n1 /dev/vd?; do
                [ -b "$dev" ] || continue
                echo "[$dev]"
                smartctl -H "$dev" 2>/dev/null | grep -E 'SMART overall|SMART Health|result' || true
            done
        fi
    } > "$out" 2>&1
}

health_network_report() {
    local out="$1"
    {
        echo "NETWORK HEALTH"
        echo "Generated: $(date '+%F %T')"
        echo
        echo "--- Hostname and resolver ---"
        hostname 2>/dev/null || true
        cat /etc/resolv.conf 2>/dev/null || true
        echo
        echo "--- Addresses ---"
        if health_has ip; then ip addr 2>&1 || true; elif health_has ifconfig; then ifconfig -a 2>&1 || true; fi
        echo
        echo "--- Routes ---"
        if health_has ip; then ip route 2>&1 || true; elif health_has route; then route -n 2>&1 || true; fi
        echo
        echo "--- Listening sockets ---"
        if health_has ss; then ss -tulpen 2>&1 || true; elif health_has netstat; then netstat -tulpen 2>&1 || true; fi
        echo
        echo "--- DNS test ---"
        if health_has getent; then getent hosts deb.debian.org 2>&1 || echo "DNS lookup failed."; fi
        echo
        echo "--- Default gateway reachability ---"
        local gw
        gw=$(ip route 2>/dev/null | awk '/default/{print $3; exit}')
        if [ -n "$gw" ] && health_has ping; then ping -c 1 -W 2 "$gw" 2>&1 || echo "Gateway ping failed or ICMP is unavailable."; else echo "No testable gateway detected."; fi
    } > "$out" 2>&1
}

health_security_report() {
    local out="$1"
    {
        echo "SECURITY HEALTH"
        echo "Generated: $(date '+%F %T')"
        echo
        echo "--- Accounts with UID 0 ---"
        awk -F: '$3==0 {print $1}' /etc/passwd
        echo
        echo "--- Empty-password accounts ---"
        if [ -r /etc/shadow ]; then awk -F: '($2==""){print $1}' /etc/shadow; else echo "Shadow file unavailable."; fi
        echo
        echo "--- World-writable files under system paths (first 100) ---"
        find /etc /usr/local /opt -xdev -type f -perm -0002 2>/dev/null | head -100
        echo
        echo "--- SSH policy ---"
        if [ -f /etc/ssh/sshd_config ]; then
            grep -Ei '^[[:space:]]*(Port|PermitRootLogin|PasswordAuthentication|PubkeyAuthentication|PermitEmptyPasswords)' /etc/ssh/sshd_config || true
            health_has sshd && sshd -t 2>&1 && echo "sshd configuration syntax: OK"
        else
            echo "OpenSSH server configuration not found."
        fi
        echo
        echo "--- Firewall status ---"
        if health_has ufw; then ufw status verbose 2>&1
        elif health_has firewall-cmd; then firewall-cmd --state 2>&1; firewall-cmd --list-all 2>&1
        elif health_has nft; then nft list ruleset 2>&1 | head -150
        elif health_has iptables; then iptables -S 2>&1
        else echo "No supported firewall frontend detected."
        fi
        echo
        echo "--- Recent authentication failures ---"
        if health_has journalctl; then journalctl --since '-24 hours' -u ssh -u sshd --no-pager 2>/dev/null | grep -Ei 'fail|invalid|error' | tail -50 || true
        else grep -Ehi 'failed password|authentication failure|invalid user' /var/log/auth.log /var/log/secure 2>/dev/null | tail -50 || true
        fi
    } > "$out" 2>&1
}

health_resource_report() {
    local out="$1"
    {
        echo "RESOURCE HEALTH"
        echo "Generated: $(date '+%F %T')"
        echo
        uptime 2>/dev/null || true
        echo
        free -h 2>/dev/null || cat /proc/meminfo
        echo
        echo "--- Top CPU consumers ---"
        ps -eo pid,user,stat,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | head -16 || ps aux | head -16
        echo
        echo "--- Top memory consumers ---"
        ps -eo pid,user,stat,%cpu,%mem,comm --sort=-%mem 2>/dev/null | head -16 || true
        echo
        echo "--- Zombie processes ---"
        ps -eo pid,ppid,user,stat,comm 2>/dev/null | awk '$4 ~ /^Z/ {print}' || true
        echo
        echo "--- Kernel messages: warnings/errors (recent) ---"
        dmesg 2>/dev/null | grep -Ei 'error|fail|warn|oom|corrupt|I/O' | tail -100 || echo "Kernel log unavailable."
    } > "$out" 2>&1
}

health_full_report() {
    local out="$1" pkg svc stor net sec res
    pkg=$(health_tmp packages); svc=$(health_tmp services); stor=$(health_tmp storage)
    net=$(health_tmp network); sec=$(health_tmp security); res=$(health_tmp resources)
    health_package_issues "$pkg"
    health_service_issues "$svc"
    health_storage_report "$stor"
    health_network_report "$net"
    health_security_report "$sec"
    health_resource_report "$res"
    {
        echo "================================================================"
        echo " SYSTUI SYSTEM HEALTH REPORT"
        echo "================================================================"
        echo "Generated : $(date '+%F %T')"
        echo "System    : $(health_os_name)"
        echo "Kernel    : $(uname -r) ($(uname -m))"
        echo "Hostname  : $(hostname 2>/dev/null)"
        echo "Init      : $INIT"
        echo "Packages  : $PM"
        echo
        for f in "$res" "$stor" "$pkg" "$svc" "$net" "$sec"; do
            cat "$f"
            echo
            echo "----------------------------------------------------------------"
        done
    } > "$out" 2>&1
}

health_dashboard() {
    local mem disk load pkg svc pkg_state="OK" svc_state="OK"
    mem=$(health_mem_percent); disk=$(health_root_percent); load=$(health_load_state)
    pkg=$(health_tmp dash-pkg); svc=$(health_tmp dash-svc)
    health_package_issues "$pkg"; health_service_issues "$svc"
    grep -Eq 'No package integrity problems detected|0 upgraded, 0 newly installed' "$pkg" || pkg_state="CHECK"
    grep -q 'No failed or crashed services detected' "$svc" || svc_state="CHECK"
    local mem_state="OK" disk_state="OK"
    [ "${mem:-0}" -ge 85 ] && mem_state="WARNING"
    [ "${mem:-0}" -ge 95 ] && mem_state="CRITICAL"
    [ "${disk:-0}" -ge 85 ] && disk_state="WARNING"
    [ "${disk:-0}" -ge 95 ] && disk_state="CRITICAL"
    tui_msg "System Health" "System: $(health_os_name)\nKernel: $(uname -r)\nUptime: $(uptime -p 2>/dev/null || uptime)\n\nCPU load: $(health_status_word "$load")\nMemory: ${mem}% used — $mem_state\nRoot filesystem: ${disk}% used — $disk_state\nPackages: $pkg_state\nServices: $svc_state"
}

health_repair_packages() {
    tui_yesno "Repair Packages" "Attempt conservative package-database and dependency repairs?" || return 0
    case "$PM" in
        apt) run_cmd "Repair APT/dpkg state" bash -c 'dpkg --configure -a && apt-get -f install -y && apt-get check' ;;
        apk) run_cmd "Repair APK state" bash -c 'apk fix && apk audit --system' ;;
        pacman) run_cmd "Refresh Pacman database" bash -c 'pacman -Syy --noconfirm && pacman -Dk' ;;
        dnf) run_cmd "Repair DNF/RPM state" bash -c 'dnf check && dnf distro-sync -y' ;;
        *) tui_msg "Unsupported" "No repair workflow is available for $PM." ;;
    esac
}

health_cleanup() {
    local selected
    selected=$(tui_check "Health Cleanup" "SPACE selects safe cleanup actions:" \
        cache "Clean package caches" on \
        orphan "Remove unused/orphan packages" off \
        temp "Remove stale files from /tmp" on \
        journal "Vacuum old systemd journal entries" off) || return 0
    case " $selected " in *" cache "*) pm_clean || true ;; esac
    case " $selected " in
        *" orphan "*)
            case "$PM" in
                apt) run_cmd "Remove unused packages" apt-get autoremove -y ;;
                apk) tui_msg "APK" "APK world dependencies are explicit; no automatic orphan removal was run." ;;
                pacman)
                    local orphans
                    local -a orphan_pkgs=()
                    orphans=$(pacman -Qtdq 2>/dev/null || true)
                    if [ -n "$orphans" ]; then
                        mapfile -t orphan_pkgs <<< "$orphans"
                        run_cmd "Remove orphan packages" pacman -Rns --noconfirm "${orphan_pkgs[@]}"
                    fi
                    ;;
                dnf) run_cmd "Remove unused packages" dnf autoremove -y ;;
            esac ;;
    esac
    case " $selected " in *" temp "*) run_cmd "Remove stale temporary files" find /tmp -xdev -mindepth 1 -mtime +7 -delete ;; esac
    case " $selected " in *" journal "*) health_has journalctl && run_cmd "Vacuum journal" journalctl --vacuum-time=14d ;; esac
}

menu_health_repairs() {
    while true; do
        local c out
        c=$(tui_menu "Health Repairs" "Conservative system repair and cleanup actions:" \
            packages "Repair package database/dependencies" \
            cleanup "Safe cleanup actions" \
            ssh "Validate OpenSSH server configuration" \
            mounts "Validate /etc/fstab with mount -a" \
            back "Back") || return 0
        case "$c" in
            packages) health_repair_packages ;;
            cleanup) health_cleanup ;;
            ssh)
                if health_has sshd; then
                    out=$(health_tmp ssh)
                    if sshd -t > "$out" 2>&1; then tui_msg "SSH Health" "OpenSSH server configuration is valid."; else tui_text "SSH Configuration Errors" "$out"; fi
                else tui_msg "Unavailable" "sshd is not installed."; fi ;;
            mounts)
                out=$(health_tmp mounts)
                if mount -a -f > "$out" 2>&1; then tui_msg "Mount Health" "/etc/fstab validation completed without errors."; else tui_text "Mount Errors" "$out"; fi ;;
            back) return 0 ;;
        esac
    done
}

menu_health() {
    while true; do
        local c out
        c=$(tui_menu "System Health" "Scan system health, review diagnostics, or run conservative repairs:" \
            dashboard "Quick health dashboard" \
            full "Run full health scan" \
            packages "Package integrity and dependency scan" \
            storage "Storage and filesystem health" \
            services "Failed and crashed services" \
            network "Network and resolver health" \
            security "Security configuration audit" \
            resources "CPU, memory, processes and kernel warnings" \
            repairs "Repair and cleanup tools" \
            export "Save full health report" \
            back "Back to main menu") || return 0
        case "$c" in
            dashboard) health_dashboard ;;
            full) out=$(health_tmp full); health_full_report "$out"; tui_text "Full System Health Report" "$out" ;;
            packages) out=$(health_tmp packages); health_package_issues "$out"; tui_text "Package Health" "$out" ;;
            storage) out=$(health_tmp storage); health_storage_report "$out"; tui_text "Storage Health" "$out" ;;
            services) out=$(health_tmp services); health_service_issues "$out"; tui_text "Service Health" "$out" ;;
            network) out=$(health_tmp network); health_network_report "$out"; tui_text "Network Health" "$out" ;;
            security) out=$(health_tmp security); health_security_report "$out"; tui_text "Security Health" "$out" ;;
            resources) out=$(health_tmp resources); health_resource_report "$out"; tui_text "Resource Health" "$out" ;;
            repairs) menu_health_repairs ;;
            export)
                local dest
                dest=$(tui_input "Save Health Report" "Output path:" "/root/systui-health-$(date +%F-%H%M).txt") || continue
                [ -n "$dest" ] || continue
                mkdir -p "$(dirname "$dest")" 2>/dev/null || true
                health_full_report "$dest"
                tui_msg "Report Saved" "Health report saved to:\n$dest" ;;
            back) return 0 ;;
        esac
    done
}

export -f menu_health
