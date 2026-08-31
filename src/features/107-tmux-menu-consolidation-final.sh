# shellcheck shell=bash
###############################################################################
# PHASE 107 — single authoritative tmux menu
###############################################################################
# Flatten the active tmux manager so catalogue/plugin/TPM/Awesome entry points
# no longer open competing menu trees. Keep detailed install/config/session
# workflows, but expose every catalogue category directly from one tmux menu.

systui_tmux_refresh_catalogue() {
    rm -f "${SYSTUI_TMUX_CATALOG_CACHE:-}" 2>/dev/null || true
    if systui_tmux_catalog_refresh; then
        tui_msg "tmux catalogue" "Catalogue refreshed from rothgar/awesome-tmux."
    else
        tui_msg "tmux catalogue" "Catalogue refresh failed."
    fi
}

systui_tmux_status_summary() {
    local conf plugin_dir configured=0 installed=0
    conf=$(systui_tmux_conf)
    plugin_dir=$(systui_tmux_plugin_dir)
    if [ -f "$conf" ]; then
        configured=$(grep -Ec "^[[:space:]]*set[[:space:]]+-g[[:space:]]+@plugin[[:space:]]+['\"]" "$conf" 2>/dev/null || echo 0)
    fi
    if [ -d "$plugin_dir" ]; then
        installed=$(find "$plugin_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')
    fi
    tui_msg "tmux status" "tmux: $(tmux -V 2>/dev/null || echo not-installed)\nConfig: $conf\nTPM: $([ -d "$plugin_dir/tpm" ] && echo installed || echo not-installed)\nConfigured plugins: $configured\nPlugin directories: $installed"
}

# One tmux manager. Catalogue views retain SPACE-to-select behavior from phase
# 106 and descriptions/live parsing from phase 105.
menu_tmux_manager() {
    local c ver
    while true; do
        ver=$(tmux -V 2>/dev/null || echo 'not installed')
        c=$(tui_menu_no_tags "tmux manager" \
            "tmux: $ver — one consolidated manager for installation, plugins, Awesome tmux, configuration and sessions." \
            install "Install / update tmux" \
            all "All catalogue projects — SPACE multi-select" \
            curated "Curated tmux plugins/projects — SPACE multi-select" \
            configuration "Configuration frameworks — SPACE multi-select" \
            tools "Tools and session managers — SPACE multi-select" \
            themes "Themes — SPACE multi-select" \
            statusbar "Status Bar extensions — SPACE multi-select" \
            plugins "Plugins — SPACE multi-select" \
            misc "Miscellaneous tmux projects — SPACE multi-select" \
            search "Search projects and descriptions" \
            tpm "TPM maintenance / custom repository" \
            refresh "Refresh Awesome tmux catalogue from GitHub" \
            config "tmux configuration and presets" \
            sessions "Live tmux session management" \
            status "Show tmux / plugin status" \
            remove "Remove native tmux package" \
            back "Back") || return 0
        case "$c" in
            install) systui_tmux_install_menu ;;
            all) systui_tmux_catalog_browse all ;;
            curated) systui_tmux_catalog_browse curated ;;
            configuration) systui_tmux_catalog_browse configuration ;;
            tools) systui_tmux_catalog_browse tools ;;
            themes) systui_tmux_catalog_browse themes ;;
            statusbar) systui_tmux_catalog_browse status ;;
            plugins) systui_tmux_catalog_browse plugins ;;
            misc) systui_tmux_catalog_browse misc ;;
            search) systui_tmux_catalog_search ;;
            tpm) systui_tmux_catalog_tpm_menu ;;
            refresh) systui_tmux_refresh_catalogue ;;
            config) systui_tmux_config_menu ;;
            sessions) systui_tmux_sessions_menu ;;
            status) systui_tmux_status_summary ;;
            remove) tui_yesno "Remove tmux" "Remove tmux through the native package manager?" && pm_remove tmux || true ;;
            back|'') return 0 ;;
        esac
    done
}

# Compatibility aliases: old tmux front doors now resolve to the same menu.
# The catalogue function itself remains available to internal callers, but old
# user-facing plugin/Awesome entry points cannot create alternate menu trees.
systui_tmux_plugins_menu() { menu_tmux_manager; }
systui_tmux_awesome_tools_menu() { menu_tmux_manager; }
systui_tmux_awesome_live_browser() { menu_tmux_manager; }

return 0 2>/dev/null || true
