# shellcheck shell=bash
# PHASE 70 — dedicated systemd manager, including iSH-AOK offline mode.
# Routing is owned by phase 72; this module only provides systemd operations.

sysconfig_systemd_provider_active() {
    if declare -F systui_detect_init >/dev/null 2>&1; then
        systui_detect_init >/dev/null 2>&1 || true
    fi
    [ "${SYSTUI_INIT_PROVIDER:-${INIT_PROVIDER:-}}" = systemd ]
}

sysconfig_systemd_manager_state() {
    if declare -F systui_systemd_online >/dev/null 2>&1 && systui_systemd_online; then
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
    local u p
    u=$(sysconfig_systemd_unit_name "$1")
    for p in "/etc/systemd/system/$u" "/usr/local/lib/systemd/system/$u" "/usr/lib/systemd/system/$u" "/lib/systemd/system/$u"; do
        [ -e "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

sysconfig_systemd_pick_editor() {
    local editor=${EDITOR:-}
    if [ -n "$editor" ] && command -v "${editor%% *}" >/dev/null 2>&1; then
        printf '%s\n' "$editor"
    elif command -v nano >/dev/null 2>&1; then printf 'nano\n'
    elif command -v vi >/dev/null 2>&1; then printf 'vi\n'
    elif command -v vim >/dev/null 2>&1; then printf 'vim\n'
    else return 1
    fi
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
    case "$action" in enable|disable|mask|unmask|preset) ;; *) return 2 ;; esac
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
    local unit path override choice editor
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
            if [ -n "$path" ]; then
                cp -f "$path" "$SYSTUI_TMP/systemd-unit"
            else
                SYSTEMD_OFFLINE=1 systemctl cat "$unit" > "$SYSTUI_TMP/systemd-unit" 2>&1 || true
            fi
            [ -s "$SYSTUI_TMP/systemd-unit" ] || echo '(unit not found)' > "$SYSTUI_TMP/systemd-unit"
            tui_text "$unit" "$SYSTUI_TMP/systemd-unit"
            ;;
        override)
            mkdir -p "${override%/*}" || return 1
            [ -e "$override" ] || printf '[Service]\n' > "$override"
            editor=$(sysconfig_systemd_pick_editor) || { tui_msg "Editor missing" "Install nano, vi, or vim, or set EDITOR."; return 1; }
            # shellcheck disable=SC2086
            $editor "$override"
            ;;
        revert)
            [ -e "$override" ] || { tui_msg "Systemd override" "No Systui override exists for $unit."; return 0; }
            tui_yesno "Remove override" "Delete $override?" || return 0
            rm -f "$override"
            rmdir "${override%/*}" 2>/dev/null || true
            ;;
        enable|disable|mask|unmask) sysconfig_systemd_unit_file_action "$choice" "$unit" ;;
    esac
}

sysconfig_systemd_dependencies() {
    local unit
    unit=$(tui_input "Systemd dependencies" "Unit name:" "") || return 0
    [ -n "$unit" ] || return 0
    unit=$(sysconfig_systemd_unit_name "$unit")
    if declare -F systui_systemd_online >/dev/null 2>&1 && systui_systemd_online; then
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
            "Offline mode supports unit-file configuration; runtime-only operations require a live manager." \
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
                if declare -F systui_systemd_online >/dev/null 2>&1 && systui_systemd_online; then
                    run_cmd "systemd daemon-reload" systemctl daemon-reload
                else
                    tui_msg "Systemd Manager" "Daemon reload requires the live systemd manager. Offline changes are already on disk."
                fi
                ;;
            analyze)
                if declare -F systui_systemd_online >/dev/null 2>&1 && systui_systemd_online && command -v systemd-analyze >/dev/null 2>&1; then
                    { systemd-analyze; echo; systemd-analyze blame | head -50; } > "$SYSTUI_TMP/systemd-analyze" 2>&1
                    tui_text "Systemd boot analysis" "$SYSTUI_TMP/systemd-analyze"
                else
                    tui_msg "Systemd Manager" "Boot analysis requires a live systemd manager."
                fi
                ;;
            back|"") return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
