# shellcheck shell=bash
# PHASE 75 — root-system systemd runtime enforcement.
#
# Runtime recovery is deliberately lazy: loading Systui must never block on
# systemctl, D-Bus, or a degraded PID 1. The live-manager check runs only when
# the user enters Systemd Manager or requests an online-only operation.

sysconfig_root_systemd_pid1() {
    cat /proc/1/comm 2>/dev/null || printf 'unknown\n'
}

sysconfig_root_systemd_online() {
    declare -F systui_systemd_online >/dev/null 2>&1 && systui_systemd_online
}

sysconfig_root_systemd_ensure_online() {
    local pid1
    sysconfig_systemd_provider_active || return 1
    sysconfig_root_systemd_online && return 0

    pid1=$(sysconfig_root_systemd_pid1)
    [ "$pid1" = systemd ] || return 1
    command -v systemctl >/dev/null 2>&1 || return 1

    # Never spawn another systemd --system. If PID 1 already is systemd, ask
    # that manager to refresh itself. Keep this bounded and non-interactive.
    if command -v timeout >/dev/null 2>&1; then
        timeout 5 systemctl daemon-reexec >/dev/null 2>&1 || true
        timeout 5 systemctl daemon-reload >/dev/null 2>&1 || true
    else
        systemctl --no-ask-password daemon-reexec >/dev/null 2>&1 || true
        systemctl --no-ask-password daemon-reload >/dev/null 2>&1 || true
    fi

    sysconfig_root_systemd_online
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
        printf 'Environment        : %s\n' "${SYSTUI_ENVIRONMENT:-unknown}"
        if [ "$provider" = systemd ] && [ "$pid1" != systemd ]; then
            printf '\nSystemd is configured on disk, but PID 1 is not systemd.\n'
            printf 'Runtime systemd operations remain unavailable until this root is booted with systemd.\n'
        fi
    } > "$SYSTUI_TMP/root-systemd-status"
    tui_text "Root systemd status" "$SYSTUI_TMP/root-systemd-status"
}

# Prefer the live manager. Static unit-file operations remain available when
# the environment cannot provide a working systemd runtime.
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

    # Lazy recovery: this happens only after the user explicitly opens the
    # Systemd Manager, never while Systui itself is starting.
    sysconfig_root_systemd_ensure_online || true

    while true; do
        state=$(sysconfig_systemd_manager_state)
        c=$(tui_menu "Systemd Manager — root system [$state]" \
            "Uses the live PID 1 manager when available; otherwise safe static unit-file operations remain available." \
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
                    tui_msg "Systemd Manager" "The live root systemd manager is unavailable. If PID 1 is not systemd, boot this root with systemd."
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

export -n -f sysconfig_root_systemd_pid1 sysconfig_root_systemd_online \
    sysconfig_root_systemd_ensure_online sysconfig_root_systemd_status_report \
    sysconfig_systemd_unit_file_action menu_systemd_manager 2>/dev/null || true
return 0 2>/dev/null || true
