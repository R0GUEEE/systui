# shellcheck shell=bash
# PHASE 65 — safe, transactional Bedrock-AOK command updates.

bedrock_aok_validate_script() { # <path>
    local script="$1"
    [ -s "$script" ] || return 1
    sh -n "$script" >/dev/null 2>&1
}

bedrock_aok_canonical_brl() { # <path>
    local p="$1" resolved
    resolved=$(readlink -f "$p" 2>/dev/null || true)
    if [ -n "$resolved" ] && [ -e "$resolved" ]; then
        printf '%s\n' "$resolved"
    else
        printf '%s\n' "$p"
    fi
}

bedrock_aok_restore_backup() { # <installed-brl>
    local requested="$1" brl candidate
    brl=$(bedrock_aok_canonical_brl "$requested")
    for candidate in \
        "${brl}.bak" \
        "${requested}.bak" \
        /bedrock/bin/brl.bak
    do
        [ -f "$candidate" ] || continue
        bedrock_aok_validate_script "$candidate" || continue
        cp -f -- "$candidate" "$brl" || continue
        chmod 0755 "$brl" 2>/dev/null || true
        if bedrock_aok_validate_script "$brl"; then
            log "bedrock-aok: restored valid backup $candidate -> $brl"
            return 0
        fi
    done
    return 1
}

bedrock_aok_self_update() {
    local requested brl work candidate backup
    bedrock_aok_require || return 1
    requested=$(bedrock_aok_brl) || return 1
    brl=$(bedrock_aok_canonical_brl "$requested")

    if ! bedrock_aok_validate_script "$brl"; then
        if bedrock_aok_restore_backup "$requested"; then
            tui_msg "Bedrock-AOK recovered" \
"The installed brl command was syntactically invalid. Systui restored a valid backup before checking for updates."
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
    tui_msg "Bedrock-AOK updated" "The canonical brl executable was downloaded, syntax-checked, backed up, and installed successfully."
}
