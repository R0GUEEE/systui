# shellcheck shell=bash
# PHASE 78 — Bedrock init-provider compatibility.
# Bedrock must remain usable regardless of the host init implementation.

bedrock_aok_init_provider() {
    if declare -F systui_detect_init >/dev/null 2>&1; then
        systui_detect_init >/dev/null 2>&1 || true
    elif declare -F detect_init >/dev/null 2>&1; then
        detect_init >/dev/null 2>&1 || true
    fi
    case "${SYSTUI_INIT_PROVIDER:-${INIT:-unknown}}" in
        systemd|ish-systemd-compat|systemd-offline) printf 'systemd\n' ;;
        openrc) printf 'openrc\n' ;;
        runit) printf 'runit\n' ;;
        sysvinit) printf 'sysvinit\n' ;;
        '') printf 'unknown\n' ;;
        *) printf '%s\n' "${SYSTUI_INIT_PROVIDER:-${INIT:-unknown}}" ;;
    esac
}

bedrock_aok_init_runtime() {
    case "$(bedrock_aok_init_provider)" in
        systemd)
            if declare -F systui_systemd_online >/dev/null 2>&1 && systui_systemd_online; then printf 'online\n'; else printf 'offline\n'; fi ;;
        openrc) command -v rc-service >/dev/null 2>&1 && printf 'online\n' || printf 'configuration-only\n' ;;
        runit) command -v sv >/dev/null 2>&1 && printf 'online\n' || printf 'configuration-only\n' ;;
        sysvinit) command -v service >/dev/null 2>&1 && printf 'online\n' || printf 'configuration-only\n' ;;
        *) printf 'provider-neutral\n' ;;
    esac
}

bedrock_aok_init_write_state() {
    local provider runtime out=/bedrock/etc/systui-init.conf
    [ -d /bedrock/etc ] || return 0
    provider=$(bedrock_aok_init_provider)
    runtime=$(bedrock_aok_init_runtime)
    {
        printf 'schema=1\n'
        printf 'provider=%s\n' "$provider"
        printf 'runtime=%s\n' "$runtime"
        printf 'pid1=%s\n' "$(cat /proc/1/comm 2>/dev/null || printf unknown)"
        printf 'service_runtime=%s\n' "${SYSTUI_SERVICE_RUNTIME:-unknown}"
    } > "$out" || return 1
    chmod 0644 "$out" 2>/dev/null || true
}

bedrock_aok_init_sync_config() {
    local provider cfg tmp
    provider=$(bedrock_aok_init_provider)
    cfg=${BEDROCK_AOK_CONFIG:-/bedrock/etc/bedrock.conf}
    [ -d /bedrock/etc ] || return 0
    [ -e "$cfg" ] || {
        declare -F bedrock_aok_generate_config >/dev/null 2>&1 && bedrock_aok_generate_config >/dev/null 2>&1 || true
    }
    [ -r "$cfg" ] || { bedrock_aok_init_write_state; return 0; }
    tmp="${SYSTUI_TMP:-/tmp}/bedrock-init-config.$$"
    awk -v manager="$provider" '
        BEGIN { in_init=0; saw_init=0; wrote=0 }
        /^\[init\][[:space:]]*$/ { print; in_init=1; saw_init=1; next }
        /^\[/ {
            if (in_init && !wrote) { print "manager = " manager; wrote=1 }
            in_init=0
            print
            next
        }
        in_init && /^[[:space:]]*manager[[:space:]]*=/ {
            if (!wrote) { print "manager = " manager; wrote=1 }
            next
        }
        { print }
        END {
            if (in_init && !wrote) print "manager = " manager
            else if (!saw_init) { print ""; print "[init]"; print "manager = " manager }
        }
    ' "$cfg" > "$tmp" || { rm -f -- "$tmp"; return 1; }
    cat "$tmp" > "$cfg" || { rm -f -- "$tmp"; return 1; }
    rm -f -- "$tmp"
    chmod 0644 "$cfg" 2>/dev/null || true
    bedrock_aok_init_write_state
    log "bedrock-aok: synchronized init provider=$provider runtime=$(bedrock_aok_init_runtime)"
}

bedrock_aok_init_service_action() { # <provider> <action> <service>
    local provider="$1" action="$2" svc="$3" bare
    bare=${svc%.service}
    case "$provider" in
        systemd)
            command -v systemctl >/dev/null 2>&1 || return 127
            case "$action" in
                enable|disable|mask|unmask)
                    if declare -F systui_systemd_online >/dev/null 2>&1 && systui_systemd_online; then
                        systemctl "$action" "$svc"
                    else
                        SYSTEMD_OFFLINE=1 systemctl "$action" "$svc"
                    fi
                    ;;
                start|stop|restart|status)
                    declare -F systui_systemd_online >/dev/null 2>&1 && systui_systemd_online || return 3
                    systemctl "$action" "$svc"
                    ;;
                *) return 2 ;;
            esac
            ;;
        openrc)
            command -v rc-service >/dev/null 2>&1 || return 127
            case "$action" in
                enable) command -v rc-update >/dev/null 2>&1 && rc-update add "$bare" default ;;
                disable) command -v rc-update >/dev/null 2>&1 && rc-update del "$bare" default ;;
                start|stop|restart|status) rc-service "$bare" "$action" ;;
                *) return 2 ;;
            esac
            ;;
        runit)
            command -v sv >/dev/null 2>&1 || return 127
            case "$action" in
                enable)
                    [ -d "/etc/sv/$bare" ] || [ -d "/etc/runit/sv/$bare" ] || return 1
                    mkdir -p /var/service
                    if [ -d "/etc/sv/$bare" ]; then ln -sfn "/etc/sv/$bare" "/var/service/$bare"; else ln -sfn "/etc/runit/sv/$bare" "/var/service/$bare"; fi
                    ;;
                disable) rm -f -- "/var/service/$bare" "/service/$bare" ;;
                start) sv up "$bare" ;;
                stop) sv down "$bare" ;;
                restart) sv restart "$bare" ;;
                status) sv status "$bare" ;;
                *) return 2 ;;
            esac
            ;;
        sysvinit)
            command -v service >/dev/null 2>&1 || return 127
            case "$action" in
                enable) command -v update-rc.d >/dev/null 2>&1 && update-rc.d "$bare" defaults ;;
                disable) command -v update-rc.d >/dev/null 2>&1 && update-rc.d -f "$bare" remove ;;
                start|stop|restart|status) service "$bare" "$action" ;;
                *) return 2 ;;
            esac
            ;;
        *) return 4 ;;
    esac
}

bedrock_aok_init_status() {
    local out="${SYSTUI_TMP:?}/bedrock-init-status" provider
    provider=$(bedrock_aok_init_provider)
    bedrock_aok_init_sync_config >/dev/null 2>&1 || true
    {
        echo 'Bedrock init compatibility'
        echo '=========================='
        echo "Provider       : $provider"
        echo "Runtime        : $(bedrock_aok_init_runtime)"
        echo "PID 1          : $(cat /proc/1/comm 2>/dev/null || echo unknown)"
        echo "Systui runtime : ${SYSTUI_SERVICE_RUNTIME:-unknown}"
        echo "Bedrock config : ${BEDROCK_AOK_CONFIG:-/bedrock/etc/bedrock.conf}"
        echo
        echo 'Supported provider adapters:'
        echo '  systemd  -> systemctl (offline unit-file operations retained)'
        echo '  OpenRC   -> rc-service / rc-update'
        echo '  runit    -> sv / service-directory links'
        echo '  SysVinit -> service / update-rc.d'
        echo '  other    -> Bedrock remains provider-neutral; no unsupported lifecycle command is guessed'
    } > "$out"
    tui_text "Bedrock init compatibility" "$out"
}

bedrock_aok_init_service_menu() {
    local provider action svc
    provider=$(bedrock_aok_init_provider)
    svc=$(tui_input "Bedrock init service" "Service name to manage with $provider:" "") || return 0
    [ -n "$svc" ] || return 0
    if declare -F sysconfig_valid_token >/dev/null 2>&1; then
        sysconfig_valid_token "$svc" || { tui_msg "Bedrock init" "Unsafe service name."; return 1; }
    else
        case "$svc" in *[!A-Za-z0-9._@:+-]*|'') tui_msg "Bedrock init" "Unsafe service name."; return 1;; esac
    fi
    action=$(tui_menu "Bedrock service — $provider" "Native service action:" \
        status "Status" start "Start" stop "Stop" restart "Restart" \
        enable "Enable at boot" disable "Disable at boot" back "Back") || return 0
    [ "$action" = back ] && return 0
    if bedrock_aok_init_service_action "$provider" "$action" "$svc"; then
        tui_msg "Bedrock init" "$action completed for $svc using $provider."
    else
        local rc=$?
        tui_msg "Bedrock init" "$action is unavailable/failed for $svc using $provider (status $rc)."
    fi
}

bedrock_aok_init_compat_menu() {
    local c
    while true; do
        c=$(tui_menu "Bedrock init compatibility" \
            "Detected provider: $(bedrock_aok_init_provider)  ·  runtime: $(bedrock_aok_init_runtime)" \
            status "Show provider/runtime status" \
            sync "Synchronize Bedrock config with current init" \
            service "Manage a service through the active init provider" \
            back "Back") || return 0
        case "$c" in
            status) bedrock_aok_init_status ;;
            sync) bedrock_aok_init_sync_config && tui_msg "Bedrock init" "Bedrock configuration synchronized with $(bedrock_aok_init_provider)." ;;
            service) bedrock_aok_init_service_menu ;;
            back|'') return 0 ;;
        esac
    done
}

# Finalize Bedrock compatibility with init synchronization too. bedrock_aok_install
# resolves this function at runtime, so this safely extends the phase-64 hook.
bedrock_aok_compat_finalize() {
    bedrock_aok_compat_write_config 2>/dev/null || true
    bedrock_aok_compat_install_helper 2>/dev/null || true
    bedrock_aok_init_sync_config 2>/dev/null || true
}

# Final configuration menu: retain all phase-71 operations and add init routing.
bedrock_aok_config_menu() {
    local c state compat
    bedrock_aok_require || return 0
    while true; do
        [ -r "${BEDROCK_AOK_CONFIG:-/bedrock/etc/bedrock.conf}" ] && state=present || state=missing
        compat=$(bedrock_aok_config_compat_state 2>/dev/null || printf unknown)
        c=$(tui_menu "Bedrock-AOK configuration  [$state]" \
            "Canonical: ${BEDROCK_AOK_CONFIG:-/bedrock/etc/bedrock.conf}\nCompatibility: ${BEDROCK_AOK_CONFIG_COMPAT:-/bedrock/etc/brl} [$compat]\nInit: $(bedrock_aok_init_provider)" \
            generate "Generate config if missing" \
            repair "Repair/migrate /bedrock/etc/brl compatibility path" \
            init "Init-system compatibility and service routing" \
            view "View configuration" \
            edit "Edit configuration" \
            get "Read one config key" \
            set "Set one config key" \
            back "Back") || return 0
        case "$c" in
            generate) bedrock_aok_generate_config; bedrock_aok_init_sync_config >/dev/null 2>&1 || true ;;
            repair) bedrock_aok_config_repair_compat && tui_msg "Bedrock config" "Compatibility path repaired." ;;
            init) bedrock_aok_init_compat_menu ;;
            view) bedrock_aok_config_view ;;
            edit) bedrock_aok_config_edit ;;
            get) bedrock_aok_config_get_key ;;
            set) bedrock_aok_config_set_key ;;
            back|'') return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
