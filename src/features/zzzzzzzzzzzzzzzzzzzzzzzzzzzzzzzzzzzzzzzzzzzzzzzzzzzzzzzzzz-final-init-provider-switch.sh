# shellcheck shell=bash
# FINAL init-provider installer override.
# Debian-family init packages are mutually exclusive at the PID1-provider level.
# Handle those replacements in one APT transaction so dependencies are solved
# with the outgoing provider removed and the requested provider installed.

if declare -F sysconfig_install_init_provider >/dev/null 2>&1 \
    && ! declare -F _sysconfig_install_init_provider_before_final_switch >/dev/null 2>&1; then
    eval "$(declare -f sysconfig_install_init_provider | sed '1s/^sysconfig_install_init_provider[[:space:]]*()/_sysconfig_install_init_provider_before_final_switch ()/')"
fi

systui_final_debian_family() {
    [ -r /etc/os-release ] || return 1
    local id like
    id=$(awk -F= '$1=="ID" {gsub(/^\"|\"$/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null)
    like=$(awk -F= '$1=="ID_LIKE" {gsub(/^\"|\"$/, "", $2); print $2; exit}' /etc/os-release 2>/dev/null)
    case " $id $like " in
        *' debian '*|*' ubuntu '*|*' kali '*|*' devuan '*) return 0 ;;
        *) return 1 ;;
    esac
}

systui_final_dpkg_installed() {
    dpkg-query -W -f='${Status}' -- "$1" 2>/dev/null | grep -q 'install ok installed'
}

systui_final_apt_init_switch() { # <provider>
    local provider="$1" label install_text remove_text rc
    local -a install=() remove=() transaction=()

    case "$provider" in
        systemd)
            install=(systemd systemd-sysv)
            systui_final_dpkg_installed runit-init && remove+=(runit-init)
            systui_final_dpkg_installed sysvinit-core && remove+=(sysvinit-core)
            systui_final_dpkg_installed openrc && remove+=(openrc)
            ;;
        runit)
            # runit alone is insufficient on Debian when it is intended to become
            # the init provider; runit-init provides the PID1 integration.
            install=(runit runit-init)
            systui_final_dpkg_installed systemd-sysv && remove+=(systemd-sysv)
            systui_final_dpkg_installed sysvinit-core && remove+=(sysvinit-core)
            systui_final_dpkg_installed openrc && remove+=(openrc)
            ;;
        sysvinit)
            install=(sysvinit-core sysvinit-utils)
            systui_final_dpkg_installed systemd-sysv && remove+=(systemd-sysv)
            systui_final_dpkg_installed runit-init && remove+=(runit-init)
            systui_final_dpkg_installed openrc && remove+=(openrc)
            ;;
        openrc)
            # Debian OpenRC uses the SysV-compatible init executable while OpenRC
            # supplies service/runlevel management.
            install=(openrc sysvinit-core sysvinit-utils)
            systui_final_dpkg_installed systemd-sysv && remove+=(systemd-sysv)
            systui_final_dpkg_installed runit-init && remove+=(runit-init)
            ;;
        busybox)
            return 2
            ;;
        *) return 2 ;;
    esac

    label=$(sysconfig_init_display_name "$provider" 2>/dev/null || printf '%s' "$provider")
    install_text=$(printf '%s ' "${install[@]}"); install_text=${install_text% }
    if [ "${#remove[@]}" -gt 0 ]; then
        remove_text=$(printf '%s ' "${remove[@]}"); remove_text=${remove_text% }
    else
        remove_text='none'
    fi

    if ! tui_yesno "Switch init provider to $label" \
        "This will replace conflicting init-provider packages in one APT transaction.\n\nInstall: $install_text\nRemove: $remove_text\n\nThe system may require a reboot after the transaction. Continue?"; then
        return 0
    fi

    transaction=("${install[@]}")
    local pkg
    for pkg in "${remove[@]}"; do
        transaction+=("${pkg}-")
    done

    run_cmd "Switch init provider to $label" \
        env DEBIAN_FRONTEND=noninteractive \
        apt-get -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confold \
        install -y -- "${transaction[@]}"
    rc=$?
    [ "$rc" -eq 0 ] || {
        tui_msg "Init switch failed" \
            "APT could not complete the init-provider replacement (exit $rc).\n\nInstall: $install_text\nRemove: $remove_text\n\nThe previous provider was requested for removal only inside the same failed APT transaction, so APT should not have committed a standalone pre-removal step."
        return "$rc"
    }

    sysconfig_refresh_init_state 2>/dev/null || true
    tui_msg "Init provider installed" \
        "$label was installed and conflicting boot-provider packages were replaced. Reboot when appropriate so PID 1 can change to the new provider."
    return 0
}

sysconfig_install_init_provider() { # <provider>
    local provider="$1" pm

    # Do not trust a stale global PM across chroot/Bedrock transitions.
    if command -v apt-get >/dev/null 2>&1 && systui_final_debian_family; then
        case "$provider" in
            systemd|runit|sysvinit|openrc)
                systui_final_apt_init_switch "$provider"
                return $?
                ;;
        esac
    fi

    if declare -F _sysconfig_install_init_provider_before_final_switch >/dev/null 2>&1; then
        _sysconfig_install_init_provider_before_final_switch "$@"
    else
        tui_msg "Init installer" "The base init-provider installer is unavailable."
        return 127
    fi
}

return 0 2>/dev/null || true
