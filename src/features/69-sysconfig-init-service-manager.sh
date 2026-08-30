# shellcheck shell=bash
# PHASE 69 — authoritative init/service manager menu integration.

sysconfig_service_config_path() { # <service>
    local s="$1"
    case "${INIT:-}" in
        systemd)
            if [ -f "/etc/systemd/system/$s.service" ]; then printf '%s\n' "/etc/systemd/system/$s.service"
            elif [ -f "/usr/lib/systemd/system/$s.service" ]; then printf '%s\n' "/usr/lib/systemd/system/$s.service"
            elif [ -f "/lib/systemd/system/$s.service" ]; then printf '%s\n' "/lib/systemd/system/$s.service"
            else printf '%s\n' "/etc/systemd/system/$s.service.d/override.conf"; fi
            ;;
        openrc) printf '%s\n' "/etc/conf.d/$s" ;;
        runit)
            if [ -d "/etc/sv/$s" ]; then printf '%s\n' "/etc/sv/$s/run"
            elif [ -d "/etc/runit/sv/$s" ]; then printf '%s\n' "/etc/runit/sv/$s/run"
            else printf '%s\n' "/etc/sv/$s/run"; fi
            ;;
        sysvinit) printf '%s\n' "/etc/init.d/$s" ;;
        *) return 1 ;;
    esac
}

sysconfig_service_config_edit() { # <service>
    local s="$1" f dir
    sysconfig_valid_token "$s" || { tui_msg "Invalid service" "Unsafe service name."; return 1; }
    f=$(sysconfig_service_config_path "$s") || { tui_msg "Service config" "Unsupported init system: ${INIT:-unknown}."; return 1; }
    dir=${f%/*}
    mkdir -p "$dir" || return 1
    [ -e "$f" ] || : > "$f"
    ${EDITOR:-nano} "$f"
}

sysconfig_service_config_view() { # <service>
    local s="$1" f
    sysconfig_valid_token "$s" || return 1
    f=$(sysconfig_service_config_path "$s") || return 1
    if [ -r "$f" ]; then cp "$f" "$SYSTUI_TMP/service-config"
    else printf '(configuration file does not exist yet)\n%s\n' "$f" > "$SYSTUI_TMP/service-config"; fi
    tui_text "Service config: $s" "$SYSTUI_TMP/service-config"
}

sysconfig_service_config_reload() {
    case "${INIT:-}" in
        systemd)
            if declare -F sysconfig_systemd_usable >/dev/null 2>&1 && sysconfig_systemd_usable; then
                run_cmd "Reload systemd manager" systemctl daemon-reload
            else
                tui_msg "Service config" "systemd is offline in this runtime; configuration was saved for the next real systemd boot."
            fi
            ;;
        openrc) tui_msg "Service config" "OpenRC reads /etc/conf.d service configuration when the service starts/restarts." ;;
        runit) tui_msg "Service config" "runit reads the service run script on the next service start/restart." ;;
        sysvinit) tui_msg "Service config" "SysVinit uses the init script directly; restart the service to apply changes." ;;
        *) tui_msg "Service config" "No reload action is available for ${INIT:-unknown}." ;;
    esac
}

menu_service_config() {
    local s c
    s=$(tui_input "Service configuration" "Service name:" "") || return 0
    sysconfig_valid_token "$s" || { tui_msg "Invalid service" "Service names cannot contain slashes or whitespace."; return 0; }
    while true; do
        c=$(tui_menu "Service config — $s" "Configuration options for $s (${INIT:-unknown}):" \
            view "View active/native configuration file" \
            edit "Edit service configuration" \
            reload "Reload/re-read service configuration" \
            status "Show service status" \
            restart "Restart service" \
            back "Back") || return 0
        case "$c" in
            view) sysconfig_service_config_view "$s" ;;
            edit) sysconfig_service_config_edit "$s" ;;
            reload) sysconfig_service_config_reload ;;
            status) sysconfig_service_output status "$s" "$SYSTUI_TMP/svc" || true; tui_text "status: $s" "$SYSTUI_TMP/svc" ;;
            restart) run_cmd "restart $s (${INIT:-unknown})" svc restart "$s" ;;
            back|"") return 0 ;;
        esac
    done
}

menu_services_manage() {
    local c s
    while true; do
        c=$(tui_menu "Services — Manage  [init: ${INIT:-unknown}]" "Manage individual services:" \
            start "Start service" stop "Stop service" restart "Restart service" \
            enable "Enable service" disable "Disable service" status "Show status" logs "Show logs" \
            config "Configure service" unit "View unit/init file" back "Back") || return 0
        case "$c" in
            config) menu_service_config ;;
            start|stop|restart|enable|disable)
                s=$(tui_input "Service" "Service name:" "") || continue
                sysconfig_valid_token "$s" || { tui_msg "Invalid service" "Unsafe service name."; continue; }
                run_cmd "$c $s (${INIT:-unknown})" svc "$c" "$s"
                ;;
            status|logs|unit)
                s=$(tui_input "Service" "Service name:" "") || continue
                sysconfig_valid_token "$s" || { tui_msg "Invalid service" "Unsafe service name."; continue; }
                sysconfig_service_output "$c" "$s" "$SYSTUI_TMP/svc" || true
                tui_text "$c: $s" "$SYSTUI_TMP/svc"
                ;;
            back|"") return 0 ;;
        esac
    done
}

menu_init_manager() {
    local c
    while true; do
        detect_init 2>/dev/null || true
        c=$(tui_menu "Init Manager  [current: ${INIT:-unknown}]" "Init-system management:" \
            status "Show detected init / PID 1" \
            switch "Switch init system (systemd/OpenRC/runit/SysVinit)" \
            runtime "Configure launch / boot command" \
            services "Open service manager" \
            back "Back") || return 0
        case "$c" in
            status) sysconfig_init_summary ;;
            switch) declare -F initswap_current >/dev/null 2>&1 && initswap_current || tui_msg "Init Manager" "Init switching is unavailable in this build." ;;
            runtime) declare -F menu_shell_runtime_commands >/dev/null 2>&1 && menu_shell_runtime_commands || tui_msg "Init Manager" "Runtime command management is unavailable." ;;
            services) menu_services ;;
            back|"") return 0 ;;
        esac
    done
}

# Final authoritative Shells > Managers layout.
menu_shell_hierarchy() {
    local c
    while true; do
        detect_init 2>/dev/null || true
        c=$(tui_menu "Shell Managers" "Shell, login and init management. Current init: ${INIT:-unknown}" \
            shells "Install, remove & configure shell managers/frameworks" \
            runtime "Shell runtime configuration (launch cmd / boot cmd)" \
            initmgr "Init Manager" \
            user "Change a user's default login shell" \
            newuser "Set default login shell for NEW users" \
            accounts "List users and their login shells" \
            shellsfile "Manage /etc/shells" \
            shprovider "Manage system /bin/sh provider" \
            back "Back") || return 0
        case "$c" in
            shells)
                if declare -F _systui_base_menu_shell_hierarchy_logininit >/dev/null 2>&1; then _systui_base_menu_shell_hierarchy_logininit
                elif declare -F _systui_base_menu_shell_hierarchy_runtime >/dev/null 2>&1; then _systui_base_menu_shell_hierarchy_runtime
                else tui_msg "Shell Managers" "The original shell manager hierarchy is unavailable."; fi
                ;;
            runtime) menu_shell_runtime_commands ;;
            initmgr) menu_init_manager ;;
            user) sysconfig_shell_set_user ;;
            newuser) sysconfig_shell_set_new_user_default ;;
            accounts) sysconfig_shell_show_accounts ;;
            shellsfile) sysconfig_shells_file_menu ;;
            shprovider) sysconfig_sh_provider ;;
            back|"") return 0 ;;
        esac
    done
}

# Final authoritative Services layout with an explicit Manage submenu.
menu_services() {
    local c
    while true; do
        detect_init 2>/dev/null || true
        c=$(tui_menu "Services  [init: ${INIT:-unknown}]" "Service management:" \
            manage "Manage services (start/stop/config/status/logs)" \
            list "List services" failed "Show failed services" \
            mask "Mask/unmask service (systemd)" analyze "Boot analysis" \
            initswap "Open Init Manager" advanced "Advanced service settings" back "Back") || return 0
        case "$c" in
            manage) menu_services_manage ;;
            list)
                case "${INIT:-}" in
                    systemd) if sysconfig_systemd_usable; then systemctl list-units --type=service --no-pager; else echo 'systemd manager is not usable in this runtime.'; fi ;;
                    openrc) rc-status -a 2>&1 ;;
                    runit) for s in /var/service/* /run/runit/service/* /service/*; do [ -d "$s" ] && basename "$s"; done ;;
                    sysvinit) service --status-all 2>&1 ;;
                    *) echo 'No supported init system detected.' ;;
                esac > "$SYSTUI_TMP/svc"
                tui_text "Services (${INIT:-unknown})" "$SYSTUI_TMP/svc"
                ;;
            failed)
                if sysconfig_systemd_usable; then systemctl --failed --no-pager > "$SYSTUI_TMP/svc" 2>&1
                elif [ "${INIT:-}" = openrc ]; then rc-status -c > "$SYSTUI_TMP/svc" 2>&1
                else echo 'Failed-service listing is unavailable for this init/runtime.' > "$SYSTUI_TMP/svc"; fi
                tui_text "Failed services" "$SYSTUI_TMP/svc"
                ;;
            mask)
                if declare -F sysconfig_systemd_usable >/dev/null 2>&1 && sysconfig_systemd_usable; then
                    local a s
                    a=$(tui_radio "Mask service" "Action:" mask Mask on unmask Unmask off) || continue
                    s=$(tui_input "Mask service" "Service name:" "") || continue
                    sysconfig_valid_token "$s" || continue
                    run_cmd "systemctl $a $s" systemctl "$a" "$s"
                else tui_msg "N/A" "Masking requires a running systemd manager."; fi
                ;;
            analyze)
                if declare -F sysconfig_systemd_usable >/dev/null 2>&1 && sysconfig_systemd_usable && command -v systemd-analyze >/dev/null 2>&1; then
                    { systemd-analyze; echo; systemd-analyze blame | head -25; } > "$SYSTUI_TMP/svc" 2>&1
                    tui_text "Boot analysis" "$SYSTUI_TMP/svc"
                else tui_msg "N/A" "Boot analysis requires a running systemd manager."; fi
                ;;
            initswap) menu_init_manager ;;
            advanced) sysconfig_call_menu menu_svc_advanced "Advanced services" ;;
            back|"") return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
