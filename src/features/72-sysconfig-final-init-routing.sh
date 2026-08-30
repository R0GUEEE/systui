# shellcheck shell=bash
# PHASE 72 — final init-manager routing and iSH systemd config compatibility.

sysconfig_refresh_init_state() {
    if declare -F systui_detect_init >/dev/null 2>&1; then
        systui_detect_init >/dev/null 2>&1 || true
    elif declare -F detect_init >/dev/null 2>&1; then
        detect_init >/dev/null 2>&1 || true
    fi
}

# Treat all centralized systemd provider states as systemd configuration paths.
sysconfig_service_config_path() { # <service>
    local s="$1" provider
    sysconfig_refresh_init_state
    provider=${SYSTUI_INIT_PROVIDER:-${INIT_PROVIDER:-${INIT:-}}}
    case "$provider" in
        systemd|ish-systemd-compat|systemd-offline)
            case "$s" in *.service) ;; *) s="$s.service" ;; esac
            # Never edit package-owned unit files for ordinary configuration.
            # Existing /etc units are user-owned; packaged units get a drop-in.
            if [ -f "/etc/systemd/system/$s" ]; then
                printf '%s\n' "/etc/systemd/system/$s"
            else
                printf '%s\n' "/etc/systemd/system/$s.d/override.conf"
            fi
            ;;
        openrc) printf '%s\n' "/etc/conf.d/${s%.service}" ;;
        runit)
            s=${s%.service}
            if [ -d "/etc/sv/$s" ]; then printf '%s\n' "/etc/sv/$s/run"
            elif [ -d "/etc/runit/sv/$s" ]; then printf '%s\n' "/etc/runit/sv/$s/run"
            else return 1; fi
            ;;
        sysvinit)
            s=${s%.service}
            if [ -f "/etc/default/$s" ]; then printf '%s\n' "/etc/default/$s"
            elif [ -f "/etc/sysconfig/$s" ]; then printf '%s\n' "/etc/sysconfig/$s"
            elif [ -f "/etc/init.d/$s" ]; then printf '%s\n' "/etc/init.d/$s"
            else return 1; fi
            ;;
        *) return 1 ;;
    esac
}

sysconfig_systemd_provider_present() {
    sysconfig_refresh_init_state
    [ "${SYSTUI_INIT_PROVIDER:-${INIT_PROVIDER:-}}" = systemd ]
}

sysconfig_final_systemd_state() {
    local s
    if ! sysconfig_systemd_provider_present; then
        printf 'absent\n'
        return 1
    fi
    if declare -F systui_systemd_online >/dev/null 2>&1 && systui_systemd_online; then
        s=$(systui_systemd_state 2>/dev/null || printf 'online\n')
        printf '%s\n' "$s"
    else
        printf 'offline\n'
    fi
}

menu_init_manager() {
    local c provider state
    local -a opts
    while true; do
        sysconfig_refresh_init_state
        provider=${SYSTUI_INIT_PROVIDER:-${INIT_PROVIDER:-unknown}}
        opts=(status "Show detected init / PID 1 / runtime state")
        if [ "$provider" = systemd ]; then
            state=$(sysconfig_final_systemd_state 2>/dev/null || printf 'offline\n')
            opts+=(systemd "Systemd Manager [$state]")
        fi
        opts+=(
            services "Services manager"
            switch "Switch init provider"
            runtime "Launch / boot command configuration"
            back "Back"
        )
        c=$(tui_menu "Init Manager  [provider: $provider]" \
            "Init/provider configuration. Offline providers retain safe configuration operations." \
            "${opts[@]}") || return 0
        case "$c" in
            status) sysconfig_init_summary ;;
            systemd)
                if [ "$provider" = systemd ] && declare -F menu_systemd_manager >/dev/null 2>&1; then
                    menu_systemd_manager
                else
                    tui_msg "Systemd Manager" "Systemd is not the configured provider."
                fi
                ;;
            services) menu_services ;;
            switch) declare -F initswap_current >/dev/null 2>&1 && initswap_current || tui_msg "Init Manager" "Init switching is unavailable." ;;
            runtime) declare -F menu_shell_runtime_commands >/dev/null 2>&1 && menu_shell_runtime_commands || tui_msg "Init Manager" "Runtime command configuration is unavailable." ;;
            back|"") return 0 ;;
        esac
    done
}

menu_shell_hierarchy() {
    local c
    while true; do
        sysconfig_refresh_init_state
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
