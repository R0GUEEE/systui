# shellcheck shell=bash
###############################################################################
# PHASE 105 — unified tmux + awesome-tmux catalogue
#
# Merge SystUI's existing tmux catalogue with every GitHub repository parsed
# from rothgar/awesome-tmux. Descriptions are parsed from the upstream Markdown
# list text and shown directly in the TUI.
###############################################################################

SYSTUI_TMUX_AWESOME_README="${SYSTUI_TMUX_AWESOME_README:-https://raw.githubusercontent.com/rothgar/awesome-tmux/master/README.md}"
SYSTUI_TMUX_CATALOG_CACHE="${SYSTUI_TMUX_CATALOG_CACHE:-${SYSTUI_TMP:-${TMPDIR:-/tmp}}/systui-awesome-tmux-catalogue.tsv}"

systui_tmux_catalog_section_key() {
    local h="$1"
    h=$(printf '%s' "$h" | sed -E 's/^##[[:space:]]*//; s/<[^>]+>//g; s/[[:space:]]+$//')
    case "${h,,}" in
        configuration) printf 'configuration\n' ;;
        'tools and session management') printf 'tools\n' ;;
        themes) printf 'themes\n' ;;
        'status bar') printf 'status\n' ;;
        plugins) printf 'plugins\n' ;;
        miscellaneous) printf 'misc\n' ;;
        *) return 1 ;;
    esac
}

# Emit: category|owner/repo|name|description
systui_tmux_catalog_parse_awesome() {
    local data line section="" repo name desc url heading
    data=$(systui_tmux_fetch_text "$SYSTUI_TMUX_AWESOME_README" 2>/dev/null) || return 1

    while IFS= read -r line; do
        case "$line" in
            '## '*)
                heading=$(systui_tmux_catalog_section_key "$line" 2>/dev/null || true)
                section="$heading"
                continue
                ;;
        esac
        [ -n "$section" ] || continue
        case "$line" in
            '- ['*'https://github.com/'*) ;;
            *) continue ;;
        esac

        url=$(printf '%s\n' "$line" | grep -oE 'https://github\.com/[^) >]+' | head -1)
        [ -n "$url" ] || continue
        repo=${url#https://github.com/}
        repo=${repo%%\?*}; repo=${repo%%\#*}; repo=${repo%.git}; repo=${repo%/}
        # Keep repository root only; awesome-tmux occasionally links into a path.
        repo=$(printf '%s' "$repo" | awk -F/ 'NF>=2 {print $1"/"$2}')
        [ -n "$repo" ] || continue

        name=$(printf '%s\n' "$line" | sed -nE 's/^- \[([^]]+)\].*/\1/p')
        [ -n "$name" ] || name="${repo#*/}"

        # Strip the leading Markdown link and retain the human-written text that
        # follows it. This is the upstream awesome-tmux description.
        desc=$(printf '%s\n' "$line" | sed -E 's/^- \[[^]]+\]\([^)]*\)[[:space:]]*//')
        desc=$(printf '%s' "$desc" | sed -E 's/^[[:space:]:—-]+//; s/[[:space:]]+$//; s/\|/\//g')
        [ -n "$desc" ] || desc="GitHub project listed by awesome-tmux"

        printf '%s|%s|%s|%s\n' "$section" "$repo" "$name" "$desc"
    done <<< "$data" | awk -F'|' '!seen[$2]++'
}

# Existing SystUI entries are merged even when awesome-tmux does not list them.
# Emit the same category|repo|name|description shape.
systui_tmux_catalog_existing() {
    local repo desc
    if declare -F systui_tmux_curated_plugins >/dev/null 2>&1; then
        while IFS='|' read -r repo desc; do
            [ -n "$repo" ] || continue
            printf 'curated|%s|%s|%s\n' "$repo" "${repo#*/}" "${desc:-SystUI curated tmux plugin}"
        done <<< "$(systui_tmux_curated_plugins)"
    fi

    # Merge phase-104 curated lists too. Deduplication happens downstream.
    if declare -F systui_tmux_awesome_plugins >/dev/null 2>&1; then
        local cat
        for cat in themes status sessions navigation utility; do
            while IFS='|' read -r repo desc; do
                [ -n "$repo" ] || continue
                printf 'curated|%s|%s|%s\n' "$repo" "${repo#*/}" "${desc:-SystUI curated tmux project}"
            done <<< "$(systui_tmux_awesome_plugins "$cat")"
        done
    fi
}

systui_tmux_catalog_refresh() {
    local tmp="${SYSTUI_TMUX_CATALOG_CACHE}.part"
    mkdir -p "$(dirname "$SYSTUI_TMUX_CATALOG_CACHE")" 2>/dev/null || true
    {
        systui_tmux_catalog_existing
        systui_tmux_catalog_parse_awesome
    } | awk -F'|' '!seen[$2]++' > "$tmp" || { rm -f "$tmp"; return 1; }
    [ -s "$tmp" ] || { rm -f "$tmp"; return 1; }
    mv -f "$tmp" "$SYSTUI_TMUX_CATALOG_CACHE"
}

systui_tmux_catalog_ensure() {
    [ -s "$SYSTUI_TMUX_CATALOG_CACHE" ] || systui_tmux_catalog_refresh
}

systui_tmux_catalog_title() {
    case "$1" in
        curated) printf 'SystUI curated\n' ;;
        configuration) printf 'Configuration frameworks\n' ;;
        tools) printf 'Tools and session management\n' ;;
        themes) printf 'Themes\n' ;;
        status) printf 'Status Bar\n' ;;
        plugins) printf 'Plugins\n' ;;
        misc) printf 'Miscellaneous\n' ;;
        all) printf 'All tmux projects\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

systui_tmux_catalog_rows() { # <category|all> [search]
    local category="$1" search="${2:-}" cat repo name desc
    systui_tmux_catalog_ensure || return 1
    while IFS='|' read -r cat repo name desc; do
        [ -n "$repo" ] || continue
        if [ "$category" != all ] && [ "$cat" != "$category" ]; then continue; fi
        if [ -n "$search" ]; then
            printf '%s %s %s' "$repo" "$name" "$desc" | grep -Fqi -- "$search" || continue
        fi
        printf '%s|%s|%s|%s\n' "$cat" "$repo" "$name" "$desc"
    done < "$SYSTUI_TMUX_CATALOG_CACHE"
}

systui_tmux_catalog_project_action() { # <category> <repo> <name> <description>
    local category="$1" repo="$2" name="$3" desc="$4" action dest conf installed="no"
    conf=$(systui_tmux_conf)
    grep -Fq "set -g @plugin '$repo'" "$conf" 2>/dev/null && installed=yes

    while true; do
        action=$(tui_menu_no_tags "$name" \
            "Category: $(systui_tmux_catalog_title "$category")\nRepository: $repo\nTPM configured: $installed\n\n$desc" \
            toggle "$([ "$installed" = yes ] && printf 'Remove from TPM configuration' || printf 'Add as TPM plugin')" \
            clone "Clone/update source locally" \
            details "Show full project details" \
            back "Back") || return 0
        case "$action" in
            toggle)
                if [ "$installed" = yes ]; then
                    systui_tmux_plugin_remove "$repo"
                    installed=no
                    declare -F systui_tmux_plugins_apply >/dev/null 2>&1 && systui_tmux_plugins_apply || true
                else
                    systui_tmux_tpm_install || return 1
                    systui_tmux_plugin_add "$repo"
                    installed=yes
                    systui_tmux_plugins_apply || true
                fi
                ;;
            clone)
                command -v git >/dev/null 2>&1 || pm_install git || return 1
                dest="${SYSTUI_TMUX_AWESOME_DIR:-$(systui_tmux_user_home)/.local/share/systui/tmux-awesome}/${repo//\//--}"
                mkdir -p "$(dirname "$dest")"
                if [ -d "$dest/.git" ]; then
                    git -C "$dest" pull --ff-only || true
                else
                    rm -rf "$dest"
                    git clone "https://github.com/$repo.git" "$dest" || return 1
                fi
                tui_msg "$name" "Source installed/updated at:\n$dest"
                ;;
            details)
                tui_msg "$name" "Repository: https://github.com/$repo\nCategory: $(systui_tmux_catalog_title "$category")\nTPM configured: $installed\n\n$desc"
                ;;
            back|'') return 0 ;;
        esac
    done
}

systui_tmux_catalog_browse() { # <category|all> [search]
    local category="$1" search="${2:-}" cat repo name desc selected
    local -a opts=()
    while IFS='|' read -r cat repo name desc; do
        [ -n "$repo" ] || continue
        opts+=("$repo" "$name — $desc [$repo]")
    done <<< "$(systui_tmux_catalog_rows "$category" "$search")"

    [ "${#opts[@]}" -gt 0 ] || {
        tui_msg "Tmux catalogue" "No projects matched this catalogue view."
        return 0
    }

    selected=$(tui_menu_no_tags "$(systui_tmux_catalog_title "$category")" \
        "${#opts[@]} menu fields loaded. Descriptions are parsed from rothgar/awesome-tmux when available." \
        "${opts[@]}" back "Back") || return 0
    [ "$selected" != back ] && [ -n "$selected" ] || return 0

    while IFS='|' read -r cat repo name desc; do
        [ "$repo" = "$selected" ] || continue
        systui_tmux_catalog_project_action "$cat" "$repo" "$name" "$desc"
        return 0
    done <<< "$(systui_tmux_catalog_rows all)"
}

systui_tmux_catalog_search() {
    local q
    q=$(tui_input "Search tmux catalogue" "Search repository, project name or description:" "") || return 0
    [ -n "${q//[[:space:]]/}" ] || return 0
    systui_tmux_catalog_browse all "$q"
}

systui_tmux_catalog_tpm_menu() {
    local c
    while true; do
        c=$(tui_menu_no_tags "TPM maintenance" "Manage Tmux Plugin Manager and configured plugins:" \
            install "Install/update TPM" \
            apply "Install configured plugins" \
            update "Update all configured plugins" \
            clean "Clean removed plugins" \
            custom "Add custom GitHub owner/repository" \
            back "Back") || return 0
        case "$c" in
            install) systui_tmux_tpm_install ;;
            apply) systui_tmux_plugins_apply ;;
            update)
                local tpm="$(systui_tmux_plugin_dir)/tpm"
                [ -x "$tpm/bin/update_plugins" ] || systui_tmux_tpm_install || continue
                "$tpm/bin/update_plugins" all || true
                ;;
            clean)
                local tpm="$(systui_tmux_plugin_dir)/tpm"
                [ -x "$tpm/bin/clean_plugins" ] || systui_tmux_tpm_install || continue
                "$tpm/bin/clean_plugins" || true
                ;;
            custom)
                local repo
                repo=$(tui_input "Custom tmux plugin" "GitHub owner/repository:" "") || continue
                repo=${repo#https://github.com/}; repo=${repo%.git}; repo=${repo%/}
                [ -n "$repo" ] || continue
                systui_tmux_tpm_install || continue
                systui_tmux_plugin_add "$repo"
                systui_tmux_plugins_apply || true
                ;;
            back|'') return 0 ;;
        esac
    done
}

# Authoritative combined catalogue. This replaces both the old Plugins browser
# and the separate Awesome tmux browser.
systui_tmux_unified_catalogue() {
    local c
    while true; do
        systui_tmux_catalog_ensure || {
            tui_msg "Tmux catalogue" "Unable to download/parse rothgar/awesome-tmux and no cached catalogue is available."
            return 1
        }
        c=$(tui_menu_no_tags "Tmux catalogue" \
            "Unified SystUI + rothgar/awesome-tmux catalogue. All GitHub repository entries are parsed live with descriptions:" \
            all "All projects" \
            curated "SystUI curated plugins/projects" \
            configuration "Configuration frameworks" \
            tools "Tools and session management" \
            themes "Themes" \
            status "Status Bar" \
            plugins "Plugins" \
            misc "Miscellaneous" \
            search "Search all projects and descriptions" \
            refresh "Refresh catalogue from GitHub" \
            tpm "TPM maintenance and custom repositories" \
            back "Back") || return 0
        case "$c" in
            all|curated|configuration|tools|themes|status|plugins|misc) systui_tmux_catalog_browse "$c" ;;
            search) systui_tmux_catalog_search ;;
            refresh)
                rm -f "$SYSTUI_TMUX_CATALOG_CACHE"
                if systui_tmux_catalog_refresh; then
                    tui_msg "Tmux catalogue" "Catalogue refreshed from rothgar/awesome-tmux."
                else
                    tui_msg "Tmux catalogue" "Catalogue refresh failed."
                fi
                ;;
            tpm) systui_tmux_catalog_tpm_menu ;;
            back|'') return 0 ;;
        esac
    done
}

# Keep callers of the old plugin menu on the new unified catalogue.
systui_tmux_plugins_menu() { systui_tmux_unified_catalogue; }
systui_tmux_awesome_tools_menu() { systui_tmux_unified_catalogue; }
systui_tmux_awesome_live_browser() { systui_tmux_unified_catalogue; }

# Final tmux manager: one catalogue entry, no separate Plugins/Awesome menus.
menu_tmux_manager() {
    local c ver
    while true; do
        ver=$(tmux -V 2>/dev/null || echo 'not installed')
        c=$(tui_menu_no_tags "tmux manager" "tmux: $ver" \
            install "Install / update tmux — package manager + live GitHub sources" \
            catalogue "Tmux catalogue — plugins, themes, tools, sessions, configs and Awesome tmux" \
            config "Configuration and presets" \
            sessions "Session management" \
            version "Show tmux/plugin status" \
            remove "Remove native tmux package" \
            back "Back") || return 0
        case "$c" in
            install) systui_tmux_install_menu ;;
            catalogue) systui_tmux_unified_catalogue ;;
            config) systui_tmux_config_menu ;;
            sessions) systui_tmux_sessions_menu ;;
            version) tui_msg "tmux status" "tmux: $(tmux -V 2>/dev/null || echo not-installed)\nConfig: $(systui_tmux_conf)\nTPM: $([ -d "$(systui_tmux_plugin_dir)/tpm" ] && echo installed || echo not-installed)" ;;
            remove) tui_yesno "Remove tmux" "Remove tmux through the native package manager?" && pm_remove tmux || true ;;
            back|'') return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
