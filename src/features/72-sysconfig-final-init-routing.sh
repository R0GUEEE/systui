# shellcheck shell=bash
# PHASE 72 — final init-manager routing and iSH systemd config compatibility.

# Treat the iSH compatibility runtime as a systemd provider for configuration
# paths. Runtime control may be offline, but unit files are still systemd files.
sysconfig_service_config_path() { # <service>
    local s="$1"
    case "${INIT:-}" in
        systemd|ish-systemd-compat)
            case "$s" in *.service) ;; *) s="$s.service" ;; esac
            if [ -f "/etc/systemd/system/$s" ]; then printf '%s\n' "/etc/systemd/system/$s"
            elif [ -f "/usr/local/lib/systemd/system/$s" ]; then printf '%s\n' "/usr/local/lib/systemd/system/$s"
            elif [ -f "/usr/lib/systemd/system/$s" ]; then printf '%s\n' "/usr/lib/systemd/system/$s"
            elif [ -f "/lib/systemd/system/$s" ]; then printf '%s\n' "/lib/systemd/system/$s"
            else printf '%s\n' "/etc/systemd/system/$s.d/override.conf"; fi
            ;;
        openrc) printf '%s\n' "/etc/conf.d/${s%.service}" ;;
        runit)
            s=${s%.service}
            if [ -d "/etc/sv/$s" ]; then printf '%s\n' "/etc/sv/$s/run"
            elif [ -d "/etc/runit/sv/$s" ]; then printf '%s\n' "/etc/runit/sv/$s/run"
            else printf '%s\n' "/etc/sv/$s/run"; fi
            ;;
        sysvinit) printf '%s\n' "/etc/init.d/${s%.service}" ;;
        *) return 1 ;;
    esac
}

sysconfig_systemd_provider_present() {
    case "${INIT:-}" in systemd|ish-systemd-compat) return 0 ;; esac
    command -v systemctl >/dev/null 2>&1 || return 1
    [ "$(cat /proc/1/comm 2>/dev/null || true)" = systemd ] || [ -x /usr/lib/systemd/systemd ] || [ -x /lib/systemd/systemd ]
}

# This is intentionally the final definition. The systemd entry is shown when
# systemd is the provider even if systemctl reports "offline".
menu_init_manager() {
    local c provider state
    while true; do
        detect_init 2>/dev/null || true
        provider=${INIT_PROVIDER:-}
        [ -n "$provider" ] || case "${INIT:-}" in systemd|ish-systemd-compat) provider=systemd ;; *) provider=${INIT:-unknown} ;; esac
        state=unavailable
        if declare -F sysconfig_systemd_manager_state >/dev/null 2>&1 && sysconfig_systemd_provider_present; then
            state=$(sysconfig_systemd_manager_state 2>/dev/null || printf 'offline\n')
        fi
        c=$(tui_menu "Init Manager  [provider: $provider]" \
            "Init/provider configuration. Systemd unit management remains available in offline iSH-AOK mode." \
            status "Show detected init / PID 1 / runtime state" \
            systemd "Systemd Manager [$state]" \
            services "Services manager" \
            switch "Switch init provider" \
            runtime "Launch / boot command configuration" \
            back "Back") || return 0
        case "$c" in
            status) sysconfig_init_summary ;;
            systemd)
                if sysconfig_systemd_provider_present && declare -F menu_systemd_manager >/dev/null 2>&1; then
                    menu_systemd_manager
                else
                    tui_msg "Systemd Manager" "Systemd tools/provider were not detected."
                fi
                ;;
            services) menu_services ;;
            switch) declare -F initswap_current >/dev/null 2>&1 && initswap_current || tui_msg "Init Manager" "Init switching is unavailable." ;;
            runtime) declare -F menu_shell_runtime_commands >/dev/null 2>&1 && menu_shell_runtime_commands || tui_msg "Init Manager" "Runtime command configuration is unavailable." ;;
            back|"") return 0 ;;
        esac
    done
}

# Final Shells > Managers route. Do not rely on preserved legacy definitions.
menu_shell_hierarchy() {
    local c
    while true; do
        detect_init 2>/dev/null || true
        c=$(tui_menu "Shell Managers" "Shell, login and init management. Current init: ${INIT:-unknown}" \
            shells "Install/remove/configure shell managers and frameworks" \
            initmgr "Init Manager" \
            runtime "Shell runtime configuration" \
            user "Change a user's login shell" \
            newuser "Default login shell for new users" \
            accounts "List users and login shells" \
            shellsfile "Manage /etc/shells" \
            shprovider "Manage /bin/sh provider" \
            back "Back") || return 0
        case "$c" in
            shells)
                if declare -F _systui_base_menu_shell_hierarchy_logininit >/dev/null 2>&1; then _systui_base_menu_shell_hierarchy_logininit
                elif declare -F _systui_base_menu_shell_hierarchy_runtime >/dev/null 2>&1; then _systui_base_menu_shell_hierarchy_runtime
                else tui_msg "Shell Managers" "Original shell manager menu unavailable."; fi
                ;;
            initmgr) menu_init_manager ;;
            runtime) menu_shell_runtime_commands ;;
            user) sysconfig_shell_set_user ;;
            newuser) sysconfig_shell_set_new_user_default ;;
            accounts) sysconfig_shell_show_accounts ;;
            shellsfile) sysconfig_shells_file_menu ;;
            shprovider) sysconfig_sh_provider ;;
            back|"") return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
