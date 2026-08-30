# shellcheck shell=bash
# PHASE 70 — dedicated systemd manager, including iSH-AOK offline mode.

sysconfig_systemd_provider_active() {
    case "${INIT:-}" in
        systemd|ish-systemd-compat) return 0 ;;
    esac
    [ "$(systui_pid1_name 2>/dev/null || cat /proc/1/comm 2>/dev/null || true)" = systemd ]
}

sysconfig_systemd_manager_state() {
    if sysconfig_systemd_usable 2>/dev/null; then
        printf 'online\n'
    elif sysconfig_systemd_provider_active; then
        printf 'offline\n'
    else
        printf 'unavailable\n'
    fi
}

sysconfig_systemd_unit_name() {
    local s="$1"
    case "$s" in *.*) printf '%s\n' "$s" ;; *) printf '%s.service\n' "$s" ;; esac
}

sysconfig_systemd_unit_path() {
    local u
    u=$(sysconfig_systemd_unit_name "$1")
    for p in "/etc/systemd/system/$u" "/usr/local/lib/systemd/system/$u" "/usr/lib/systemd/system/$u" "/lib/systemd/system/$u"; do
        [ -e "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

sysconfig_systemd_show_units() {
    {
        echo "Systemd manager state: $(sysconfig_systemd_manager_state)"
        echo
        SYSTEMD_OFFLINE=1 systemctl list-unit-files --no-pager 2>&1 || true
    } > "$SYSTUI_TMP/systemd-units"
    tui_text "Systemd unit files" "$SYSTUI_TMP/systemd-units"
}

sysconfig_systemd_unit_file_action() { # <enable|disable|mask|unmask|preset> <unit>
    local action="$1" unit="$2"
    unit=$(sysconfig_systemd_unit_name "$unit")
    case "$action" in
        enable|disable|mask|unmask|preset) ;;
        *) return 2 ;;
    esac
    run_cmd "systemctl $action $unit (offline-capable)" env SYSTEMD_OFFLINE=1 systemctl "$action" "$unit"
}

sysconfig_systemd_default_target() {
    local state target current
    state=$(sysconfig_systemd_manager_state)
    current=$(SYSTEMD_OFFLINE=1 systemctl get-default 2>/dev/null || true)
    target=$(tui_radio "Systemd default target" "Manager: $state\nCurrent: ${current:-unknown}\n\nSelect default target:" \
        multi-user.target "Multi-user / server" off \
        graphical.target "Graphical" off \
        rescue.target "Rescue" off \
        emergency.target "Emergency" off) || return 0
    [ -n "$target" ] || return 0
    run_cmd "Set systemd default target" env SYSTEMD_OFFLINE=1 systemctl set-default "$target"
}

sysconfig_systemd_unit_editor() {
    local unit path override choice
    unit=$(tui_input "Systemd unit" "Unit name:" "") || return 0
    [ -n "$unit" ] || return 0
    unit=$(sysconfig_systemd_unit_name "$unit")
    path=$(sysconfig_systemd_unit_path "$unit" 2>/dev/null || true)
    override="/etc/systemd/system/$unit.d/override.conf"
    choice=$(tui_menu "Systemd unit config — $unit" "Manager: $(sysconfig_systemd_manager_state)" \
        view "View effective/base unit file" \
        override "Edit drop-in override.conf" \
        revert "Remove Systui drop-in override" \
        enable "Enable unit offline" \
        disable "Disable unit offline" \
        mask "Mask unit offline" \
        unmask "Unmask unit offline" \
        back "Back") || return 0
    case "$choice" in
        view)
            if [ -n "$path" ]; then cp -f "$path" "$SYSTUI_TMP/systemd-unit"; else SYSTEMD_OFFLINE=1 systemctl cat "$unit" > "$SYSTUI_TMP/systemd-unit" 2>&1 || true; fi
            [ -s "$SYSTUI_TMP/systemd-unit" ] || echo '(unit not found)' > "$SYSTUI_TMP/systemd-unit"
            tui_text "$unit" "$SYSTUI_TMP/systemd-unit"
            ;;
        override)
            mkdir -p "${override%/*}" || return 1
            [ -e "$override" ] || printf '[Service]\n' > "$override"
            ${EDITOR:-nano} "$override"
            ;;
        revert)
            [ -e "$override" ] || { tui_msg "Systemd override" "No Systui override exists for $unit."; return 0; }
            tui_yesno "Remove override" "Delete $override?" || return 0
            rm -f "$override"; rmdir "${override%/*}" 2>/dev/null || true
            ;;
        enable|disable|mask|unmask) sysconfig_systemd_unit_file_action "$choice" "$unit" ;;
    esac
}

sysconfig_systemd_dependencies() {
    local unit
    unit=$(tui_input "Systemd dependencies" "Unit name:" "") || return 0
    [ -n "$unit" ] || return 0
    unit=$(sysconfig_systemd_unit_name "$unit")
    if sysconfig_systemd_usable 2>/dev/null; then
        systemctl list-dependencies --all "$unit" > "$SYSTUI_TMP/systemd-deps" 2>&1 || true
    else
        {
            echo "Offline dependency hints for $unit"
            echo
            SYSTEMD_OFFLINE=1 systemctl cat "$unit" 2>/dev/null | grep -E '^(Requires|Wants|Requisite|BindsTo|PartOf|After|Before)=' || true
        } > "$SYSTUI_TMP/systemd-deps"
    fi
    tui_text "Dependencies — $unit" "$SYSTUI_TMP/systemd-deps"
}

menu_systemd_manager() {
    local c unit state
    sysconfig_systemd_provider_active || { tui_msg "Systemd Manager" "Systemd is not the configured init provider."; return 0; }
    while true; do
        state=$(sysconfig_systemd_manager_state)
        c=$(tui_menu "Systemd Manager  [$state]" \
            "Offline mode still supports unit-file configuration. Runtime-only operations are shown only when the manager is online." \
            units "List unit files" \
            config "Configure/edit a unit" \
            enable "Enable unit" \
            disable "Disable unit" \
            mask "Mask unit" \
            unmask "Unmask unit" \
            preset "Apply unit preset" \
            target "Get/set default target" \
            deps "Inspect dependencies" \
            daemonreload "Daemon reload (online only)" \
            analyze "Boot analysis (online only)" \
            back "Back") || return 0
        case "$c" in
            units) sysconfig_systemd_show_units ;;
            config) sysconfig_systemd_unit_editor ;;
            enable|disable|mask|unmask|preset)
                unit=$(tui_input "Systemd unit" "Unit name:" "") || continue
                [ -n "$unit" ] && sysconfig_systemd_unit_file_action "$c" "$unit"
                ;;
            target) sysconfig_systemd_default_target ;;
            deps) sysconfig_systemd_dependencies ;;
            daemonreload)
                if sysconfig_systemd_usable 2>/dev/null; then run_cmd "systemd daemon-reload" systemctl daemon-reload
                else tui_msg "Systemd Manager" "Daemon reload requires the live systemd manager. Offline unit-file changes are already written to disk and will be seen when a usable manager starts."; fi
                ;;
            analyze)
                if sysconfig_systemd_usable 2>/dev/null && command -v systemd-analyze >/dev/null 2>&1; then
                    { systemd-analyze; echo; systemd-analyze blame | head -50; } > "$SYSTUI_TMP/systemd-analyze" 2>&1
                    tui_text "Systemd boot analysis" "$SYSTUI_TMP/systemd-analyze"
                else tui_msg "Systemd Manager" "Boot analysis requires a live systemd manager."; fi
                ;;
            back|"") return 0 ;;
        esac
    done
}

# Final Init Manager definition: explicitly expose provider-specific manager.
menu_init_manager() {
    local c
    while true; do
        detect_init 2>/dev/null || true
        c=$(tui_menu "Init Manager  [${INIT:-unknown}]" "Init provider and manager tools:" \
            status "Show detected init / PID 1 / runtime state" \
            systemd "Systemd Manager (online or offline)" \
            switch "Switch init provider" \
            runtime "Launch / boot command configuration" \
            services "Services manager" \
            back "Back") || return 0
        case "$c" in
            status) sysconfig_init_summary ;;
            systemd) menu_systemd_manager ;;
            switch) declare -F initswap_current >/dev/null 2>&1 && initswap_current || tui_msg "Init Manager" "Init switching is unavailable." ;;
            runtime) declare -F menu_shell_runtime_commands >/dev/null 2>&1 && menu_shell_runtime_commands || tui_msg "Init Manager" "Runtime command configuration is unavailable." ;;
            services) menu_services ;;
            back|"") return 0 ;;
        esac
    done
}

# Reassert Shells > Managers with a dedicated Init Manager entry.
if declare -F menu_shell_hierarchy >/dev/null 2>&1 && ! declare -F _systui_base_menu_shell_hierarchy_systemd >/dev/null 2>&1; then
    _systui_systemd_menu_def=$(declare -f menu_shell_hierarchy)
    _systui_systemd_menu_def=${_systui_systemd_menu_def/#menu_shell_hierarchy ()/_systui_base_menu_shell_hierarchy_systemd ()}
    eval "$_systui_systemd_menu_def"
    unset _systui_systemd_menu_def
fi

menu_shell_hierarchy() {
    local c
    while true; do
        detect_init 2>/dev/null || true
        c=$(tui_menu "Shell Managers" "Shell and system runtime managers. Current init: ${INIT:-unknown}" \
            shells "Shell managers/frameworks" \
            init "Init Manager" \
            runtime "Shell runtime configuration" \
            user "Change a user's login shell" \
            newuser "Default login shell for new users" \
            accounts "List users and login shells" \
            shellsfile "Manage /etc/shells" \
            shprovider "Manage /bin/sh provider" \
            back "Back") || return 0
        case "$c" in
            shells) declare -F _systui_base_menu_shell_hierarchy_logininit >/dev/null 2>&1 && _systui_base_menu_shell_hierarchy_logininit || true ;;
            init) menu_init_manager ;;
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
