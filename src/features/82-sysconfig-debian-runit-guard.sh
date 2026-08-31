# shellcheck shell=bash
# PHASE 82 — Debian-family init-provider replacement transactions.
#
# Debian boot-provider packages intentionally conflict with one another.  When
# the user explicitly installs another init system, replace the conflicting
# boot provider in ONE APT transaction instead of attempting to co-install it.
# This avoids the systemd-sysv/sysvinit-core and systemd-sysv/runit conflicts.

if declare -F sysconfig_install_init_provider >/dev/null 2>&1 \
    && ! declare -F _sysconfig_install_init_provider_before_debian_init_switch >/dev/null 2>&1; then
    eval "$(declare -f sysconfig_install_init_provider | sed '1s/^sysconfig_install_init_provider[[:space:]]*()/_sysconfig_install_init_provider_before_debian_init_switch ()/')"
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
    command -v dpkg-query >/dev/null 2>&1 || return 1
    dpkg-query -W -f='${Status}' -- "$1" 2>/dev/null | grep -q 'install ok installed'
}

# Full boot-provider packages used only for an explicit provider replacement.
# The ordinary Services installer may use lighter management-only packages.
systui_debian_init_target_packages() { # <provider>
    case "${1:-}" in
        systemd)  printf '%s\n' 'systemd systemd-sysv' ;;
        runit)    printf '%s\n' 'runit runit-init' ;;
        sysvinit) printf '%s\n' 'sysvinit-core sysvinit-utils' ;;
        openrc)   printf '%s\n' 'openrc sysvinit-core sysvinit-utils' ;;
        busybox)  printf '%s\n' 'busybox' ;;
        *) return 1 ;;
    esac
}

# Return installed boot-provider packages that conflict with the target.
systui_debian_init_conflicts() { # <target-provider>
    local target="$1" pkg
    case "$target" in
        systemd)
            for pkg in runit-init sysvinit-core; do
                systui_dpkg_installed "$pkg" && printf '%s\n' "$pkg"
            done
            ;;
        runit)
            for pkg in systemd-sysv sysvinit-core; do
                systui_dpkg_installed "$pkg" && printf '%s\n' "$pkg"
            done
            ;;
        sysvinit|openrc)
            for pkg in systemd-sysv runit-init; do
                systui_dpkg_installed "$pkg" && printf '%s\n' "$pkg"
            done
            ;;
        busybox)
            # Debian's busybox package is a utility package, not a supported
            # distro boot-provider replacement. Do not remove the active init.
            ;;
    esac
}

systui_debian_replace_init_provider() { # <provider>
    local provider="$1" label targets_raw conflicts_raw target_text conflict_text rc pkg
    local -a targets=() conflicts=() apt_args=()

    command -v apt-get >/dev/null 2>&1 || return 127
    targets_raw=$(systui_debian_init_target_packages "$provider") || return 2
    read -r -a targets <<< "$targets_raw"
    mapfile -t conflicts < <(systui_debian_init_conflicts "$provider")

    # No boot-provider conflict: use the normal installer/reinstaller path.
    if [ "${#conflicts[@]}" -eq 0 ]; then
        return 3
    fi

    label=$(sysconfig_init_display_name "$provider" 2>/dev/null || printf '%s' "$provider")
    target_text=$(printf '%s ' "${targets[@]}"); target_text=${target_text% }
    conflict_text=$(printf '%s ' "${conflicts[@]}"); conflict_text=${conflict_text% }

    tui_yesno "Replace init provider with $label" \
        "Installing $label requires replacing the currently installed boot-provider package(s).\n\nRemove: $conflict_text\nInstall: $target_text\n\nAPT will perform removal and installation in ONE transaction. If the transaction cannot be solved, no package changes will be committed. Continue?" || return 0

    # APT supports a trailing '-' to request removal. Combining removals and
    # installs in one solver transaction avoids leaving /sbin/init unowned if
    # installation cannot be resolved.
    apt_args=("${targets[@]}")
    for pkg in "${conflicts[@]}"; do
        apt_args+=("${pkg}-")
    done

    if [ -t 1 ]; then clear 2>/dev/null || true; fi
    printf 'Replacing init provider with %s\n' "$label"
    printf 'Install: %s\nRemove: %s\n\n' "$target_text" "$conflict_text"

    run_cmd "Replace init provider with $label" \
        apt-get -o Dpkg::Use-Pty=0 install -y -- "${apt_args[@]}"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        tui_msg "Init provider switch failed" \
            "APT could not replace the current init with $label (exit $rc). No separate removal step was used, so APT retained transactional dependency handling. Review $LOGFILE for details."
        return "$rc"
    fi

    sysconfig_refresh_init_state 2>/dev/null || true
    tui_msg "Init provider installed" \
        "$label was installed and the conflicting boot-provider package(s) were removed. Reboot is normally required before the new PID 1 becomes active."
    return 0
}

sysconfig_install_init_provider() { # <provider>
    local provider="$1" rc

    if systui_debian_family && command -v apt-get >/dev/null 2>&1; then
        systui_debian_replace_init_provider "$provider"
        rc=$?
        case "$rc" in
            0) return 0 ;;       # switched, or user cancelled confirmation
            3) ;;                # no conflict; fall through to normal installer
            2) ;;                # no full-provider mapping; normal installer may handle it
            127) ;;              # apt unavailable; normal installer reports runtime issue
            *) return "$rc" ;;
        esac
    fi

    if declare -F _sysconfig_install_init_provider_before_debian_init_switch >/dev/null 2>&1; then
        _sysconfig_install_init_provider_before_debian_init_switch "$@"
    else
        tui_msg "Init installer" "The base init-provider installer is unavailable."
        return 127
    fi
}

return 0 2>/dev/null || true
