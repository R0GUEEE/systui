# shellcheck shell=bash
# PHASE 97 — final curated software-collection registry and installer.
# Keep curated collections independent from legacy load-order/global-state loss.

systui_catalogue_collections_ensure() {
    # Recreate the collection registry if a legacy/late feature lost it.
    if ! declare -p CAT_COLLECTIONS >/dev/null 2>&1; then
        declare -gA CAT_COLLECTIONS=()
    fi

    [ -n "${CAT_COLLECTIONS[ish]:-}" ] || CAT_COLLECTIONS[ish]="curl wget git nano bash-completion openssh-server tmux htop jq unzip zip rsync"
    [ -n "${CAT_COLLECTIONS[developer]:-}" ] || CAT_COLLECTIONS[developer]="build-essential gcc make cmake git python3 python3-pip nodejs npm go rust cargo gdb pkg-config"
    [ -n "${CAT_COLLECTIONS[terminal]:-}" ] || CAT_COLLECTIONS[terminal]="tmux fzf ripgrep fd-find bat jq yq zoxide ranger nnn mc lf lazygit tig"
    [ -n "${CAT_COLLECTIONS[server]:-}" ] || CAT_COLLECTIONS[server]="openssh-server curl wget rsync nginx chrony logrotate tmux htop"
    [ -n "${CAT_COLLECTIONS[network]:-}" ] || CAT_COLLECTIONS[network]="openssh-client nmap tcpdump mtr traceroute dnsutils netcat-openbsd socat iperf3 rsync curl wget"
    [ -n "${CAT_COLLECTIONS[security]:-}" ] || CAT_COLLECTIONS[security]="gnupg openssl fail2ban clamav lynis aide nftables sudo"
    [ -n "${CAT_COLLECTIONS[python]:-}" ] || CAT_COLLECTIONS[python]="python3 python3-pip python3-venv python3-dev build-essential git"
    [ -n "${CAT_COLLECTIONS[rust]:-}" ] || CAT_COLLECTIONS[rust]="rust cargo build-essential pkg-config openssl git"
    [ -n "${CAT_COLLECTIONS[cpp]:-}" ] || CAT_COLLECTIONS[cpp]="build-essential gcc g++ make cmake ninja-build gdb clang lldb pkg-config git"
    [ -n "${CAT_COLLECTIONS[web]:-}" ] || CAT_COLLECTIONS[web]="nodejs npm python3 python3-pip git curl wget nginx sqlite3"
    [ -n "${CAT_COLLECTIONS[backup]:-}" ] || CAT_COLLECTIONS[backup]="rsync rclone restic tar gzip bzip2 xz-utils zstd zip unzip"
}

systui_catalogue_collection_title() {
    case "$1" in
        ish)       printf 'iSH-AOK essentials\n' ;;
        developer) printf 'Developer workstation\n' ;;
        terminal)  printf 'Terminal power user\n' ;;
        server)    printf 'Minimal server\n' ;;
        network)   printf 'Networking toolkit\n' ;;
        security)  printf 'Security toolkit\n' ;;
        python)    printf 'Python development\n' ;;
        rust)      printf 'Rust development\n' ;;
        cpp)       printf 'C/C++ development\n' ;;
        web)       printf 'Web development\n' ;;
        backup)    printf 'Backup toolkit\n' ;;
        *)         printf '%s\n' "$1" ;;
    esac
}

catalogue_collections() {
    local c keys k native state picks mapped
    local -a menu_opts=() check_opts=() pkgs=()

    systui_catalogue_collections_ensure
    declare -F systui_catalogue_registry_ensure >/dev/null 2>&1 \
        && systui_catalogue_registry_ensure >/dev/null 2>&1 || true

    menu_opts=(
        ish       "iSH-AOK essentials"
        developer "Developer workstation"
        terminal  "Terminal power user"
        server    "Minimal server"
        network   "Networking toolkit"
        security  "Security toolkit"
        python    "Python development"
        rust      "Rust development"
        cpp       "C/C++ development"
        web       "Web development"
        backup    "Backup toolkit"
        back      "Back"
    )

    while true; do
        c=$(tui_menu_no_tags "Curated software collections" \
            "Choose a collection, then select the packages to install:" \
            "${menu_opts[@]}") || return 0
        case "$c" in back|'') return 0 ;; esac

        keys="${CAT_COLLECTIONS[$c]:-}"
        if [ -z "${keys//[[:space:]]/}" ]; then
            tui_msg "Software collection" "The collection '$(systui_catalogue_collection_title "$c")' has no package definitions."
            continue
        fi

        check_opts=()
        for k in $keys; do
            native=$(app_native_name "$k" 2>/dev/null || printf SKIP)
            [ -n "$native" ] && [ "$native" != SKIP ] || continue
            if is_pkg_installed "$native" 2>/dev/null; then
                state=off
                check_opts+=("$k" "$native [installed]" "$state")
            else
                state=on
                check_opts+=("$k" "$native" "$state")
            fi
        done

        if [ "${#check_opts[@]}" -eq 0 ]; then
            tui_msg "Software collection" "No packages in '$(systui_catalogue_collection_title "$c")' are available through ${PM:-the current package manager}."
            continue
        fi

        picks=$(tui_check "$(systui_catalogue_collection_title "$c")" \
            "SPACE toggles packages. Missing packages start selected; already-installed packages start unselected." \
            "${check_opts[@]}") || continue
        picks=${picks//\"/}
        [ -n "${picks//[[:space:]]/}" ] || { tui_msg "No selection" "No packages were selected."; continue; }

        mapped=""
        pkgs=()
        for k in $picks; do
            native=$(app_native_name "$k" 2>/dev/null || printf SKIP)
            [ -n "$native" ] && [ "$native" != SKIP ] || continue
            mapped+="${mapped:+ }$native"
        done
        [ -n "$mapped" ] || { tui_msg "No installable packages" "The selected entries do not map to packages for ${PM:-this system}."; continue; }

        if ! parse_package_input "$mapped" pkgs; then
            tui_msg "Software collection" "Could not parse the selected package set."
            continue
        fi

        if tui_yesno "Install collection" "Install ${#pkgs[@]} selected package(s)?\n\n${pkgs[*]}"; then
            pm_install "${pkgs[@]}" || tui_msg "Collection install" "One or more packages failed to install. Review the Systui log for details."
        fi
        show_warnings
    done
}

# Populate immediately as well as lazily so callers that inspect the registry
# directly see valid collections.
systui_catalogue_collections_ensure

return 0 2>/dev/null || true
