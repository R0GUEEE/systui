# shellcheck shell=bash
###############################################################################
# iSH-AOK — offline systemd service-manager compatibility
###############################################################################

# iSH can execute systemd binaries but does not provide all kernel/runtime
# facilities needed by a normal systemd manager. When systemctl reports
# "offline", treat the system as a compatibility environment rather than a
# fully usable systemd host.

sysconfig_ish_systemd_offline() {
    declare -F sysconfig_is_ish >/dev/null 2>&1 && sysconfig_is_ish || return 1
    command -v systemctl >/dev/null 2>&1 || return 1
    local state
    state=$(systemctl is-system-running 2>/dev/null || true)
    [ "$state" = offline ] || [ "$state" = unknown ] || [ -z "$state" ]
}

if declare -F detect_init >/dev/null 2>&1 && ! declare -F _systui_detect_init_before_ish_offline >/dev/null 2>&1; then
    eval "$(declare -f detect_init | sed '1s/^detect_init[[:space:]]*()/_systui_detect_init_before_ish_offline ()/')"
fi

detect_init() {
    _systui_detect_init_before_ish_offline 2>/dev/null || true
    if sysconfig_ish_systemd_offline; then
        INIT=ish-systemd-compat
    fi
    export INIT
}

sysconfig_ish_service_script() { # <service>
    local s="${1%.service}"
    for p in "/etc/init.d/$s" "/etc/init.d/${s%d}"; do
        [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

sysconfig_ish_unit_exists() { # <service>
    local s="$1"
    case "$s" in *.service) ;; *) s="$s.service" ;; esac
    [ -e "/etc/systemd/system/$s" ] || [ -e "/usr/lib/systemd/system/$s" ] || [ -e "/lib/systemd/system/$s" ]
}

if declare -F svc >/dev/null 2>&1 && ! declare -F _systui_svc_before_ish_offline >/dev/null 2>&1; then
    eval "$(declare -f svc | sed '1s/^svc[[:space:]]*()/_systui_svc_before_ish_offline ()/')"
fi

svc() { # <enable|disable|start|stop|restart|status> <service>
    local action="$1" s="$2" script=""
    if [ "${INIT:-}" != ish-systemd-compat ]; then
        _systui_svc_before_ish_offline "$@"
        return $?
    fi

    script=$(sysconfig_ish_service_script "$s" 2>/dev/null || true)
    case "$action" in
        enable)
            # `systemctl enable` only edits unit-file symlinks and works even
            # when no manager is online. Prefer it for packaged systemd units.
            if sysconfig_ish_unit_exists "$s"; then
                SYSTEMD_OFFLINE=1 systemctl enable "$s" 2>/dev/null && return 0
            fi
            if command -v update-rc.d >/dev/null 2>&1 && [ -n "$script" ]; then
                update-rc.d "${s%.service}" defaults && return 0
            fi
            if command -v rc-update >/dev/null 2>&1 && [ -n "$script" ]; then
                rc-update add "${s%.service}" default && return 0
            fi
            return 1
            ;;
        disable)
            if sysconfig_ish_unit_exists "$s"; then
                SYSTEMD_OFFLINE=1 systemctl disable "$s" 2>/dev/null && return 0
            fi
            if command -v update-rc.d >/dev/null 2>&1 && [ -n "$script" ]; then
                update-rc.d "${s%.service}" disable && return 0
            fi
            if command -v rc-update >/dev/null 2>&1 && [ -n "$script" ]; then
                rc-update del "${s%.service}" default && return 0
            fi
            return 1
            ;;
        start|stop|restart|status)
            if [ -n "$script" ]; then
                "$script" "$action"
                return $?
            fi
            if command -v service >/dev/null 2>&1; then
                service "${s%.service}" "$action"
                return $?
            fi
            printf 'Service %s has no iSH-compatible init script. Its systemd unit can be enabled/disabled offline, but cannot be controlled by an offline manager.\n' "$s" >&2
            return 1
            ;;
        *) return 2 ;;
    esac
}

sysconfig_ish_service_inventory() {
    {
        echo 'iSH-AOK systemd compatibility service inventory'
        echo
        echo '--- Systemd unit files ---'
        if command -v systemctl >/dev/null 2>&1; then
            SYSTEMD_OFFLINE=1 systemctl list-unit-files --type=service --no-pager 2>/dev/null || true
        fi
        echo
        echo '--- Runtime-compatible init scripts ---'
        if [ -d /etc/init.d ]; then
            find /etc/init.d -mindepth 1 -maxdepth 1 -type f -perm /111 -printf '%f\n' 2>/dev/null | sort
        fi
    } > "$SYSTUI_TMP/init-list"
    tui_text "Services — iSH-AOK compatibility" "$SYSTUI_TMP/init-list"
}

# Override the generic listing function so Services > Manage remains useful in
# compatibility mode instead of falling into the unknown-init branch.
if declare -F sysconfig_init_service_list >/dev/null 2>&1 && ! declare -F _systui_init_service_list_before_ish_offline >/dev/null 2>&1; then
    eval "$(declare -f sysconfig_init_service_list | sed '1s/^sysconfig_init_service_list[[:space:]]*()/_systui_init_service_list_before_ish_offline ()/')"
fi
sysconfig_init_service_list() {
    if [ "${INIT:-}" = ish-systemd-compat ]; then
        sysconfig_ish_service_inventory
    else
        _systui_init_service_list_before_ish_offline "$@"
    fi
}

# Replace the status summary with explicit manager capability information.
if declare -F sysconfig_init_summary >/dev/null 2>&1 && ! declare -F _systui_init_summary_before_ish_offline >/dev/null 2>&1; then
    eval "$(declare -f sysconfig_init_summary | sed '1s/^sysconfig_init_summary[[:space:]]*()/_systui_init_summary_before_ish_offline ()/')"
fi
sysconfig_init_summary() {
    detect_init 2>/dev/null || true
    if [ "${INIT:-}" != ish-systemd-compat ]; then
        _systui_init_summary_before_ish_offline "$@"
        return $?
    fi
    {
        echo "Detected init : ish-systemd-compat"
        echo "PID 1         : $(cat /proc/1/comm 2>/dev/null || echo unknown)"
        echo "/sbin/init    : $(readlink -f /sbin/init 2>/dev/null || echo unavailable)"
        echo "Environment   : iSH-AOK"
        echo "Manager state : offline"
        echo "Runtime mode  : init-script compatibility"
        echo "Unit files    : systemctl offline enable/disable supported"
        echo
        echo "Real systemd is installed, but its manager is not usable as a normal"
        echo "Linux system manager in this iSH-AOK environment. Systui therefore"
        echo "uses init scripts for runtime service control and systemd only for"
        echo "offline unit-file configuration."
    } > "$SYSTUI_TMP/init-summary"
    tui_text "Init system" "$SYSTUI_TMP/init-summary"
}

# The advanced systemd menu should not imply runtime operations work while the
# manager is offline. Keep safe unit-file inspection and enable/disable in the
# main service utility; block manager-only controls with a precise message.
if declare -F sysconfig_systemd_usable >/dev/null 2>&1 && ! declare -F _systui_systemd_usable_before_ish_offline >/dev/null 2>&1; then
    eval "$(declare -f sysconfig_systemd_usable | sed '1s/^sysconfig_systemd_usable[[:space:]]*()/_systui_systemd_usable_before_ish_offline ()/')"
fi
sysconfig_systemd_usable() {
    [ "${INIT:-}" = ish-systemd-compat ] && return 1
    _systui_systemd_usable_before_ish_offline "$@"
}

# Do not export these functions. iSH has a small ARG_MAX and exported Bash
# function bodies can make child execs fail with "Argument list too long".
