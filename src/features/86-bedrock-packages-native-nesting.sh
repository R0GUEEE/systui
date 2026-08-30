# shellcheck shell=bash
# PHASE 86 — keep native Package Configuration as the front door.
# Bedrock managers are nested inside Config > Packages instead of making the
# native package UI a child of a Bedrock-centric wrapper.

bedrock_systui_package_managers_menu() {
    local c st pm class cfg key
    local -a opts=()

    if ! bedrock_systui_is_installed 2>/dev/null; then
        tui_msg "Bedrock package managers" "Bedrock is not installed or no Bedrock strata are available."
        return 0
    fi

    bedrock_systui_scan_capabilities >/dev/null 2>&1 || true
    while IFS='|' read -r st pm class cfg; do
        [ -n "$st" ] && [ -n "$pm" ] || continue
        key="br_${st}_${pm}"
        key=${key//[^A-Za-z0-9_]/_}
        opts+=("$key" "$st → $pm [$class]")
    done <<< "$(bedrock_systui_capability_rows)"

    if [ ${#opts[@]} -eq 0 ]; then
        tui_msg "Bedrock package managers" "No package managers were detected in the installed Bedrock strata."
        return 0
    fi

    opts+=(rescan "Rescan Bedrock strata capabilities" back "Back")
    while true; do
        c=$(tui_menu "Bedrock strata package managers" \
            "Package managers discovered across installed Bedrock strata:" \
            "${opts[@]}") || return 0
        case "$c" in
            rescan)
                if bedrock_systui_scan_capabilities; then
                    tui_msg "Bedrock integration" "Strata capabilities rescanned. Reopen this submenu to refresh the list."
                    return 0
                fi
                ;;
            back|'') return 0 ;;
            br_*)
                while IFS='|' read -r st pm class cfg; do
                    key="br_${st}_${pm}"
                    key=${key//[^A-Za-z0-9_]/_}
                    [ "$key" = "$c" ] || continue
                    bedrock_systui_manager_menu "$st" "$pm" "$class" "$cfg"
                    break
                done <<< "$(bedrock_systui_capability_rows)"
                ;;
        esac
    done
}

# Restore Package Configuration as the native/top-level experience.  Bedrock
# contributes one nested section only when actually installed.
menu_packages() {
    local c
    local -a tags=(
        packages  "Install, remove, search and update packages"
        catalogue "Browse the application catalogue"
        repos      "Repositories and keys"
        managers   "Package managers (native, Flatpak, Snap, language)"
    )

    if bedrock_systui_is_installed 2>/dev/null; then
        tags+=(bedrock "Bedrock strata package managers")
    fi
    tags+=(advanced "Advanced package management" back "Back")

    while true; do
        c=$(tui_menu_no_tags "Package Configuration [${PM:-unknown}]" \
            "Select a package-management section:" \
            "${tags[@]}") || return 0
        case "$c" in
            packages)  menu_package_operations || true ;;
            catalogue) pkg_catalogue || true ;;
            repos)     menu_repos || true ;;
            managers)  menu_package_managers || true ;;
            bedrock)   bedrock_systui_package_managers_menu || true ;;
            advanced)  menu_pkg_advanced || true ;;
            back|'')   return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
