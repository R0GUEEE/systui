# shellcheck shell=bash
# PHASE 79 — BusyBox init support across init detection, services, rootfs and Bedrock.

# Preserve the centralized detector, then refine unknown/SysV-looking BusyBox PID1 cases.
if declare -F systui_detect_init >/dev/null 2>&1 && ! declare -F _systui_detect_init_before_busybox >/dev/null 2>&1; then
    eval "$(declare -f systui_detect_init | sed '1s/^systui_detect_init[[:space:]]*()/_systui_detect_init_before_busybox ()/')"
fi

systui_busybox_init_present() {
    command -v busybox >/dev/null 2>&1 || [ -x /bin/busybox ] || [ -x /usr/bin/busybox ] || return 1
    [ -r /etc/inittab ] || return 1
    return 0
}

systui_busybox_pid1() {
    local p target
    p=$(cat /proc/1/comm 2>/dev/null || true)
    target=$(readlink -f /proc/1/exe 2>/dev/null || true)
    case "$p $target" in
        *busybox*|*BusyBox*) return 0 ;;
    esac
    # BusyBox init often reports simply "init"; require the BusyBox applet plus inittab.
    [ "$p" = init ] && systui_busybox_init_present
}

systui_detect_init() {
    _systui_detect_init_before_busybox 2>/dev/null || true
    if systui_busybox_pid1; then
        INIT=busybox
        SYSTUI_INIT_PROVIDER=busybox
        SYSTUI_SERVICE_RUNTIME=busybox
        [ -n "${SYSTUI_ENVIRONMENT:-}" ] || SYSTUI_ENVIRONMENT=$(systui_runtime_profile 2>/dev/null || printf native-linux)
        SYSTUI_SYSTEMD_STATE=absent
        export INIT SYSTUI_INIT_PROVIDER SYSTUI_SERVICE_RUNTIME SYSTUI_ENVIRONMENT SYSTUI_SYSTEMD_STATE
    fi
}

sysconfig_init_provider_available() {
    case "${1:-}" in
        busybox) systui_busybox_init_present ;;
        *)
            case "${1:-}" in
                systemd) command -v systemctl >/dev/null 2>&1 || [ -d /etc/systemd/system ] || [ -d /usr/lib/systemd/system ] || [ -d /lib/systemd/system ] ;;
                openrc) command -v rc-service >/dev/null 2>&1 || [ -d /etc/conf.d ] ;;
                runit) command -v sv >/dev/null 2>&1 || [ -d /etc/sv ] || [ -d /etc/runit/sv ] ;;
                sysvinit) command -v service >/dev/null 2>&1 || [ -d /etc/init.d ] ;;
                *) return 2 ;;
            esac
            ;;
    esac
}

sysconfig_service_config_path_for() {
    local provider="$1" s="$2"
    case "$provider" in
        busybox)
            s=${s%.service}
            if [ -f "/etc/init.d/$s" ]; then printf '%s\n' "/etc/init.d/$s"
            else printf '%s\n' /etc/inittab; fi
            ;;
        systemd)
            case "$s" in *.*) ;; *) s="$s.service" ;; esac
            [ -f "/etc/systemd/system/$s" ] && printf '%s\n' "/etc/systemd/system/$s" || printf '%s\n' "/etc/systemd/system/$s.d/override.conf"
            ;;
        openrc) printf '%s\n' "/etc/conf.d/${s%.service}" ;;
        runit) s=${s%.service}; [ -d "/etc/sv/$s" ] && printf '%s\n' "/etc/sv/$s/run" || printf '%s\n' "/etc/runit/sv/$s/run" ;;
        sysvinit) s=${s%.service}; [ -f "/etc/default/$s" ] && printf '%s\n' "/etc/default/$s" || printf '%s\n' "/etc/init.d/$s" ;;
        *) return 2 ;;
    esac
}

sysconfig_busybox_inittab_has_service() { # <service>
    local s="$1"
    [ -r /etc/inittab ] || return 1
    grep -Eq "(^|[/:[:space:]])${s}([[:space:]]|$)" /etc/inittab 2>/dev/null
}

sysconfig_service_action_for() {
    local provider="$1" action="$2" s="$3" bare
    sysconfig_valid_token "$s" || return 2
    bare=${s%.service}
    case "$provider" in
        busybox)
            case "$action" in
                start|stop|restart|status)
                    if [ -x "/etc/init.d/$bare" ]; then
                        "/etc/init.d/$bare" "$action"
                    elif command -v service >/dev/null 2>&1; then
                        service "$bare" "$action"
                    else
                        printf 'BusyBox init has no native per-service control API; use /etc/init.d or edit /etc/inittab.\n' >&2
                        return 3
                    fi
                    ;;
                enable)
                    sysconfig_busybox_inittab_has_service "$bare" && return 0
                    printf 'Enable BusyBox-init services by adding the appropriate /etc/inittab entry.\n' >&2
                    return 3
                    ;;
                disable)
                    sysconfig_busybox_inittab_has_service "$bare" || return 0
                    printf 'Disable BusyBox-init services by removing/commenting the matching /etc/inittab entry.\n' >&2
                    return 3
                    ;;
                *) return 2 ;;
            esac
            ;;
        systemd) case "$action" in start|stop|restart|status) sysconfig_root_systemd_ensure_online >/dev/null 2>&1 || return 1; systemctl "$action" "$s" ;; enable|disable|mask|unmask|preset) sysconfig_systemd_unit_file_action "$action" "$s" ;; *) return 2 ;; esac ;;
        openrc) case "$action" in start|stop|restart|status) rc-service "$bare" "$action" ;; enable) rc-update add "$bare" default ;; disable) rc-update del "$bare" default ;; *) return 2 ;; esac ;;
        runit) case "$action" in start) sv up "$bare" ;; stop) sv down "$bare" ;; restart) sv restart "$bare" ;; status) sv status "$bare" ;; enable) mkdir -p /var/service; [ -d "/etc/sv/$bare" ] && ln -sfn "/etc/sv/$bare" "/var/service/$bare" || ln -sfn "/etc/runit/sv/$bare" "/var/service/$bare" ;; disable) rm -f -- "/var/service/$bare" "/service/$bare" ;; *) return 2 ;; esac ;;
        sysvinit) case "$action" in start|stop|restart|status) service "$bare" "$action" ;; enable) update-rc.d "$bare" defaults ;; disable) update-rc.d -f "$bare" remove ;; *) return 2 ;; esac ;;
        *) return 2 ;;
    esac
}

sysconfig_service_list_for() {
    local provider="$1" out="$2" p
    case "$provider" in
        busybox)
            {
                echo 'BusyBox init entries (/etc/inittab)'
                echo '----------------------------------'
                cat /etc/inittab 2>/dev/null || echo '(no /etc/inittab)'
                echo
                echo 'Init scripts (/etc/init.d)'
                echo '--------------------------'
                for p in /etc/init.d/*; do [ -e "$p" ] && basename "$p"; done
            } > "$out"
            ;;
        systemd) if sysconfig_root_systemd_online 2>/dev/null; then systemctl list-units --type=service --all --no-pager >"$out" 2>&1; else SYSTEMD_OFFLINE=1 systemctl list-unit-files --type=service --no-pager >"$out" 2>&1 || true; fi ;;
        openrc) rc-status -a >"$out" 2>&1 ;;
        runit) { for p in /var/service/* /run/runit/service/* /service/* /etc/sv/* /etc/runit/sv/*; do [ -d "$p" ] && basename "$p"; done; } | sort -u >"$out" ;;
        sysvinit) service --status-all >"$out" 2>&1 ;;
        *) return 2 ;;
    esac
}

# Override Services front door to expose BusyBox explicitly.
menu_services() {
    local c current label
    while true; do
        sysconfig_refresh_init_state
        current=${SYSTUI_INIT_PROVIDER:-${INIT:-unknown}}
        c=$(tui_menu "Services  [current: $current]" "Manage the active init or any installed alternate init/service implementation:" \
            current "Manage current provider ($current)" \
            systemd "systemd services / units" openrc "OpenRC services" runit "runit services" \
            sysvinit "SysVinit services" busybox "BusyBox init / inittab services" \
            initmgr "Init Manager / switch provider" advanced "Advanced service settings" back "Back") || return 0
        case "$c" in
            current) case "$current" in systemd|openrc|runit|sysvinit|busybox) menu_services_provider "$current" ;; *) tui_msg "Services" "No supported active provider detected." ;; esac ;;
            systemd|openrc|runit|sysvinit|busybox)
                if sysconfig_init_provider_available "$c"; then menu_services_provider "$c"; else label="$c"; tui_msg "Services — $label" "$label is not currently installed/detected."; fi ;;
            initmgr) menu_init_manager ;;
            advanced) sysconfig_call_menu menu_svc_advanced "Advanced services" ;;
            back|'') return 0 ;;
        esac
    done
}

# Rootfs support: recognize and wire the BusyBox init applet.
if declare -F systui_rootfs_init_detect >/dev/null 2>&1 && ! declare -F _systui_rootfs_init_detect_before_busybox >/dev/null 2>&1; then
    eval "$(declare -f systui_rootfs_init_detect | sed '1s/^systui_rootfs_init_detect[[:space:]]*()/_systui_rootfs_init_detect_before_busybox ()/')"
fi
systui_rootfs_init_detect() {
    local t="$1" detected
    detected=$(_systui_rootfs_init_detect_before_busybox "$t" 2>/dev/null || true)
    [ "$detected" != unknown ] && [ -n "$detected" ] && { printf '%s\n' "$detected"; return 0; }
    if { [ -x "$t/bin/busybox" ] || [ -x "$t/usr/bin/busybox" ]; } && [ -r "$t/etc/inittab" ]; then
        printf 'busybox\n'; return 0
    fi
    printf 'unknown\n'; return 1
}

if declare -F rootfs_wb_init_link_target >/dev/null 2>&1 && ! declare -F _rootfs_wb_init_link_target_before_busybox >/dev/null 2>&1; then
    eval "$(declare -f rootfs_wb_init_link_target | sed '1s/^rootfs_wb_init_link_target[[:space:]]*()/_rootfs_wb_init_link_target_before_busybox ()/')"
fi
rootfs_wb_init_link_target() {
    local t="$1" init="$2"
    if [ "$init" = busybox ]; then
        [ -x "$t/bin/busybox" ] && printf '../bin/busybox\n' && return 0
        [ -x "$t/usr/bin/busybox" ] && printf '../usr/bin/busybox\n' && return 0
        return 1
    fi
    _rootfs_wb_init_link_target_before_busybox "$@"
}

# Bedrock recognizes BusyBox as a first-class provider.
bedrock_aok_init_provider() {
    systui_detect_init >/dev/null 2>&1 || true
    case "${SYSTUI_INIT_PROVIDER:-${INIT:-unknown}}" in
        systemd|ish-systemd-compat|systemd-offline) printf 'systemd\n' ;;
        openrc|runit|sysvinit|busybox) printf '%s\n' "${SYSTUI_INIT_PROVIDER:-${INIT}}" ;;
        '') printf 'unknown\n' ;;
        *) printf '%s\n' "${SYSTUI_INIT_PROVIDER:-${INIT:-unknown}}" ;;
    esac
}

bedrock_aok_init_runtime() {
    case "$(bedrock_aok_init_provider)" in
        systemd) systui_systemd_online 2>/dev/null && printf 'online\n' || printf 'offline\n' ;;
        openrc) command -v rc-service >/dev/null 2>&1 && printf 'online\n' || printf 'configuration-only\n' ;;
        runit) command -v sv >/dev/null 2>&1 && printf 'online\n' || printf 'configuration-only\n' ;;
        sysvinit) command -v service >/dev/null 2>&1 && printf 'online\n' || printf 'configuration-only\n' ;;
        busybox) systui_busybox_pid1 && printf 'online\n' || printf 'configuration-only\n' ;;
        *) printf 'provider-neutral\n' ;;
    esac
}

bedrock_aok_init_service_action() {
    local provider="$1" action="$2" svc="$3"
    if [ "$provider" = busybox ]; then
        sysconfig_service_action_for busybox "$action" "$svc"
        return $?
    fi
    sysconfig_service_action_for "$provider" "$action" "$svc"
}

return 0 2>/dev/null || true
