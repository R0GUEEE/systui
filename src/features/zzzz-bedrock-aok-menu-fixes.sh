# shellcheck shell=bash
# Bedrock-AOK menu correctness fixes.
# Loaded after zzz-bedrock-aok.sh so these definitions replace the initial
# integration handlers without duplicating the main-menu injection.

# Return the installed Bedrock-AOK strata, one per line.
bedrock_aok_installed_strata() {
    [ -d /bedrock/strata ] || return 0
    find /bedrock/strata -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null \
        | sed 's#.*/##' \
        | LC_ALL=C sort
}

# Pick one installed stratum with a SPACE-to-select radio menu.  This avoids
# typo-prone free-text prompts for operations that require an existing stratum.
bedrock_aok_pick_stratum() { # <title> <prompt>
    local title="$1" prompt="$2" st
    local -a opts=()
    while IFS= read -r st; do
        [ -n "$st" ] || continue
        opts+=("$st" "$st" off)
    done < <(bedrock_aok_installed_strata)
    if [ ${#opts[@]} -eq 0 ]; then
        tui_msg "No strata installed" "No Bedrock-AOK strata are currently installed."
        return 1
    fi
    tui_radio "$title" "$prompt (SPACE selects):" "${opts[@]}"
}

# `brl fetch --list` prints four distro names per row.  The original parser
# only consumed column 1, which made most available distributions disappear.
# Strip ANSI escapes/headings and emit every catalog token.
bedrock_aok_available_strata() { # prints tag|description
    local brl out token
    brl=$(bedrock_aok_brl) || return 1
    out="${SYSTUI_TMP:?}/bedrock-aok-fetch-list"
    "$brl" fetch --list >"$out" 2>&1 || return 1

    # Remove ANSI CSI sequences, then accept every token matching the stratum
    # naming grammar.  Filter the known heading words from brl's presentation.
    sed 's/\x1b\[[0-9;]*[[:alpha:]]//g' "$out" \
        | tr '[:space:]' '\n' \
        | awk '
            /^[A-Za-z0-9][A-Za-z0-9+._-]*$/ {
                low=tolower($0)
                if (low ~ /^(strata|available|to|fetch|distribution|distributions|name|usage|brl)$/) next
                if (!seen[$0]++) print $0 "|" $0
            }
        '
}

bedrock_aok_fetch_menu() {
    local brl rows sel tag label
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
"systui could not parse 'brl fetch --list'. The raw list will be shown next."
        run_cmd "Available Bedrock-AOK strata" "$brl" fetch --list || true
        return 1
    fi

    sel=$(tui_check "Fetch Bedrock-AOK strata" \
        "Available distributions (SPACE toggles multiple, ENTER fetches):" \
        "${opts[@]}") || return 0
    sel=${sel//\"/}
    [ -n "${sel//[[:space:]]/}" ] || return 0
    for tag in $sel; do
        run_cmd "Fetching Bedrock-AOK stratum: $tag" "$brl" fetch "$tag" || true
    done
    run_cmd "Reload cross-distro wrappers" "$brl" reload || true
}

# Upstream's `brl self-update` intentionally requires BRL_SELF_URL.  Supply the
# trusted upstream raw URL explicitly so the menu item works out of the box.
bedrock_aok_self_update() {
    local brl
    bedrock_aok_require || return 1
    brl=$(bedrock_aok_brl) || return 1
    run_cmd "Updating Bedrock-AOK command" \
        env BRL_SELF_URL="$BEDROCK_AOK_RAW/brl" "$brl" self-update
}

bedrock_aok_update_menu() {
    local c brl st
    bedrock_aok_require || return 0
    brl=$(bedrock_aok_brl) || return 1
    while true; do
        c=$(tui_menu "Bedrock-AOK update" "Choose what to update:" \
            program "Update Bedrock-AOK itself from upstream" \
            one     "Update packages in one installed stratum" \
            all     "Update packages in all installed strata" \
            urls    "Refresh live stratum source URLs" \
            back    "Back") || return 0
        case "$c" in
            back|"") return 0 ;;
            program) bedrock_aok_self_update ;;
            one)
                st=$(bedrock_aok_pick_stratum "Update stratum" "Choose a stratum") || continue
                run_cmd "Update $st" "$brl" update "$st"
                ;;
            all) run_cmd "Update all Bedrock-AOK strata" "$brl" update ;;
            urls) run_cmd "Refresh Bedrock-AOK stratum URLs" "$brl" update-urls ;;
        esac
    done
}

bedrock_aok_strata_menu() {
    local c brl st new pkg
    bedrock_aok_require || return 0
    brl=$(bedrock_aok_brl) || return 1
    while true; do
        c=$(tui_menu "Bedrock-AOK strata" "Manage Bedrock-AOK distributions:" \
            fetch   "Fetch distributions (SPACE-to-select multi-menu)" \
            list    "List installed strata" \
            status  "Show a stratum status" \
            show    "Show stratum details" \
            shell   "Open an interactive stratum shell" \
            install "Install packages into a stratum" \
            update  "Update packages in a stratum" \
            enable  "Enable cross-command access" \
            disable "Disable cross-command access" \
            rename  "Rename a stratum" \
            remove  "Remove a stratum" \
            umount  "Release a stratum's mounts" \
            back    "Back") || return 0
        case "$c" in
            back|"") return 0 ;;
            fetch) bedrock_aok_fetch_menu ;;
            list) run_cmd "Bedrock-AOK strata" "$brl" list ;;
            status|show|enable|disable|update|umount)
                st=$(bedrock_aok_pick_stratum "Bedrock-AOK $c" "Choose a stratum") || continue
                run_cmd "brl $c $st" "$brl" "$c" "$st"
                ;;
            shell)
                st=$(bedrock_aok_pick_stratum "Stratum shell" "Choose a stratum") || continue
                clear
                "$brl" shell "$st"
                ;;
            install)
                st=$(bedrock_aok_pick_stratum "Install packages" "Choose a stratum") || continue
                pkg=$(tui_input "Install packages" "Package names (space-separated):" "") || continue
                [ -n "${pkg//[[:space:]]/}" ] || continue
                # brl expects one argv token per package. Package names may only
                # contain conventional package-name characters; reject shell text.
                if ! printf '%s\n' "$pkg" | tr ' ' '\n' | grep -Eqv '^[A-Za-z0-9][A-Za-z0-9+._:@/-]*$'; then
                    # Every non-empty line must match; grep -v succeeding means bad input.
                    :
                fi
                local bad=0 p
                for p in $pkg; do
                    case "$p" in *[!A-Za-z0-9+._:@/-]*|'') bad=1 ;; esac
                done
                if [ "$bad" = 1 ]; then
                    tui_msg "Invalid package name" "Package names may only contain letters, numbers, + . _ : @ / and -."
                    continue
                fi
                # Intentional word splitting: validated package tokens become argv.
                # shellcheck disable=SC2086
                run_cmd "Install into $st" "$brl" install "$st" $pkg
                ;;
            rename)
                st=$(bedrock_aok_pick_stratum "Rename stratum" "Choose a stratum") || continue
                new=$(tui_input "Rename stratum" "New name:" "") || continue
                case "$new" in ''|*[!A-Za-z0-9+._-]*) tui_msg "Invalid name" "Use letters, numbers, + . _ and - only."; continue ;; esac
                run_cmd "Rename $st -> $new" "$brl" rename "$st" "$new"
                ;;
            remove)
                st=$(bedrock_aok_pick_stratum "Remove stratum" "Choose a stratum") || continue
                tui_yesno "Remove stratum" "Remove '$st'?" || continue
                run_cmd "Remove $st" "$brl" remove "$st"
                ;;
        esac
    done
}

# Fix the permanent/reversible uninstall wording and use upstream syntax.
bedrock_aok_uninstall_menu() {
    local c brl work uninstaller
    bedrock_aok_require || return 0
    c=$(tui_radio "Remove Bedrock-AOK" \
        "Choose removal mode (SPACE selects):" \
        reversible "Reversible edition — brl unhijack" on \
        permanent  "Permanent edition — brl-uninstall" off) || return 0
    tui_yesno "Remove Bedrock-AOK" \
"Remove the current Bedrock-AOK installation using '$c' mode?\n\nThis may remove configured strata. Continue?" || return 0
    case "$c" in
        reversible)
            brl=$(bedrock_aok_brl) || return 1
            run_cmd "Unhijacking Bedrock-AOK" "$brl" unhijack
            ;;
        permanent)
            if command -v brl-uninstall >/dev/null 2>&1; then
                uninstaller=$(command -v brl-uninstall)
            elif [ -x /bedrock/bin/brl-uninstall ]; then
                uninstaller=/bedrock/bin/brl-uninstall
            else
                work="${SYSTUI_TMP:?}/bedrock-aok-uninstall"
                rm -rf "$work"; mkdir -p "$work"
                uninstaller="$work/brl-uninstall"
                bedrock_aok_download brl-uninstall "$uninstaller" || return 1
                chmod 0755 "$uninstaller"
            fi
            run_cmd "Uninstalling permanent Bedrock-AOK" "$uninstaller"
            ;;
    esac
}

return 0 2>/dev/null || true
