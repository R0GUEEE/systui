# shellcheck shell=bash
###############################################################################
# PHASE 106 — tmux catalogue multi-select installation
#
# Convert tmux catalogue project views from single-item menus to SPACE-select
# checklists. Existing TPM-configured projects start selected. Applying the
# checklist adds newly selected projects, removes unchecked configured projects
# from the current view, then runs TPM once for the complete batch.
###############################################################################

systui_tmux_catalog_browse() { # <category|all> [search]
    local category="$1" search="${2:-}" cat repo name desc state picks conf changed=0
    local -a opts=() rows=()

    conf=$(systui_tmux_conf)

    while IFS='|' read -r cat repo name desc; do
        [ -n "$repo" ] || continue
        rows+=("$cat|$repo|$name|$desc")
        if grep -Fq "set -g @plugin '$repo'" "$conf" 2>/dev/null; then
            state=on
        else
            state=off
        fi
        opts+=("$repo" "$name — $desc [$repo]" "$state")
    done <<< "$(systui_tmux_catalog_rows "$category" "$search")"

    [ "${#opts[@]}" -gt 0 ] || {
        tui_msg "Tmux catalogue" "No projects matched this catalogue view."
        return 0
    }

    picks=$(tui_check "$(systui_tmux_catalog_title "$category")" \
        "SPACE toggles projects. ENTER applies the complete selection. Existing TPM plugins start selected; unchecking removes them from TPM configuration." \
        "${opts[@]}") || return 0
    picks=${picks//\"/}

    # Ensure TPM exists once before applying any selected plugins.
    if [ -n "${picks//[[:space:]]/}" ]; then
        systui_tmux_tpm_install || return 1
    fi

    for row in "${rows[@]}"; do
        IFS='|' read -r cat repo name desc <<< "$row"
        [ -n "$repo" ] || continue

        if printf ' %s ' "$picks" | grep -Fq " $repo "; then
            if ! grep -Fq "set -g @plugin '$repo'" "$conf" 2>/dev/null; then
                systui_tmux_plugin_add "$repo"
                changed=1
            fi
        else
            if grep -Fq "set -g @plugin '$repo'" "$conf" 2>/dev/null; then
                systui_tmux_plugin_remove "$repo"
                changed=1
            fi
        fi
    done

    if [ "$changed" -eq 1 ]; then
        systui_tmux_plugins_apply || true
        tui_msg "Tmux catalogue" "Applied the selected plugin set. TPM configuration was updated in one batch."
    else
        tui_msg "Tmux catalogue" "No plugin selection changes were required."
    fi
}

# Keep old plugin-category entry points on the same multi-select catalogue.
systui_tmux_plugin_selector() {
    systui_tmux_catalog_browse plugins
}

systui_tmux_awesome_plugin_category() { # <category> <title>
    case "$1" in
        themes) systui_tmux_catalog_browse themes ;;
        status) systui_tmux_catalog_browse status ;;
        sessions|navigation|utility) systui_tmux_catalog_browse tools ;;
        *) systui_tmux_catalog_browse all ;;
    esac
}

return 0 2>/dev/null || true
