# shellcheck shell=bash
###############################################################################
# PHASE 30 — runtime capability visibility in System Health
###############################################################################

health_runtime_capability_compact() {
    local cap out=""
    for cap in chroot mount namespaces systemd-runtime fuse qemu netlink; do
        if systui_capability "$cap"; then
            out="${out}${out:+, }$cap=yes"
        else
            out="${out}${out:+, }$cap=no"
        fi
    done
    printf '%s\n' "$out"
}

health_dashboard() {
    local mem disk load pkg svc pkg_state="OK" svc_state="OK"
    local mem_state="OK" disk_state="OK" profile caps
    mem=$(health_mem_percent); disk=$(health_root_percent); load=$(health_load_state)
    pkg=$(health_tmp dash-pkg); svc=$(health_tmp dash-svc)
    health_package_issues "$pkg"; health_service_issues "$svc"
    grep -Eq 'No package integrity problems detected|0 upgraded, 0 newly installed' "$pkg" || pkg_state="CHECK"
    grep -q 'No failed or crashed services detected' "$svc" || svc_state="CHECK"
    [ "${mem:-0}" -ge 85 ] && mem_state="WARNING"
    [ "${mem:-0}" -ge 95 ] && mem_state="CRITICAL"
    [ "${disk:-0}" -ge 85 ] && disk_state="WARNING"
    [ "${disk:-0}" -ge 95 ] && disk_state="CRITICAL"
    profile=$(systui_runtime_profile 2>/dev/null || printf 'unknown')
    caps=$(health_runtime_capability_compact)

    tui_msg "System Health" "System: $(health_os_name)\nKernel: $(uname -r)\nRuntime: $profile\nInit: ${INIT:-unknown} (${SYSTUI_SERVICE_RUNTIME:-unknown})\nUptime: $(uptime -p 2>/dev/null || uptime)\n\nCPU load: $(health_status_word "$load")\nMemory: ${mem}% used — $mem_state\nRoot filesystem: ${disk}% used — $disk_state\nPackages: $pkg_state\nServices: $svc_state\n\nCapabilities:\n$caps"
}

export -n -f health_runtime_capability_compact health_dashboard 2>/dev/null || true
