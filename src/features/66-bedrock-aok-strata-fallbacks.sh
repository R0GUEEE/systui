# shellcheck shell=bash
# PHASE 66 — resilient Bedrock-AOK stratum source resolution.
#
# Bedrock-AOK stores one resolved URL per stratum in /bedrock/etc/urls.cache.
# When a cached/primary LinuxContainers URL fails, refresh upstream resolution,
# then retry the same image path against the official US/UK mirror frontends.
# Never leave the cache pinned to a failed mirror.

bedrock_aok_url_cache_file() {
    printf '%s\n' /bedrock/etc/urls.cache
}

bedrock_aok_cached_url() { # <stratum>
    local tag="$1" cache line
    cache=$(bedrock_aok_url_cache_file)
    [ -r "$cache" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            "$tag "*) printf '%s\n' "${line#* }"; return 0 ;;
        esac
    done < "$cache"
    return 1
}

bedrock_aok_cache_set_url() { # <stratum> <url>
    local tag="$1" url="$2" cache dir tmp line found=0
    cache=$(bedrock_aok_url_cache_file)
    dir=${cache%/*}
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "${SYSTUI_TMP:-${TMPDIR:-/tmp}}/bedrock-urls.XXXXXX") || return 1
    if [ -r "$cache" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in
                "$tag "*)
                    if [ "$found" -eq 0 ]; then
                        printf '%s %s\n' "$tag" "$url" >> "$tmp"
                        found=1
                    fi
                    ;;
                *) printf '%s\n' "$line" >> "$tmp" ;;
            esac
        done < "$cache"
    fi
    [ "$found" -eq 1 ] || printf '%s %s\n' "$tag" "$url" >> "$tmp"
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$cache"
}

bedrock_aok_mirror_candidates() { # <url>
    local url="$1" rest
    case "$url" in
        https://images.linuxcontainers.org/*)
            rest=${url#https://images.linuxcontainers.org}
            printf '%s\n' \
                "https://us.lxd.images.canonical.com$rest" \
                "https://uk.lxd.images.canonical.com$rest"
            ;;
        https://us.lxd.images.canonical.com/*)
            rest=${url#https://us.lxd.images.canonical.com}
            printf '%s\n' \
                "https://images.linuxcontainers.org$rest" \
                "https://uk.lxd.images.canonical.com$rest"
            ;;
        https://uk.lxd.images.canonical.com/*)
            rest=${url#https://uk.lxd.images.canonical.com}
            printf '%s\n' \
                "https://images.linuxcontainers.org$rest" \
                "https://us.lxd.images.canonical.com$rest"
            ;;
    esac
}

bedrock_aok_fetch_stratum_resilient() { # <stratum>
    local tag="$1" brl original refreshed candidate
    bedrock_aok_require || return 1
    brl=$(bedrock_aok_brl) || return 1

    original=$(bedrock_aok_cached_url "$tag" 2>/dev/null || true)

    # Fast path: current resolver/cache still works.
    if run_cmd "Fetching Bedrock-AOK stratum: $tag" "$brl" fetch "$tag"; then
        return 0
    fi

    # Ask upstream to refresh every dynamic URL, then retry once.
    run_cmd "Refreshing Bedrock-AOK stratum URLs" "$brl" update-urls || true
    refreshed=$(bedrock_aok_cached_url "$tag" 2>/dev/null || true)
    if run_cmd "Retrying Bedrock-AOK stratum: $tag" "$brl" fetch "$tag"; then
        return 0
    fi

    # Preserve the newest upstream-resolved URL for rollback if mirrors fail.
    [ -n "$refreshed" ] || refreshed="$original"
    [ -n "$refreshed" ] || {
        tui_msg "Stratum download failed" \
            "Bedrock-AOK could not resolve a source URL for '$tag'."
        return 1
    }

    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        [ "$candidate" != "$refreshed" ] || continue
        bedrock_aok_cache_set_url "$tag" "$candidate" || continue
        if run_cmd "Trying alternate mirror for $tag" "$brl" fetch "$tag"; then
            log "bedrock-aok: $tag fetched from alternate mirror $candidate"
            return 0
        fi
    done <<< "$(bedrock_aok_mirror_candidates "$refreshed")"

    # Do not leave a failed alternate mirror cached.
    bedrock_aok_cache_set_url "$tag" "$refreshed" || true
    tui_msg "Stratum download failed" \
        "All known sources failed for '$tag'. The upstream-resolved URL was restored."
    return 1
}

bedrock_aok_refresh_urls_resilient() {
    local brl
    bedrock_aok_require || return 1
    brl=$(bedrock_aok_brl) || return 1
    run_cmd "Refresh Bedrock-AOK stratum URLs" "$brl" update-urls
}

# Override the earlier fetch menu so every selected stratum receives automatic
# refresh + mirror fallback behavior.
bedrock_aok_fetch_menu() {
    local rows sel tag label
    local -a opts=()
    bedrock_aok_require || return 0
    rows=$(bedrock_aok_available_strata 2>/dev/null || true)
    while IFS='|' read -r tag label; do
        [ -n "$tag" ] || continue
        opts+=("$tag" "$label" off)
    done <<< "$rows"

    if [ ${#opts[@]} -eq 0 ]; then
        tui_msg "Could not parse distro list" \
            "systui could not parse 'brl fetch --list'. The raw list will be shown next."
        bedrock_aok_run "Available Bedrock-AOK strata" fetch --list || true
        return 1
    fi

    sel=$(tui_check "Fetch Bedrock-AOK strata" \
        "Available distributions (SPACE toggles multiple, ENTER fetches):" \
        "${opts[@]}") || return 0
    sel=${sel//\"/}
    [ -n "${sel//[[:space:]]/}" ] || return 0
    for tag in $sel; do
        bedrock_aok_fetch_stratum_resilient "$tag" || true
    done
    bedrock_aok_run "Reload cross-distro wrappers" reload || true
}

# Reassert the update menu so URL refresh uses the resilient front door while
# leaving package/program updates unchanged.
bedrock_aok_update_menu() {
    local c brl st
    bedrock_aok_require || return 0
    brl=$(bedrock_aok_brl) || return 1
    while true; do
        c=$(tui_menu "Bedrock-AOK update" "Choose what to update:" \
            program "Update Bedrock-AOK itself from upstream" \
            one     "Update packages in one installed stratum" \
            all     "Update packages in all installed strata" \
            urls    "Refresh live stratum source URLs" \
            back    "Back") || return 0
        case "$c" in
            back|"") return 0 ;;
            program) bedrock_aok_self_update ;;
            one)
                st=$(bedrock_aok_pick_stratum "Update stratum" "Choose a stratum") || continue
                run_cmd "Update $st" "$brl" update "$st"
                ;;
            all) run_cmd "Update all Bedrock-AOK strata" "$brl" update ;;
            urls) bedrock_aok_refresh_urls_resilient ;;
        esac
    done
}

return 0 2>/dev/null || true
