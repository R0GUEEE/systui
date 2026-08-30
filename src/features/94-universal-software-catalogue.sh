# shellcheck shell=bash
# PHASE 94 — universal software catalogue package resolution.
#
# The catalogue stores stable Debian-style/canonical keys, but installation,
# status and package metadata must be resolved through the host package manager.
# This phase is intentionally package-manager driven instead of distro-name
# driven, so derivatives automatically inherit the correct behavior.

systui_catalogue_pm() {
    if [ -n "${PM:-}" ] && [ "${PM:-unknown}" != unknown ]; then
        printf '%s\n' "$PM"
        return 0
    fi
    command -v apt-get >/dev/null 2>&1 && { printf 'apt\n'; return 0; }
    command -v apk >/dev/null 2>&1 && { printf 'apk\n'; return 0; }
    command -v pacman >/dev/null 2>&1 && { printf 'pacman\n'; return 0; }
    command -v dnf >/dev/null 2>&1 && { printf 'dnf\n'; return 0; }
    command -v yum >/dev/null 2>&1 && { printf 'yum\n'; return 0; }
    command -v zypper >/dev/null 2>&1 && { printf 'zypper\n'; return 0; }
    command -v xbps-install >/dev/null 2>&1 && { printf 'xbps\n'; return 0; }
    command -v emerge >/dev/null 2>&1 && { printf 'emerge\n'; return 0; }
    printf 'unknown\n'
    return 1
}

systui_catalogue_first_word() {
    local s="${1:-}"
    set -- $s
    printf '%s\n' "${1:-}"
}

systui_catalogue_map_opensuse() { # <canonical-key>
    case "$1" in
        build-essential) printf 'patterns-devel-base-devel_basis\n' ;;
        g++) printf 'gcc-c++\n' ;;
        python3-dev) printf 'python3-devel\n' ;;
        python3-venv) printf 'python3\n' ;;
        python3-pip) printf 'python3-pip\n' ;;
        pkg-config) printf 'pkgconf-pkg-config\n' ;;
        openssh-server|openssh-client) printf 'openssh\n' ;;
        dnsutils|dig|host|nslookup) printf 'bind-utils\n' ;;
        docker.io) printf 'docker\n' ;;
        redis-server) printf 'redis\n' ;;
        postgresql-client) printf 'postgresql\n' ;;
        mysql-client) printf 'mariadb-client\n' ;;
        java-default-jdk) printf 'java-21-openjdk-devel\n' ;;
        qemu-system) printf 'qemu\n' ;;
        fd-find) printf 'fd\n' ;;
        xz-utils) printf 'xz\n' ;;
        p7zip-full) printf '7zip\n' ;;
        netcat-openbsd) printf 'netcat-openbsd\n' ;;
        docker-compose) printf 'docker-compose\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

systui_catalogue_map_gentoo() { # <canonical-key>
    case "$1" in
        build-essential) printf 'sys-devel/gcc\n' ;;
        gcc) printf 'sys-devel/gcc\n' ;;
        g++) printf 'sys-devel/gcc\n' ;;
        pkg-config) printf 'dev-util/pkgconf\n' ;;
        python3|python3-dev|python3-venv) printf 'dev-lang/python\n' ;;
        python3-pip) printf 'dev-python/pip\n' ;;
        openssh-server|openssh-client) printf 'net-misc/openssh\n' ;;
        dnsutils|dig|host|nslookup) printf 'net-dns/bind-tools\n' ;;
        docker.io) printf 'app-containers/docker\n' ;;
        docker-compose) printf 'app-containers/docker-compose\n' ;;
        qemu|qemu-system) printf 'app-emulation/qemu\n' ;;
        java-default-jdk) printf 'virtual/jdk\n' ;;
        postgresql-client) printf 'dev-db/postgresql\n' ;;
        mysql-client|mariadb-server) printf 'dev-db/mariadb\n' ;;
        redis-server|redis-tools) printf 'dev-db/redis\n' ;;
        fd-find) printf 'sys-apps/fd\n' ;;
        ripgrep) printf 'sys-apps/ripgrep\n' ;;
        xz-utils) printf 'app-arch/xz-utils\n' ;;
        p7zip-full) printf 'app-arch/p7zip\n' ;;
        netcat-openbsd) printf 'net-analyzer/netcat\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
}

systui_catalogue_map_one() { # <pm> <canonical-key>
    local pm="$1" key="$2" mapped=""
    [ -n "$key" ] || return 1
    [ "$key" = SKIP ] && { printf 'SKIP\n'; return 0; }

    case "$pm" in
        apt)
            if [ -n "${APT_CANDIDATES[$key]:-}" ]; then
                local candidate
                for candidate in ${APT_CANDIDATES[$key]}; do
                    if ! command -v apt-cache >/dev/null 2>&1 || apt-cache show "$candidate" >/dev/null 2>&1; then
                        printf '%s\n' "$candidate"
                        return 0
                    fi
                done
                systui_catalogue_first_word "${APT_CANDIDATES[$key]}"
                return 0
            fi
            case "$key" in
                go) printf 'golang-go\n' ;;
                docker) printf 'docker.io\n' ;;
                pip|pip3) printf 'python3-pip\n' ;;
                gem) printf 'ruby\n' ;;
                *) printf '%s\n' "$key" ;;
            esac
            ;;
        apk)
            if declare -F map_packages >/dev/null 2>&1; then mapped=$(map_packages alpine "$key" 2>/dev/null || true); fi
            mapped=$(systui_catalogue_first_word "$mapped")
            [ -n "$mapped" ] && [ "$mapped" != SKIP ] && printf '%s\n' "$mapped" || printf 'SKIP\n'
            ;;
        pacman)
            if declare -F map_packages >/dev/null 2>&1; then mapped=$(map_packages arch "$key" 2>/dev/null || true); fi
            mapped=$(systui_catalogue_first_word "$mapped")
            [ -n "$mapped" ] && [ "$mapped" != SKIP ] && printf '%s\n' "$mapped" || printf 'SKIP\n'
            ;;
        dnf|yum)
            if declare -F map_packages >/dev/null 2>&1; then mapped=$(map_packages fedora "$key" 2>/dev/null || true); fi
            mapped=$(systui_catalogue_first_word "$mapped")
            [ -n "$mapped" ] && [ "$mapped" != SKIP ] && printf '%s\n' "$mapped" || printf 'SKIP\n'
            ;;
        xbps)
            if declare -F map_packages >/dev/null 2>&1; then mapped=$(map_packages void "$key" 2>/dev/null || true); fi
            mapped=$(systui_catalogue_first_word "$mapped")
            [ -n "$mapped" ] && [ "$mapped" != SKIP ] && printf '%s\n' "$mapped" || printf 'SKIP\n'
            ;;
        zypper) systui_catalogue_map_opensuse "$key" ;;
        emerge) systui_catalogue_map_gentoo "$key" ;;
        *) printf 'SKIP\n' ;;
    esac
}

# Public mapper used by catalogue checklists and legacy system-configuration
# paths. Map every token independently and omit unsupported entries.
local_pkg_map() {
    local pm p mapped out=""
    pm=$(systui_catalogue_pm 2>/dev/null || printf unknown)
    for p in "$@"; do
        mapped=$(systui_catalogue_map_one "$pm" "$p" 2>/dev/null || true)
        [ -n "$mapped" ] && [ "$mapped" != SKIP ] || continue
        out+="${out:+ }$mapped"
    done
    printf '%s\n' "$out"
}

app_native_name() {
    local pm
    pm=$(systui_catalogue_pm 2>/dev/null || printf unknown)
    systui_catalogue_map_one "$pm" "$1"
}

app_status() {
    local native
    native=$(app_native_name "$1" 2>/dev/null || printf SKIP)
    [ -n "$native" ] && [ "$native" != SKIP ] || { printf 'unavailable\n'; return 0; }
    if is_pkg_installed "$native"; then printf 'installed\n'; else printf 'available\n'; fi
}

pkg_show_info() {
    case "$(systui_catalogue_pm 2>/dev/null || printf unknown)" in
        apt) apt-cache show "$1" 2>&1 | head -80 ;;
        apk) apk info -a "$1" 2>&1 | head -80 ;;
        pacman) { pacman -Si "$1" 2>/dev/null || pacman -Qi "$1"; } 2>&1 | head -80 ;;
        dnf) dnf info "$1" 2>&1 | head -80 ;;
        yum) yum info "$1" 2>&1 | head -80 ;;
        zypper) zypper --non-interactive info "$1" 2>&1 | head -80 ;;
        xbps) xbps-query -R "$1" 2>&1 | head -80 ;;
        emerge) emerge --search "$1" 2>&1 | head -80 ;;
        *) printf 'No supported package metadata backend.\n'; return 1 ;;
    esac
}

pkg_list_files() {
    case "$(systui_catalogue_pm 2>/dev/null || printf unknown)" in
        apt) dpkg -L "$1" ;;
        apk) apk info -L "$1" ;;
        pacman) pacman -Ql "$1" ;;
        dnf|yum|zypper) rpm -ql "$1" ;;
        xbps) xbps-query -f "$1" ;;
        emerge)
            if command -v qlist >/dev/null 2>&1; then qlist "$1"
            elif command -v equery >/dev/null 2>&1; then equery files "$1"
            else printf 'Install app-portage/portage-utils for installed-file listing on Gentoo.\n'; return 1; fi
            ;;
        *) return 1 ;;
    esac
}

pkg_reinstall() {
    case "$(systui_catalogue_pm 2>/dev/null || printf unknown)" in
        apt) run_cmd "Reinstall $1" apt-get install --reinstall -y -- "$1" ;;
        apk) run_cmd "Reinstall $1" apk fix --reinstall -- "$1" ;;
        pacman) run_cmd "Reinstall $1" pacman -S --noconfirm --needed -- "$1" ;;
        dnf) run_cmd "Reinstall $1" dnf reinstall -y -- "$1" ;;
        yum) run_cmd "Reinstall $1" yum reinstall -y -- "$1" ;;
        zypper) run_cmd "Reinstall $1" zypper --non-interactive install --force -- "$1" ;;
        xbps) run_cmd "Reinstall $1" xbps-install -fy -- "$1" ;;
        emerge) run_cmd "Reinstall $1" emerge --ask=n --oneshot "$1" ;;
        *) return 1 ;;
    esac
}

pkg_hold_toggle() {
    local p="$1" pm
    pm=$(systui_catalogue_pm 2>/dev/null || printf unknown)
    case "$pm" in
        apt)
            if apt-mark showhold | grep -qx "$p"; then run_cmd "Unhold $p" apt-mark unhold "$p"
            else run_cmd "Hold $p" apt-mark hold "$p"; fi
            ;;
        apk) tui_msg "Package hold" "Pin '$p' to an exact version or repository tag in /etc/apk/world." ;;
        pacman) tui_msg "Package hold" "Add '$p' to IgnorePkg in /etc/pacman.conf." ;;
        dnf|yum) tui_msg "Package hold" "Use versionlock for '$p' (dnf/yum versionlock plugin)." ;;
        zypper)
            if zypper --non-interactive locks 2>/dev/null | awk -F'|' -v p="$p" '{gsub(/^[ \t]+|[ \t]+$/, "", $2); if ($2==p) found=1} END{exit !found}'; then
                run_cmd "Unlock $p" zypper --non-interactive removelock "$p"
            else
                run_cmd "Lock $p" zypper --non-interactive addlock "$p"
            fi
            ;;
        xbps) tui_msg "Package hold" "Use 'xbps-pkgdb -m hold $p' to hold and '-m unhold' to release it." ;;
        emerge) tui_msg "Package hold" "Use /etc/portage/package.mask or package.accept_keywords for '$p'." ;;
        *) tui_msg "Package hold" "Package locking is unavailable for the detected package manager." ;;
    esac
}

# Keep the catalogue itself usable when PM was stale/unknown at startup.
pkg_catalogue() {
    local detected c args cat
    detected=$(systui_catalogue_pm 2>/dev/null || printf unknown)
    PM="$detected"
    export PM
    if [ "$PM" = unknown ]; then
        tui_msg "Software Catalogue" "No supported system package manager was detected.\n\nSupported native backends: APT, apk, pacman, dnf, yum, zypper, XBPS and Portage."
        return 0
    fi

    while true; do
        args=(featured "* Featured software" collections "Curated one-click collections")
        for cat in $CAT_ORDER; do args+=("$cat" "$(cat_title "$cat")"); done
        args+=(cli "Terminal-tool checklists" installed "Installed catalogue software" updates "Available updates" search "Search all repositories" bulk "Bulk actions and package lists" health "Package health and repair" back "Back")
        c=$(tui_menu "Software Catalogue  [$PM]" "Browse, install and manage software using the native $PM backend:" "${args[@]}") || return 0
        case "$c" in
            featured) browse_category featured "$FEATURED_APPS" ;;
            collections) catalogue_collections ;;
            cli) pkg_catalogue_cli ;;
            installed) catalogue_installed ;;
            updates) catalogue_updates ;;
            search) catalogue_search ;;
            bulk) catalogue_bulk_manage ;;
            health) catalogue_health ;;
            back|'') return 0 ;;
            *) browse_category "$c" ;;
        esac
    done
}

return 0 2>/dev/null || true
