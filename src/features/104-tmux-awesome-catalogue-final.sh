# shellcheck shell=bash
###############################################################################
# PHASE 104 — awesome-tmux catalogue integration
# Source catalogue: https://github.com/rothgar/awesome-tmux
###############################################################################

SYSTUI_TMUX_AWESOME_README="https://raw.githubusercontent.com/rothgar/awesome-tmux/master/README.md"
SYSTUI_TMUX_AWESOME_DIR="$(systui_tmux_user_home)/.local/share/systui/tmux-awesome"

# Curated entries from awesome-tmux that are known to work naturally through
# TPM (or are simple tmux configuration/theme repositories).
systui_tmux_awesome_plugins() { # <category>
    case "$1" in
        themes)
            printf '%s\n' \
                'catppuccin/tmux|Catppuccin — Latte/Frappe/Macchiato/Mocha' \
                'dracula/tmux|Dracula — official Dracula theme' \
                'rose-pine/tmux|Rose Pine — Soho-style theme' \
                'janoamaral/tokyo-night-tmux|Tokyo Night' \
                'jimeh/tmux-themepack|Tmux Themepack — multiple themes' \
                'wfxr/tmux-power|tmux-power — powerline-style themes' \
                'o0th/tmux-nova|tmux-nova — customizable theme' \
                'egel/tmux-gruvbox|tmux-gruvbox — light/dark Gruvbox' \
                'ivnvxd/tmux-snazzy|tmux-snazzy' \
                'Nybkox/tmux-kanagawa|Kanagawa theme' \
                'uhs-robert/tmux-oasis|Oasis theme pack' \
                'niksingh710/minimal-tmux-status|Minimal status theme'
            ;;
        status)
            printf '%s\n' \
                'tmux-plugins/tmux-cpu|CPU and RAM status' \
                'tmux-plugins/tmux-battery|Battery status' \
                'MunifTanjim/tmux-mode-indicator|Current tmux mode indicator' \
                'joshmedeski/tmux-nerd-font-window-name|Nerd Font window names' \
                'tony-sol/tmux-current-pane-hostname|SSH user/hostname status' \
                'tony-sol/tmux-kubectx|Kubernetes context status' \
                'tassaron/tmux-df|Filesystem free-space status' \
                'theo64oliver/tmux-code-time|Session coding-time status' \
                '2KAbhishek/tmux2k|Configurable status-bar framework'
            ;;
        sessions)
            printf '%s\n' \
                'omerxx/tmux-sessionx|Session manager with previews/fuzzy finding' \
                'MunifTanjim/tmux-suspend|Suspend local session for nested remote tmux' \
                'nickdiego/tmux-pocket-pane|Toggle persistent named side panes' \
                'bcampolo/tmux-lazy-restore|Lazy session restore' \
                'leohenon/tmux-tab|MRU Alt-Tab for tmux sessions' \
                'maxonvim/tmux-underkeys|Jump to sessions using underlined letters' \
                'juancruzfl/tmux-canvas|Save/automate session layouts' \
                'timvw/tmux-assistant-resurrect|Restore AI assistant sessions' \
                'Subbeh/tmux-tpad|Popup session manager'
            ;;
        navigation)
            printf '%s\n' \
                'christoomey/vim-tmux-navigator|Seamless Vim/tmux pane navigation' \
                'TheSast/tmux-nav-master|Cross-navigation between tmux/apps' \
                'tmux-plugins/tmux-pain-control|Pane navigation/resize bindings' \
                'sei40kr/tmux-project|Find projects and open sessions' \
                'Chaitanyabsprip/tmux-harpoon|Bookmark and jump between sessions' \
                'fabioluciano/tmux-powerkit|Plugin/theme framework' \
                'jaclu/tmux-menus|Menu framework' \
                'wfxr/tmux-fzf-url|URL picker using fzf'
            ;;
        utility)
            printf '%s\n' \
                'tmux-plugins/tmux-yank|Clipboard integration' \
                'tmux-plugins/tmux-logging|Pane logging and capture' \
                'tmux-plugins/tmux-open|Open highlighted paths and URLs' \
                'tmux-plugins/tmux-copycat|Enhanced searching' \
                'dianoga-theory/tmux-poltergeist|Popup text-buffer clipboard' \
                'kesor/tmux-player-ctl|MPRIS media-player popup' \
                'YlanAllouche/tmux-task-monitor|Session process monitor popup' \
                'nhdaly/tmux-better-mouse-mode|Improved mouse behavior'
            ;;
    esac
}

systui_tmux_awesome_plugin_category() { # <category> <title>
    local category="$1" title="$2" repo desc state picks conf
    local -a opts=()
    conf=$(systui_tmux_conf)
    while IFS='|' read -r repo desc; do
        [ -n "$repo" ] || continue
        grep -Fq "set -g @plugin '$repo'" "$conf" 2>/dev/null && state=on || state=off
        opts+=("$repo" "$desc [$repo]" "$state")
    done <<< "$(systui_tmux_awesome_plugins "$category")"
    [ "${#opts[@]}" -gt 0 ] || return 0
    picks=$(tui_check "$title" "SPACE toggles entries. Selected entries are managed through TPM." "${opts[@]}") || return 0
    picks=${picks//\"/}
    # Make selected state authoritative for this category only.
    while IFS='|' read -r repo desc; do
        [ -n "$repo" ] || continue
        case " $picks " in
            *" $repo "*) systui_tmux_plugin_add "$repo" ;;
            *) systui_tmux_plugin_remove "$repo" ;;
        esac
    done <<< "$(systui_tmux_awesome_plugins "$category")"
    systui_tmux_plugins_apply
}

# Parse a specific awesome-tmux section live and emit owner/repo|label. This is
# intentionally runtime-driven: upstream additions become visible without a
# Systui release. Only GitHub links are emitted because those can be managed by
# the existing GitHub/TPM/source workflows.
systui_tmux_awesome_live_section() { # <heading text>
    local wanted="$1" data section=0 line label repo
    data=$(systui_tmux_fetch_text "$SYSTUI_TMUX_AWESOME_README" 2>/dev/null) || return 1
    while IFS= read -r line; do
        case "$line" in
            '## '*|'## <a '* )
                if printf '%s' "$line" | grep -Fqi "$wanted"; then section=1; continue; fi
                [ "$section" -eq 1 ] && break
                ;;
        esac
        [ "$section" -eq 1 ] || continue
        case "$line" in
            *'https://github.com/'*)
                repo=$(printf '%s\n' "$line" | sed -nE 's@.*https://github\.com/([^)/?# ]+/[^)/?# ]+).*@\1@p' | sed 's/\.git$//' | head -1)
                [ -n "$repo" ] || continue
                label=$(printf '%s\n' "$line" | sed -nE 's/^- \[([^]]+)\].*/\1/p')
                [ -n "$label" ] || label="$repo"
                printf '%s|%s\n' "$repo" "$label"
                ;;
        esac
    done <<< "$data" | awk -F'|' '!seen[$1]++'
}

systui_tmux_awesome_live_browser() {
    local section heading repo label action dest
    section=$(tui_menu_no_tags "Awesome tmux — live GitHub catalogue" \
        "Parsed live from rothgar/awesome-tmux:" \
        configuration "Configuration" \
        tools "Tools and session management" \
        themes "Themes" \
        status "Status Bar" \
        plugins "Plugins" \
        back "Back") || return 0
    [ "$section" != back ] || return 0
    case "$section" in
        configuration) heading='Configuration' ;;
        tools) heading='Tools and session management' ;;
        themes) heading='Themes' ;;
        status) heading='Status Bar' ;;
        plugins) heading='Plugins' ;;
    esac
    local -a opts=()
    while IFS='|' read -r repo label; do
        [ -n "$repo" ] || continue
        opts+=("$repo" "$label — $repo")
    done <<< "$(systui_tmux_awesome_live_section "$heading")"
    [ "${#opts[@]}" -gt 0 ] || { tui_msg "Awesome tmux" "No GitHub entries could be parsed from the '$heading' section."; return 0; }
    repo=$(tui_menu_no_tags "$heading" "Choose a GitHub project:" "${opts[@]}" back "Back") || return 0
    [ "$repo" != back ] || return 0
    action=$(tui_menu_no_tags "$repo" "Choose how Systui should handle this project:" \
        tpm "Add to .tmux.conf as a TPM plugin" \
        clone "Clone/update source under ~/.local/share/systui/tmux-awesome" \
        back "Back") || return 0
    case "$action" in
        tpm)
            systui_tmux_tpm_install || return 1
            systui_tmux_plugin_add "$repo"
            systui_tmux_plugins_apply
            ;;
        clone)
            command -v git >/dev/null 2>&1 || pm_install git || return 1
            dest="$SYSTUI_TMUX_AWESOME_DIR/${repo//\//--}"
            mkdir -p "$SYSTUI_TMUX_AWESOME_DIR"
            if [ -d "$dest/.git" ]; then
                git -C "$dest" pull --ff-only || true
            else
                rm -rf "$dest"
                git clone "https://github.com/$repo.git" "$dest" || return 1
            fi
            tui_msg "Awesome tmux" "Source installed/updated at:\n$dest"
            ;;
    esac
}

systui_tmux_install_oh_my_tmux() {
    local home repo conf
    command -v git >/dev/null 2>&1 || pm_install git || return 1
    home=$(systui_tmux_user_home); repo="$home/.tmux"
    if [ -d "$repo/.git" ]; then git -C "$repo" pull --ff-only || return 1
    else rm -rf "$repo"; git clone https://github.com/gpakosz/.tmux.git "$repo" || return 1; fi
    conf="$home/.tmux.conf"
    [ -e "$conf" ] || ln -s -f "$repo/.tmux.conf" "$conf"
    [ -e "$home/.tmux.conf.local" ] || cp "$repo/.tmux.conf.local" "$home/.tmux.conf.local"
    tui_msg "Oh My Tmux!" "Installed/updated gpakosz/.tmux in $repo.\nLocal overrides: $home/.tmux.conf.local"
}

systui_tmux_awesome_tools_menu() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Awesome tmux" \
            "Curated and live options sourced from rothgar/awesome-tmux:" \
            themes "Themes — Catppuccin, Dracula, Rose Pine, Tokyo Night, Gruvbox..." \
            status "Status bar — CPU, battery, modes, host, Kubernetes..." \
            sessions "Sessions/workspaces — sessionx, lazy restore, tmux-tab..." \
            navigation "Navigation/workflow — vim navigator, project picker, menus..." \
            utility "Utilities — yank, logging, open, task monitor, media..." \
            ohmytmux "Install/update Oh My Tmux! (gpakosz/.tmux)" \
            live "Browse awesome-tmux live from GitHub" \
            back "Back") || return 0
        case "$c" in
            themes) systui_tmux_awesome_plugin_category themes "Awesome tmux themes" ;;
            status) systui_tmux_awesome_plugin_category status "Awesome tmux status bar" ;;
            sessions) systui_tmux_awesome_plugin_category sessions "Awesome tmux sessions" ;;
            navigation) systui_tmux_awesome_plugin_category navigation "Awesome tmux navigation" ;;
            utility) systui_tmux_awesome_plugin_category utility "Awesome tmux utilities" ;;
            ohmytmux) systui_tmux_install_oh_my_tmux ;;
            live) systui_tmux_awesome_live_browser ;;
            back|'') return 0 ;;
        esac
    done
}

# Extend the phase-102 manager without changing its other behavior.
if declare -F menu_tmux_manager >/dev/null 2>&1 \
    && ! declare -F _systui_tmux_manager_before_awesome >/dev/null 2>&1; then
    _systui_tmux_mgr_def=$(declare -f menu_tmux_manager)
    _systui_tmux_mgr_def=${_systui_tmux_mgr_def/#menu_tmux_manager ()/_systui_tmux_manager_before_awesome ()}
    _systui_tmux_mgr_def=${_systui_tmux_mgr_def/#menu_tmux_manager()/_systui_tmux_manager_before_awesome()}
    eval "$_systui_tmux_mgr_def"
    unset _systui_tmux_mgr_def
fi

menu_tmux_manager() {
    local c ver
    while true; do
        ver=$(tmux -V 2>/dev/null || echo 'not installed')
        c=$(tui_menu_no_tags "tmux manager" "tmux: $ver" \
            install "Install / update tmux — package manager + live GitHub sources" \
            plugins "Plugins — TPM, curated, live GitHub browser, custom repos" \
            awesome "Awesome tmux — themes, status, sessions, tools and live catalogue" \
            config "Configuration and presets" \
            sessions "Session management" \
            version "Show tmux/plugin status" \
            remove "Remove native tmux package" \
            back "Back") || return 0
        case "$c" in
            install) systui_tmux_install_menu ;;
            plugins) systui_tmux_plugins_menu ;;
            awesome) systui_tmux_awesome_tools_menu ;;
            config) systui_tmux_config_menu ;;
            sessions) systui_tmux_sessions_menu ;;
            version) tui_msg "tmux status" "tmux: $(tmux -V 2>/dev/null || echo not-installed)\nConfig: $(systui_tmux_conf)\nTPM: $([ -d "$(systui_tmux_plugin_dir)/tpm" ] && echo installed || echo not-installed)\nAwesome source dir: $SYSTUI_TMUX_AWESOME_DIR" ;;
            remove) tui_yesno "Remove tmux" "Remove tmux through the native package manager?" && pm_remove tmux || true ;;
            back|'') return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
