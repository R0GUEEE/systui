# shellcheck shell=bash
# PHASE 95 — final software catalogue registry/runtime repair.
#
# The catalogue historically lived as large shell globals in sysconfig.sh.
# Late feature overrides must never make the UI depend on those globals being
# perfectly preserved. Validate them at menu entry, rebuild category ordering,
# and seed a conservative built-in registry only when the legacy data is gone.

systui_catalogue_seed_fallback() {
    declare -gA CAT_APPS
    CAT_APPS[internet]=$'firefox|Firefox|Mozilla web browser\nchromium|Chromium|Open-source web browser\nthunderbird|Thunderbird|Email and calendar client\ncurl|curl|URL transfer utility\nwget|wget|Network downloader'
    CAT_APPS[multimedia]=$'vlc|VLC|General-purpose media player\nmpv|mpv|Scriptable media player\nffmpeg|FFmpeg|Audio/video conversion toolkit\nyt-dlp|yt-dlp|Command-line media downloader\nsox|SoX|Audio processing toolkit'
    CAT_APPS[graphics]=$'gimp|GIMP|Raster image editor\ninkscape|Inkscape|Vector graphics editor\nkrita|Krita|Digital painting\nblender|Blender|3D modelling and rendering\nimagemagick|ImageMagick|Image conversion toolkit'
    CAT_APPS[office]=$'libreoffice|LibreOffice|Office suite\nkeepassxc|KeePassXC|Password manager\nnewsboat|Newsboat|Terminal RSS reader\ncalcurse|Calcurse|Terminal calendar\ntaskwarrior|Taskwarrior|Command-line task manager'
    CAT_APPS[development]=$'build-essential|Build toolchain|Compiler and build tools\ngcc|GCC|GNU C compiler\nclang|Clang|LLVM C/C++ compiler\ncmake|CMake|Cross-platform build generator\nmake|GNU Make|Build automation\npython3|Python 3|Python interpreter\npython3-pip|pip|Python package installer\nnodejs|Node.js|JavaScript runtime\nnpm|npm|Node package manager\ngo|Go|Go compiler and tools\nrust|Rust|Rust compiler\ncargo|Cargo|Rust package manager\ngit|Git|Version control'
    CAT_APPS[terminal]=$'tmux|tmux|Terminal multiplexer\nscreen|GNU Screen|Terminal multiplexer\nfzf|fzf|Fuzzy finder\nripgrep|ripgrep|Fast recursive search\nfd-find|fd|Fast find alternative\nbat|bat|Highlighted cat replacement\njq|jq|JSON processor\nranger|Ranger|Console file manager\nnnn|nnn|Terminal file manager\nmc|Midnight Commander|Terminal file manager'
    CAT_APPS[editors]=$'nano|Nano|Simple terminal editor\nvim|Vim|Modal editor\nneovim|Neovim|Extensible Vim-based editor\nmicro|Micro|Modern terminal editor\nemacs|Emacs|Extensible editor'
    CAT_APPS[shells]=$'bash|Bash|GNU shell\nbash-completion|Bash Completion|Completion definitions\nzsh|Zsh|Interactive shell\nfish|Fish|Friendly interactive shell\nksh|KornShell|Korn shell\nmksh|MirBSD Korn Shell|Compact Korn shell\nstarship|Starship|Cross-shell prompt'
    CAT_APPS[network]=$'openssh-server|OpenSSH Server|SSH server\nopenssh-client|OpenSSH Client|SSH client tools\nnmap|Nmap|Network scanner\ntcpdump|tcpdump|Packet capture\nmtr|MTR|Ping/traceroute tool\ndnsutils|DNS utilities|dig and nslookup\nsocat|socat|Bidirectional data relay\niperf3|iperf3|Network performance test\nrsync|rsync|Remote file synchronization'
    CAT_APPS[security]=$'gnupg|GnuPG|OpenPGP tools\nopenssl|OpenSSL|TLS/cryptography toolkit\nfail2ban|Fail2ban|Authentication abuse blocker\nclamav|ClamAV|Antivirus scanner\nlynis|Lynis|Security auditing\naide|AIDE|File integrity monitor\nnftables|nftables|Packet filtering\nsudo|sudo|Delegated privilege execution'
    CAT_APPS[monitoring]=$'htop|htop|Process viewer\nbtop|btop|Resource monitor\niotop|iotop|I/O monitor\nncdu|ncdu|Disk usage browser\nduf|duf|Filesystem usage overview\nlsof|lsof|Open files\nstrace|strace|System call tracer\nsysstat|sysstat|Performance tools\nfastfetch|Fastfetch|System summary\nstress-ng|stress-ng|System stress tester'
    CAT_APPS[servers]=$'nginx|Nginx|Web/reverse proxy server\napache2|Apache HTTP Server|Web server\nlighttpd|Lighttpd|Lightweight web server\nopenssh-server|OpenSSH Server|SSH service\nrsyslog|rsyslog|System logging daemon\nchrony|Chrony|Clock synchronization'
    CAT_APPS[containers]=$'docker.io|Docker|Container engine\npodman|Podman|Daemonless containers\ncontainerd|containerd|Container runtime\nskopeo|skopeo|Container image transport\nbuildah|Buildah|OCI image builder\nrunc|runc|OCI runtime\nqemu|QEMU|Machine emulator'
    CAT_APPS[backup]=$'rclone|rclone|Cloud/file synchronization\nrsync|rsync|File synchronization\nrestic|Restic|Encrypted backup tool\nborgbackup|BorgBackup|Deduplicating backups\ntar|tar|Archive utility'
    CAT_APPS[files]=$'tree|tree|Directory tree viewer\nfile|file|File type detection\nrsync|rsync|File synchronization\nzip|zip|ZIP archiver\nunzip|unzip|ZIP extractor\nxz-utils|xz|XZ compression\nzstd|zstd|Zstandard compression'
    CAT_APPS[systemtools]=$'procps|procps|Process utilities\nutil-linux|util-linux|Core system utilities\ncoreutils|coreutils|GNU core utilities\nless|less|Pager\nman-db|Manual pages|Manual page reader\ntmux|tmux|Terminal multiplexer\ncron|Cron|Scheduled jobs'
    CAT_APPS[games]=$'minetest|Luanti|Open voxel game engine\nwesnoth|Battle for Wesnoth|Turn-based strategy\nsupertuxkart|SuperTuxKart|Kart racing game'
}

systui_catalogue_registry_count() {
    local cat count=0
    if ! declare -p CAT_APPS >/dev/null 2>&1; then
        printf '0\n'; return 0
    fi
    for cat in "${!CAT_APPS[@]}"; do
        [ -n "${CAT_APPS[$cat]:-}" ] && count=$((count + 1))
    done
    printf '%s\n' "$count"
}

systui_catalogue_rebuild_order() {
    local preferred cat out=""
    preferred='internet multimedia graphics office development terminal editors shells network security monitoring servers containers backup files systemtools games'
    for cat in $preferred; do
        [ -n "${CAT_APPS[$cat]:-}" ] || continue
        out+="${out:+ }$cat"
    done
    for cat in "${!CAT_APPS[@]}"; do
        [ -n "${CAT_APPS[$cat]:-}" ] || continue
        case " $out " in *" $cat "*) ;; *) out+="${out:+ }$cat" ;; esac
    done
    CAT_ORDER="$out"
    export CAT_ORDER
}

systui_catalogue_ensure_registry() {
    local count
    count=$(systui_catalogue_registry_count)
    if [ "$count" -eq 0 ]; then
        systui_catalogue_seed_fallback
        count=$(systui_catalogue_registry_count)
        log "software-catalogue: legacy registry missing; seeded $count fallback categories" 2>/dev/null || true
    fi
    systui_catalogue_rebuild_order
    [ -n "${FEATURED_APPS:-}" ] || FEATURED_APPS='firefox git htop tmux neovim python3 nodejs docker.io'
    [ -n "$CAT_ORDER" ] && [ "$count" -gt 0 ]
}

systui_catalogue_category_data() { # <category> [featured-keys]
    local cat="$1" keys="${2:-}" k line data=""
    systui_catalogue_ensure_registry || return 1
    if [ -n "$keys" ]; then
        for k in $keys; do
            line=$(catalogue_find_line "$k" 2>/dev/null || true)
            [ -n "$line" ] && data+="$line"$'\n'
        done
    else
        data="${CAT_APPS[$cat]:-}"
    fi
    printf '%s' "$data"
}

# Replace the renderer so it never relies on an unset associative-array index.
# Keep the existing install/remove semantics, but filter entries that genuinely
# cannot map to the current package manager instead of presenting a dead row.
browse_category() {
    local cat="$1" data key name desc state installed="" picks k native
    data=$(systui_catalogue_category_data "$cat" "${2:-}" 2>/dev/null || true)
    [ -n "$data" ] || {
        tui_msg "Software Catalogue" "Category '$cat' has no registry entries. The catalogue registry was rebuilt, but this category is still empty."
        return 0
    }

    while true; do
        local -a args=()
        installed=""
        while IFS='|' read -r key name desc; do
            [ -n "$key" ] || continue
            native=$(app_native_name "$key" 2>/dev/null || printf SKIP)
            [ -n "$native" ] && [ "$native" != SKIP ] || continue
            if [ "$(app_status "$key")" = installed ]; then
                state=on; installed+="${installed:+ }$key"
            else
                state=off
            fi
            args+=("$key" "$name — $desc [$native]" "$state")
        done <<< "$data"

        [ "${#args[@]}" -gt 0 ] || {
            tui_msg "Software Catalogue" "No entries in '$cat' map to the current package manager (${PM:-unknown})."
            return 0
        }
        args+=(show-details "» Show details for one item" off)
        picks=$(tui_check "$(cat_title "$cat")" "SPACE toggles packages; package names are mapped for ${PM:-unknown}." "${args[@]}") || return 0
        picks=${picks//\"/}

        case " $picks " in
            *" show-details "*)
                local -a details=()
                local sel line
                while IFS='|' read -r key name desc; do
                    [ -n "$key" ] || continue
                    native=$(app_native_name "$key" 2>/dev/null || printf SKIP)
                    [ "$native" = SKIP ] && continue
                    details+=("$key" "$name [$native]")
                done <<< "$data"
                sel=$(tui_menu_no_tags "Software details" "Select an application:" "${details[@]}" __back "Back") || continue
                [ "$sel" = __back ] && continue
                line=$(grep -m1 "^${sel}|" <<< "$data" || true)
                [ -n "$line" ] && app_page "$sel" "$(cut -d'|' -f2 <<< "$line")" "$(cut -d'|' -f3- <<< "$line")"
                continue
                ;;
        esac

        local to_install="" to_remove=""
        for k in $picks; do
            [ "$k" = show-details ] && continue
            case " $installed " in *" $k "*) ;; *)
                native=$(app_native_name "$k" 2>/dev/null || printf SKIP)
                [ "$native" != SKIP ] && to_install+="${to_install:+ }$native"
                ;;
            esac
        done
        for k in $installed; do
            case " $picks " in *" $k "*) ;; *)
                native=$(app_native_name "$k" 2>/dev/null || printf SKIP)
                [ "$native" != SKIP ] && to_remove+="${to_remove:+ }$native"
                ;;
            esac
        done
        [ -z "$to_install" ] || { local -a ipkgs=(); read -r -a ipkgs <<< "$to_install"; pm_install "${ipkgs[@]}" || true; }
        if [ -n "$to_remove" ] && tui_yesno "Remove unchecked software" "Remove these installed packages?\n\n$to_remove"; then
            local -a rpkgs=(); read -r -a rpkgs <<< "$to_remove"; pm_remove "${rpkgs[@]}" || true
        fi
        [ -n "$to_install$to_remove" ] || tui_msg "No changes" "The selection matches the installed state."
    done
}

# Final catalogue front door. Validate the registry on every entry so a late
# feature cannot leave the UI with zero categories. Awesome Linux remains an
# optional secondary catalogue, not a wrapper around the Systui registry.
pkg_catalogue() {
    local detected c cat
    local -a args=()
    systui_catalogue_ensure_registry || {
        tui_msg "Software Catalogue" "Unable to initialize the software registry."
        return 1
    }
    detected=$(systui_catalogue_pm 2>/dev/null || printf unknown)
    PM="$detected"; export PM
    [ "$PM" != unknown ] || {
        tui_msg "Software Catalogue" "No supported native package manager was detected."
        return 0
    }

    while true; do
        args=(featured "Featured software" collections "Curated collections")
        for cat in $CAT_ORDER; do
            [ -n "${CAT_APPS[$cat]:-}" ] || continue
            args+=("$cat" "$(cat_title "$cat")")
        done
        args+=(cli "Terminal-tool checklists" installed "Installed catalogue software" search "Search repositories")
        declare -F menu_awesome_linux >/dev/null 2>&1 && args+=(awesome "Awesome Linux catalogue")
        args+=(back "Back")

        c=$(tui_menu "Software Catalogue [$PM]" "${#CAT_APPS[@]} registry categories loaded. Select a category:" "${args[@]}") || return 0
        case "$c" in
            featured) browse_category featured "$FEATURED_APPS" ;;
            collections) catalogue_collections ;;
            cli) pkg_catalogue_cli ;;
            installed) catalogue_installed ;;
            search) catalogue_search ;;
            awesome) menu_awesome_linux ;;
            back|'') return 0 ;;
            *) browse_category "$c" ;;
        esac
    done
}

# The old Awesome integration captured pkg_catalogue before the final catalogue
# phases existed. Repoint that compatibility alias at the final native menu so
# no legacy caller can open a stale/empty snapshot.
_systui_base_pkg_catalogue() { pkg_catalogue "$@"; }

return 0 2>/dev/null || true
