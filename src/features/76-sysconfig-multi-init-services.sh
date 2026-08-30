# shellcheck shell=bash
# PHASE 76 — automatic systemd compatibility + provider-specific service tools.
#
# Selecting systemd always installs/uses the iSH-AOK-aware compatibility layer.
# The compatibility init auto-detects the kernel: real systemd is exec'd on a
# normal Linux host; iSH-AOK receives the compatibility supervisor.
#
# Service management is provider-addressable so systemd, OpenRC, runit and
# SysVinit can all be inspected/configured from the Services UI even when one
# of the other providers is currently PID 1.

sysconfig_init_provider_available() { # <systemd|openrc|runit|sysvinit>
    case "${1:-}" in
        systemd) command -v systemctl >/dev/null 2>&1 || [ -d /etc/systemd/system ] || [ -d /usr/lib/systemd/system ] || [ -d /lib/systemd/system ] ;;
        openrc) command -v rc-service >/dev/null 2>&1 || [ -d /etc/conf.d ] ;;
        runit) command -v sv >/dev/null 2>&1 || [ -d /etc/sv ] || [ -d /etc/runit/sv ] ;;
        sysvinit) command -v service >/dev/null 2>&1 || [ -d /etc/init.d ] ;;
        *) return 2 ;;
    esac
}

sysconfig_service_config_path_for() { # <provider> <service>
    local provider="$1" s="$2"
    case "$provider" in
        systemd)
            case "$s" in *.*) ;; *) s="$s.service" ;; esac
            if [ -f "/etc/systemd/system/$s" ]; then printf '%s\n' "/etc/systemd/system/$s"
            else printf '%s\n' "/etc/systemd/system/$s.d/override.conf"; fi
            ;;
        openrc) printf '%s\n' "/etc/conf.d/${s%.service}" ;;
        runit)
            s=${s%.service}
            if [ -d "/etc/sv/$s" ]; then printf '%s\n' "/etc/sv/$s/run"
            elif [ -d "/etc/runit/sv/$s" ]; then printf '%s\n' "/etc/runit/sv/$s/run"
            else printf '%s\n' "/etc/sv/$s/run"; fi
            ;;
        sysvinit)
            s=${s%.service}
            if [ -f "/etc/default/$s" ]; then printf '%s\n' "/etc/default/$s"
            elif [ -f "/etc/sysconfig/$s" ]; then printf '%s\n' "/etc/sysconfig/$s"
            else printf '%s\n' "/etc/init.d/$s"; fi
            ;;
        *) return 2 ;;
    esac
}

sysconfig_service_action_for() { # <provider> <action> <service>
    local provider="$1" action="$2" s="$3" bare
    sysconfig_valid_token "$s" || return 2
    bare=${s%.service}
    case "$provider" in
        systemd)
            case "$action" in
                start|stop|restart|status)
                    if declare -F sysconfig_root_systemd_ensure_online >/dev/null 2>&1 && sysconfig_root_systemd_ensure_online; then
                        systemctl "$action" "$s"
                    else
                        printf 'systemd runtime operation requires the live PID 1 manager.\n' >&2
                        return 1
                    fi
                    ;;
                enable|disable|mask|unmask|preset)
                    sysconfig_systemd_unit_file_action "$action" "$s"
                    ;;
                *) return 2 ;;
            esac
            ;;
        openrc)
            command -v rc-service >/dev/null 2>&1 || return 127
            case "$action" in
                start|stop|restart|status) rc-service "$bare" "$action" ;;
                enable) command -v rc-update >/dev/null 2>&1 && rc-update add "$bare" default ;;
                disable) command -v rc-update >/dev/null 2>&1 && rc-update del "$bare" default ;;
                *) return 2 ;;
            esac
            ;;
        runit)
            command -v sv >/dev/null 2>&1 || return 127
            case "$action" in
                start) sv up "$bare" ;;
                stop) sv down "$bare" ;;
                restart) sv restart "$bare" ;;
                status) sv status "$bare" ;;
                enable)
                    [ -d "/etc/sv/$bare" ] || [ -d "/etc/runit/sv/$bare" ] || return 1
                    mkdir -p /var/service
                    if [ -d "/etc/sv/$bare" ]; then ln -sfn "/etc/sv/$bare" "/var/service/$bare"
                    else ln -sfn "/etc/runit/sv/$bare" "/var/service/$bare"; fi
                    ;;
                disable) rm -f -- "/var/service/$bare" "/service/$bare" "/run/runit/service/$bare" ;;
                *) return 2 ;;
            esac
            ;;
        sysvinit)
            command -v service >/dev/null 2>&1 || return 127
            case "$action" in
                start|stop|restart|status) service "$bare" "$action" ;;
                enable) command -v update-rc.d >/dev/null 2>&1 && update-rc.d "$bare" defaults ;;
                disable) command -v update-rc.d >/dev/null 2>&1 && update-rc.d -f "$bare" remove ;;
                *) return 2 ;;
            esac
            ;;
        *) return 2 ;;
    esac
}

sysconfig_service_list_for() { # <provider> <output-file>
    local provider="$1" out="$2" p
    case "$provider" in
        systemd)
            if declare -F sysconfig_root_systemd_online >/dev/null 2>&1 && sysconfig_root_systemd_online; then
                systemctl list-units --type=service --all --no-pager > "$out" 2>&1
            else
                { command -v systemctl >/dev/null 2>&1 && SYSTEMD_OFFLINE=1 systemctl list-unit-files --type=service --no-pager 2>/dev/null || true; } > "$out"
            fi
            ;;
        openrc) { command -v rc-status >/dev/null 2>&1 && rc-status -a 2>&1 || find /etc/init.d -mindepth 1 -maxdepth 1 -type f -printf '%f\n' 2>/dev/null; } > "$out" ;;
        runit)
            { for p in /var/service/* /run/runit/service/* /service/* /etc/sv/* /etc/runit/sv/*; do [ -d "$p" ] && basename "$p"; done; } | sort -u > "$out"
            ;;
        sysvinit) { command -v service >/dev/null 2>&1 && service --status-all 2>&1 || find /etc/init.d -mindepth 1 -maxdepth 1 -type f -printf '%f\n' 2>/dev/null; } > "$out" ;;
        *) return 2 ;;
    esac
}

sysconfig_service_edit_for() { # <provider> <service>
    local provider="$1" s="$2" f dir
    sysconfig_valid_token "$s" || { tui_msg "Invalid service" "Unsafe service name."; return 1; }
    f=$(sysconfig_service_config_path_for "$provider" "$s") || return 1
    dir=${f%/*}
    mkdir -p "$dir" || return 1
    [ -e "$f" ] || : > "$f"
    if declare -F safe_edit >/dev/null 2>&1; then safe_edit "$f"; else ${EDITOR:-vi} "$f"; fi
}

menu_services_provider() { # <provider>
    local provider="$1" c s f
    while true; do
        c=$(tui_menu "Services — $provider" "Manage $provider services directly. Current detected provider: ${SYSTUI_INIT_PROVIDER:-${INIT:-unknown}}" \
            list "List $provider services" \
            start "Start service" stop "Stop service" restart "Restart service" status "Show status" \
            enable "Enable service" disable "Disable service" \
            config "View/edit native service configuration" \
            systemd_mask "Mask/unmask systemd unit" \
            back "Back") || return 0
        case "$c" in
            list)
                sysconfig_service_list_for "$provider" "$SYSTUI_TMP/svc-$provider" || true
                tui_text "$provider services" "$SYSTUI_TMP/svc-$provider"
                ;;
            start|stop|restart|status|enable|disable)
                s=$(tui_input "$provider service" "Service name:" "") || continue
                [ -n "$s" ] || continue
                run_cmd "$provider $c $s" sysconfig_service_action_for "$provider" "$c" "$s" || true
                ;;
            config)
                s=$(tui_input "$provider service" "Service name:" "") || continue
                [ -n "$s" ] || continue
                f=$(sysconfig_service_config_path_for "$provider" "$s" 2>/dev/null || true)
                c=$(tui_menu "$provider config — $s" "Native path: ${f:-unavailable}" view "View configuration" edit "Edit configuration" back "Back") || continue
                case "$c" in
                    view)
                        if [ -n "$f" ] && [ -r "$f" ]; then cp "$f" "$SYSTUI_TMP/svc-config"; else printf '(not present yet)\n%s\n' "${f:-unknown}" > "$SYSTUI_TMP/svc-config"; fi
                        tui_text "$provider config — $s" "$SYSTUI_TMP/svc-config"
                        ;;
                    edit) sysconfig_service_edit_for "$provider" "$s" ;;
                esac
                ;;
            systemd_mask)
                [ "$provider" = systemd ] || { tui_msg "$provider" "Mask/unmask is a systemd unit-file operation."; continue; }
                local a
                a=$(tui_radio "Systemd mask" "Action:" mask Mask on unmask Unmask off) || continue
                s=$(tui_input "Systemd unit" "Unit name:" "") || continue
                [ -n "$s" ] && sysconfig_systemd_mask_service "$a" "$s" || true
                ;;
            back|"") return 0 ;;
        esac
    done
}

menu_services() {
    local c current label
    while true; do
        sysconfig_refresh_init_state
        current=${SYSTUI_INIT_PROVIDER:-${INIT:-unknown}}
        c=$(tui_menu "Services  [current: $current]" "Manage the active init or any installed alternate init/service implementation:" \
            current "Manage current provider ($current)" \
            systemd "systemd services / units" \
            openrc "OpenRC services" \
            runit "runit services" \
            sysvinit "SysVinit services" \
            initmgr "Init Manager / switch provider" \
            advanced "Advanced service settings" \
            back "Back") || return 0
        case "$c" in
            current)
                case "$current" in systemd) menu_services_provider systemd ;; openrc) menu_services_provider openrc ;; runit) menu_services_provider runit ;; sysvinit) menu_services_provider sysvinit ;; *) tui_msg "Services" "No supported active provider detected." ;; esac
                ;;
            systemd|openrc|runit|sysvinit)
                if sysconfig_init_provider_available "$c"; then menu_services_provider "$c"
                else
                    case "$c" in systemd) label=systemd ;; openrc) label=OpenRC ;; runit) label=runit ;; sysvinit) label=SysVinit ;; esac
                    tui_msg "Services — $label" "$label is not currently installed/detected. Its manager remains available after installing the corresponding init/service tools."
                fi
                ;;
            initmgr) menu_init_manager ;;
            advanced) sysconfig_call_menu menu_svc_advanced "Advanced services" ;;
            back|"") return 0 ;;
        esac
    done
}

rootfs_wb_init_wire() { # <target> <init>
    local t="$1" init="$2" link tmp
    mkdir -p "$t/sbin" || return 1
    if [ "$init" = systemd ] && declare -F rootfs_install_ish_systemd_compat >/dev/null 2>&1; then
        SYSTUI_ISH_COMPAT_SKIP_COREUTILS_MIGRATION=1 rootfs_install_ish_systemd_compat "$t"
        return $?
    fi
    link=$(rootfs_wb_init_link_target "$t" "$init") || return $?
    tmp="$t/sbin/.init.systui-new.$$"
    rm -f "$tmp"
    ln -s "$link" "$tmp" || return 1
    mv -f "$tmp" "$t/sbin/init" || { rm -f "$tmp"; return 1; }
}

rootfs_wb_init_commit_metadata() { # <target> <new> <old>
    local t="$1" new="$2" old="$3"
    local runtime="$new"
    mkdir -p "$t/etc/systui" || return 1
    printf 'init=%s\nprevious=%s\n' "$new" "$old" > "$t/etc/systui/init-selection.conf" || return 1
    [ "$new" = systemd ] && runtime=ish-systemd-compat
    if declare -F systui_rootfs_metadata_set >/dev/null 2>&1; then
        [ -n "$(systui_rootfs_metadata_get "$t" schema)" ] || systui_rootfs_metadata_set "$t" schema "${SYSTUI_ROOTFS_SCHEMA:-1}" || return 1
        systui_rootfs_metadata_set "$t" init "$new" || return 1
        systui_rootfs_metadata_set "$t" runtime "$runtime" || return 1
    fi
}

sysconfig_refresh_init_state() {
    if declare -F systui_detect_init >/dev/null 2>&1; then systui_detect_init >/dev/null 2>&1 || true
    elif declare -F detect_init >/dev/null 2>&1; then detect_init >/dev/null 2>&1 || true
    fi
    if [ "${SYSTUI_INIT_PROVIDER:-${INIT_PROVIDER:-}}" = systemd ]; then
        SYSTUI_SYSTEMD_COMPAT_MODE=ish-aok-auto
    else
        SYSTUI_SYSTEMD_COMPAT_MODE=off
    fi
    export SYSTUI_SYSTEMD_COMPAT_MODE
}

return 0 2>/dev/null || true
