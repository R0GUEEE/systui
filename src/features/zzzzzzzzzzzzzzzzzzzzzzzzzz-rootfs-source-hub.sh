# shellcheck shell=bash
###############################################################################
# ROOTFS SOURCE HUB — aggregate as many live rootfs repositories as practical
###############################################################################

rootfs_source_pick() { # <title> <prompt> <newline-items>
    local title="$1" prompt="$2" data="$3" item
    local -a opts=()
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        opts+=("$item" "$item")
    done <<< "$data"
    [ ${#opts[@]} -gt 0 ] || return 1
    tui_menu_no_tags "$title" "$prompt" "${opts[@]}"
}

rootfs_source_fetch_dirs() { # <url>
    rootfs_web_dirs "$1" 2>/dev/null
}

rootfs_source_fetch_files() { # <url>
    rootfs_web_files "$1" 2>/dev/null
}

rootfs_source_ubuntu_base() {
    local base='https://cdimage.ubuntu.com/ubuntu-base/releases' rel html file arch
    local releases files arches
    releases=$(rootfs_source_fetch_dirs "$base" | grep -E '^[0-9]{2}\.[0-9]{2}(\.[0-9]+)?$|^[a-z][a-z0-9-]+$' | sort -Vr)
    rel=$(rootfs_source_pick 'Ubuntu Base' 'Release / codename:' "$releases") || return 0
    html=$(rootfs_fetch_text "$base/$rel/release/" 2>/dev/null) || { tui_msg 'Ubuntu Base' 'Unable to read selected release.'; return 1; }
    files=$(printf '%s\n' "$html" | grep -oE 'ubuntu-base-[^"<> ]+-base-(amd64|arm64|armhf|ppc64el|riscv64|s390x)\.tar\.gz' | sort -u)
    arches=$(printf '%s\n' "$files" | sed -E 's/.*-base-([^.]+)\.tar\.gz/\1/' | sort -u)
    arch=$(rootfs_source_pick "Ubuntu Base $rel" 'Architecture:' "$arches") || return 0
    file=$(printf '%s\n' "$files" | grep -E "-base-${arch}\\.tar\\.gz$" | sort -V | tail -1)
    [ -n "$file" ] || return 1
    rootfs_download_import_url "$base/$rel/release/$file" ubuntu "$rel" "$arch" official-ubuntu-base
}

rootfs_source_alpine() {
    local base='https://dl-cdn.alpinelinux.org/alpine' branch arch html file native
    local branches arches
    branches=$(rootfs_source_fetch_dirs "$base" | grep -E '^v[0-9]+\.[0-9]+$|^latest-stable$|^edge$' | sort -Vr)
    branch=$(rootfs_source_pick 'Alpine minirootfs' 'Release branch:' "$branches") || return 0
    arches=$(rootfs_source_fetch_dirs "$base/$branch/releases")
    arch=$(rootfs_source_pick "Alpine $branch" 'Architecture:' "$arches") || return 0
    html=$(rootfs_fetch_text "$base/$branch/releases/$arch/" 2>/dev/null) || return 1
    file=$(printf '%s\n' "$html" | grep -oE "alpine-minirootfs-[^\"<> ]+-${arch}\\.tar\\.gz" | sort -V | tail -1)
    [ -n "$file" ] || { tui_msg 'Alpine' 'No minirootfs tarball found for this architecture.'; return 1; }
    case "$arch" in x86_64) native=amd64 ;; aarch64) native=arm64 ;; x86) native=i386 ;; armv7) native=armhf ;; *) native="$arch" ;; esac
    rootfs_download_import_url "$base/$branch/releases/$arch/$file" alpine "$branch" "$native" official-alpine
}

rootfs_source_void() {
    local base='https://repo-default.voidlinux.org/live/current' html file choice arch variant
    local files
    html=$(rootfs_fetch_text "$base/" 2>/dev/null) || return 1
    files=$(printf '%s\n' "$html" | grep -oE 'void-[A-Za-z0-9_-]+-ROOTFS-[0-9]+\.tar\.xz' | sort -u)
    file=$(rootfs_source_pick 'Void Linux ROOTFS' 'Official ROOTFS image:' "$files") || return 0
    arch=$(printf '%s\n' "$file" | sed -E 's/^void-([^-]+).*/\1/')
    variant=glibc; printf '%s\n' "$file" | grep -q -- '-musl-' && variant=musl
    rootfs_download_import_url "$base/$file" void current "$arch" "official-void-$variant"
}

rootfs_source_arch() {
    local choice arch url
    choice=$(tui_menu 'Arch rootfs' 'Official/bootstrap root filesystems:' \
        x86_64 'Arch Linux bootstrap — x86_64' \
        aarch64 'Arch Linux ARM — aarch64' \
        armv7 'Arch Linux ARM — armv7' \
        back 'Back') || return 0
    case "$choice" in
        x86_64) arch=amd64; url='https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst' ;;
        aarch64) arch=arm64; url='http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz' ;;
        armv7) arch=armhf; url='http://os.archlinuxarm.org/os/ArchLinuxARM-armv7-latest.tar.gz' ;;
        *) return 0 ;;
    esac
    rootfs_download_import_url "$url" arch current "$arch" official-arch
}

rootfs_source_gentoo() {
    local relbase='https://distfiles.gentoo.org/releases' archdir autobuild variant html file archlabel
    local arches variants
    arches=$(rootfs_source_fetch_dirs "$relbase" | grep -E '^(amd64|arm|arm64|ppc|ppc64|riscv|s390|x86)$' | sort)
    archdir=$(rootfs_source_pick 'Gentoo stage3' 'Architecture family:' "$arches") || return 0
    autobuild="$relbase/$archdir/autobuilds"
    variants=$(rootfs_source_fetch_dirs "$autobuild" | grep '^current-stage3-' | sort)
    variant=$(rootfs_source_pick "Gentoo $archdir" 'Stage3 variant / init / ABI:' "$variants") || return 0
    html=$(rootfs_fetch_text "$autobuild/$variant/" 2>/dev/null) || return 1
    file=$(printf '%s\n' "$html" | grep -oE 'stage3-[A-Za-z0-9_.+-]+-[0-9]{8}T[0-9]{6}Z\.tar\.(xz|gz)' | sort | tail -1)
    [ -n "$file" ] || { tui_msg 'Gentoo' 'No current stage3 tarball was found.'; return 1; }
    archlabel=${variant#current-stage3-}
    rootfs_download_import_url "$autobuild/$variant/$file" gentoo current "$archlabel" official-gentoo-stage3
}

rootfs_source_debian() {
    if declare -F rootfs_download_debian_official >/dev/null 2>&1; then
        rootfs_download_debian_official
    elif declare -F rootfs_download_debian_docker >/dev/null 2>&1; then
        rootfs_download_debian_docker
    else
        tui_msg 'Debian rootfs' 'The Debian official artifact adapter is not available in this build.'
    fi
}

rootfs_source_linuxcontainers() {
    rootfs_download_live_catalogue
}

rootfs_download_source_hub() {
    local c
    while true; do
        c=$(tui_menu 'Rootfs download sources' \
            'Browse live upstream repositories. Only sources that publish extractable rootfs/bootstrap tarballs are included.' \
            debian 'Debian official Docker/rootfs artifacts' \
            ubuntu 'Ubuntu Base official rootfs' \
            alpine 'Alpine official minirootfs' \
            arch 'Arch Linux / ArchLinuxARM bootstrap rootfs' \
            void 'Void Linux official ROOTFS images' \
            gentoo 'Gentoo official stage3 autobuilds' \
            lxc 'Linux Containers multi-distro image catalogue' \
            legacy 'Legacy official/community compatibility catalogue' \
            back 'Back') || return 0
        case "$c" in
            debian) rootfs_source_debian || true ;;
            ubuntu) rootfs_source_ubuntu_base || true ;;
            alpine) rootfs_source_alpine || true ;;
            arch) rootfs_source_arch || true ;;
            void) rootfs_source_void || true ;;
            gentoo) rootfs_source_gentoo || true ;;
            lxc) rootfs_source_linuxcontainers || true ;;
            legacy)
                if declare -F _rootfs_download_before_web_catalogue >/dev/null 2>&1; then _rootfs_download_before_web_catalogue || true
                else tui_msg 'Rootfs download' 'Legacy downloader is unavailable.'; fi ;;
            back|'') return 0 ;;
        esac
    done
}

# Final download route: expose the source hub directly from Rootfs > Download.
rootfs_download() {
    rootfs_download_source_hub
}

return 0 2>/dev/null || true
