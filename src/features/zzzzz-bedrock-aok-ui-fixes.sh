# shellcheck shell=bash
# Bedrock-AOK TUI/TTY fixes.
# Loaded last so it can replace the earlier menu overlay safely.

# Run a read-only Bedrock command into a dialog text viewer. This avoids the
# old behavior where output flashed on the terminal and the menu immediately
# redrew, making "List strata" appear broken.
bedrock_aok_view_command() { # <title> <brl args...>
    local title="$1" brl out rc=0
    shift
    bedrock_aok_require || return 1
    brl=$(bedrock_aok_brl) || return 1
    out="${SYSTUI_TMP:?}/bedrock-aok-view.$$.txt"

    "$brl" "$@" >"$out" 2>&1 || rc=$?
    # Strip ANSI CSI color/control sequences before feeding dialog --textbox.
    # BusyBox/GNU sed both accept this expression in the environments systui
    # targets.
    sed -i 's/\x1b\[[0-9;]*[[:alpha:]]//g' "$out" 2>/dev/null || true

    if [ ! -s "$out" ]; then
        printf '(no output)\n' >"$out"
    fi
    tui_text "$title" "$out" || true
    rm -f "$out"
    return "$rc"
}

bedrock_aok_list_strata_menu() {
    local brl out rc=0
    bedrock_aok_require || return 1
    brl=$(bedrock_aok_brl) || return 1
    out="${SYSTUI_TMP:?}/bedrock-aok-strata-list.$$.txt"

    "$brl" list >"$out" 2>&1 || rc=$?
    sed -i 's/\x1b\[[0-9;]*[[:alpha:]]//g' "$out" 2>/dev/null || true

    if [ ! -s "$out" ]; then
        {
            echo "No strata reported by Bedrock-AOK."
            echo
            echo "On-disk strata:"
            bedrock_aok_installed_strata | sed 's/^/  /'
        } >"$out"
    fi

    tui_text "Installed Bedrock-AOK strata" "$out" || true
    rm -f "$out"
    return "$rc"
}

# The information submenu used run_cmd for every diagnostic, which dumps to the
# terminal with `clear` and (on failure) a `read` prompt — but the Bedrock menu
# is launched from a $(tui_menu ...) command substitution, so that output lands
# inside a captured subshell and instantly garbles / crashes the TUI.  Render
# all read-only reports through the persistent dialog viewer instead.
bedrock_aok_info_menu() {
    local c brl
    bedrock_aok_require || return 0
    brl=$(bedrock_aok_brl) || return 1
    while true; do
        c=$(tui_menu "Bedrock-AOK information" "Diagnostics and documentation:" \
            report       "System report / health overview" \
            status       "Bedrock-AOK status" \
            capabilities "Kernel capability report" \
            version      "Bedrock-AOK version" \
            tutorial     "Quick-start tutorial" \
            back         "Back") || return 0
        case "$c" in
            back|"") return 0 ;;
            report)       bedrock_aok_view_command "Bedrock-AOK report" report ;;
            status)       bedrock_aok_view_command "Bedrock-AOK status" status ;;
            capabilities) bedrock_aok_view_command "Bedrock-AOK capabilities" capabilities ;;
            version)      bedrock_aok_view_command "Bedrock-AOK version" version ;;
            tutorial)     bedrock_aok_view_command "Bedrock-AOK tutorial" tutorial ;;
        esac
    done
}

# Manage Bedrock-AOK configuration.  Bedrock stores its persistent settings in
# /bedrock/etc/brl (e.g. brl.conf).  Editing stages the file out, lets the user
# edit with the system editor, and writes it back; read-only inspection uses the
# persistent text viewer.  Runtime actions (URL refresh, reload, rollback) are
# provided too so the whole configuration lifecycle lives under one entry.
BEDROCK_BRL_ETC="/bedrock/etc/brl"

bedrock_aok_config_view() { # <path-or-dir>
    bedrock_aok_require || return 1
    local out rc=0
    out="${SYSTUI_TMP:?}/bedrock-aok-config.$$.txt"
    if [ -f "$1" ]; then
        cat "$1" >"$out" 2>/dev/null || rc=$?
    elif [ -d "$1" ]; then
        {
            echo "Bedrock config directory: $1"
            echo "=========================="
            {
                ls -la "$1" 2>/dev/null
                echo
                echo "===== contents ====="
                for f in "$1"/*; do
                    [ -f "$f" ] || continue
                    echo
                    echo "--- $(basename "$f") ---"
                    cat "$f" 2>/dev/null
                done
            } 2>/dev/null
        } >"$out"
    else
        printf 'Path not found: %s\n' "$1" >"$out"
        rc=1
    fi
    sed -i 's/\x1b\[[0-9;]*[[:alpha:]]//g' "$out" 2>/dev/null || true
    [ -s "$out" ] || printf '(no output)\n' >"$out"
    tui_text "Bedrock-AOK configuration" "$out" || true
    rm -f "$out"
    return "$rc"
}

bedrock_aok_config_edit() { # [path]
    bedrock_aok_require || return 1
    local path="${1:-$BEDROCK_BRL_ETC/brl.conf}" staged
    if [ ! -f "$path" ]; then
        # Prefer brl.conf, else let the user pick any .conf present.
        path=""
        for f in "$BEDROCK_BRL_ETC"/*.conf; do
            [ -f "$f" ] && { path="$f"; break; }
        done
        [ -n "$path" ] || { tui_msg "Bedrock config" "No configuration file found under\n$BEDROCK_BRL_ETC."; return 1; }
    fi
    tui_yesno "Edit Bedrock config" "Open '$path' with the system editor?" || return 0
    staged="${SYSTUI_TMP:?}/bedrock-aok-brl-conf"
    cp "$path" "$staged" 2>/dev/null || { tui_msg "Bedrock config" "Could not read '$path'."; return 1; }
    if safe_edit "$staged"; then
        cp "$staged" "$path" 2>/dev/null || { tui_msg "Bedrock config" "Could not write '$path'."; return 1; }
        tui_yesno "Bedrock config" "Configuration updated. Reload Bedrock so changes take effect?" \
            && bedrock_aok_run "Reload Bedrock configuration" reload || true
    fi
    rm -f "$staged"
}

bedrock_aok_config_menu() {
    local c brl
    bedrock_aok_require || return 0
    brl=$(bedrock_aok_brl) || return 1
    while true; do
        c=$(tui_menu "Bedrock-AOK configuration" \
            "Manage Bedrock-AOK configuration (stored in $BEDROCK_BRL_ETC):" \
            edit       "Edit the main configuration file (brl.conf)" \
            viewall    "View configuration and config directory" \
            list       "List config directory contents" \
            urls       "Refresh live stratum source URLs" \
            reload     "Reload configuration / command wrappers" \
            rollback   "Manage configuration rollback points" \
            back       "Back") || return 0
        case "$c" in
            back|"") return 0 ;;
            edit)    bedrock_aok_config_edit ;;
            viewall) bedrock_aok_config_view "$BEDROCK_BRL_ETC" ;;
            list)    bedrock_aok_view_command "Bedrock config directory" ls -la "$BEDROCK_BRL_ETC" ;;
            urls)    bedrock_aok_run "Refresh Bedrock-AOK stratum URLs" update-urls ;;
            reload)  bedrock_aok_run "Reload Bedrock-AOK" reload ;;
            rollback) bedrock_aok_rollback_menu ;;
        esac
    done
}

# Replace the strata submenu so all read-only actions use proper dialog viewers
# and interactive shell execution is attached directly to /dev/tty.
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
            list) bedrock_aok_list_strata_menu ;;
            status|show)
                st=$(bedrock_aok_pick_stratum "Bedrock-AOK $c" "Choose a stratum") || continue
                bedrock_aok_view_command "Bedrock-AOK $c: $st" "$c" "$st"
                ;;
            enable|disable|update|umount)
                st=$(bedrock_aok_pick_stratum "Bedrock-AOK $c" "Choose a stratum") || continue
                run_cmd "brl $c $st" "$brl" "$c" "$st"
                ;;
            shell)
                st=$(bedrock_aok_pick_stratum "Stratum shell" "Choose a stratum") || continue
                clear
                # Explicit TTY attachment is important because the top-level
                # main-menu choice itself is captured with $(tui_menu ...).
                # Without this, nested Bedrock shells can inherit captured
                # stdout and appear frozen until extra Enter presses.
                "$brl" shell "$st" </dev/tty >/dev/tty 2>/dev/tty || true
                ;;
            install)
                st=$(bedrock_aok_pick_stratum "Install packages" "Choose a stratum") || continue
                pkg=$(tui_input "Install packages" "Package names (space-separated):" "") || continue
                [ -n "${pkg//[[:space:]]/}" ] || continue
                local bad=0 p
                for p in $pkg; do
                    case "$p" in *[!A-Za-z0-9+._:@/-]*|'') bad=1 ;; esac
                done
                if [ "$bad" = 1 ]; then
                    tui_msg "Invalid package name" "Package names may only contain letters, numbers, + . _ : @ / and -."
                    continue
                fi
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

# The initial Bedrock integration wrapped tui_menu and launched menu_bedrock_aok
# directly when "bedrock" was selected from Main Menu. Main Menu itself is
# invoked as: choice=$(tui_menu ...), so that launch occurs inside a command
# substitution subshell. Attach the entire nested Bedrock UI to /dev/tty so its
# dialog widgets, command output and interactive shells are not captured by the
# parent's $(...) pipe. This removes the apparent freezes/double-Enter behavior.
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
            if [ -r /dev/tty ] && [ -w /dev/tty ]; then
                menu_bedrock_aok </dev/tty >/dev/tty 2>/dev/tty
            else
                menu_bedrock_aok
            fi
            continue
        fi
        printf '%s\n' "$choice"
        return 0
    done
}

return 0 2>/dev/null || true
