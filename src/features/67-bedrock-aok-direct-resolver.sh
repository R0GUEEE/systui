# shellcheck shell=bash
# PHASE 67 — direct Systui resolver for Bedrock-AOK LXC-backed strata.
#
# This module is deliberately self-contained. It does not depend on private
# shell functions inside the external brl executable.

bedrock_aok_host_arch() {
    local a
    a=$(uname -m 2>/dev/null || true)
    case "$a" in
        aarch64|arm64) printf 'arm64\n' ;;
        x86_64|amd64) printf 'amd64\n' ;;
        riscv64) printf 'riscv64\n' ;;
        armv7l|armhf) printf 'armhf\n' ;;
        *) return 1 ;;
    esac
}

# Systui-owned copy of the upstream Bedrock-AOK catalog. Keeping the mapping in
# this process avoids the former test-only dependency on `catalog_recipe`, which
# normally exists only inside /bedrock/bin/brl.
bedrock_aok_catalog_recipe() { # <stratum>
    case "$1" in
        alpine)      printf 'lxc:alpine:edge\n' ;;
        debian)      printf 'lxc:debian:bookworm\n' ;;
        ubuntu)      printf 'lxc:ubuntu:noble\n' ;;
        devuan)      printf 'lxc:devuan:daedalus\n' ;;
        kali)        printf 'lxc:kali:current\n' ;;
        parrot)      printf 'fixed:https://raw.githubusercontent.com/EXALAB/AnLinux-Resources/master/Rootfs/Parrot/arm64/parrot-rootfs-arm64.tar.xz\n' ;;
        fedora)      printf 'lxc:fedora:44\n' ;;
        rockylinux)  printf 'lxc:rockylinux:9\n' ;;
        almalinux)   printf 'lxc:almalinux:9\n' ;;
        oracle)      printf 'lxc:oracle:9\n' ;;
        centos)      printf 'lxc:centos:9-Stream\n' ;;
        openeuler)   printf 'lxc:openeuler:24.03\n' ;;
        opensuse)    printf 'lxc:opensuse:tumbleweed\n' ;;
        archlinux)   printf 'lxc:archlinux:current\n' ;;
        arch)        printf 'fixed:http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz\n' ;;
        void)        printf 'lxc:voidlinux:current\n' ;;
        gentoo)      printf 'disc:gentoo\n' ;;
        amazonlinux) printf 'lxc:amazonlinux:2023\n' ;;
        openwrt)     printf 'lxc:openwrt:24.10\n' ;;
        alt)         printf 'lxc:alt:Sisyphus\n' ;;
        busybox)     printf 'disc:busybox\n' ;;
        chimera)     printf 'disc:chimera\n' ;;
        apertis)     printf 'lxc:apertis:v2024\n' ;;
        springdale)  printf 'lxc:springdalelinux:9\n' ;;
        funtoo)      printf 'lxc:funtoo:current\n' ;;
        slackware)   printf 'lxc:slackware:current\n' ;;
        mageia)      printf 'lxc:mageia:9\n' ;;
        nixos)       printf 'lxc:nixos:unstable\n' ;;
        manjaro)     printf 'lxc:manjaro:current\n' ;;
        *) return 1 ;;
    esac
}

bedrock_aok_catalog_names() {
    printf '%s\n' alpine debian ubuntu devuan kali parrot fedora rockylinux almalinux oracle centos openeuler opensuse archlinux arch void gentoo amazonlinux openwrt alt busybox chimera apertis springdale funtoo slackware mageia nixos manjaro
}

bedrock_aok_http_text() { # <url>
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -LfsS --connect-timeout 10 --max-time 90 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- -T 90 "$url"
    else
        return 127
    fi
}

bedrock_aok_lxc_recipe() { # <stratum> -> distro|release
    local recipe rest
    recipe=$(bedrock_aok_catalog_recipe "$1" 2>/dev/null || true)
    case "$recipe" in
        lxc:*)
            rest=${recipe#lxc:}
            printf '%s|%s\n' "${rest%%:*}" "${rest#*:}"
            ;;
        *) return 1 ;;
    esac
}

bedrock_aok_lxc_newest_build() { # <base-dir-url>
    local url="$1" html line href newest=""
    html=$(bedrock_aok_http_text "$url" 2>/dev/null || true)
    [ -n "$html" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *href=*)
                href=${line#*href=}
                href=${href#\"}; href=${href#\'}
                href=${href%%\"*}; href=${href%%\'*}
                href=${href%/}
                case "$href" in
                    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[0-9][0-9]:[0-9][0-9])
                        [ -z "$newest" ] || [[ "$href" > "$newest" ]] || continue
                        newest="$href"
                        ;;
                esac
                ;;
        esac
    done <<< "$html"
    [ -n "$newest" ] || return 1
    printf '%s\n' "$newest"
}

bedrock_aok_lxc_pick_rootfs() { # <build-url>
    local url="$1" html line href
    html=$(bedrock_aok_http_text "$url" 2>/dev/null || true)
    [ -n "$html" ] || return 1
    for href in rootfs.tar.xz rootfs.tar.gz rootfs.tar.zst rootfs.tar; do
        case "$html" in *"$href"*) printf '%s/%s\n' "${url%/}" "$href"; return 0 ;; esac
    done
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            *rootfs.tar.*)
                href=${line#*href=}
                href=${href#\"}; href=${href#\'}
                href=${href%%\"*}; href=${href%%\'*}
                case "$href" in rootfs.tar.*) printf '%s/%s\n' "${url%/}" "$href"; return 0 ;; esac
                ;;
        esac
    done <<< "$html"
    return 1
}

bedrock_aok_resolve_lxc_direct() { # <stratum>
    local tag="$1" pair distro release arch frontend base build rootfs
    pair=$(bedrock_aok_lxc_recipe "$tag" 2>/dev/null || true)
    [ -n "$pair" ] || return 1
    distro=${pair%%|*}; release=${pair#*|}
    arch=$(bedrock_aok_host_arch) || return 1

    for frontend in \
        https://images.linuxcontainers.org/images \
        https://us.lxd.images.canonical.com/images \
        https://uk.lxd.images.canonical.com/images
    do
        base="$frontend/$distro/$release/$arch/default"
        build=$(bedrock_aok_lxc_newest_build "$base/" 2>/dev/null || true)
        [ -n "$build" ] || continue
        rootfs=$(bedrock_aok_lxc_pick_rootfs "$base/$build/" 2>/dev/null || true)
        [ -n "$rootfs" ] || continue
        printf '%s\n' "$rootfs"
        return 0
    done
    return 1
}

bedrock_aok_refresh_one_url() { # <stratum>
    local tag="$1" url
    url=$(bedrock_aok_resolve_lxc_direct "$tag" 2>/dev/null || true)
    [ -n "$url" ] || return 1
    bedrock_aok_cache_set_url "$tag" "$url"
    log "bedrock-aok: resolved $tag directly to $url"
    printf '%s\n' "$url"
}

bedrock_aok_fetch_url_direct() { # <stratum> <url>
    local tag="$1" url="$2" brl
    brl=$(bedrock_aok_brl) || return 1
    run_cmd "Fetching Bedrock-AOK stratum directly: $tag" "$brl" fetch-url "$tag" "$url"
}

bedrock_aok_refresh_urls_resilient() {
    local brl tag ok=0 fail=0 url
    bedrock_aok_require || return 1
    brl=$(bedrock_aok_brl) || return 1

    # Upstream refresh first. It may fail with SIGPIPE 141, and it may write
    # unresolved entries; Systui's verified LXC results are written afterward
    # so upstream cannot overwrite them.
    "$brl" update-urls >/dev/null 2>&1 || true

    while IFS= read -r tag; do
        [ -n "$tag" ] || continue
        bedrock_aok_lxc_recipe "$tag" >/dev/null 2>&1 || continue
        url=$(bedrock_aok_refresh_one_url "$tag" 2>/dev/null || true)
        if [ -n "$url" ]; then
            ok=$((ok + 1))
        else
            fail=$((fail + 1))
        fi
    done <<< "$(bedrock_aok_catalog_names)"

    log "bedrock-aok: direct URL refresh complete (ok=$ok fail=$fail)"
    [ "$ok" -gt 0 ]
}

bedrock_aok_fetch_stratum_resilient() { # <stratum>
    local tag="$1" brl url current candidate
    bedrock_aok_require || return 1
    brl=$(bedrock_aok_brl) || return 1

    if run_cmd "Fetching Bedrock-AOK stratum: $tag" "$brl" fetch "$tag"; then
        return 0
    fi

    url=$(bedrock_aok_resolve_lxc_direct "$tag" 2>/dev/null || true)
    if [ -n "$url" ]; then
        bedrock_aok_cache_set_url "$tag" "$url" || true
        log "bedrock-aok: bypassing resolver for $tag with $url"
        if bedrock_aok_fetch_url_direct "$tag" "$url"; then
            return 0
        fi
    fi

    current=${url:-$(bedrock_aok_cached_url "$tag" 2>/dev/null || true)}
    [ -n "$current" ] || {
        tui_msg "Stratum download failed" "No working source could be resolved for '$tag'."
        return 1
    }

    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        [ "$candidate" != "$current" ] || continue
        bedrock_aok_cache_set_url "$tag" "$candidate" || true
        if bedrock_aok_fetch_url_direct "$tag" "$candidate"; then
            log "bedrock-aok: $tag fetched directly from alternate mirror $candidate"
            return 0
        fi
    done <<< "$(bedrock_aok_mirror_candidates "$current")"

    bedrock_aok_cache_set_url "$tag" "$current" || true
    tui_msg "Stratum download failed" "All directly resolved sources failed for '$tag'."
    return 1
}

return 0 2>/dev/null || true
