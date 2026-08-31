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

# Keep every provider directly addressable from System Config > Services.
# The active/install state is shown in-place instead of duplicating a separate
# "Manage current provider" action.
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
    printf '%s — install / manage [%s]\n' "$name" "$state"
}

systui_service_provider_menu() { # <provider>
    local provider="$1" c current label state
    while true; do
        sysconfig_refresh_init_state 2>/dev/null || true
        current=${SYSTUI_INIT_PROVIDER:-${INIT:-unknown}}
        label=$(sysconfig_init_display_name "$provider" 2>/dev/null || printf '%s\n' "$provider")
        if [ "$provider" = "$current" ]; then
            state=active
        elif sysconfig_init_provider_available "$provider" 2>/dev/null; then
            state=installed
        else
            state='not installed'
        fi

        c=$(tui_menu "$label  [$state]" \
            "Install or manage $label. Installing utilities does not automatically replace PID 1." \
            manage "Manage $label services" \
            install "Install / reinstall $label" \
            remove "Remove $label" \
            switch "Switch active init provider" \
            back "Back") || return 0

        case "$c" in
            manage)
                if sysconfig_init_provider_available "$provider" 2>/dev/null; then
                    menu_services_provider "$provider"
                else
                    if tui_yesno "$label not installed" "Install $label utilities now?"; then
                        sysconfig_install_init_provider "$provider" || true
                        if sysconfig_init_provider_available "$provider" 2>/dev/null; then
                            menu_services_provider "$provider"
                        fi
                    fi
                fi
                ;;
            install)
                sysconfig_install_init_provider "$provider" || true
                ;;
            remove)
                sysconfig_remove_init_provider "$provider" || true
                ;;
            switch)
                menu_init_manager
                ;;
            back|'') return 0 ;;
        esac
    done
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
        opts+=(status "Installed init provider status" initmgr "Init Manager / switch provider" advanced "Advanced service settings" back "Back")

        c=$(tui_menu "Services  [active: $current]" \
            "Select an init provider to install, reinstall, remove, or manage its services." \
            "${opts[@]}") || return 0
        case "$c" in
            systemd|openrc|runit|sysvinit|busybox)
                systui_service_provider_menu "$c"
                ;;
            status)
                if declare -F menu_init_utilities >/dev/null 2>&1; then
                    local p n
                    {
                        printf 'Active init: %s\n\n' "$current"
                        for p in systemd openrc runit sysvinit busybox; do
                            n=$(sysconfig_init_display_name "$p" 2>/dev/null || printf '%s' "$p")
                            if [ "$p" = "$current" ]; then
                                printf '%-14s active\n' "$n"
                            elif sysconfig_init_provider_available "$p" 2>/dev/null; then
                                printf '%-14s installed\n' "$n"
                            else
                                printf '%-14s not installed\n' "$n"
                            fi
                        done
                    } > "$SYSTUI_TMP/init-provider-status"
                    tui_text "Init providers" "$SYSTUI_TMP/init-provider-status"
                fi
                ;;
            initmgr) menu_init_manager ;;
            advanced) sysconfig_call_menu menu_svc_advanced "Advanced services" ;;
            back|'') return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
