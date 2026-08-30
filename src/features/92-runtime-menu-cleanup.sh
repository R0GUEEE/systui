# shellcheck shell=bash
# PHASE 92 — final runtime/menu cleanup.
# Consolidates late Bedrock integrations without removing compatibility helpers
# that older feature layers may still call directly.

# The phase-85 host+Bedrock front door was superseded by phase 86. Keeping the
# helper defined serves no runtime purpose and makes introspection report a
# second package front door, so remove only that obsolete private entry point.
unset -f bedrock_systui_integrated_packages_menu 2>/dev/null || true

# Only offer install targets that Systui can actually operate. Previously a
# stratum with no recognized system package manager appeared as [unknown] and
# failed only after the user selected it.
systui_bedrock_install_target_menu() { # [thing]
    local thing="${1:-software}" st pm picked
    local -a opts=(host "Host system [${PM:-native}]" on)

    systui_bedrock_install_active || {
        printf 'host\n'
        return 0
    }

    while IFS= read -r st; do
        [ -n "$st" ] || continue
        pm=$(systui_bedrock_stratum_pm "$st" 2>/dev/null || true)
        [ -n "$pm" ] || continue
        opts+=("stratum:$st" "Bedrock stratum: $st [$pm]" off)
    done <<< "$(systui_bedrock_install_strata)"

    [ "${#opts[@]}" -gt 3 ] || {
        printf 'host\n'
        return 0
    }

    picked=$(tui_radio "Install target — $thing" \
        "Choose where this installation should be performed (SPACE selects):" \
        "${opts[@]}") || return 1
    printf '%s\n' "$picked"
}

# Final nested Bedrock package-manager browser. Rebuild options each iteration
# so a rescan immediately updates the visible list and deduplicate identical
# stratum/manager rows produced by overlapping detection paths.
bedrock_systui_package_managers_menu() {
    local c st pm class cfg key seen rows

    if ! bedrock_systui_is_installed 2>/dev/null; then
        tui_msg "Bedrock package managers" "Bedrock is not installed or no Bedrock strata are available."
        return 0
    fi

    while true; do
        local -a opts=()
        seen='|'
        bedrock_systui_scan_capabilities >/dev/null 2>&1 || true
        rows=$(bedrock_systui_capability_rows)

        while IFS='|' read -r st pm class cfg; do
            [ -n "$st" ] && [ -n "$pm" ] || continue
            key="br_${st}_${pm}"
            key=${key//[^A-Za-z0-9_]/_}
            case "$seen" in *"|$key|"*) continue ;; esac
            seen+="$key|"
            opts+=("$key" "$st → $pm [$class]")
        done <<< "$rows"

        if [ "${#opts[@]}" -eq 0 ]; then
            tui_msg "Bedrock package managers" "No package managers were detected in the installed Bedrock strata."
            return 0
        fi

        opts+=(rescan "Rescan Bedrock strata capabilities" back "Back")
        c=$(tui_menu "Bedrock strata package managers" \
            "Package managers discovered across installed Bedrock strata:" \
            "${opts[@]}") || return 0

        case "$c" in
            rescan)
                if bedrock_systui_scan_capabilities; then
                    tui_msg "Bedrock integration" "Strata capabilities rescanned."
                fi
                continue
                ;;
            back|'') return 0 ;;
            br_*)
                while IFS='|' read -r st pm class cfg; do
                    key="br_${st}_${pm}"
                    key=${key//[^A-Za-z0-9_]/_}
                    [ "$key" = "$c" ] || continue
                    bedrock_systui_manager_menu "$st" "$pm" "$class" "$cfg"
                    break
                done <<< "$rows"
                ;;
        esac
    done
}

# Multi-select already expresses consent to install the selected managers. Use
# one confirmation for the whole batch instead of another yes/no per manager.
systui_bedrock_stratum_multi_pm_install() { # <stratum>
    local st="$1" selected tag label pm pkg summary=''
    local -a opts=() packages=()

    pm=$(systui_bedrock_stratum_pm "$st" 2>/dev/null || true)
    [ -n "$pm" ] || {
        tui_msg "Install unavailable" "No supported system package manager was detected in Bedrock stratum '$st'."
        return 1
    }

    while IFS='|' read -r tag _ label; do
        [ -n "$tag" ] || continue
        pkg=$(systui_bedrock_pkg_name "$pm" "$tag" 2>/dev/null || true)
        [ -n "$pkg" ] || continue
        opts+=("$tag" "$label → $pkg" off)
    done <<< "$(sysconfig_pm_multi_catalogue)"

    [ "${#opts[@]}" -gt 0 ] || {
        tui_msg "Package managers" "No package-manager installs are mapped for '$st' [$pm]."
        return 0
    }

    selected=$(tui_check "Install package managers in $st" \
        "SPACE selects managers; ENTER continues with the selected batch." \
        "${opts[@]}") || return 0
    selected=${selected//\"/}
    [ -n "${selected//[[:space:]]/}" ] || return 0

    for tag in $selected; do
        pkg=$(systui_bedrock_pkg_name "$pm" "$tag" 2>/dev/null || true)
        [ -n "$pkg" ] || continue
        packages+=("$pkg")
        summary+="${summary:+, }$tag"
    done

    [ "${#packages[@]}" -gt 0 ] || return 0
    tui_yesno "Install in $st" \
        "Install the selected package managers in Bedrock stratum '$st' using $pm?\n\n$summary" || return 0

    for pkg in "${packages[@]}"; do
        systui_bedrock_pm_install_raw "$st" "$pkg" || true
    done
}

return 0 2>/dev/null || true
