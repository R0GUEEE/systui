# shellcheck shell=bash
# PHASE 65 — safe, transactional Bedrock-AOK command updates.
#
# Upstream `brl self-update` currently replaces the live command before the
# downloaded script is syntax-checked. If upstream publishes a malformed brl,
# the installed command is left broken. Stage and validate the candidate first,
# and recover from the upstream-created .bak when the current command is already
# invalid.

bedrock_aok_validate_script() { # <path>
    local script="$1"
    [ -s "$script" ] || return 1
    sh -n "$script" >/dev/null 2>&1
}

bedrock_aok_restore_backup() { # <installed-brl>
    local brl="$1" backup
    backup="${brl}.bak"
    [ -f "$backup" ] || return 1
    bedrock_aok_validate_script "$backup" || return 1
    cp -f -- "$backup" "$brl" || return 1
    chmod 0755 "$brl" 2>/dev/null || true
    bedrock_aok_validate_script "$brl"
}

bedrock_aok_self_update() {
    local brl work candidate backup
    bedrock_aok_require || return 1
    brl=$(bedrock_aok_brl) || return 1

    # Recover first when a previous upstream self-update already installed a
    # malformed command. Upstream writes <brl>.bak before replacing the file.
    if ! bedrock_aok_validate_script "$brl"; then
        if bedrock_aok_restore_backup "$brl"; then
            tui_msg "Bedrock-AOK recovered" \
"The installed brl command was syntactically invalid. systui restored the valid backup at ${brl}.bak before checking for updates."
        else
            tui_msg "Bedrock-AOK is broken" \
"The installed brl command is syntactically invalid and no valid backup could be restored. Reinstall Bedrock-AOK before updating."
            return 1
        fi
    fi

    work="${SYSTUI_TMP:?}/bedrock-aok-safe-update"
    rm -rf -- "$work"
    mkdir -p -- "$work" || return 1
    candidate="$work/brl"

    # Download through the existing trusted upstream integration. This also
    # applies Systui's compatibility patch before validation.
    bedrock_aok_download brl "$candidate" || return 1
    chmod 0755 "$candidate" || return 1

    if ! bedrock_aok_validate_script "$candidate"; then
        log "bedrock-aok: rejected upstream brl because sh -n failed"
        tui_msg "Update rejected" \
"The upstream Bedrock-AOK brl script failed syntax validation. The installed command was not replaced."
        return 2
    fi

    backup="${brl}.bak"
    cp -f -- "$brl" "$backup" || return 1
    chmod 0755 "$backup" 2>/dev/null || true

    # Install atomically in the same directory where possible.
    if ! cp -f -- "$candidate" "${brl}.systui-new"; then
        return 1
    fi
    chmod 0755 "${brl}.systui-new" || { rm -f -- "${brl}.systui-new"; return 1; }
    if ! mv -f -- "${brl}.systui-new" "$brl"; then
        rm -f -- "${brl}.systui-new"
        return 1
    fi

    if ! bedrock_aok_validate_script "$brl"; then
        cp -f -- "$backup" "$brl" 2>/dev/null || true
        chmod 0755 "$brl" 2>/dev/null || true
        tui_msg "Update rolled back" \
"The new brl failed validation after installation. The previous command was restored from backup."
        return 2
    fi

    run_cmd "Bedrock-AOK version" "$brl" version || true
    tui_msg "Bedrock-AOK updated" "The brl command was downloaded, syntax-checked, backed up, and installed successfully."
}
