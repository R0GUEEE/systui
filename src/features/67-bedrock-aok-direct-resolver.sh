# shellcheck shell=bash
# PHASE 67 — direct Systui resolver for Bedrock-AOK LXC-backed strata.
#
# Avoids fragile upstream resolver/update-urls pipelines (including SIGPIPE 141)
# by resolving LinuxContainers image URLs directly and writing urls.cache.

bedrock_aok_host_arch() {
    local a
    a=$(uname -m 2>/dev/null || printf 'aarch64\n')
    case "$a" in
        aarch64|arm64) printf 'arm64\n' ;;
        x86_64|amd64) printf 'amd64\n' ;;
        riscv64) printf 'riscv64\n' ;;
        *) printf 'arm64\n' ;;
    esac
}

bedrock_aok_http_text() { # <url>
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -4 -LfsS --connect-timeout 10 --max-time 60 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -4 -qO- -T 60 "$url"
    else
        return 127
    fi
}

bedrock_aok_lxc_recipe() { # <stratum> -> distro|release
    local tag="$1" recipe rest
    declare -F catalog_recipe >/dev/null 2>&1 || return 1
    recipe=$(catalog_recipe "$tag" 2>/dev/null || true)
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
                case "$href" in
                    ../|'' ) continue ;;
                    */)
                        href=${href%/}
                        case "$href" in
                            [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_*)
                                [ -z "$newest" ] || [[ "$href" > "$newest" ]] || continue
                                newest="$href"
                                ;;
                        esac
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
    # Prefer the standard LXC rootfs names in order.
    for href in rootfs.tar.xz rootfs.tar.gz rootfs.tar.zst rootfs.tar; do
        case "$html" in *"$href"*) printf '%s/%s\n' "${url%/}" "$href"; return 0 ;; esac
    done
    # Fallback: first rootfs.tar.* link found.
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
    arch=$(bedrock_aok_host_arch)

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
}

bedrock_aok_refresh_urls_resilient() {
    local brl tag ok=0 fail=0
    bedrock_aok_require || return 1
    brl=$(bedrock_aok_brl) || return 1

    # Prefer Systui direct resolution for every LXC-backed catalog entry.
    if declare -F catalog_names >/dev/null 2>&1; then
        for tag in $(catalog_names); do
            if bedrock_aok_lxc_recipe "$tag" >/dev/null 2>&1; then
                if bedrock_aok_refresh_one_url "$tag"; then
                    ok=$((ok + 1))
                else
                    fail=$((fail + 1))
                fi
            fi
        done
    fi

    # Do not treat upstream SIGPIPE 141 as authoritative failure. Run it only
    # as a secondary refresh for non-LXC/fixed/discovery-backed entries.
    "$brl" update-urls >/dev/null 2>&1 || true
    log "bedrock-aok: direct URL refresh complete (ok=$ok fail=$fail)"
    [ "$ok" -gt 0 ]
}

# Override the resilient fetch front door so an unresolved LXC stratum gets a
# direct Systui URL before invoking brl again.
bedrock_aok_fetch_stratum_resilient() { # <stratum>
    local tag="$1" brl current candidate
    bedrock_aok_require || return 1
    brl=$(bedrock_aok_brl) || return 1

    if run_cmd "Fetching Bedrock-AOK stratum: $tag" "$brl" fetch "$tag"; then
        return 0
    fi

    if bedrock_aok_refresh_one_url "$tag"; then
        if run_cmd "Retrying Bedrock-AOK stratum: $tag" "$brl" fetch "$tag"; then
            return 0
        fi
    fi

    current=$(bedrock_aok_cached_url "$tag" 2>/dev/null || true)
    [ -n "$current" ] || {
        tui_msg "Stratum download failed" "No working source could be resolved for '$tag'."
        return 1
    }

    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        [ "$candidate" != "$current" ] || continue
        bedrock_aok_cache_set_url "$tag" "$candidate" || continue
        if run_cmd "Trying alternate mirror for $tag" "$brl" fetch "$tag"; then
            log "bedrock-aok: $tag fetched from alternate mirror $candidate"
            return 0
        fi
    done <<< "$(bedrock_aok_mirror_candidates "$current")"

    bedrock_aok_cache_set_url "$tag" "$current" || true
    tui_msg "Stratum download failed" "All directly resolved sources failed for '$tag'."
    return 1
}

return 0 2>/dev/null || true
