# shellcheck shell=bash
###############################################################################
# ROOTFS SOURCE ADAPTERS — live download sources for Rootfs > Download
#
# The final "Rootfs download sources" hub dispatches to per-distribution
# adapters. Those names were referenced but never implemented, so selecting
# Debian/Ubuntu/Alpine/Arch/Void/Gentoo/Linux Containers printed
# "rootfs_source_x: command not found" and immediately redrew the hub menu.
#
# This module implements the adapters from the same live upstream catalogues
# used elsewhere in Systui, adds a guarded dispatcher so an unavailable adapter
# explains itself instead of silently returning to the menu, and hardens the
# Linux Containers walk against menus that return no selection.
###############################################################################

# Architecture names used by each upstream project, mapped from Systui's
# Debian-style architecture tokens.
rootfs_source_native_arch() { # <debarch> <flavour>
    local arch="$1" flavour="$2"
    case "$flavour" in
        alpine)
            case "$arch" in
                amd64)   printf 'x86_64\n' ;;
                arm64)   printf 'aarch64\n' ;;
                armhf)   printf 'armv7\n' ;;
                i386)    printf 'x86\n' ;;
                riscv64) printf 'riscv64\n' ;;
                *) return 1 ;;
            esac ;;
        void)
            case "$arch" in
                amd64)   printf 'x86_64\n' ;;
                arm64)   printf 'aarch64\n' ;;
                armhf)   printf 'armv7l\n' ;;
                i386)    printf 'i686\n' ;;
                riscv64) printf 'riscv64\n' ;;
                *) return 1 ;;
            esac ;;
        gentoo)
            case "$arch" in
                amd64)   printf 'amd64\n' ;;
                arm64)   printf 'arm64\n' ;;
                armhf)   printf 'armv7a\n' ;;
                i386)    printf 'x86\n' ;;
                riscv64) printf 'riscv\n' ;;
                *) return 1 ;;
            esac ;;
        arch)
            case "$arch" in
                amd64) printf 'x86_64\n' ;;
                arm64) printf 'aarch64\n' ;;
                armhf) printf 'armv7\n' ;;
                *) return 1 ;;
            esac ;;
        *) return 1 ;;
    esac
}

# Pick one entry from a newline-separated list. A menu that reports success but
# captures no selection is a widget hiccup on some iSH dialog builds: ask once
# more, then tell the user explicitly instead of silently returning to the menu.
rootfs_source_pick() { # <title> <prompt> <newline-items> <what> -> selection
    local title="$1" prompt="$2" data="$3" what="${4:-entry}" pick rc=0
    [ -n "$data" ] || return 1

    pick=$(rootfs_web_pick "$title" "$prompt" "$data") || rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$pick" ]; then
        pick=$(rootfs_web_pick "$title" "$prompt" "$data") || rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        return 1
    fi
    if [ -z "$pick" ]; then
        warn "rootfs: download menu returned no $what"
        tui_msg "Selection not captured" \
"The menu closed without returning a $what.

This is a dialog/widget problem on this host, not an upstream catalogue problem.
Select the entry again, or use another download source."
        return 1
    fi
    printf '%s\n' "$pick"
}

# Scratch file for catalogue parsing. iSH can wedge forever inside a piped
# `grep` that finds no match (measured: "printf x | grep -E nomatch" hangs
# intermittently), so catalogue text is always filtered as a FILE.
rootfs_source_scan_seq=0
rootfs_source_scratch() { # -> path
    local dir="${SYSTUI_TMP:-${TMPDIR:-/tmp}}"
    mkdir -p "$dir" 2>/dev/null || return 1
    rootfs_source_scan_seq=$((rootfs_source_scan_seq + 1))
    printf '%s/.systui-cat-scan.%s.%s\n' "$dir" "$$" "$rootfs_source_scan_seq"
}

# Lines of <data> matching the extended regex <regex>. Pure Bash: no process
# is spawned, so the host's intermittent piped-grep wedge cannot happen. An
# empty result is reported as failure (callers treat "no entry" as "not found").
rootfs_source_filter() { # <regex> <data>
    local re="$1" rest="$2" out="" line
    while [ -n "$rest" ]; do
        line="${rest%%$'\n'*}"
        if [ "$line" = "$rest" ]; then rest=""; else rest="${rest#*$'\n'}"; fi
        if [ -n "$line" ] && [[ "$line" =~ $re ]]; then
            out="$out$line"$'\n'
        fi
    done
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

# Only the matching substrings of <data> (the equivalent of `grep -oE`), again
# in pure Bash.
rootfs_source_filter_o() { # <regex> <data>
    local re="$1" rest="$2" out="" line m
    while [ -n "$rest" ]; do
        line="${rest%%$'\n'*}"
        if [ "$line" = "$rest" ]; then rest=""; else rest="${rest#*$'\n'}"; fi
        while [[ "$line" =~ $re ]]; do
            m="${BASH_REMATCH[0]}"
            [ -n "$m" ] || break
            out="$out$m"$'\n'
            line="${line#*"$m"}"
        done
    done
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

# Zero-padded sort key for every numeric field of <text>, so 3.23.0 outranks
# 3.9.0 without `sort -V`.
rootfs_source_version_key() { # <text>
    local s="$1" key="" part
    while [ -n "$s" ]; do
        case "$s" in
            *[0-9]*) ;;
            *) break ;;
        esac
        s="${s#"${s%%[0-9]*}"}"
        part="${s%%[!0-9]*}"
        [ -n "$part" ] || break
        key="$key$(printf '%08d.' "$part")"
        s="${s#"$part"}"
    done
    printf '%s\n' "$key"
}

# Entry carrying the highest version number. Upstream directories such as
# Alpine's "edge" also list retired versions, where a plain lexical sort picks
# 3.9.0 over 3.23.x. Pure Bash, like the filters above.
rootfs_source_newest() { # <newline entries> -> newest entry
    local rest="$1" line key best="" bestkey="" have=0
    while [ -n "$rest" ]; do
        line="${rest%%$'\n'*}"
        if [ "$line" = "$rest" ]; then rest=""; else rest="${rest#*$'\n'}"; fi
        [ -n "$line" ] || continue
        key=$(rootfs_source_version_key "$line")
        if [ "$have" -eq 0 ] || [[ "$key" > "$bestkey" ]]; then
            best="$line"
            bestkey="$key"
            have=1
        fi
    done
    [ "$have" -eq 1 ] || return 1
    printf '%s\n' "$best"
}

# First directory published at <url> matching <extended-regex>, or nothing.
# Upstream arch/branch directories are renamed from time to time (armv7a vs
# armv7, riscv vs riscv64), so adapters never assume one exact name.
rootfs_source_dir_match() { # <url> <regex>
    local dirs matches
    dirs=$(rootfs_web_dirs "$1" 2>/dev/null || true)
    [ -n "$dirs" ] || return 1
    matches=$(rootfs_source_filter "$2" "$dirs") || true
    [ -n "$matches" ] || return 1
    printf '%s\n' "${matches%%$'\n'*}"
}

rootfs_source_reverse() { # <newline entries> -> same entries, last first
    local d="$1" out="" line rest
    while [ -n "$d" ]; do
        line="${d%%$'\n'*}"
        if [ "$line" = "$d" ]; then rest=""; else rest="${d#*$'\n'}"; fi
        out="$line${out:+$'\n'$out}"
        d="$rest"
    done
    printf '%s\n' "$out"
}

rootfs_source_no_entries() { # <what> <url>
    tui_msg "Nothing to download" \
"No $1 entries could be read from:

$2

Check the network connection, or pick another download source."
}

rootfs_source_unreachable() { # <what> <url>
    tui_msg "Catalogue unavailable" \
"Could not read the $1 catalogue:

$2

Check the network connection, or pick another download source."
}

# Ask for the target architecture using the same picker as the rootfs builder.
rootfs_source_pick_arch() { # <distro>
    local arch
    arch=$(rootfs_download_arch_menu "$1") || return 1
    [ -n "$arch" ] || return 1
    printf '%s\n' "$arch"
}

###############################################################################
# ADAPTERS
###############################################################################

# Linux Containers multi-distro catalogue (implemented in the web catalogue and
# extended by the extra-web-images module).
rootfs_source_linuxcontainers() {
    if declare -F rootfs_download_live_catalogue >/dev/null 2>&1; then
        rootfs_download_live_catalogue
        return $?
    fi
    tui_msg "Linux Containers catalogue" \
"The live Linux Containers image catalogue is not available in this build."
    return 1
}

# Debian: official minirootfs artifacts published by the Debian Docker image
# project (already parsed by the Debian catalogue module).
rootfs_source_debian() {
    if declare -F rootfs_download_debian_docker >/dev/null 2>&1; then
        rootfs_download_debian_docker && return 0
        tui_yesno "Debian catalogue unavailable" \
"The Debian official artifact catalogue could not be read.

Open the Linux Containers Debian images instead?" || return 1
        rootfs_source_linuxcontainers
        return $?
    fi
    rootfs_source_linuxcontainers
}

# Ubuntu Base: official tarballs from cdimage.ubuntu.com.
rootfs_source_ubuntu_base() {
    local base="https://cdimage.ubuntu.com/ubuntu-base/releases" releases release arch files file
    releases=$(rootfs_web_dirs "$base") || { rootfs_source_unreachable "Ubuntu Base" "$base"; return 1; }
    [ -n "$releases" ] || { rootfs_source_no_entries "Ubuntu Base release" "$base"; return 1; }
    # Keep release names only ("24.04"), dropping the point-release web archive
    # ("24.04.2") which duplicates the same images.
    releases=$(rootfs_source_filter '^[0-9]+\.[0-9]+$' "$releases") || true
    [ -n "$releases" ] || { rootfs_source_no_entries "Ubuntu Base release" "$base"; return 1; }
    releases=$(rootfs_source_reverse "$releases")
    release=$(rootfs_source_pick "Ubuntu Base rootfs" \
        "Ubuntu release — parsed live from cdimage.ubuntu.com (newest first):" "$releases" "Ubuntu release") || return 1

    arch=$(rootfs_source_pick_arch ubuntu) || return 1
    files=$(rootfs_web_files "$base/$release/release" 2>/dev/null || true)
    file=$(rootfs_source_newest "$(rootfs_source_filter "^ubuntu-base-[0-9.]+-base-${arch}\.tar\.gz$" "$files")") || file=""
    if [ -z "$file" ]; then
        tui_msg "No Ubuntu Base image" \
"No ubuntu-base archive was published for:

$release ($arch)

Older releases keep only the newest point release; choose another release or
another download source."
        return 1
    fi
    rootfs_download_import_url "$base/$release/release/$file" ubuntu "$release" "$arch" "ubuntu-base"
}

# Alpine: official minirootfs from dl-cdn.alpinelinux.org.
rootfs_source_alpine() {
    local base="https://dl-cdn.alpinelinux.org/alpine" releases release arch narch files file
    releases=$(rootfs_web_dirs "$base") || { rootfs_source_unreachable "Alpine" "$base"; return 1; }
    [ -n "$releases" ] || { rootfs_source_no_entries "Alpine release" "$base"; return 1; }
    releases=$(rootfs_source_reverse "$releases")
    release=$(rootfs_source_pick "Alpine rootfs" \
        "Release — parsed live from dl-cdn.alpinelinux.org (newest first, edge is the rolling branch):" "$releases" "Alpine release") || return 1

    arch=$(rootfs_source_pick_arch alpine) || return 1
    narch=$(rootfs_source_native_arch "$arch" alpine) || {
        tui_msg "Unsupported architecture" "Alpine does not publish a minirootfs for $arch."
        return 1
    }
    files=$(rootfs_web_files "$base/$release/releases/$narch" 2>/dev/null || true)
    file=$(rootfs_source_newest "$(rootfs_source_filter '^alpine-minirootfs-[0-9]+\.[0-9]+\.[0-9]+-.*\.tar\.gz$' "$files")") || file=""
    if [ -z "$file" ]; then
        tui_msg "No Alpine minirootfs" \
"No alpine-minirootfs archive was found for:

$release ($narch)

Choose another release or branch."
        return 1
    fi
    rootfs_download_import_url "$base/$release/releases/$narch/$file" alpine "$release" "$arch" "alpine-official"
}

# Arch Linux: the official bootstrap tarball for x86_64 and the Arch Linux ARM
# release tarballs for 32/64-bit ARM.
rootfs_source_arch() {
    local arch url base files file
    arch=$(rootfs_source_pick_arch arch) || return 1

    case "$arch" in
        amd64)
            base="https://geo.mirror.pkgbuild.com/iso/latest"
            files=$(rootfs_web_files "$base" 2>/dev/null || true)
            file=$(rootfs_source_newest "$(rootfs_source_filter '^archlinux-bootstrap-[0-9.]+-x86_64\.tar\.(gz|zst)$' "$files")") || file=""
            [ -n "$file" ] || file=archlinux-bootstrap-x86_64.tar.zst
            url="$base/$file"
            ;;
        arm64|armhf)
            case "$arch" in
                arm64) url="http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz" ;;
                *)     url="http://os.archlinuxarm.org/os/ArchLinuxARM-armv7-latest.tar.gz" ;;
            esac
            ;;
        *)
            tui_msg "Unsupported architecture" \
"Arch Linux images are published for x86_64 (official) and aarch64/armv7
(Arch Linux ARM)."
            return 1
            ;;
    esac

    rootfs_download_import_url "$url" arch rolling "$arch" "arch-bootstrap"
}

# Void Linux: official ROOTFS images.
rootfs_source_void() {
    local base="https://repo-default.voidlinux.org/live/current" arch narch files file
    arch=$(rootfs_source_pick_arch void) || return 1
    narch=$(rootfs_source_native_arch "$arch" void) || {
        tui_msg "Unsupported architecture" "Void Linux does not publish a ROOTFS image for $arch."
        return 1
    }
    files=$(rootfs_web_files "$base" 2>/dev/null || true)
    [ -n "$files" ] || { rootfs_source_unreachable "Void Linux ROOTFS" "$base"; return 1; }
    file=$(rootfs_source_newest "$(rootfs_source_filter "^void-${narch}-ROOTFS-[0-9_]+\.tar\.xz$" "$files")") || file=""
    if [ -z "$file" ]; then
        tui_msg "No Void ROOTFS image" \
"No Void ROOTFS archive was found for:

$narch

Void publishes a limited architecture set on the current live images."
        return 1
    fi
    rootfs_download_import_url "$base/$file" void current "$arch" "void-official"
}

# Gentoo: official stage3 autobuilds.
rootfs_source_gentoo() {
    local base="https://distfiles.gentoo.org/releases" arch garch release init dir files file
    arch=$(rootfs_source_pick_arch gentoo) || return 1
    garch=$(rootfs_source_native_arch "$arch" gentoo) || {
        tui_msg "Unsupported architecture" "Gentoo does not publish a stage3 autobuild for $arch."
        return 1
    }

    release=$(rootfs_source_pick "Gentoo stage3" \
        "Init system for the stage3 autobuild:" "openrc
systemd" "Gentoo init system") || return 1

    dir=$(rootfs_source_dir_match "$base/$garch/autobuilds" "^current-stage3-${garch}-${release}$") || true
    [ -n "$dir" ] || dir=$(rootfs_source_dir_match "$base/$garch/autobuilds" "^current-stage3-${garch}" 2>/dev/null || true)
    [ -n "$dir" ] || {
        tui_msg "No Gentoo stage3" \
"No current stage3 autobuild directory was found for:

$garch

Gentoo renames its release directories over time; choose another architecture."
        return 1
    }

    files=$(rootfs_web_files "$base/$garch/autobuilds/$dir" 2>/dev/null || true)
    file=$(rootfs_source_newest "$(rootfs_source_filter '^stage3-.*\.tar\.xz$' "$files")") || file=""
    if [ -z "$file" ]; then
        tui_msg "No Gentoo stage3 archive" \
"No stage3 tarball was published in:

$garch/autobuilds/$dir"
        return 1
    fi
    rootfs_download_import_url "$base/$garch/autobuilds/$dir/$file" gentoo "$release" "$arch" "gentoo-stage3"
}

###############################################################################
# CATALOGUE PARSERS — file-based, no piped grep
###############################################################################
#
# The shared parsers read upstream Apache/nginx directory indexes. They used to
# feed the HTML into `printf | grep -oE`, and on iSH a piped grep that finds no
# match can wedge forever (measured intermittently), freezing the whole download
# flow. The same extraction runs against a scratch file here, which is reliable
# on every supported host. Output and return status match the originals.

rootfs_web_dirs() { # <url>
    local url="$1" html scratch out rc=0
    html=$(rootfs_fetch_text "$url/") || return 1
    scratch=$(rootfs_source_scratch) || return 1
    printf '%s\n' "$html" > "$scratch" || { rm -f -- "$scratch"; return 1; }

    out=$(
        {
            grep -oE 'href=["'"'"']?[^"'"'"' >?#]+/["'"'"']?' "$scratch" 2>/dev/null |
                sed -E 's/^href=["'"'"']?//; s|/["'"'"']?$||'

            sed -nE 's@.*>([^<>/[:space:]][^<>]*)/</a>.*@\1@p' "$scratch" 2>/dev/null
        } |
            sed 's/&amp;/\&/g; s/%3[Aa]/:/g' |
            sed 's|/$||; s|.*/||' |
            awk 'NF && $0 != ".." && $0 != "." && $0 !~ /^https?:\/\//' |
            sort -u
    ) || rc=$?
    rm -f -- "$scratch"
    printf '%s\n' "$out"
    return "$rc"
}

rootfs_web_files() { # <url>
    local url="$1" html scratch out rc=0
    html=$(rootfs_fetch_text "$url/") || return 1
    scratch=$(rootfs_source_scratch) || return 1
    printf '%s\n' "$html" > "$scratch" || { rm -f -- "$scratch"; return 1; }

    out=$(
        {
            grep -oE 'href=["'"'"']?[^"'"'"' >?#]+\.(tar\.gz|tgz|tar\.xz|tar\.zst|tar)["'"'"']?' "$scratch" 2>/dev/null |
                sed -E 's/^href=["'"'"']?//; s/["'"'"']?$//'

            sed -nE 's@.*>([^<>[:space:]]+\.(tar\.gz|tgz|tar\.xz|tar\.zst|tar))</a>.*@\1@p' "$scratch" 2>/dev/null
        } |
            sed 's|.*/||' |
            sort -u
    ) || rc=$?
    rm -f -- "$scratch"
    printf '%s\n' "$out"
    return "$rc"
}


###############################################################################
# DISPATCH
###############################################################################

# Run a source adapter, or explain that this build does not provide it. The old
# hub called the adapters directly, so a missing one only produced a
# "command not found" on stderr and redrew the menu.
rootfs_source_dispatch() { # <function> <label> [fallback]
    local fn="$1" label="$2" fallback="${3:-}"

    if declare -F "$fn" >/dev/null 2>&1; then
        "$fn"
        return $?
    fi

    warn "rootfs: download source adapter '$fn' is not available"
    if [ -n "$fallback" ] && declare -F "$fallback" >/dev/null 2>&1; then
        if tui_yesno "Download source unavailable" \
"$label is not available in this build.

Open the Linux Containers image catalogue instead?"; then
            "$fallback"
            return $?
        fi
        return 1
    fi
    tui_msg "Download source unavailable" \
"$label is not available in this build.

Update Systui, or use the Linux Containers catalogue."
    return 1
}

# Final Rootfs > Download front door. Distributions come first: the previous
# ordering put "OCI/container images" on the first line, which made a
# distribution selection feel like it had gone to the wrong place.
rootfs_download_source_hub() {
    local c
    while true; do
        c=$(tui_menu 'Rootfs download sources' \
            'Prebuilt root filesystems from official and community catalogues.' \
            debian 'Debian — official rootfs artifacts' \
            ubuntu 'Ubuntu Base — official rootfs tarballs' \
            alpine 'Alpine — official minirootfs' \
            arch 'Arch Linux / Arch Linux ARM — bootstrap rootfs' \
            void 'Void Linux — official ROOTFS images' \
            gentoo 'Gentoo — official stage3 autobuilds' \
            lxc 'Linux Containers — multi-distro image catalogue' \
            oci 'OCI/container images — Podman/Docker/GHCR/Quay/custom registries' \
            legacy 'Legacy official/community compatibility catalogue' \
            back 'Back') || return 0
        case "$c" in
            debian) rootfs_source_dispatch rootfs_source_debian 'The Debian rootfs source' rootfs_source_linuxcontainers ;;
            ubuntu) rootfs_source_dispatch rootfs_source_ubuntu_base 'The Ubuntu Base source' rootfs_source_linuxcontainers ;;
            alpine) rootfs_source_dispatch rootfs_source_alpine 'The Alpine rootfs source' rootfs_source_linuxcontainers ;;
            arch)   rootfs_source_dispatch rootfs_source_arch 'The Arch Linux rootfs source' rootfs_source_linuxcontainers ;;
            void)   rootfs_source_dispatch rootfs_source_void 'The Void Linux rootfs source' rootfs_source_linuxcontainers ;;
            gentoo) rootfs_source_dispatch rootfs_source_gentoo 'The Gentoo rootfs source' rootfs_source_linuxcontainers ;;
            lxc)    rootfs_source_dispatch rootfs_source_linuxcontainers 'The Linux Containers catalogue' ;;
            oci)
                if declare -F rootfs_oci_known_image_menu >/dev/null 2>&1; then
                    rootfs_oci_known_image_menu || true
                else
                    tui_msg "OCI images" "The OCI/container image importer is not available in this build."
                fi ;;
            legacy)
                if declare -F _rootfs_download_before_web_catalogue >/dev/null 2>&1; then
                    _rootfs_download_before_web_catalogue || true
                else
                    tui_msg 'Rootfs download' 'The legacy downloader is not available in this build.'
                fi ;;
            back|'') return 0 ;;
        esac
    done
}

###############################################################################
# LINUX CONTAINERS WALK — no more silent returns
###############################################################################

# Walk the live Linux Containers catalogue. Every level reports what it could
# not read; the previous implementation returned straight to the caller as soon
# as a level parsed to nothing, which looked like "selecting a distribution
# just goes back to the menu".
rootfs_download_live_catalogue() {
    local base="$ROOTFS_WEB_CATALOGUE_BASE" distro release arch variant resolved build file url
    local distros releases archs variants

    distros=$(rootfs_web_dirs "$base") || {
        tui_msg "Web catalogue unavailable" "Could not read the live rootfs catalogue:\n$base"
        return 1
    }
    [ -n "$distros" ] || { rootfs_source_no_entries "distribution" "$base"; return 1; }
    distro=$(rootfs_source_pick "Download rootfs" \
        "Distribution — parsed live from the web:" "$distros" "distribution") || return 0

    releases=$(rootfs_web_dirs "$base/$distro" 2>/dev/null || true)
    if [ "$distro" = debian ] && declare -F rootfs_web_debian_releases_fallback >/dev/null 2>&1; then
        releases=$(printf '%s\n%s\n' "$releases" "$(rootfs_web_debian_releases_fallback)" | sed '/^$/d' | sort -u)
    fi
    [ -n "$releases" ] || {
        tui_msg "No releases found" "No downloadable $distro releases could be parsed from:\n$base/$distro"
        return 1
    }
    release=$(rootfs_source_pick "$distro" \
        "Release / branch — parsed live from upstream:" "$releases" "$distro release") || return 0

    archs=$(rootfs_web_dirs "$base/$distro/$release" 2>/dev/null || true)
    [ -n "$archs" ] || {
        tui_msg "No architectures found" \
"No architectures could be parsed for:

$distro $release

This branch may have been retired upstream; choose another release."
        return 1
    }
    arch=$(rootfs_source_pick "$distro $release" \
        "Architecture — parsed live from upstream:" "$archs" "architecture") || return 0

    variants=$(rootfs_web_dirs "$base/$distro/$release/$arch" 2>/dev/null || true)
    [ -n "$variants" ] || {
        tui_msg "No image variants found" "No image variants were published for:\n$distro $release ($arch)"
        return 1
    }
    variant=$(rootfs_source_pick "$distro $release $arch" \
        "Image variant:" "$variants" "image variant") || return 0

    resolved=$(rootfs_web_resolve_latest_usable_build "$base/$distro/$release/$arch/$variant" 2>/dev/null || true)
    if [ -z "$resolved" ]; then
        if [ "$distro" = debian ]; then
            if tui_yesno "No usable LXC build" \
"No usable Linux Containers tarball was found for Debian $release ($arch/$variant).

Try Debian's official Docker rootfs catalogue instead?"; then
                rootfs_download_debian_docker || true
            fi
            return 0
        fi
        tui_msg "No rootfs archive" \
"No verified downloadable rootfs tarball was found in:

$distro $release ($arch/$variant)

Pick another build, or use a distribution-specific download source."
        return 1
    fi

    build=${resolved%%|*}
    file=${resolved#*|}
    url="$base/$distro/$release/$arch/$variant/$build/$file"
    rootfs_download_import_url "$url" "$distro" "$release" "$arch" "web-${variant}-${build}"
}

###############################################################################
# REMAINING PIPED-GREP CATALOGUE PARSERS
###############################################################################
#
# These upstream parsers are reached from the same download menus and used the
# same `printf | grep -oE` shape, so they are re-implemented against scratch
# files as well.

# Release aliases published by docker.debian.net (Rootfs > Download > Debian).
rootfs_debian_docker_suites() {
    local html tokens line out=""
    html=$(rootfs_fetch_text "$ROOTFS_DEBIAN_DOCKER_INDEX" 2>/dev/null) || return 1
    tokens=$(rootfs_source_filter_o 'debian:[A-Za-z][A-Za-z0-9._-]*' "$html") || return 1
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        line="${line#debian:}"
        [ -n "$line" ] || continue
        case "$line" in
            *-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) continue ;;
        esac
        case "$line" in
            *[!0-9.]*) ;;
            *) continue ;;
        esac
        out="$out$line"$'\n'
    done <<< "$tokens"
    [ -n "$out" ] || return 1
    printf '%s' "$out"
}

# Newest Linux Containers build directory for <distro>/<release>/<arch>.
# Build directories are stamped YYYYMMDD_HH:MM, so the newest is the string
# maximum; no `sort | tail -1` pipeline is needed.
rootfs_web_latest_build() { # <url>
    local html builds b best=""
    html=$(rootfs_fetch_text "$1/" 2>/dev/null) || return 1
    builds=$(rootfs_source_filter_o 'href="[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9]:[0-9][0-9]/"' "$html") || return 1
    while IFS= read -r b; do
        [ -n "$b" ] || continue
        b=${b#href=\"}
        b=${b%\"}
        b=${b%/}
        [ -n "$b" ] || continue
        if [ -z "$best" ] || [[ "$b" > "$best" ]]; then
            best="$b"
        fi
    done <<< "$builds"
    [ -n "$best" ] || return 1
    printf '%s\n' "$best"
}

# Compatibility downloader URL resolvers (Rootfs > Download > legacy). They used
# piped `grep -oE` for the same extraction and are re-implemented on the shared
# file-based helpers, which also makes them version-aware.
rootfs_download_community_url() { # <distro> <release> <arch>
    local distro="$1" release="$2" arch="$3" image_distro="$1" image_release="$2" base latest
    case "$distro" in
        arch) image_distro=archlinux; image_release=current ;;
        void) image_distro=voidlinux ;;
        tumbleweed) image_distro=opensuse; image_release=tumbleweed ;;
        bedrock) return 1 ;;
    esac
    base="https://images.linuxcontainers.org/images/$image_distro/$image_release/$arch/default"
    latest=$(rootfs_web_latest_build "$base") || return 1
    printf '%s/%s/rootfs.tar.xz\n' "$base" "$latest"
}

rootfs_download_official_url() { # <distro> <release> <arch>
    local distro="$1" release="$2" arch="$3" narch
    case "$distro" in
        ubuntu)
            rootfs_source_official_file \
                "https://cdimage.ubuntu.com/ubuntu-base/releases/$release/release" \
                "ubuntu-base-[0-9.]+-base-${arch}\.tar\.gz" ;;
        alpine)
            narch=$(rootfs_source_native_arch "$arch" alpine) || return 1
            rootfs_source_official_file \
                "https://dl-cdn.alpinelinux.org/alpine/$release/releases/$narch" \
                "alpine-minirootfs-[0-9]+\.[0-9]+\.[0-9]+-.*\.tar\.gz" ;;
        arch)
            case "$arch" in
                amd64) printf '%s\n' "https://geo.mirror.pkgbuild.com/iso/latest/archlinux-bootstrap-x86_64.tar.zst" ;;
                arm64) printf '%s\n' "http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz" ;;
                armhf) printf '%s\n' "http://os.archlinuxarm.org/os/ArchLinuxARM-armv7-latest.tar.gz" ;;
                *) return 1 ;;
            esac ;;
        void)
            narch=$(rootfs_source_native_arch "$arch" void) || return 1
            rootfs_source_official_file \
                "https://repo-default.voidlinux.org/live/current" \
                "void-${narch}-ROOTFS-[0-9_]+\.tar\.xz" ;;
        *) return 1 ;;
    esac
}

# Official per-distribution rootfs URL used by the compatibility downloader.
rootfs_source_official_file() { # <dir-url> <extended-regex>
    local html files
    html=$(rootfs_fetch_text "$1/" 2>/dev/null) || return 1
    files=$(rootfs_source_filter_o "$2" "$html") || return 1
    [ -n "$files" ] || return 1
    rootfs_source_newest "$files"
}
