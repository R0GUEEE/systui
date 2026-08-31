# shellcheck shell=bash
# PHASE 82 — guard Debian-family runit installs that cannot coexist with
# systemd-sysv on releases where runit -> sysuser-helper conflicts with it.

if declare -F sysconfig_install_init_provider >/dev/null 2>&1 \
    && ! declare -F _sysconfig_install_init_provider_before_debian_runit_guard >/dev/null 2>&1; then
    eval "$(declare -f sysconfig_install_init_provider | sed '1s/^sysconfig_install_init_provider[[:space:]]*()/_sysconfig_install_init_provider_before_debian_runit_guard ()/')"
fi

systui_debian_family() {
    [ -r /etc/os-release ] || return 1
    local id like
    id=$(awk -F= '$1=="ID" {gsub(/^\"|\"$/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null)
    like=$(awk -F= '$1=="ID_LIKE" {gsub(/^\"|\"$/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null)
    case " $id $like " in
        *' debian '*|*' ubuntu '*|*' kali '*|*' devuan '*) return 0 ;;
        *) return 1 ;;
    esac
}

systui_dpkg_installed() { # <package>
    dpkg-query -W -f='${Status}' -- "$1" 2>/dev/null | grep -q 'install ok installed'
}

systui_debian_runit_conflicts_with_current_init() {
    command -v apt-get >/dev/null 2>&1 || return 1
    command -v dpkg-query >/dev/null 2>&1 || return 1
    systui_debian_family || return 1
    systui_dpkg_installed systemd-sysv || return 1

    # Newer Debian-family runit packages depend on sysuser-helper. On affected
    # releases sysuser-helper conflicts with systemd-sysv, so APT cannot solve
    # the transaction without replacing the current /sbin/init provider.
    local conflicts
    conflicts=$(apt-cache show sysuser-helper 2>/dev/null | awk -F': ' '/^Conflicts:/ {print $2}' | tr '\n' ' ')
    case " $conflicts " in
        *' systemd-sysv '*) return 0 ;;
    esac
    return 1
}

sysconfig_install_init_provider() { # <provider>
    local provider="$1" choice

    if [ "$provider" = runit ] && systui_debian_runit_conflicts_with_current_init; then
        choice=$(tui_menu "runit installation conflict" \
            "This Debian-family release cannot install runit alongside the currently installed systemd-sysv package. runit requires sysuser-helper, and sysuser-helper conflicts with systemd-sysv. Installing runit therefore requires an init-provider switch rather than a normal Services package install." \
            switch "Open Init Manager and switch to runit" \
            info "Show conflict details" \
            back "Back") || return 0
        case "$choice" in
            switch)
                if declare -F menu_init_manager >/dev/null 2>&1; then
                    menu_init_manager
                else
                    tui_msg "runit" "Init Manager is unavailable in this build."
                fi
                ;;
            info)
                {
                    printf '%s\n' 'runit cannot be co-installed with the current Debian systemd-sysv setup.'
                    printf '%s\n\n' 'Reason:'
                    printf '%s\n' '  runit -> sysuser-helper'
                    printf '%s\n' '  sysuser-helper conflicts with systemd-sysv'
                    printf '%s\n\n' 'systemd-sysv owns the systemd /sbin/init compatibility link.'
                    printf '%s\n' 'Use Init Manager for a deliberate runit init switch.'
                } > "${SYSTUI_TMP:-/tmp}/runit-conflict"
                tui_text "runit installation conflict" "${SYSTUI_TMP:-/tmp}/runit-conflict"
                ;;
        esac
        return 0
    fi

    if declare -F _sysconfig_install_init_provider_before_debian_runit_guard >/dev/null 2>&1; then
        _sysconfig_install_init_provider_before_debian_runit_guard "$@"
    else
        tui_msg "Init installer" "The base init-provider installer is unavailable."
        return 127
    fi
}

return 0 2>/dev/null || true
