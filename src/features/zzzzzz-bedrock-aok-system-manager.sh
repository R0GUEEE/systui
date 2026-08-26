# shellcheck shell=bash
# Bedrock-AOK cohesive multi-strata system management.
# Loaded last to extend the Bedrock menu with bulk/system-wide operations.

bedrock_aok_pick_strata_multi() { # <title> <prompt>
    local title="$1" prompt="$2" st sel
    local -a opts=()
    while IFS= read -r st; do
        [ -n "$st" ] || continue
        opts+=("$st" "$st" off)
    done < <(bedrock_aok_installed_strata)
    if [ ${#opts[@]} -eq 0 ]; then
        tui_msg "No strata installed" "No Bedrock-AOK strata are currently installed."
        return 1
    fi
    sel=$(tui_check "$title" "$prompt (SPACE toggles, ENTER confirms):" "${opts[@]}") || return 1
    printf '%s\n' "${sel//\"/}"
}

bedrock_aok_system_overview() {
    local brl out st
    bedrock_aok_require || return 1
    brl=$(bedrock_aok_brl) || return 1
    out="${SYSTUI_TMP:?}/bedrock-aok-overview.$$.txt"
    {
        echo "Bedrock-AOK unified system overview"
        echo "=================================="
        echo
        "$brl" version 2>&1 || true
        echo
        echo "Installed strata"
        echo "----------------"
        "$brl" list 2>&1 || true
        echo
        echo "Per-stratum summary"
        echo "-------------------"
        while IFS= read -r st; do
            [ -n "$st" ] || continue
            echo
            echo "[$st]"
            "$brl" show "$st" 2>&1 || "$brl" status "$st" 2>&1 || true
        done < <(bedrock_aok_installed_strata)
        echo
        echo "Health"
        echo "------"
        "$brl" health 2>&1 || true
    } >"$out"
    sed -i 's/\x1b\[[0-9;]*[[:alpha:]]//g' "$out" 2>/dev/null || true
    tui_text "Bedrock-AOK system overview" "$out" || true
    rm -f "$out"
}

bedrock_aok_bulk_each() { # <description-prefix> <brl-command> [strata-list]
    local prefix="$1" cmd="$2" strata="${3:-}" brl st rc=0
    bedrock_aok_require || return 1
    brl=$(bedrock_aok_brl) || return 1
    if [ -z "${strata//[[:space:]]/}" ]; then
        strata=$(bedrock_aok_installed_strata | tr '\n' ' ')
    fi
    for st in $strata; do
        run_cmd "$prefix: $st" "$brl" "$cmd" "$st" || rc=1
    done
    return "$rc"
}

bedrock_aok_bulk_install_packages() {
    local brl strata pkg st bad=0 p
    bedrock_aok_require || return 1
    brl=$(bedrock_aok_brl) || return 1
    strata=$(bedrock_aok_pick_strata_multi "Install packages" "Choose target strata") || return 0
    [ -n "${strata//[[:space:]]/}" ] || return 0
    pkg=$(tui_input "Install packages" "Package names to install into every selected stratum:" "") || return 0
    [ -n "${pkg//[[:space:]]/}" ] || return 0
    for p in $pkg; do
        case "$p" in *[!A-Za-z0-9+._:@/-]*|'') bad=1 ;; esac
    done
    if [ "$bad" = 1 ]; then
        tui_msg "Invalid package name" "Package names may only contain letters, numbers, + . _ : @ / and -."
        return 1
    fi
    tui_yesno "Bulk package install" "Install '$pkg' into all selected strata?\n\n$strata" || return 0
    for st in $strata; do
        # shellcheck disable=SC2086
        run_cmd "Install into $st" "$brl" install "$st" $pkg || true
    done
}

bedrock_aok_bulk_remove() {
    local brl strata st
    bedrock_aok_require || return 1
    brl=$(bedrock_aok_brl) || return 1
    strata=$(bedrock_aok_pick_strata_multi "Remove strata" "Select strata to remove") || return 0
    [ -n "${strata//[[:space:]]/}" ] || return 0
    tui_yesno "Remove selected strata" "Permanently remove these strata?\n\n$strata" || return 0
    for st in $strata; do
        run_cmd "Remove $st" "$brl" remove "$st" || true
    done
    run_cmd "Reload cross-distro wrappers" "$brl" reload || true
}

bedrock_aok_bulk_update() {
    local brl mode strata st
    bedrock_aok_require || return 1
    brl=$(bedrock_aok_brl) || return 1
    mode=$(tui_radio "Update strata" "Choose update scope (SPACE selects):" \
        all "Update packages in all installed strata" on \
        selected "Update selected strata only" off) || return 0
    case "$mode" in
        all) run_cmd "Update all Bedrock-AOK strata" "$brl" update ;;
        selected)
            strata=$(bedrock_aok_pick_strata_multi "Update strata" "Choose strata to update") || return 0
            for st in $strata; do run_cmd "Update $st" "$brl" update "$st" || true; done
            ;;
    esac
}

bedrock_aok_bulk_health_fix() {
    local brl sel f st
    bedrock_aok_require || return 1
    brl=$(bedrock_aok_brl) || return 1
    sel=$(tui_check "System maintenance" "Run across the Bedrock-AOK environment (SPACE toggles):" \
        health "Health-check all strata and auto-repair" on \
        fix "Re-apply environment fixes to every stratum" off \
        verify "Verify Bedrock structure" off \
        repair "Verify and repair Bedrock structure" off \
        reload "Rebuild unified cross-distro command wrappers" on \
        urls "Refresh all stratum source URLs" off \
        umount "Release mounts for all strata" off) || return 0
    sel=${sel//\"/}
    for f in $sel; do
        case "$f" in
            health) run_cmd "Health-check all strata" "$brl" health || true ;;
            fix)
                while IFS= read -r st; do
                    [ -n "$st" ] && run_cmd "Fix $st" "$brl" fix "$st" || true
                done < <(bedrock_aok_installed_strata)
                ;;
            verify) run_cmd "Verify Bedrock-AOK" "$brl" verify || true ;;
            repair) run_cmd "Repair Bedrock-AOK" "$brl" verify --repair || true ;;
            reload) run_cmd "Reload unified wrappers" "$brl" reload || true ;;
            urls) run_cmd "Refresh stratum URLs" "$brl" update-urls || true ;;
            umount) run_cmd "Unmount all strata" "$brl" umount || true ;;
        esac
    done
}

bedrock_aok_cross_access_menu() {
    local c brl strata st
    bedrock_aok_require || return 1
    brl=$(bedrock_aok_brl) || return 1
    while true; do
        c=$(tui_menu "Unified command access" "Manage which strata participate in the shared Bedrock command environment:" \
            enable_all "Enable cross-command access for all strata" \
            disable_all "Disable cross-command access for all strata" \
            enable_selected "Enable selected strata" \
            disable_selected "Disable selected strata" \
            reload "Rebuild shared command wrappers" \
            back "Back") || return 0
        case "$c" in
            back|"") return 0 ;;
            enable_all) bedrock_aok_bulk_each "Enable cross access" enable; run_cmd "Reload unified wrappers" "$brl" reload || true ;;
            disable_all) bedrock_aok_bulk_each "Disable cross access" disable; run_cmd "Reload unified wrappers" "$brl" reload || true ;;
            enable_selected|disable_selected)
                strata=$(bedrock_aok_pick_strata_multi "Cross-command access" "Choose strata") || continue
                [ -n "${strata//[[:space:]]/}" ] || continue
                if [ "$c" = enable_selected ]; then
                    for st in $strata; do run_cmd "Enable $st" "$brl" enable "$st" || true; done
                else
                    for st in $strata; do run_cmd "Disable $st" "$brl" disable "$st" || true; done
                fi
                run_cmd "Reload unified wrappers" "$brl" reload || true
                ;;
            reload) run_cmd "Reload unified wrappers" "$brl" reload ;;
        esac
    done
}

bedrock_aok_system_manager_menu() {
    local c
    bedrock_aok_require || return 0
    while true; do
        c=$(tui_menu "Bedrock-AOK system manager" "Treat all strata as one cohesive Bedrock environment:" \
            overview "Unified system overview" \
            update "Update all or selected strata" \
            packages "Install packages across selected strata" \
            access "Manage unified cross-command access" \
            maintenance "Health/fix/verify/reload/unmount system-wide" \
            remove "Remove multiple strata (SPACE-to-select)" \
            back "Back") || return 0
        case "$c" in
            back|"") return 0 ;;
            overview) bedrock_aok_system_overview ;;
            update) bedrock_aok_bulk_update ;;
            packages) bedrock_aok_bulk_install_packages ;;
            access) bedrock_aok_cross_access_menu ;;
            maintenance) bedrock_aok_bulk_health_fix ;;
            remove) bedrock_aok_bulk_remove ;;
        esac
    done
}

# Extend the Bedrock top-level menu with cohesive system management.
menu_bedrock_aok() {
    local c status
    while true; do
        if bedrock_aok_installed; then status="installed ($(bedrock_aok_brl))"; else status="not installed"; fi
        c=$(tui_menu "Bedrock-AOK" \
            "Bedrock Linux for iSH-AOK — unified multi-distro environment.\nStatus: $status" \
            install   "Install Bedrock-AOK from the upstream template" \
            system    "Unified system manager (all/multiple strata)" \
            strata    "Manage individual distributions / strata" \
            config    "Manage Bedrock-AOK configuration" \
            features  "Additional features (SPACE-to-select)" \
            rollback  "Rollback points" \
            update    "Update Bedrock-AOK / stratum sources" \
            info      "Reports, capabilities, version, tutorial" \
            uninstall "Remove / unhijack Bedrock-AOK" \
            back      "Back") || return 0
        case "$c" in
            back|"") return 0 ;;
            install) bedrock_aok_install ;;
            system) bedrock_aok_system_manager_menu ;;
            strata) bedrock_aok_strata_menu ;;
            config) bedrock_aok_config_menu ;;
            features) bedrock_aok_features_menu ;;
            rollback) bedrock_aok_rollback_menu ;;
            update) bedrock_aok_update_menu ;;
            info) bedrock_aok_info_menu ;;
            uninstall) bedrock_aok_uninstall_menu ;;
        esac
    done
}

return 0 2>/dev/null || true
