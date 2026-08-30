# shellcheck shell=bash
# PHASE 75 — root-system systemd runtime enforcement.
#
# When systemd is the configured root init provider, prefer the live PID 1
# manager for runtime operations. Never launch a second system manager as a
# child process; if PID 1 is not systemd, only static/offline configuration is
# safe until the system is actually booted with systemd.

sysconfig_root_systemd_pid1() {
    cat /proc/1/comm 2>/dev/null || printf 'unknown\n'
}

sysconfig_root_systemd_online() {
    declare -F systui_systemd_online >/dev/null 2>&1 && systui_systemd_online
}

sysconfig_root_systemd_ensure_online() {
    local pid1 i
    sysconfig_systemd_provider_active || return 1
    sysconfig_root_systemd_online && return 0

    pid1=$(sysconfig_root_systemd_pid1)
    [ "$pid1" = systemd ] || return 1
    command -v systemctl >/dev/null 2>&1 || return 1

    # PID 1 is already systemd. Ask that manager to re-exec/reload rather than
    # spawning another systemd process, which would not own the root cgroup or
    # system bus correctly.
    systemctl daemon-reexec >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true

    i=0
    while [ "$i" -lt 5 ]; do
        sysconfig_root_systemd_online && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

sysconfig_root_systemd_status_report() {
    local pid1 state provider init_target
    pid1=$(sysconfig_root_systemd_pid1)
    state=$(sysconfig_systemd_manager_state 2>/dev/null || printf 'unavailable\n')
    provider=${SYSTUI_INIT_PROVIDER:-${INIT_PROVIDER:-unknown}}
    init_target=$(readlink -f /sbin/init 2>/dev/null || true)
    {
        printf 'Root init provider : %s\n' "$provider"
        printf 'PID 1              : %s\n' "$pid1"
        printf '/sbin/init          : %s\n' "${init_target:-unknown}"
        printf 'Systemd manager    : %s\n' "$state"
        printf 'Runtime            : %s\n' "${SYSTUI_ENVIRONMENT:-unknown}"
        if [ "$provider" = systemd ] && [ "$pid1" != systemd ]; then
            printf '\nSystemd is configured on disk, but the root system is not currently booted with systemd as PID 1.\n'
            printf 'Systui will not start a second system manager as a child process.\n'
        fi
    } > "$SYSTUI_TMP/root-systemd-status"
    tui_text "Root systemd status" "$SYSTUI_TMP/root-systemd-status"
}

# Prefer the live root manager when available. Static/offline mode remains a
# fallback for iSH-AOK and other constrained runtimes.
sysconfig_systemd_unit_file_action() { # <enable|disable|mask|unmask|preset> <unit>
    local action="$1" unit="$2"
    unit=$(sysconfig_systemd_unit_name "$unit")
    case "$action" in enable|disable|mask|unmask|preset) ;; *) return 2 ;; esac

    if sysconfig_root_systemd_online; then
        run_cmd "systemctl $action $unit" systemctl "$action" "$unit"
    else
        run_cmd "systemctl $action $unit (offline root)" env SYSTEMD_OFFLINE=1 systemctl "$action" "$unit"
    fi
}

menu_systemd_manager() {
    local c unit state
    sysconfig_systemd_provider_active || {
        tui_msg "Systemd Manager" "Systemd is not the configured root init provider."
        return 0
    }

    # Root-system systemd should have a live manager whenever the current PID 1
    # is systemd. Attempt recovery before presenting runtime controls.
    sysconfig_root_systemd_ensure_online || true

    while true; do
        state=$(sysconfig_systemd_manager_state)
        c=$(tui_menu "Systemd Manager — root system [$state]" \
            "Systui uses the live PID 1 systemd manager when available. Offline unit-file operations remain available when this runtime cannot host a live manager." \
            status "Root systemd/provider status" \
            online "Bring manager online / recheck" \
            units "List unit files" \
            config "Configure/edit a unit" \
            enable "Enable unit" \
            disable "Disable unit" \
            mask "Mask unit" \
            unmask "Unmask unit" \
            preset "Apply unit preset" \
            target "Get/set default target" \
            deps "Inspect dependencies" \
            daemonreload "Daemon reload" \
            analyze "Boot analysis" \
            back "Back") || return 0
        case "$c" in
            status) sysconfig_root_systemd_status_report ;;
            online)
                if sysconfig_root_systemd_ensure_online; then
                    tui_msg "Systemd Manager" "The root systemd manager is online."
                else
                    tui_msg "Systemd Manager" "Could not bring the root manager online. If PID 1 is not systemd, boot this root system with systemd; Systui will not launch a second system manager as a child."
                fi
                ;;
            units) sysconfig_systemd_show_units ;;
            config) sysconfig_systemd_unit_editor ;;
            enable|disable|mask|unmask|preset)
                unit=$(tui_input "Systemd unit" "Unit name:" "") || continue
                [ -n "$unit" ] && sysconfig_systemd_unit_file_action "$c" "$unit"
                ;;
            target) sysconfig_systemd_default_target ;;
            deps) sysconfig_systemd_dependencies ;;
            daemonreload)
                if sysconfig_root_systemd_ensure_online; then
                    run_cmd "systemd daemon-reload" systemctl daemon-reload
                else
                    tui_msg "Systemd Manager" "Daemon reload requires the live root systemd manager. Static unit changes remain on disk."
                fi
                ;;
            analyze)
                if sysconfig_root_systemd_ensure_online && command -v systemd-analyze >/dev/null 2>&1; then
                    { systemd-analyze; echo; systemd-analyze blame | head -50; } > "$SYSTUI_TMP/systemd-analyze" 2>&1
                    tui_text "Systemd boot analysis" "$SYSTUI_TMP/systemd-analyze"
                else
                    tui_msg "Systemd Manager" "Boot analysis requires the live root systemd manager."
                fi
                ;;
            back|"") return 0 ;;
        esac
    done
}

# Final init routing: entering the root Init Manager proactively checks the live
# manager when systemd is the selected provider.
if declare -F menu_init_manager >/dev/null 2>&1 && ! declare -F _systui_base_menu_init_manager_root_systemd >/dev/null 2>&1; then
    _systui_init_menu_def=$(declare -f menu_init_manager)
    _systui_init_menu_def=${_systui_init_menu_def/#menu_init_manager ()/_systui_base_menu_init_manager_root_systemd ()}
    eval "$_systui_init_menu_def"
    unset _systui_init_menu_def
fi

menu_init_manager() {
    if declare -F sysconfig_refresh_init_state >/dev/null 2>&1; then
        sysconfig_refresh_init_state
    fi
    if [ "${SYSTUI_INIT_PROVIDER:-${INIT_PROVIDER:-}}" = systemd ]; then
        sysconfig_root_systemd_ensure_online || true
    fi
    _systui_base_menu_init_manager_root_systemd "$@"
}

export -n -f sysconfig_root_systemd_pid1 sysconfig_root_systemd_online \
    sysconfig_root_systemd_ensure_online sysconfig_root_systemd_status_report \
    sysconfig_systemd_unit_file_action menu_systemd_manager menu_init_manager \
    _systui_base_menu_init_manager_root_systemd 2>/dev/null || true
return 0 2>/dev/null || true
