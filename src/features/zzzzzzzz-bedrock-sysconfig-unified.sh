# shellcheck shell=bash
# Final System Configuration integration layer for Bedrock-AOK.
# Keeps host package management as the primary system while making Bedrock
# strata visible and manageable as part of the same package workflow.

if declare -F pm_update >/dev/null 2>&1 && ! declare -F _systui_native_pm_update >/dev/null 2>&1; then
    eval "$(declare -f pm_update | sed '1s/^pm_update[[:space:]]*()/_systui_native_pm_update ()/')"
fi
if declare -F tui_menu_no_tags >/dev/null 2>&1 && ! declare -F _systui_bedrock_sysconfig_orig_no_tags >/dev/null 2>&1; then
    eval "$(declare -f tui_menu_no_tags | sed '1s/^tui_menu_no_tags[[:space:]]*()/_systui_bedrock_sysconfig_orig_no_tags ()/')"
fi

# Package-installed detection for every host PM supported by sysconfig.  This
# prevents a failed multi-package host transaction from causing an already
# installed package to be redundantly offered from a Bedrock stratum.
bedrock_sysconfig_host_has_package() { # <package>
    local pkg="$1"
    case "$PM" in
        apt) dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q 'install ok installed' ;;
        apk) apk info -e "$pkg" >/dev/null 2>&1 ;;
        pacman) pacman -Q "$pkg" >/dev/null 2>&1 ;;
        dnf|yum|zypper) rpm -q "$pkg" >/dev/null 2>&1 ;;
        xbps) xbps-query -p pkgver "$pkg" >/dev/null 2>&1 ;;
        emerge) command -v portageq >/dev/null 2>&1 && [ -n "$(portageq match / "$pkg" 2>/dev/null)" ] ;;
        *) command -v "$pkg" >/dev/null 2>&1 ;;
    esac
}

# Re-replace pm_install only to improve the partial-install check while keeping
# the Bedrock-first fallback logic from the preceding integration module.
if declare -F pm_install >/dev/null 2>&1 && ! declare -F _systui_bedrock_pm_install_integrated >/dev/null 2>&1; then
    eval "$(declare -f pm_install | sed '1s/^pm_install[[:space:]]*()/_systui_bedrock_pm_install_integrated ()/')"
fi

pm_install() {
    validate_packages "$@" || return 1
    local native_rc=0 pkg unresolved=0

    # Use the original native installer directly so Bedrock fallback happens
    # once, in this function, and the old web fallback remains last-resort.
    SYSTUI_PM_NO_WEB_FALLBACK=1 _systui_native_pm_install "$@" || native_rc=$?
    [ "$native_rc" -eq 0 ] && return 0

    for pkg in "$@"; do
        bedrock_sysconfig_host_has_package "$pkg" && continue

        if [ "${SYSTUI_PM_NO_BEDROCK:-0}" != "1" ] && bedrock_sysconfig_install_fallback "$pkg"; then
            continue
        fi

        unresolved=1
        if [ "${SYSTUI_PM_NO_WEB_FALLBACK:-0}" != "1" ] && declare -F pkg_web_fallback >/dev/null 2>&1; then
            pkg_web_fallback "$pkg" || true
        fi
    done

    [ "$unresolved" -eq 0 ] && return 0
    return "$native_rc"
}

# A normal System Configuration "Update packages" now offers one cohesive
# transaction: update the host first, then all installed Bedrock strata.
pm_update() {
    local host_rc=0 brl bedrock_rc=0
    _systui_native_pm_update || host_rc=$?

    if [ "${SYSTUI_PM_NO_BEDROCK:-0}" != "1" ] && bedrock_sysconfig_active; then
        if tui_yesno "Update unified system" \
"Host package update finished.\n\nBedrock-AOK is installed. Update packages in all installed Bedrock strata as part of the same system update?"; then
            brl=$(bedrock_aok_brl) || return "$host_rc"
            run_cmd "Update all Bedrock strata" "$brl" update || bedrock_rc=$?
            run_cmd "Refresh Bedrock unified command PATH" "$brl" reload || true
        fi
    fi

    [ "$host_rc" -ne 0 ] && return "$host_rc"
    return "$bedrock_rc"
}

# Make Bedrock participation visible throughout System Configuration without
# adding another nested-menu/subshell layer. The existing package menu title
# becomes e.g. "Package Configuration [apt + Bedrock]" when active.
tui_menu_no_tags() {
    local title="${1:-}" text="${2:-}"
    shift 2 || true
    if bedrock_sysconfig_active && [[ "$title" == "Package Configuration ["* ]]; then
        title=${title%]}
        title="$title + Bedrock]"
        text="$text  Bedrock strata are integrated as package sources and command providers."
    fi
    _systui_bedrock_sysconfig_orig_no_tags "$title" "$text" "$@"
}

return 0 2>/dev/null || true
