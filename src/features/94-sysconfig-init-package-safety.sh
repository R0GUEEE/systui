# shellcheck shell=bash
# PHASE 94 — safe init utility package mappings.
#
# System Config > Services installs management utilities only. It must not
# replace PID 1 or request mutually-exclusive init-provider packages. Full init
# replacement remains the responsibility of Init Manager.

if declare -F sysconfig_init_install_packages >/dev/null 2>&1 \
    && ! declare -F _sysconfig_init_install_packages_before_safety >/dev/null 2>&1; then
    eval "$(declare -f sysconfig_init_install_packages | sed '1s/^sysconfig_init_install_packages[[:space:]]*()/_sysconfig_init_install_packages_before_safety ()/')"
fi

sysconfig_init_install_packages() { # <provider> <package-manager>
    local provider="$1" pm="$2"

    case "$pm:$provider" in
        # Debian-family safety: sysvinit-core owns/replaces the SysV PID 1 and
        # conflicts with systemd-sysv. For Services we only need the compatible
        # management/utility layer. init-system-helpers provides service,
        # invoke-rc.d and update-rc.d; sysvinit-utils provides SysV utilities.
        apt:sysvinit)
            printf '%s\n' 'sysvinit-utils init-system-helpers'
            return 0
            ;;
    esac

    if declare -F _sysconfig_init_install_packages_before_safety >/dev/null 2>&1; then
        _sysconfig_init_install_packages_before_safety "$provider" "$pm"
        return $?
    fi
    return 1
}

return 0 2>/dev/null || true
