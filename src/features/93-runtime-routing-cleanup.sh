# shellcheck shell=bash
# PHASE 93 — final routing cleanup after menu consolidation.

# Translate only well-known distro-specific package aliases before a raw
# pm_install request crosses from the host into a different Bedrock stratum.
# Unknown package names are deliberately preserved verbatim.
systui_bedrock_cross_pkg_alias() { # <target-pm> <package>
    local pm="$1" pkg="$2" canonical=''
    case "$pkg" in
        tigervnc-standalone-server) canonical=tigervnc ;;
        python3-pip|python-pip|py3-pip) canonical=pip ;;
        golang-go|golang) canonical=go ;;
        docker.io|moby-engine) canonical=docker ;;
        python3) canonical=python ;;
        nodejs) canonical=node ;;
        ruby) canonical=gem ;;
        snapd) canonical=snap ;;
    esac
    if [ -n "$canonical" ]; then
        systui_bedrock_pkg_name "$pm" "$canonical" 2>/dev/null || printf '%s\n' "$pkg"
    else
        printf '%s\n' "$pkg"
    fi
}

if declare -F systui_bedrock_pm_install_raw >/dev/null 2>&1 \
    && ! declare -F _systui_bedrock_pm_install_raw_before_alias_cleanup >/dev/null 2>&1; then
    eval "$(declare -f systui_bedrock_pm_install_raw | sed '1s/^systui_bedrock_pm_install_raw[[:space:]]*()/_systui_bedrock_pm_install_raw_before_alias_cleanup ()/')"
fi

systui_bedrock_pm_install_raw() { # <stratum> <packages...>
    local st="$1" pm p mapped
    local -a normalized=()
    shift
    [ "$#" -gt 0 ] || return 1
    pm=$(systui_bedrock_stratum_pm "$st" 2>/dev/null || true)
    [ -n "$pm" ] || {
        tui_msg "Install unavailable" "No supported package manager was detected in Bedrock stratum '$st'."
        return 1
    }
    for p in "$@"; do
        mapped=$(systui_bedrock_cross_pkg_alias "$pm" "$p")
        normalized+=("$mapped")
    done
    _systui_bedrock_pm_install_raw_before_alias_cleanup "$st" "${normalized[@]}"
}

# The older Services front doors listed both "Manage current provider" and the
# same provider again by name. Keep every provider directly addressable but
# represent the active state in its label instead of duplicating the action.
systui_service_provider_label() { # <provider> <active>
    local provider="$1" active="$2" name state
    case "$provider" in
        systemd) name=systemd ;;
        openrc) name=OpenRC ;;
        runit) name=runit ;;
        sysvinit) name=SysVinit ;;
        busybox) name='BusyBox init' ;;
        *) name="$provider" ;;
    esac
    if [ "$provider" = "$active" ]; then
        state='active'
    elif sysconfig_init_provider_available "$provider" 2>/dev/null; then
        state='installed'
    else
        state='not installed'
    fi
    printf '%s services [%s]\n' "$name" "$state"
}

menu_services() {
    local c current provider label
    local -a opts=()
    while true; do
        sysconfig_refresh_init_state
        current=${SYSTUI_INIT_PROVIDER:-${INIT:-unknown}}
        opts=()
        for provider in systemd openrc runit sysvinit busybox; do
            label=$(systui_service_provider_label "$provider" "$current")
            opts+=("$provider" "$label")
        done
        opts+=(initmgr "Init Manager / switch provider" advanced "Advanced service settings" back "Back")

        c=$(tui_menu "Services  [active: $current]" \
            "Manage an init/service provider. The active provider is marked in-place; duplicate current-provider entries are removed." \
            "${opts[@]}") || return 0
        case "$c" in
            systemd|openrc|runit|sysvinit|busybox)
                if sysconfig_init_provider_available "$c" 2>/dev/null; then
                    menu_services_provider "$c"
                else
                    label=$(systui_service_provider_label "$c" "$current")
                    tui_msg "Services" "$label\n\nInstall this init/service implementation before managing it."
                fi
                ;;
            initmgr) menu_init_manager ;;
            advanced) sysconfig_call_menu menu_svc_advanced "Advanced services" ;;
            back|'') return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
