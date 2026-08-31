# shellcheck shell=bash
###############################################################################
# PHASE 102 — tmux management overhaul
###############################################################################

systui_tmux_user_home() {
    local u="${SUDO_USER:-${USER:-root}}" h
    h=$(getent passwd "$u" 2>/dev/null | cut -d: -f6)
    [ -n "$h" ] || h="${HOME:-/root}"
    printf '%s\n' "$h"
}

systui_tmux_conf() { printf '%s/.tmux.conf\n' "$(systui_tmux_user_home)"; }
systui_tmux_plugin_dir() { printf '%s/.tmux/plugins\n' "$(systui_tmux_user_home)"; }

systui_tmux_fetch_text() {
    if declare -F rootfs_fetch_text >/dev/null 2>&1; then rootfs_fetch_text "$1"
    elif command -v curl >/dev/null 2>&1; then curl -4 -LfsS --connect-timeout 10 --max-time 120 "$1"
    elif command -v wget >/dev/null 2>&1; then wget -4 -qO- -T 120 "$1"
    else return 127; fi
}

systui_tmux_fetch_file() {
    if declare -F rootfs_fetch_file >/dev/null 2>&1; then rootfs_fetch_file "$1" "$2"
    elif command -v curl >/dev/null 2>&1; then curl -4 -fL --retry 3 --connect-timeout 10 --max-time 600 -o "$2" "$1"
    elif command -v wget >/dev/null 2>&1; then wget -4 -T 600 -O "$2" "$1"
    else return 127; fi
}

systui_tmux_arch() {
    case "$(uname -m 2>/dev/null)" in
        x86_64|amd64) printf 'x86_64\n' ;;
        aarch64|arm64) printf 'arm64\n' ;;
        armv7l|armv7*) printf 'armv7\n' ;;
        *) uname -m ;;
    esac
}

systui_tmux_install_build_deps() {
    case "${PM:-}" in
        apt) pm_install build-essential automake autoconf bison pkg-config libevent-dev libncurses-dev git ca-certificates ;;
        apk) pm_install build-base automake autoconf bison pkgconf libevent-dev ncurses-dev git ca-certificates ;;
        pacman) pm_install base-devel automake autoconf bison pkgconf libevent ncurses git ca-certificates ;;
        dnf|yum) pm_install gcc make automake autoconf bison pkgconf-pkg-config libevent-devel ncurses-devel git ca-certificates ;;
        zypper) pm_install gcc make automake autoconf bison pkg-config libevent-devel ncurses-devel git ca-certificates ;;
        xbps) pm_install base-devel automake autoconf bison pkg-config libevent-devel ncurses-devel git ca-certificates ;;
        emerge) pm_install sys-devel/gcc sys-devel/make sys-devel/autoconf sys-devel/automake sys-devel/bison virtual/pkgconfig dev-libs/libevent sys-libs/ncurses dev-vcs/git ;;
        *) return 1 ;;
    esac
}

systui_tmux_install_native() {
    pm_install tmux
}

systui_tmux_release_asset_url() { # <repo> <regex>
    local repo="$1" regex="$2" json
    json=$(systui_tmux_fetch_text "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null) || return 1
    printf '%s\n' "$json" | grep -oE '"browser_download_url"[[:space:]]*:[[:space:]]*"[^"]+"' |
        sed -E 's/^.*"(https:[^"]+)"$/\1/' | grep -Ei "$regex" | head -1
}

systui_tmux_install_static_github() {
    local arch regex url tmp unpack bin
    arch=$(systui_tmux_arch)
    case "$arch" in
        x86_64) regex='linux[-_.](x86_64|amd64).*\.tar\.gz$|linux.*(x86_64|amd64).*\.tar\.gz$' ;;
        arm64) regex='linux[-_.](arm64|aarch64).*\.tar\.gz$|linux.*(arm64|aarch64).*\.tar\.gz$' ;;
        *) tui_msg "tmux static build" "tmux/tmux-builds currently targets Linux x86_64 and arm64."; return 1 ;;
    esac
    url=$(systui_tmux_release_asset_url tmux/tmux-builds "$regex") || true
    [ -n "$url" ] || { tui_msg "tmux static build" "No matching current tmux/tmux-builds release asset was found for $arch."; return 1; }
    tmp=$(mktemp -d "${SYSTUI_TMP:-${TMPDIR:-/tmp}}/tmux-static.XXXXXX") || return 1
    systui_tmux_fetch_file "$url" "$tmp/tmux.tar.gz" || { rm -rf "$tmp"; return 1; }
    mkdir -p "$tmp/unpack"; tar -xzf "$tmp/tmux.tar.gz" -C "$tmp/unpack" || { rm -rf "$tmp"; return 1; }
    bin=$(find "$tmp/unpack" -type f -name tmux -perm -111 2>/dev/null | head -1)
    [ -n "$bin" ] || bin=$(find "$tmp/unpack" -type f -name tmux 2>/dev/null | head -1)
    [ -n "$bin" ] || { rm -rf "$tmp"; return 1; }
    install -m 0755 "$bin" /usr/local/bin/tmux || { rm -rf "$tmp"; return 1; }
    rm -rf "$tmp"
    tui_msg "tmux installed" "Installed current static GitHub build to /usr/local/bin/tmux."
}

systui_tmux_install_appimage() {
    local arch regex url dest
    arch=$(systui_tmux_arch)
    case "$arch" in
        x86_64) regex='(x86_64|amd64).*AppImage$|AppImage.*(x86_64|amd64)' ;;
        arm64) regex='(aarch64|arm64).*AppImage$|AppImage.*(aarch64|arm64)' ;;
        *) tui_msg "tmux AppImage" "No known AppImage architecture mapping for $arch."; return 1 ;;
    esac
    url=$(systui_tmux_release_asset_url nelsonenzo/tmux-appimage "$regex") || true
    [ -n "$url" ] || { tui_msg "tmux AppImage" "No matching current nelsonenzo/tmux-appimage asset was found for $arch."; return 1; }
    dest=/usr/local/bin/tmux.AppImage
    systui_tmux_fetch_file "$url" "$dest.part" || { rm -f "$dest.part"; return 1; }
    chmod 0755 "$dest.part" && mv -f "$dest.part" "$dest" || return 1
    ln -sf "$dest" /usr/local/bin/tmux-appimage
    tui_msg "tmux AppImage" "Installed to $dest. Use tmux-appimage to launch it."
}

systui_tmux_build_from_git() { # <stable|master>
    local mode="$1" tmp src tag json tarurl
    systui_tmux_install_build_deps || return 1
    tmp=$(mktemp -d "${SYSTUI_TMP:-${TMPDIR:-/tmp}}/tmux-build.XXXXXX") || return 1
    if [ "$mode" = master ]; then
        git clone --depth 1 https://github.com/tmux/tmux.git "$tmp/tmux" || { rm -rf "$tmp"; return 1; }
        src="$tmp/tmux"
        (cd "$src" && sh autogen.sh && ./configure --prefix=/usr/local && make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)" && make install) || { rm -rf "$tmp"; return 1; }
    else
        json=$(systui_tmux_fetch_text https://api.github.com/repos/tmux/tmux/releases/latest 2>/dev/null) || { rm -rf "$tmp"; return 1; }
        tarurl=$(printf '%s\n' "$json" | sed -nE 's/.*"tarball_url"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' | head -1)
        [ -n "$tarurl" ] || { rm -rf "$tmp"; return 1; }
        systui_tmux_fetch_file "$tarurl" "$tmp/tmux.tar.gz" || { rm -rf "$tmp"; return 1; }
        mkdir -p "$tmp/src"; tar -xzf "$tmp/tmux.tar.gz" -C "$tmp/src" || { rm -rf "$tmp"; return 1; }
        src=$(find "$tmp/src" -mindepth 1 -maxdepth 1 -type d | head -1)
        (cd "$src" && sh autogen.sh >/dev/null 2>&1 || true; ./configure --prefix=/usr/local && make -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)" && make install) || { rm -rf "$tmp"; return 1; }
    fi
    rm -rf "$tmp"
    tui_msg "tmux installed" "Installed tmux from GitHub $mode source to /usr/local."
}

systui_tmux_install_menu() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Install / update tmux" "Choose an installation source. GitHub-backed options resolve current releases live:" \
            native "Native package manager (${PM:-unknown})" \
            static "GitHub tmux/tmux-builds — static Linux binary" \
            source "GitHub tmux/tmux — latest stable source" \
            master "GitHub tmux/tmux — current master source" \
            appimage "GitHub nelsonenzo/tmux-appimage" \
            brew "Homebrew (when installed)" \
            nix "Nix profile (when installed)" \
            back "Back") || return 0
        case "$c" in
            native) systui_tmux_install_native || true ;;
            static) systui_tmux_install_static_github || true ;;
            source) systui_tmux_build_from_git stable || true ;;
            master) systui_tmux_build_from_git master || true ;;
            appimage) systui_tmux_install_appimage || true ;;
            brew) command -v brew >/dev/null 2>&1 && brew install tmux || tui_msg "Homebrew" "Homebrew is not installed." ;;
            nix) command -v nix >/dev/null 2>&1 && nix profile install nixpkgs#tmux || tui_msg "Nix" "Nix is not installed." ;;
            back|'') return 0 ;;
        esac
    done
}

systui_tmux_tpm_install() {
    local home dir conf
    command -v git >/dev/null 2>&1 || pm_install git || return 1
    home=$(systui_tmux_user_home); dir="$home/.tmux/plugins/tpm"; conf="$home/.tmux.conf"
    mkdir -p "$home/.tmux/plugins"
    if [ -d "$dir/.git" ]; then git -C "$dir" pull --ff-only || true
    else rm -rf "$dir"; git clone https://github.com/tmux-plugins/tpm "$dir" || return 1; fi
    touch "$conf"
    grep -Fq "set -g @plugin 'tmux-plugins/tpm'" "$conf" || printf "\nset -g @plugin 'tmux-plugins/tpm'\n" >> "$conf"
    grep -Eq "run(-shell)? .*plugins/tpm/tpm" "$conf" || printf "run '~/.tmux/plugins/tpm/tpm'\n" >> "$conf"
    [ "$(id -u)" -eq 0 ] && [ -n "${SUDO_USER:-}" ] && chown -R "$SUDO_USER":"$(id -gn "$SUDO_USER" 2>/dev/null || echo "$SUDO_USER")" "$home/.tmux" "$conf" 2>/dev/null || true
    tui_msg "TPM" "Tmux Plugin Manager installed/updated."
}

systui_tmux_plugin_add() { # <owner/repo>
    local repo="$1" conf tmp
    conf=$(systui_tmux_conf); mkdir -p "$(dirname "$conf")"; touch "$conf"
    grep -Fq "set -g @plugin '$repo'" "$conf" && return 0
    tmp="${SYSTUI_TMP:-${TMPDIR:-/tmp}}/tmux-conf.$$"
    grep -Ev "run(-shell)? .*plugins/tpm/tpm" "$conf" > "$tmp" 2>/dev/null || true
    printf "set -g @plugin '%s'\n" "$repo" >> "$tmp"
    printf "run '~/.tmux/plugins/tpm/tpm'\n" >> "$tmp"
    mv -f "$tmp" "$conf"
}

systui_tmux_plugin_remove() { # <owner/repo>
    local repo="$1" conf tmp
    conf=$(systui_tmux_conf); [ -f "$conf" ] || return 0
    tmp="${SYSTUI_TMP:-${TMPDIR:-/tmp}}/tmux-conf.$$"
    grep -Fv "set -g @plugin '$repo'" "$conf" > "$tmp" || true
    mv -f "$tmp" "$conf"
}

systui_tmux_plugins_apply() {
    local tpm="$(systui_tmux_plugin_dir)/tpm"
    [ -x "$tpm/bin/install_plugins" ] || systui_tmux_tpm_install || return 1
    "$tpm/bin/install_plugins" || true
    command -v tmux >/dev/null 2>&1 && tmux source-file "$(systui_tmux_conf)" 2>/dev/null || true
}

systui_tmux_curated_plugins() {
    printf '%s\n' \
        'tmux-plugins/tmux-sensible|Sensible defaults' \
        'tmux-plugins/tmux-resurrect|Persist sessions across restarts' \
        'tmux-plugins/tmux-continuum|Automatic resurrect save/restore' \
        'tmux-plugins/tmux-yank|System clipboard integration' \
        'tmux-plugins/tmux-pain-control|Pane navigation and resize bindings' \
        'tmux-plugins/tmux-copycat|Enhanced searching' \
        'tmux-plugins/tmux-sessionist|Session utilities' \
        'tmux-plugins/tmux-logging|Pane logging and screen capture' \
        'tmux-plugins/tmux-open|Open highlighted paths/URLs' \
        'tmux-plugins/tmux-cpu|CPU/RAM status helpers' \
        'tmux-plugins/tmux-battery|Battery status helpers' \
        'tmux-plugins/tmux-prefix-highlight|Prefix-key status indicator' \
        'tmux-plugins/tmux-sidebar|Directory tree sidebar' \
        'tmux-plugins/tmux-fpp|Facebook PathPicker integration' \
        'nhdaly/tmux-better-mouse-mode|Improved mouse scrolling' \
        'wfxr/tmux-fzf-url|Open URLs through fzf' \
        'jaclu/tmux-menus|Menu framework for tmux'
}

systui_tmux_plugin_selector_data() { # curated/live
    local mode="$1" repo desc state conf json page
    local -a opts=()
    conf=$(systui_tmux_conf)
    if [ "$mode" = curated ]; then
        while IFS='|' read -r repo desc; do
            grep -Fq "set -g @plugin '$repo'" "$conf" 2>/dev/null && state=on || state=off
            opts+=("$repo" "$desc [$repo]" "$state")
        done <<< "$(systui_tmux_curated_plugins)"
    else
        for page in 1 2 3; do
            json=$(systui_tmux_fetch_text "https://api.github.com/orgs/tmux-plugins/repos?per_page=100&page=$page" 2>/dev/null || true)
            [ -n "$json" ] || continue
            while IFS= read -r repo; do
                [ -n "$repo" ] || continue
                case "$repo" in tmux-plugins/tpm) continue ;; esac
                grep -Fq "set -g @plugin '$repo'" "$conf" 2>/dev/null && state=on || state=off
                opts+=("$repo" "$repo" "$state")
            done < <(printf '%s\n' "$json" | grep -oE '"full_name"[[:space:]]*:[[:space:]]*"tmux-plugins/[^"]+"' | sed -E 's/^.*"(tmux-plugins\/[^"]+)"$/\1/' | sort -u)
        done
    fi
    [ "${#opts[@]}" -gt 0 ] || return 1
    tui_check "tmux plugins" "SPACE toggles plugins. GitHub entries are parsed live when using the live browser." "${opts[@]}"
}

systui_tmux_manage_plugin_selection() { # curated|live
    local picks repo conf existing
    conf=$(systui_tmux_conf)
    picks=$(systui_tmux_plugin_selector_data "$1") || return 0
    picks=${picks//\"/}
    while IFS= read -r repo; do
        [ -n "$repo" ] || continue
        case " $picks " in *" $repo "*) systui_tmux_plugin_add "$repo" ;; *) systui_tmux_plugin_remove "$repo" ;; esac
    done < <({ systui_tmux_curated_plugins | cut -d'|' -f1; grep -oE "set -g @plugin '[^']+'" "$conf" 2>/dev/null | sed -E "s/set -g @plugin '([^']+)'/\1/"; } | sort -u)
    systui_tmux_plugins_apply
}

systui_tmux_custom_plugin() {
    local repo
    repo=$(tui_input "Add tmux plugin" "GitHub repository (owner/repo):" "") || return 0
    case "$repo" in */*) ;; *) tui_msg "tmux plugin" "Use GitHub owner/repository format."; return 1 ;; esac
    systui_tmux_tpm_install || return 1
    systui_tmux_plugin_add "$repo" && systui_tmux_plugins_apply
}

systui_tmux_plugins_menu() {
    local c tpm
    while true; do
        tpm="$(systui_tmux_plugin_dir)/tpm"
        c=$(tui_menu_no_tags "tmux plugins" "TPM: $([ -d "$tpm" ] && echo installed || echo not-installed). Manage curated or live GitHub plugins:" \
            tpm "Install/update TPM (tmux-plugins/tpm)" \
            curated "Curated plugin collection" \
            github "Browse tmux-plugins organization live from GitHub" \
            custom "Add any GitHub plugin owner/repo" \
            install "Install configured plugins now" \
            update "Update all installed TPM plugins" \
            clean "Remove plugins no longer in .tmux.conf" \
            back "Back") || return 0
        case "$c" in
            tpm) systui_tmux_tpm_install || true ;;
            curated) systui_tmux_tpm_install >/dev/null 2>&1 || true; systui_tmux_manage_plugin_selection curated ;;
            github) systui_tmux_tpm_install >/dev/null 2>&1 || true; systui_tmux_manage_plugin_selection live ;;
            custom) systui_tmux_custom_plugin ;;
            install) systui_tmux_plugins_apply ;;
            update) [ -x "$tpm/bin/update_plugins" ] && "$tpm/bin/update_plugins" all || tui_msg "TPM" "TPM is not installed." ;;
            clean) [ -x "$tpm/bin/clean_plugins" ] && "$tpm/bin/clean_plugins" || tui_msg "TPM" "TPM is not installed." ;;
            back|'') return 0 ;;
        esac
    done
}

systui_tmux_config_menu() {
    local c conf
    conf=$(systui_tmux_conf); touch "$conf"
    while true; do
        c=$(tui_menu_no_tags "tmux configuration" "Config: $conf" \
            edit "Edit .tmux.conf" \
            basic "Apply basic sane defaults" \
            mouse "Toggle mouse support" \
            vi "Enable vi copy-mode keys" \
            reload "Reload active tmux configuration" \
            backup "Backup .tmux.conf" \
            back "Back") || return 0
        case "$c" in
            edit) "${EDITOR:-nano}" "$conf" ;;
            basic) cat >> "$conf" <<'EOF'

# SystUI tmux defaults
set -g history-limit 100000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -g set-clipboard on
set -g escape-time 10
EOF
                ;;
            mouse)
                if grep -Eq '^set -g mouse on' "$conf"; then sed -i 's/^set -g mouse on$/set -g mouse off/' "$conf"
                elif grep -Eq '^set -g mouse off' "$conf"; then sed -i 's/^set -g mouse off$/set -g mouse on/' "$conf"
                else printf 'set -g mouse on\n' >> "$conf"; fi ;;
            vi) grep -Eq '^setw -g mode-keys vi' "$conf" || printf 'setw -g mode-keys vi\n' >> "$conf" ;;
            reload) command -v tmux >/dev/null 2>&1 && tmux source-file "$conf" || true ;;
            backup) cp -a "$conf" "$conf.bak.$(date +%Y%m%d%H%M%S)" ;;
            back|'') return 0 ;;
        esac
    done
}

systui_tmux_sessions_menu() {
    local c name session
    command -v tmux >/dev/null 2>&1 || { tui_msg "tmux" "tmux is not installed."; return 0; }
    while true; do
        c=$(tui_menu_no_tags "tmux sessions" "$(tmux list-sessions 2>/dev/null || echo 'No running sessions')" \
            new "Create new session" attach "Attach/select session" kill "Kill selected session" killall "Kill tmux server" back "Back") || return 0
        case "$c" in
            new) name=$(tui_input "New tmux session" "Session name:" "main") || continue; [ -n "$name" ] && tmux new-session -d -s "$name" ;;
            attach)
                session=$(tmux list-sessions -F '#S' 2>/dev/null | head -1); [ -n "$session" ] || continue
                tmux attach-session -t "$session" ;;
            kill)
                session=$(tmux list-sessions -F '#S' 2>/dev/null | awk '{print $0" "$0}' | xargs 2>/dev/null) || true
                name=$(tui_input "Kill tmux session" "Session name:" "") || continue
                [ -n "$name" ] && tmux kill-session -t "$name" ;;
            killall) tui_yesno "Kill tmux server" "Terminate all tmux sessions?" && tmux kill-server || true ;;
            back|'') return 0 ;;
        esac
    done
}

menu_tmux_manager() {
    local c ver
    while true; do
        ver=$(tmux -V 2>/dev/null || echo 'not installed')
        c=$(tui_menu_no_tags "tmux manager" "tmux: $ver" \
            install "Install / update tmux — package manager + live GitHub sources" \
            plugins "Plugins — TPM, curated, live GitHub browser, custom repos" \
            config "Configuration and presets" \
            sessions "Session management" \
            version "Show tmux/plugin status" \
            remove "Remove native tmux package" \
            back "Back") || return 0
        case "$c" in
            install) systui_tmux_install_menu ;;
            plugins) systui_tmux_plugins_menu ;;
            config) systui_tmux_config_menu ;;
            sessions) systui_tmux_sessions_menu ;;
            version) tui_msg "tmux status" "tmux: $(tmux -V 2>/dev/null || echo not-installed)\nConfig: $(systui_tmux_conf)\nTPM: $([ -d "$(systui_tmux_plugin_dir)/tpm" ] && echo installed || echo not-installed)" ;;
            remove) tui_yesno "Remove tmux" "Remove tmux through the native package manager?" && pm_remove tmux || true ;;
            back|'') return 0 ;;
        esac
    done
}

if declare -F menu_shells >/dev/null 2>&1 && ! declare -F _systui_shells_before_tmux_overhaul >/dev/null 2>&1; then
    _systui_tmux_shell_def=$(declare -f menu_shells)
    _systui_tmux_shell_def=${_systui_tmux_shell_def/#menu_shells ()/_systui_shells_before_tmux_overhaul ()}
    _systui_tmux_shell_def=${_systui_tmux_shell_def/#menu_shells()/_systui_shells_before_tmux_overhaul()}
    eval "$_systui_tmux_shell_def"
    unset _systui_tmux_shell_def
fi

menu_shells() {
    local c
    while true; do
        c=$(tui_menu_no_tags "Shells & terminal environment" "Shell configuration and terminal multiplexing:" \
            shells "Shells, prompts and shell plugins" \
            tmux "tmux manager — installation, sessions, config and plugins" \
            back "Back") || return 0
        case "$c" in
            shells) declare -F _systui_shells_before_tmux_overhaul >/dev/null 2>&1 && _systui_shells_before_tmux_overhaul ;;
            tmux) menu_tmux_manager ;;
            back|'') return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
