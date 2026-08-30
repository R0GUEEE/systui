# shellcheck shell=bash
# PHASE 87 — keep native package-manager status Bedrock-aware.
# The native Packages > Package managers UI remains host-owned, but managers
# found in Bedrock strata are annotated without being mistaken for host installs.

sysconfig_pm_bedrock_strata_for_cmd() { # <command>
    local cmd="$1" st out=""
    declare -F bedrock_systui_is_installed >/dev/null 2>&1 || return 0
    bedrock_systui_is_installed || return 0
    declare -F bedrock_systui_strata >/dev/null 2>&1 || return 0
    declare -F bedrock_systui_has_cmd >/dev/null 2>&1 || return 0
    while IFS= read -r st; do
        [ -n "$st" ] || continue
        bedrock_systui_has_cmd "$st" "$cmd" || continue
        if [ -n "$out" ]; then out="$out, $st"; else out="$st"; fi
    done <<< "$(bedrock_systui_strata)"
    [ -n "$out" ] && printf '%s\n' "$out"
}

sysconfig_pm_native_status() { # <tag> <command>
    local tag="$1" cmd="$2" host strata base
    if command -v "$cmd" >/dev/null 2>&1; then
        host='installed'
    elif sysconfig_pm_multi_package "$tag" >/dev/null 2>&1; then
        host='not installed'
    elif sysconfig_pm_multi_special_installer "$tag" >/dev/null 2>&1; then
        host='not installed — upstream installer'
    elif [ "$tag" = pnpm ] || [ "$tag" = yarn ]; then
        host='not installed — npm global install'
    else
        host='not available for this distro'
    fi

    strata=$(sysconfig_pm_bedrock_strata_for_cmd "$cmd" 2>/dev/null || true)
    if [ -n "$strata" ]; then
        printf 'host: %s; strata: %s\n' "$host" "$strata"
    else
        printf 'host: %s\n' "$host"
    fi
}

# Final native multi-install picker. Bedrock presence changes labels only; the
# actual installation decision continues to depend solely on command -v on the
# host, so a manager present in a stratum does not suppress a native install.
sysconfig_pm_multi_install() {
    local tag cmd label state selected pkg fn p
    local -a opts=() packages=() npm_globals=() specials=() dedup=()
    while IFS='|' read -r tag cmd label; do
        [ -n "$tag" ] || continue
        state=$(sysconfig_pm_native_status "$tag" "$cmd")
        opts+=("$tag" "$label — $state" off)
    done <<< "$(sysconfig_pm_multi_catalogue)"

    selected=$(tui_check "Install package managers" \
        "SPACE selects managers; host and Bedrock-strata install states are shown separately." \
        "${opts[@]}") || return 0
    selected=${selected//\"/}
    [ -n "${selected//[[:space:]]/}" ] || return 0

    for tag in $selected; do
        while IFS='|' read -r p cmd label; do
            [ "$p" = "$tag" ] || continue
            # Only a host command suppresses native installation. A copy in a
            # Bedrock stratum is informational and must not affect this check.
            command -v "$cmd" >/dev/null 2>&1 && continue 2
            break
        done <<< "$(sysconfig_pm_multi_catalogue)"
        case "$tag" in
            pnpm|yarn) npm_globals+=("$tag") ;;
            yay|paru|nix|brew) specials+=("$tag") ;;
            *)
                pkg=$(sysconfig_pm_multi_package "$tag" 2>/dev/null || true)
                [ -n "$pkg" ] && packages+=("$pkg")
                ;;
        esac
    done

    if [ "${#packages[@]}" -gt 0 ]; then
        for pkg in "${packages[@]}"; do
            case " ${dedup[*]} " in *" $pkg "*) ;; *) dedup+=("$pkg") ;; esac
        done
        [ "${#dedup[@]}" -eq 0 ] || pm_install "${dedup[@]}" || true
    fi
    if [ "${#npm_globals[@]}" -gt 0 ]; then
        command -v npm >/dev/null 2>&1 || pm_install npm || true
        command -v npm >/dev/null 2>&1 && \
            run_cmd "Install npm package managers: ${npm_globals[*]}" npm install -g "${npm_globals[@]}" || true
    fi
    for tag in "${specials[@]}"; do
        fn=$(sysconfig_pm_multi_special_installer "$tag" 2>/dev/null || true)
        [ -n "$fn" ] && declare -F "$fn" >/dev/null 2>&1 && "$fn" || true
    done
}

return 0 2>/dev/null || true
