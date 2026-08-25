# shellcheck shell=bash
# Dedicated Bedrock-AOK integration for iSH-AOK.
#
# Bedrock-AOK is intentionally NOT part of the Rootfs Builder.  It is a
# host-level multi-distro environment and is managed from its own top-level
# systui menu.  The implementation follows:
#   https://github.com/vjnzbcsbgf-maker/Bedrock-AOK

BEDROCK_AOK_REPO="https://github.com/vjnzbcsbgf-maker/Bedrock-AOK"
BEDROCK_AOK_RAW="https://raw.githubusercontent.com/vjnzbcsbgf-maker/Bedrock-AOK/main"

bedrock_aok_download() { # <remote-name> <destination>
    local name="$1" dst="$2"
    mkdir -p "$(dirname "$dst")" || return 1
    if command -v curl >/dev/null 2>&1; then
        curl -4 -fL --retry 3 --connect-timeout 10 --max-time 600 \
            -o "$dst" "$BEDROCK_AOK_RAW/$name"
    elif command -v wget >/dev/null 2>&1; then
        wget -4 -q -T 600 -O "$dst" "$BEDROCK_AOK_RAW/$name"
    else
        tui_msg "Missing downloader" "Bedrock-AOK requires curl or wget."
        return 1
    fi
}

bedrock_aok_brl() {
    local p
    for p in "$(command -v brl 2>/dev/null)" /bedrock/bin/brl /usr/local/bin/brl /usr/bin/brl; do
        [ -n "$p" ] && [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}

bedrock_aok_installed() {
    [ -d /bedrock ] && bedrock_aok_brl >/dev/null 2>&1
}

bedrock_aok_require() {
    if ! bedrock_aok_installed; then
        tui_msg "Bedrock-AOK not installed" \
"Install Bedrock-AOK first from this menu.

Template source:
$BEDROCK_AOK_REPO"
        return 1
    fi
}

bedrock_aok_run() { # <description> <brl args...>
    local desc="$1" brl; shift
    bedrock_aok_require || return 1
    brl=$(bedrock_aok_brl) || return 1
    run_cmd "$desc" "$brl" "$@"
}

bedrock_aok_post_features() { # <space-separated feature tags>
    local features="$1" f brl
    [ -n "${features//[[:space:]]/}" ] || return 0
    brl=$(bedrock_aok_brl 2>/dev/null || true)
    [ -n "$brl" ] || return 1
    for f in $features; do
        case "$f" in
            deps)       run_cmd "Bedrock-AOK dependencies" "$brl" deps || true ;;
            integrate)  run_cmd "Bedrock-AOK integration" "$brl" integrate || true ;;
            aokroots)   run_cmd "Register /AOK/roots" "$brl" register-aok || true ;;
            verify)     run_cmd "Verify Bedrock-AOK" "$brl" verify || true ;;
            health)     run_cmd "Bedrock-AOK health check" "$brl" health || true ;;
            test)       run_cmd "Bedrock-AOK self-test" "$brl" test || true ;;
            reload)     run_cmd "Reload cross-distro wrappers" "$brl" reload || true ;;
            strata)     bedrock_aok_fetch_menu ;;
        esac
    done
}

bedrock_aok_install() {
    local edition features work script
    edition=$(tui_radio "Install Bedrock-AOK" \
        "Choose an edition (SPACE selects, ENTER confirms):" \
        permanent  "Permanent — bedrockport.sh --hijack (recommended)" on \
        reversible "Reversible — brl hijack / brl unhijack" off) || return 0

    features=$(tui_check "Bedrock-AOK additional features" \
        "Optional actions to run after installation (SPACE toggles):" \
        deps      "Check/install Bedrock-AOK host dependencies" on \
        integrate "Configure full integration layer" on \
        aokroots  "Discover/register existing /AOK/roots" on \
        verify    "Verify Bedrock directory integrity" on \
        health    "Run stratum health checks" off \
        test      "Run the full Bedrock-AOK self-test suite" off \
        reload    "Rebuild cross-distribution command wrappers" on \
        strata    "Choose initial strata after install" off) || features=""
    features=${features//\"/}

    tui_yesno "Install Bedrock-AOK" \
"This installs Bedrock-AOK from:
$BEDROCK_AOK_REPO

Edition: $edition
Extras : ${features:-none}

Continue?" || return 0

    work="${SYSTUI_TMP:?}/bedrock-aok-install"
    rm -rf "$work"; mkdir -p "$work"
    case "$edition" in
        permanent)
            script="$work/bedrockport.sh"
            bedrock_aok_download bedrockport.sh "$script" || return 1
            bedrock_aok_download brl-uninstall "$work/brl-uninstall" || return 1
            chmod 0755 "$script" "$work/brl-uninstall"
            run_cmd "Installing permanent Bedrock-AOK" "$script" --hijack || return 1
            ;;
        reversible)
            script="$work/brl"
            bedrock_aok_download brl "$script" || return 1
            chmod 0755 "$script"
            run_cmd "Installing reversible Bedrock-AOK" "$script" hijack || return 1
            ;;
    esac

    if bedrock_aok_installed; then
        bedrock_aok_post_features "$features"
        tui_msg "Bedrock-AOK installed" \
"Bedrock-AOK is installed and can now be managed from the systui main menu."
    else
        tui_msg "Install incomplete" \
"The installer finished but systui could not find an executable brl command or /bedrock installation. Review $LOGFILE."
        return 1
    fi
}

bedrock_aok_update_menu() {
    local c work script
    c=$(tui_menu "Bedrock-AOK update" "Choose an update method:" \
        self      "Run brl self-update" \
        permanent "Run latest bedrockport.sh --update" \
        force     "Run latest bedrockport.sh --force-update" \
        urls      "Refresh live stratum source URLs" \
        back      "Back") || return 0
    case "$c" in
        back|"") return 0 ;;
        self) bedrock_aok_run "Bedrock-AOK self-update" self-update ;;
        urls) bedrock_aok_run "Update Bedrock-AOK stratum URLs" update-urls ;;
        permanent|force)
            work="${SYSTUI_TMP:?}/bedrock-aok-update"; rm -rf "$work"; mkdir -p "$work"
            script="$work/bedrockport.sh"
            bedrock_aok_download bedrockport.sh "$script" || return 1
            chmod 0755 "$script"
            if [ "$c" = force ]; then
                run_cmd "Force updating Bedrock-AOK" "$script" --force-update
            else
                run_cmd "Updating Bedrock-AOK" "$script" --update
            fi
            ;;
    esac
}

bedrock_aok_uninstall_menu() {
    local c brl work uninstaller
    bedrock_aok_require || return 0
    c=$(tui_radio "Remove Bedrock-AOK" \
        "Choose removal mode (SPACE selects):" \
        permanent  "Permanent install — run brl-uninstall" on \
        reversible "Reversible install — run brl unhijack" off) || return 0
    tui_yesno "Remove Bedrock-AOK" \
"Remove the current Bedrock-AOK installation?

Mode: $c

This can remove configured strata. Continue?" || return 0
    case "$c" in
        reversible)
            brl=$(bedrock_aok_brl) || return 1
            run_cmd "Unhijacking Bedrock-AOK" "$brl" unhijack
            ;;
        permanent)
            if [ -x /bedrock/bin/brl-uninstall ]; then
                uninstaller=/bedrock/bin/brl-uninstall
            elif command -v brl-uninstall >/dev/null 2>&1; then
                uninstaller=$(command -v brl-uninstall)
            else
                work="${SYSTUI_TMP:?}/bedrock-aok-uninstall"; rm -rf "$work"; mkdir -p "$work"
                uninstaller="$work/brl-uninstall"
                bedrock_aok_download brl-uninstall "$uninstaller" || return 1
                chmod 0755 "$uninstaller"
            fi
            run_cmd "Uninstalling Bedrock-AOK" "$uninstaller"
            ;;
    esac
}

bedrock_aok_available_strata() { # prints tag|description
    local brl out
    brl=$(bedrock_aok_brl) || return 1
    out="${SYSTUI_TMP:?}/bedrock-aok-fetch-list"
    "$brl" fetch --list >"$out" 2>&1 || return 1
    awk '
        /^[[:space:]]*$/ { next }
        {
            line=$0
            sub(/^[[:space:]]+/, "", line)
            split(line, a, /[[:space:]]+/)
            tag=a[1]
            if (tag !~ /^[A-Za-z0-9][A-Za-z0-9+._-]*$/) next
            low=tolower(tag)
            if (low ~ /^(available|distribution|distributions|name|usage|fetch|brl)$/) next
            if (!seen[tag]++) print tag "|" line
        }
    ' "$out"
}

bedrock_aok_fetch_menu() {
    local brl rows sel line tag label
    local -a opts=()
    bedrock_aok_require || return 0
    brl=$(bedrock_aok_brl) || return 1
    rows=$(bedrock_aok_available_strata 2>/dev/null || true)
    while IFS='|' read -r tag label; do
        [ -n "$tag" ] || continue
        opts+=("$tag" "$label" off)
    done <<< "$rows"

    if [ ${#opts[@]} -eq 0 ]; then
        tui_msg "Could not parse distro list" \
"systui could not parse 'brl fetch --list'. The raw command will be shown; use the manual fetch option instead."
        run_cmd "Available Bedrock-AOK strata" "$brl" fetch --list || true
        tag=$(tui_input "Fetch stratum" "Distribution name:" "alpine") || return 0
        [ -n "$tag" ] && run_cmd "Fetching $tag" "$brl" fetch "$tag"
        return 0
    fi

    sel=$(tui_check "Fetch Bedrock-AOK strata" \
        "Available distributions (SPACE toggles multiple, ENTER fetches):" \
        "${opts[@]}") || return 0
    sel=${sel//\"/}
    [ -n "${sel//[[:space:]]/}" ] || return 0
    for tag in $sel; do
        run_cmd "Fetching Bedrock-AOK stratum: $tag" "$brl" fetch "$tag" || true
    done
    bedrock_aok_run "Reload cross-distro wrappers" reload || true
}

bedrock_aok_strata_menu() {
    local c brl st name new pkg
    bedrock_aok_require || return 0
    brl=$(bedrock_aok_brl) || return 1
    while true; do
        c=$(tui_menu "Bedrock-AOK strata" "Manage Bedrock-AOK distributions:" \
            fetch   "Fetch distributions (SPACE-to-select multi-menu)" \
            list    "List installed strata" \
            status  "Show a stratum status" \
            shell   "Open an interactive stratum shell" \
            install "Install packages into a stratum" \
            update  "Update one stratum or all strata" \
            enable  "Enable cross-command access" \
            disable "Disable cross-command access" \
            rename  "Rename a stratum" \
            remove  "Remove a stratum" \
            umount  "Release stratum mounts" \
            back    "Back") || return 0
        case "$c" in
            back|"") return 0 ;;
            fetch) bedrock_aok_fetch_menu ;;
            list) run_cmd "Bedrock-AOK strata" "$brl" list ;;
            status)
                st=$(tui_input "Stratum status" "Stratum name:" "") || continue
                [ -n "$st" ] && run_cmd "Status: $st" "$brl" status "$st"
                ;;
            shell)
                st=$(tui_input "Stratum shell" "Stratum name:" "") || continue
                [ -n "$st" ] || continue
                clear
                "$brl" shell "$st"
                ;;
            install)
                st=$(tui_input "Install packages" "Stratum name:" "") || continue
                [ -n "$st" ] || continue
                pkg=$(tui_input "Install packages" "Package names (space-separated):" "") || continue
                [ -n "$pkg" ] || continue
                # Package tokens are deliberately split here to match brl's argv.
                # shellcheck disable=SC2086
                run_cmd "Install into $st" "$brl" install "$st" $pkg
                ;;
            update)
                st=$(tui_input "Update strata" "Stratum name (blank = all):" "") || continue
                if [ -n "$st" ]; then run_cmd "Update $st" "$brl" update "$st"; else run_cmd "Update all strata" "$brl" update; fi
                ;;
            enable|disable|remove)
                st=$(tui_input "brl $c" "Stratum name:" "") || continue
                [ -n "$st" ] || continue
                if [ "$c" = remove ]; then tui_yesno "Remove stratum" "Remove '$st'?" || continue; fi
                run_cmd "brl $c $st" "$brl" "$c" "$st"
                ;;
            rename)
                st=$(tui_input "Rename stratum" "Current name:" "") || continue
                [ -n "$st" ] || continue
                new=$(tui_input "Rename stratum" "New name:" "") || continue
                [ -n "$new" ] && run_cmd "Rename $st -> $new" "$brl" rename "$st" "$new"
                ;;
            umount)
                st=$(tui_input "Release mounts" "Stratum name (blank = all):" "") || continue
                if [ -n "$st" ]; then run_cmd "Unmount $st" "$brl" umount "$st"; else run_cmd "Unmount strata" "$brl" umount; fi
                ;;
        esac
    done
}

bedrock_aok_features_menu() {
    local sel f brl
    bedrock_aok_require || return 0
    brl=$(bedrock_aok_brl) || return 1
    sel=$(tui_check "Bedrock-AOK features" \
        "Run one or more maintenance/integration features (SPACE toggles):" \
        deps       "Check/install host dependencies" off \
        capabilities "Detect iSH-AOK kernel capabilities" off \
        integrate  "Set up full Bedrock-AOK integration" off \
        aokroots   "Register /AOK/roots as strata" off \
        verify     "Verify Bedrock directory structure" off \
        repair     "Verify and repair Bedrock directory structure" off \
        health     "Health-check and auto-repair strata" off \
        test       "Run full self-test / regression suite" off \
        reload     "Rebuild cross-distro command wrappers" off \
        urls       "Re-resolve all stratum source URLs" off) || return 0
    sel=${sel//\"/}
    for f in $sel; do
        case "$f" in
            deps)         run_cmd "Bedrock dependencies" "$brl" deps || true ;;
            capabilities) run_cmd "Bedrock capabilities" "$brl" capabilities || true ;;
            integrate)    run_cmd "Bedrock integration" "$brl" integrate || true ;;
            aokroots)     run_cmd "Register AOK roots" "$brl" register-aok || true ;;
            verify)       run_cmd "Verify Bedrock" "$brl" verify || true ;;
            repair)       run_cmd "Repair Bedrock" "$brl" verify --repair || true ;;
            health)       run_cmd "Bedrock health" "$brl" health || true ;;
            test)         run_cmd "Bedrock self-test" "$brl" test || true ;;
            reload)       run_cmd "Reload Bedrock wrappers" "$brl" reload || true ;;
            urls)         run_cmd "Update Bedrock URLs" "$brl" update-urls || true ;;
        esac
    done
}

bedrock_aok_rollback_menu() {
    local c brl label id
    bedrock_aok_require || return 0
    brl=$(bedrock_aok_brl) || return 1
    while true; do
        c=$(tui_menu "Bedrock-AOK rollback" "Configuration rollback points:" \
            list    "List rollback points" \
            create  "Create a rollback point" \
            restore "Restore a rollback point" \
            back    "Back") || return 0
        case "$c" in
            back|"") return 0 ;;
            list) run_cmd "Bedrock rollback points" "$brl" rollback list ;;
            create)
                label=$(tui_input "Rollback point" "Label (blank = automatic):" "") || continue
                if [ -n "$label" ]; then run_cmd "Create rollback" "$brl" rollback create "$label"; else run_cmd "Create rollback" "$brl" rollback create; fi
                ;;
            restore)
                id=$(tui_input "Restore rollback" "Rollback ID:" "") || continue
                [ -n "$id" ] || continue
                tui_yesno "Restore rollback" "Restore rollback point '$id'?" || continue
                run_cmd "Restore rollback $id" "$brl" rollback restore "$id"
                ;;
        esac
    done
}

bedrock_aok_info_menu() {
    local c brl
    bedrock_aok_require || return 0
    brl=$(bedrock_aok_brl) || return 1
    c=$(tui_menu "Bedrock-AOK information" "Diagnostics and documentation:" \
        report       "System report / health overview" \
        capabilities "Kernel capability report" \
        version      "Bedrock-AOK version" \
        tutorial     "Quick-start tutorial" \
        back         "Back") || return 0
    case "$c" in
        report)       run_cmd "Bedrock-AOK report" "$brl" report ;;
        capabilities) run_cmd "Bedrock-AOK capabilities" "$brl" capabilities ;;
        version)      run_cmd "Bedrock-AOK version" "$brl" version ;;
        tutorial)     run_cmd "Bedrock-AOK tutorial" "$brl" tutorial ;;
    esac
}

menu_bedrock_aok() {
    local c status
    while true; do
        if bedrock_aok_installed; then status="installed ($(bedrock_aok_brl))"; else status="not installed"; fi
        c=$(tui_menu "Bedrock-AOK" \
            "Bedrock Linux for iSH-AOK — chroot/bind-mount implementation.\nStatus: $status" \
            install   "Install Bedrock-AOK from the upstream template" \
            strata    "Manage distributions / strata" \
            features  "Additional features (SPACE-to-select)" \
            rollback  "Rollback points" \
            update    "Update Bedrock-AOK" \
            info      "Reports, capabilities, version, tutorial" \
            uninstall "Remove / unhijack Bedrock-AOK" \
            back      "Back") || return 0
        case "$c" in
            back|"") return 0 ;;
            install) bedrock_aok_install ;;
            strata) bedrock_aok_strata_menu ;;
            features) bedrock_aok_features_menu ;;
            rollback) bedrock_aok_rollback_menu ;;
            update) bedrock_aok_update_menu ;;
            info) bedrock_aok_info_menu ;;
            uninstall) bedrock_aok_uninstall_menu ;;
        esac
    done
}

###############################################################################
# Menu integration overlays
#
# install.sh defines the generated main_menu after feature modules are sourced.
# To add Bedrock-AOK without duplicating that generated main menu, wrap tui_menu:
# when the Main Menu is displayed, insert a Bedrock-AOK entry before Quit.  If
# selected, run the Bedrock menu locally and then re-display Main Menu; only
# non-Bedrock choices are returned to install.sh's main_menu case statement.
#
# Rootfs Builder's distro chooser is similarly filtered so its former Bedrock
# entry cannot be selected.  Bedrock-AOK is now exclusively a host-level menu.
###############################################################################

if declare -F tui_menu >/dev/null 2>&1 && ! declare -F _systui_bedrock_orig_tui_menu >/dev/null 2>&1; then
    eval "$(declare -f tui_menu | sed '1s/^tui_menu[[:space:]]*()/_systui_bedrock_orig_tui_menu ()/')"
fi
if declare -F tui_check >/dev/null 2>&1 && ! declare -F _systui_bedrock_orig_tui_check >/dev/null 2>&1; then
    eval "$(declare -f tui_check | sed '1s/^tui_check[[:space:]]*()/_systui_bedrock_orig_tui_check ()/')"
fi

tui_menu() {
    local title="${1:-}" choice i inserted=0
    local -a src=("$@") out=()
    if [ "$title" != "Main Menu" ] || ! declare -F _systui_bedrock_orig_tui_menu >/dev/null 2>&1; then
        _systui_bedrock_orig_tui_menu "$@"
        return $?
    fi

    out+=("${src[0]}" "${src[1]}")
    for ((i=2; i<${#src[@]}; i+=2)); do
        if [ "${src[i]}" = quit ] && [ "$inserted" = 0 ]; then
            out+=(bedrock "Bedrock-AOK (install/manage multi-distro environment)")
            inserted=1
        fi
        out+=("${src[i]}" "${src[i+1]}")
    done
    [ "$inserted" = 1 ] || out+=(bedrock "Bedrock-AOK (install/manage multi-distro environment)")

    while true; do
        choice=$(_systui_bedrock_orig_tui_menu "${out[@]}") || return 1
        if [ "$choice" = bedrock ]; then
            menu_bedrock_aok
            continue
        fi
        printf '%s\n' "$choice"
        return 0
    done
}

tui_check() {
    local title="${1:-}" i
    local -a src=("$@") out=()
    if [ "$title" != "Rootfs Builder 1/13" ] || ! declare -F _systui_bedrock_orig_tui_check >/dev/null 2>&1; then
        _systui_bedrock_orig_tui_check "$@"
        return $?
    fi

    out+=("${src[0]}" "${src[1]}")
    for ((i=2; i<${#src[@]}; i+=3)); do
        [ "${src[i]}" = bedrock ] && continue
        out+=("${src[i]}" "${src[i+1]}" "${src[i+2]}")
    done
    _systui_bedrock_orig_tui_check "${out[@]}"
}

return 0 2>/dev/null || true
