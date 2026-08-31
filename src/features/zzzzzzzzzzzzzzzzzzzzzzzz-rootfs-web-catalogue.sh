# shellcheck shell=bash
###############################################################################
# ROOTFS WEB CATALOGUE — live discovery of downloadable rootfs images
###############################################################################

ROOTFS_WEB_CATALOGUE_BASE="${ROOTFS_WEB_CATALOGUE_BASE:-https://images.linuxcontainers.org/images}"

rootfs_web_dirs() { # <url>
    local url="$1" html
    html=$(rootfs_fetch_text "$url/" 2>/dev/null) || return 1

    # Directory indexes differ between mirrors/server versions. Accept quoted
    # and unquoted href values, then fall back to Apache-style visible entries.
    {
        printf '%s\n' "$html" |
            grep -oE 'href=["'"'"']?[^"'"'"' >?#]+/["'"'"']?' 2>/dev/null |
            sed -E 's/^href=["'"'"']?//; s|/["'"'"']?$||'

        printf '%s\n' "$html" |
            sed -nE 's@.*>([^<>/[:space:]][^<>]*)/</a>.*@\1@p' 2>/dev/null
    } |
        sed 's/&amp;/\&/g; s/%3[Aa]/:/g' |
        sed 's|/$||; s|.*/||' |
        awk 'NF && $0 != ".." && $0 != "." && $0 !~ /^https?:\/\//' |
        sort -u
}

rootfs_web_files() { # <url>
    local html
    html=$(rootfs_fetch_text "$1/" 2>/dev/null) || return 1
    {
        printf '%s\n' "$html" |
            grep -oE 'href=["'"'"']?[^"'"'"' >?#]+\.(tar\.gz|tgz|tar\.xz|tar\.zst|tar)["'"'"']?' 2>/dev/null |
            sed -E 's/^href=["'"'"']?//; s/["'"'"']?$//'
        printf '%s\n' "$html" |
            sed -nE 's@.*>([^<>[:space:]]+\.(tar\.gz|tgz|tar\.xz|tar\.zst|tar))</a>.*@\1@p' 2>/dev/null
    } |
        sed 's|.*/||' |
        sort -u
}

rootfs_web_debian_releases_fallback() {
    # Keep Debian useful even if the upstream directory-index markup changes.
    # Probe known current Debian suites and emit only directories that exist.
    local suite
    for suite in bullseye bookworm trixie forky sid; do
        if rootfs_fetch_text "$ROOTFS_WEB_CATALOGUE_BASE/debian/$suite/" >/dev/null 2>&1; then
            printf '%s\n' "$suite"
        fi
    done
}

rootfs_web_pick() { # <title> <prompt> <newline-items>
    local title="$1" prompt="$2" data="$3" item
    local -a opts=()
    while IFS= read -r item; do
        [ -n "$item" ] || continue
        opts+=("$item" "$item")
    done <<< "$data"
    [ ${#opts[@]} -gt 0 ] || return 1
    tui_menu_no_tags "$title" "$prompt" "${opts[@]}"
}

rootfs_web_pick_rootfs_file() { # <url>
    local files preferred
    files=$(rootfs_web_files "$1") || return 1
    [ -n "$files" ] || return 1
    preferred=$(printf '%s\n' "$files" | grep -E '(^|-)rootfs\.(tar\.gz|tar\.xz|tar\.zst|tar)$|^rootfs\.(tar\.gz|tar\.xz|tar\.zst|tar)$' | head -1)
    [ -n "$preferred" ] && { printf '%s\n' "$preferred"; return 0; }
    printf '%s\n' "$files" | head -1
}

rootfs_download_live_catalogue() {
    local base="$ROOTFS_WEB_CATALOGUE_BASE" distro release arch variant build file url
    local distros releases archs variants builds

    distros=$(rootfs_web_dirs "$base") || {
        tui_msg "Web catalogue unavailable" "Could not read the live rootfs catalogue:\n$base"
        return 1
    }
    distro=$(rootfs_web_pick "Download rootfs" "Distribution — parsed live from the web:" "$distros") || return 0

    releases=$(rootfs_web_dirs "$base/$distro" 2>/dev/null || true)
    if [ "$distro" = debian ]; then
        releases=$(printf '%s\n%s\n' "$releases" "$(rootfs_web_debian_releases_fallback)" | sed '/^$/d' | sort -u)
    fi
    [ -n "$releases" ] || {
        tui_msg "No releases found" "No downloadable releases were parsed for $distro."
        return 1
    }
    release=$(rootfs_web_pick "$distro" "Release / branch — parsed live from upstream:" "$releases") || return 0

    archs=$(rootfs_web_dirs "$base/$distro/$release") || return 1
    arch=$(rootfs_web_pick "$distro $release" "Architecture — parsed live from upstream:" "$archs") || return 0

    variants=$(rootfs_web_dirs "$base/$distro/$release/$arch") || return 1
    variant=$(rootfs_web_pick "$distro $release $arch" "Image variant:" "$variants") || return 0

    builds=$(rootfs_web_dirs "$base/$distro/$release/$arch/$variant") || return 1
    build=$(printf '%s\n' "$builds" | sort | tail -1)
    if [ "$(printf '%s\n' "$builds" | sed '/^$/d' | wc -l | tr -d ' ')" -gt 1 ]; then
        build=$(rootfs_web_pick "$distro $release $arch" "Published build:" "$(printf '%s\n' "$builds" | sort -r)") || return 0
    fi
    [ -n "$build" ] || return 1

    file=$(rootfs_web_pick_rootfs_file "$base/$distro/$release/$arch/$variant/$build") || {
        tui_msg "No rootfs archive" "No supported rootfs tarball was found in the selected build."
        return 1
    }
    url="$base/$distro/$release/$arch/$variant/$build/$file"

    rootfs_download_import_url "$url" "$distro" "$release" "$arch" "web-${variant}-${build}"
}

rootfs_download_import_url() { # <url> <distro> <release> <arch> <source-tag>
    local url="$1" distro="$2" release="$3" arch="$4" source="$5" name output target
    name=$(printf '%s-%s-%s-%s' "$distro" "$release" "$arch" "$source" | tr '/ :+' '----')
    output="$ROOTFS_BASE/${name}.tar.gz"
    target="$ROOTFS_BASE/$name"
    mkdir -p "$ROOTFS_BASE"

    if [ -e "$output" ]; then
        tui_yesno "Replace download" "$output already exists. Replace it?" || return 0
        rm -f -- "$output"
    fi
    if ! rootfs_download_to_gz "$url" "$output"; then
        tui_msg "Download failed" "Could not download or normalize:\n$url\n\nSee $LOGFILE for details."
        return 1
    fi
    if tui_yesno "Unpack rootfs" "Imported archive:\n$output\n\nUnpack it now to:\n$target ?"; then
        rootfs_download_unpack "$output" "$target" && tui_msg "Rootfs imported" "Archive:\n$output\n\nRootfs:\n$target"
    else
        tui_msg "Rootfs imported" "Archive imported to:\n$output"
    fi
}

if declare -F rootfs_download >/dev/null 2>&1 \
    && ! declare -F _rootfs_download_before_web_catalogue >/dev/null 2>&1; then
    eval "$(declare -f rootfs_download | sed '1s/^rootfs_download[[:space:]]*()/_rootfs_download_before_web_catalogue ()/')"
fi

rootfs_download() {
    local choice
    choice=$(tui_menu "Download rootfs" \
        "Discover downloadable root filesystems from the web or use the compatibility catalogue." \
        live "Browse all live web catalogue options" \
        legacy "Official/community compatibility downloader" \
        back "Back") || return 0
    case "$choice" in
        live) rootfs_download_live_catalogue || true ;;
        legacy) _rootfs_download_before_web_catalogue || true ;;
    esac
}

return 0 2>/dev/null || true
