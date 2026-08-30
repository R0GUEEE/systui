# shellcheck shell=bash
# Final capability routing. This is deliberately loaded near the end of the
# feature stack so older compatibility layers cannot leave conflicting init
# semantics behind.

if [ -r "$SYSTUI_LIBDIR/src/core/platform.sh" ]; then
    # shellcheck source=../core/platform.sh
    . "$SYSTUI_LIBDIR/src/core/platform.sh"
fi

# Cross-distribution package rescue is intentionally opt-in. Installing foreign
# distro packages as an automatic fallback can corrupt the native package DB or
# introduce ABI conflicts. Set SYSTUI_ENABLE_FOREIGN_PACKAGE_RESCUE=1 only for
# an explicit advanced recovery operation.
if [ "${SYSTUI_ENABLE_FOREIGN_PACKAGE_RESCUE:-0}" != 1 ]; then
    SYSTUI_PM_NO_WEB_FALLBACK=1
    export SYSTUI_PM_NO_WEB_FALLBACK
fi

detect_init() {
    systui_detect_init
    log "Detected init: ${INIT:-unknown} (provider=${SYSTUI_INIT_PROVIDER:-unknown}, runtime=${SYSTUI_SERVICE_RUNTIME:-unknown}, systemd=${SYSTUI_SYSTEMD_STATE:-unknown}, env=${SYSTUI_ENVIRONMENT:-unknown})"
}

sysconfig_is_ish() { systui_is_ish; }
sysconfig_systemd_usable() { [ "${SYSTUI_SERVICE_RUNTIME:-}" = systemd ] && systui_systemd_online; }
rootfs_wb_init_detect() { systui_rootfs_init_detect "$1"; }

svc() { # <action> <service>
    local action="$1" name="$2" bare=${2%.service}
    detect_init 2>/dev/null || true
    case "${SYSTUI_SERVICE_RUNTIME:-}" in
        systemd)
            systemctl "$action" "$name"
            ;;
        init-script)
            case "$action" in
                enable|disable)
                    if command -v systemctl >/dev/null 2>&1; then
                        systemctl "$action" "$name" 2>/dev/null && return 0
                    fi
                    if command -v update-rc.d >/dev/null 2>&1 && [ -e "/etc/init.d/$bare" ]; then
                        [ "$action" = enable ] && update-rc.d "$bare" defaults || update-rc.d -f "$bare" remove
                    else
                        return 1
                    fi
                    ;;
                start|stop|restart|status)
                    if [ -x "/etc/init.d/$bare" ]; then
                        "/etc/init.d/$bare" "$action"
                    elif command -v service >/dev/null 2>&1; then
                        service "$bare" "$action"
                    else
                        return 1
                    fi
                    ;;
                *) return 2 ;;
            esac
            ;;
        openrc)
            case "$action" in
                enable) rc-update add "$bare" default ;;
                disable) rc-update del "$bare" default ;;
                *) rc-service "$bare" "$action" ;;
            esac
            ;;
        runit)
            case "$action" in
                enable) [ -d "/etc/sv/$bare" ] || return 1; mkdir -p /var/service; ln -sfn "/etc/sv/$bare" "/var/service/$bare" ;;
                disable) rm -f -- "/var/service/$bare" "/service/$bare" ;;
                start) sv up "$bare" ;;
                stop) sv down "$bare" ;;
                restart) sv restart "$bare" ;;
                status) sv status "$bare" ;;
                *) return 2 ;;
            esac
            ;;
        sysvinit)
            case "$action" in
                enable) update-rc.d "$bare" defaults ;;
                disable) update-rc.d -f "$bare" remove ;;
                *) service "$bare" "$action" ;;
            esac
            ;;
        *) return 1 ;;
    esac
}

sysconfig_init_summary() {
    detect_init 2>/dev/null || true
    {
        echo "Detected init : ${INIT:-unknown}"
        echo "Provider      : ${SYSTUI_INIT_PROVIDER:-unknown}"
        echo "Runtime mode  : ${SYSTUI_SERVICE_RUNTIME:-unknown}"
        echo "PID 1         : $(systui_pid1_name)"
        echo "/sbin/init    : $(readlink -f /sbin/init 2>/dev/null || echo unavailable)"
        echo "Environment   : ${SYSTUI_ENVIRONMENT:-unknown}"
        echo "Manager state : ${SYSTUI_SYSTEMD_STATE:-n/a}"
        echo "Foreign pkg rescue: $([ "${SYSTUI_PM_NO_WEB_FALLBACK:-1}" = 1 ] && echo disabled || echo ENABLED)"
    } > "$SYSTUI_TMP/init-summary"
    tui_text "Init system" "$SYSTUI_TMP/init-summary"
}
