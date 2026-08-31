# shellcheck shell=bash
###############################################################################
# ROOTFS EXTRA WEB IMAGES — additional live upstream image sources
###############################################################################

ROOTFS_DEBIAN_DOCKER_INDEX="${ROOTFS_DEBIAN_DOCKER_INDEX:-https://docker.debian.net/}"
ROOTFS_DEBIAN_ARTIFACT_RAW="${ROOTFS_DEBIAN_ARTIFACT_RAW:-https://raw.githubusercontent.com/debuerreotype/docker-debian-artifacts}"

rootfs_url_exists() { # <url>
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsIL --max-time 20 --retry 1 -- "$url" >/dev/null 2>&1
    elif command -v wget >/dev/null 2>&1; then
        wget -q --spider --timeout=20 --tries=1 -- "$url" >/dev/null 2>&1
    else
        return 1
    fi
}

rootfs_debian_docker_suites() {
    local html
    html=$(rootfs_fetch_text "$ROOTFS_DEBIAN_DOCKER_INDEX" 2>/dev/null) || return 1

    # docker.debian.net publishes headings such as:
    #   Image: debian:forky, debian:forky-20260824
    # Keep symbolic suite/release aliases and discard dated/numeric aliases.
    printf '%s\n' "$html" |
        grep -oE 'debian:[A-Za-z][A-Za-z0-9._-]*' |
        sed 's/^debian://' |
        grep -Ev -- '-[0-9]{8}$|^[0-9]+([.][0-9]+)*$' |
        sort -u
}

rootfs_debian_artifact_url() { # <suite> <arch>
    local suite="$1" arch="$2"
    printf '%s/dist-%s/%s/rootfs.tar.xz\n' "$ROOTFS_DEBIAN_ARTIFACT_RAW" "$arch" "$suite"
}

rootfs_debian_docker_arches() { # <suite>
    local suite="$1" arch url
    # These are Debian dpkg architecture names used by the artifact branches.
    for arch in amd64 arm64 armel armhf i386 ppc64el riscv64 s390x; do
        url=$(rootfs_debian_artifact_url "$suite" "$arch")
        rootfs_url_exists "$url" && printf '%s\n' "$arch"
    done
}

rootfs_download_debian_docker() {
    local suites suite arches arch url
    suites=$(rootfs_debian_docker_suites) || {
        tui_msg "Debian image catalogue" "Could not parse the current Debian rootfs catalogue at:\n$ROOTFS_DEBIAN_DOCKER_INDEX"
        return 1
    }
    [ -n "$suites" ] || {
        tui_msg "Debian image catalogue" "No Debian release entries were found in the live catalogue."
        return 1
    }

    suite=$(rootfs_web_pick "Debian rootfs" "Release/tag — parsed live from docker.debian.net:" "$suites") || return 0
    [ -n "$suite" ] || return 0

    arches=$(rootfs_debian_docker_arches "$suite")
    [ -n "$arches" ] || {
        tui_msg "Debian $suite" "No downloadable rootfs.tar.xz artifacts were found for this release."
        return 1
    }

    arch=$(rootfs_web_pick "Debian $suite" "Architecture — only verified downloadable artifacts are shown:" "$arches") || return 0
    [ -n "$arch" ] || return 0

    url=$(rootfs_debian_artifact_url "$suite" "$arch")
    if ! rootfs_url_exists "$url"; then
        tui_msg "Debian artifact unavailable" "The selected artifact disappeared or is temporarily unavailable:\n$url"
        return 1
    fi

    rootfs_download_import_url "$url" debian "$suite" "$arch" "debian-official-docker"
}

# Improve the Linux Containers path as well: do not assume the newest build
# directory contains a usable tarball. Probe newest-to-oldest and use the first
# build that actually publishes a supported rootfs archive.
rootfs_web_resolve_latest_usable_build() { # <variant-url> -> build|file
    local base="$1" builds build file
    builds=$(rootfs_web_dirs "$base" 2>/dev/null) || return 1
    [ -n "$builds" ] || return 1
    while IFS= read -r build; do
        [ -n "$build" ] || continue
        file=$(rootfs_web_pick_rootfs_file "$base/$build" 2>/dev/null || true)
        [ -n "$file" ] || continue
        if rootfs_url_exists "$base/$build/$file"; then
            printf '%s|%s\n' "$build" "$file"
            return 0
        fi
    done <<< "$(printf '%s\n' "$builds" | sort -r)"
    return 1
}

if declare -F rootfs_download_live_catalogue >/dev/null 2>&1 \
    && ! declare -F _rootfs_download_live_catalogue_before_extra_sources >/dev/null 2>&1; then
    eval "$(declare -f rootfs_download_live_catalogue | sed '1s/^rootfs_download_live_catalogue[[:space:]]*()/_rootfs_download_live_catalogue_before_extra_sources ()/')"
fi

rootfs_download_live_catalogue() {
    local base="$ROOTFS_WEB_CATALOGUE_BASE" distro release arch variant resolved build file url
    local distros releases archs variants

    distros=$(rootfs_web_dirs "$base") || {
        tui_msg "Web catalogue unavailable" "Could not read the live rootfs catalogue:\n$base"
        return 1
    }
    distro=$(rootfs_web_pick "Download rootfs" "Distribution — parsed live from the web:" "$distros") || return 0

    releases=$(rootfs_web_dirs "$base/$distro") || return 1
    release=$(rootfs_web_pick "$distro" "Release / branch — parsed live from upstream:" "$releases") || return 0

    archs=$(rootfs_web_dirs "$base/$distro/$release") || return 1
    arch=$(rootfs_web_pick "$distro $release" "Architecture — parsed live from upstream:" "$archs") || return 0

    variants=$(rootfs_web_dirs "$base/$distro/$release/$arch") || return 1
    variant=$(rootfs_web_pick "$distro $release $arch" "Image variant:" "$variants") || return 0

    resolved=$(rootfs_web_resolve_latest_usable_build "$base/$distro/$release/$arch/$variant" 2>/dev/null || true)
    if [ -z "$resolved" ]; then
        if [ "$distro" = debian ]; then
            if tui_yesno "No usable LXC build" "No usable Linux Containers tarball was found for Debian $release ($arch/$variant).\n\nTry Debian's official Docker rootfs catalogue instead?"; then
                rootfs_download_debian_docker
            fi
            return 0
        fi
        tui_msg "No rootfs archive" "No verified downloadable rootfs tarball was found in the selected image stream."
        return 1
    fi

    build=${resolved%%|*}
    file=${resolved#*|}
    url="$base/$distro/$release/$arch/$variant/$build/$file"
    rootfs_download_import_url "$url" "$distro" "$release" "$arch" "web-${variant}-${build}"
}

if declare -F rootfs_download >/dev/null 2>&1 \
    && ! declare -F _rootfs_download_before_extra_web_images >/dev/null 2>&1; then
    eval "$(declare -f rootfs_download | sed '1s/^rootfs_download[[:space:]]*()/_rootfs_download_before_extra_web_images ()/')"
fi

rootfs_download() {
    local choice
    choice=$(tui_menu "Download rootfs" \
        "Parse multiple live upstream catalogues for downloadable root filesystems." \
        live "Linux Containers live image catalogue" \
        debian "Debian official Docker rootfs artifacts" \
        legacy "Official/community compatibility downloader" \
        back "Back") || return 0
    case "$choice" in
        live) rootfs_download_live_catalogue || true ;;
        debian) rootfs_download_debian_docker || true ;;
        legacy)
            if declare -F _rootfs_download_before_web_catalogue >/dev/null 2>&1; then
                _rootfs_download_before_web_catalogue || true
            elif declare -F _rootfs_download_before_extra_web_images >/dev/null 2>&1; then
                _rootfs_download_before_extra_web_images || true
            fi
            ;;
    esac
}

return 0 2>/dev/null || true
