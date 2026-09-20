# shellcheck shell=bash
###############################################################################
# PHASE 103 — integrate tmux into the existing Shells menu
#
# Keep System Configuration > Shells as a single direct shell-management menu.
# Avoid the old pattern of nested wrapper screens and long duplicate login/init
# action lists: group account/login controls under one submenu and route init
# work to the authoritative Init/Services manager.
###############################################################################

# Restore the Shells menu captured by phase 102 so System Configuration > Shells
# opens the real shell menu immediately instead of an extra wrapper menu.
if declare -F _systui_shells_before_tmux_overhaul >/dev/null 2>&1; then
    menu_shells() {
        _systui_shells_before_tmux_overhaul "$@"
    }
fi

# Preserve the final Shell Managers implementation for compatibility/fallbacks,
# then replace the user-facing front door with one compact hierarchy.
if declare -F menu_shell_hierarchy >/dev/null 2>&1 \
    && ! declare -F _systui_shell_hierarchy_before_tmux_final >/dev/null 2>&1; then
    _systui_tmux_hierarchy_def=$(declare -f menu_shell_hierarchy)
    _systui_tmux_hierarchy_def=${_systui_tmux_hierarchy_def/#menu_shell_hierarchy ()/_systui_shell_hierarchy_before_tmux_final ()}
    _systui_tmux_hierarchy_def=${_systui_tmux_hierarchy_def/#menu_shell_hierarchy()/_systui_shell_hierarchy_before_tmux_final()}
    eval "$_systui_tmux_hierarchy_def"
    unset _systui_tmux_hierarchy_def
fi

systui_shell_login_accounts_menu() {
    local c
    while true; do
        tui_capture_menu c tui_menu_no_tags "Shell login & accounts" \
            "Login-shell defaults and account shell metadata:" \
            user "Change a user's default login shell" \
            newuser "Set default login shell for NEW users" \
            accounts "List users and their login shells" \
            shellsfile "Manage /etc/shells" \
            shprovider "Manage system /bin/sh provider" \
            back "Back" || return $?
        case "$c" in
            user) sysconfig_shell_set_user ;;
            newuser) sysconfig_shell_set_new_user_default ;;
            accounts) sysconfig_shell_show_accounts ;;
            shellsfile) sysconfig_shells_file_menu ;;
            shprovider) sysconfig_sh_provider ;;
            back|'') return 0 ;;
        esac
    done
}

systui_shell_init_services_menu() {
    if declare -F menu_init_manager >/dev/null 2>&1; then
        menu_init_manager
    elif declare -F menu_services >/dev/null 2>&1; then
        menu_services
    elif declare -F initswap_current >/dev/null 2>&1; then
        initswap_current
    else
        tui_msg "Init & services" "Init/service management is unavailable in this build."
    fi
}

menu_shell_hierarchy() {
    local c
    while true; do
        if declare -F systui_init_refresh >/dev/null 2>&1; then
            systui_init_refresh
        elif [ "${SYSTUI_SERVICE_RUNTIME+x}" != x ]; then
            detect_init 2>/dev/null || true
        fi
        tui_capture_menu c tui_menu_no_tags "Shell Managers" \
            "Shells, terminal multiplexing, login defaults and runtime commands. Current init: ${INIT:-unknown}" \
            shells "Install, remove & configure shell managers/frameworks" \
            tmux "tmux — install/update, plugins, config and sessions" \
            runtime "Shell runtime commands (launch cmd / boot cmd)" \
            login "Login shells, /etc/shells and /bin/sh provider" \
            initmgr "Init & services manager" \
            back "Back" || return $?
        case "$c" in
            shells)
                if declare -F _systui_base_menu_shell_hierarchy_logininit >/dev/null 2>&1; then
                    _systui_base_menu_shell_hierarchy_logininit
                elif declare -F _systui_base_menu_shell_hierarchy_runtime >/dev/null 2>&1; then
                    _systui_base_menu_shell_hierarchy_runtime
                elif declare -F _systui_shell_hierarchy_before_tmux_final >/dev/null 2>&1; then
                    _systui_shell_hierarchy_before_tmux_final
                else
                    tui_msg "Shell Managers" "The shell manager hierarchy is unavailable."
                fi
                ;;
            tmux)
                if declare -F menu_tmux_manager >/dev/null 2>&1; then
                    menu_tmux_manager
                else
                    tui_msg "tmux" "tmux management is unavailable in this build."
                fi
                ;;
            runtime)
                if declare -F menu_shell_runtime_commands >/dev/null 2>&1; then
                    menu_shell_runtime_commands
                else
                    tui_msg "Shell runtime" "Shell runtime command configuration is unavailable in this build."
                fi
                ;;
            login) systui_shell_login_accounts_menu ;;
            initmgr) systui_shell_init_services_menu ;;
            back|'') return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
