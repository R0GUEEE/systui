# shellcheck shell=bash
# PHASE 82 — web-discovered Bedrock distro sources.
#
# Systui parses trusted distro-maintained HTTP indexes at runtime, caches
# discovered rootfs URLs, and merges them into Bedrock's distro picker.
# This supplements phase 81's fixed/custom fallbacks without replacing upstream.

BEDROCK_AOK_DISCOVERY_CACHE=${BEDROCK_AOK_DISCOVERY_CACHE:-/bedrock/etc/systui-discovered-sources.cache}
BEDROCK_AOK_DISCOVERY_TTL=${BEDROCK_AOK_DISCOVERY_TTL:-21600}

bedrock_aok_discovery_now() { date +%s 2>/dev/null || printf '0\n'; }

bedrock_aok_discovery_cache_fresh() {
    local now stamp age
    [ -r "$BEDROCK_AOK_DISCOVERY_CACHE" ] || return 1
    stamp=$(awk -F= '/^# generated=/{print $2; exit}' "$BEDROCK_AOK_DISCOVERY_CACHE" 2>/dev/null || true)
    case "$stamp" in ''|*[!0-9]*) return 1 ;; esac
    now=$(bedrock_aok_discovery_now)
    case "$now" in ''|*[!0-9]*) return 1 ;; esac
    age=$((now - stamp))
    [ "$age" -ge 0 ] && [ "$age" -lt "$BEDROCK_AOK_DISCOVERY_TTL" ]
}

bedrock_aok_discovery_http() { # <url>
    bedrock_aok_http_text "$1"
}

bedrock_aok_discovery_host_arch() {
    bedrock_aok_host_arch 2>/dev/null || return 1
}

bedrock_aok_discovery_alpine() {
    local arch webarch base html file
    arch=$(bedrock_aok_discovery_host_arch) || return 0
    case "$arch" in
        arm64) webarch=aarch64 ;;
        amd64) webarch=x86_64 ;;
        armhf) webarch=armhf ;;
        riscv64) webarch=riscv64 ;;
        *) return 0 ;;
    esac
    base="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$webarch"
    html=$(bedrock_aok_discovery_http "$base/" 2>/dev/null || true)
    [ -n "$html" ] || return 0
    file=$(printf '%s\n' "$html" | grep -Eo "alpine-minirootfs-[0-9][0-9A-Za-z._-]*-$webarch\\.tar\\.gz" | LC_ALL=C sort -Vu | tail -n1)
    [ -n "$file" ] || return 0
    printf 'alpine|Alpine Linux — discovered official minirootfs|%s/%s|alpinelinux.org\n' "$base" "$file"
}

bedrock_aok_discovery_ubuntu() {
    local arch uarch releases latest base html file
    arch=$(bedrock_aok_discovery_host_arch) || return 0
    case "$arch" in
        arm64) uarch=arm64 ;;
        amd64) uarch=amd64 ;;
        armhf) uarch=armhf ;;
        riscv64) uarch=riscv64 ;;
        *) return 0 ;;
    esac
    releases='https://cdimage.ubuntu.com/ubuntu-base/releases'
    html=$(bedrock_aok_discovery_http "$releases/" 2>/dev/null || true)
    [ -n "$html" ] || return 0
    latest=$(printf '%s\n' "$html" | grep -Eo 'href="[0-9]{2}\\.[0-9]{2}/"' | sed -E 's/^href="//;s#/$##;s/"$//' | LC_ALL=C sort -Vu | tail -n1)
    [ -n "$latest" ] || return 0
    base="$releases/$latest/release"
    html=$(bedrock_aok_discovery_http "$base/" 2>/dev/null || true)
    [ -n "$html" ] || return 0
    file=$(printf '%s\n' "$html" | grep -Eo "ubuntu-base-$latest-base-$uarch\\.tar\\.gz" | head -n1)
    [ -n "$file" ] || return 0
    printf 'ubuntu|Ubuntu Base %s — discovered official rootfs|%s/%s|cdimage.ubuntu.com\n' "$latest" "$base" "$file"
}

bedrock_aok_discovery_void() {
    local arch var base html file
    arch=$(bedrock_aok_discovery_host_arch) || return 0
    case "$arch" in
        arm64) var=aarch64 ;;
        amd64) var=x86_64 ;;
        armhf) var=armv7l ;;
        *) return 0 ;;
    esac
    base='https://repo-default.voidlinux.org/live/current'
    html=$(bedrock_aok_discovery_http "$base/" 2>/dev/null || true)
    [ -n "$html" ] || return 0
    file=$(printf '%s\n' "$html" | grep -Eo "void-$var-ROOTFS-[0-9]+\\.tar\\.xz" | LC_ALL=C sort -Vu | tail -n1)
    [ -n "$file" ] && printf 'void|Void Linux — discovered glibc ROOTFS|%s/%s|voidlinux.org\n' "$base" "$file"
    file=$(printf '%s\n' "$html" | grep -Eo "void-$var-musl-ROOTFS-[0-9]+\\.tar\\.xz" | LC_ALL=C sort -Vu | tail -n1)
    [ -n "$file" ] && printf 'void-musl|Void Linux musl — discovered ROOTFS|%s/%s|voidlinux.org\n' "$base" "$file"
}

bedrock_aok_discovery_gentoo_variant() { # <tag> <path-arch> <stage-name> <label>
    local tag="$1" patharch="$2" stage="$3" label="$4" base txt file
    base="https://distfiles.gentoo.org/releases/$patharch/autobuilds/current-$stage"
    txt=$(bedrock_aok_discovery_http "$base/latest-$stage.txt" 2>/dev/null || true)
    file=$(printf '%s\n' "$txt" | awk '!/^#/ && $1 ~ /\\.tar\\.(xz|gz|zst)$/ {print $1; exit}')
    [ -n "$file" ] || return 0
    printf '%s|%s|%s/%s|gentoo.org\n' "$tag" "$label" "$base" "$file"
}

bedrock_aok_discovery_gentoo() {
    local arch
    arch=$(bedrock_aok_discovery_host_arch) || return 0
    case "$arch" in
        arm64)
            bedrock_aok_discovery_gentoo_variant gentoo arm64 stage3-arm64-openrc 'Gentoo — discovered OpenRC stage3'
            bedrock_aok_discovery_gentoo_variant gentoo-systemd arm64 stage3-arm64-systemd 'Gentoo — discovered systemd stage3'
            bedrock_aok_discovery_gentoo_variant gentoo-musl arm64 stage3-arm64-musl-openrc 'Gentoo musl — discovered OpenRC stage3'
            ;;
        amd64)
            bedrock_aok_discovery_gentoo_variant gentoo amd64 stage3-amd64-openrc 'Gentoo — discovered OpenRC stage3'
            bedrock_aok_discovery_gentoo_variant gentoo-systemd amd64 stage3-amd64-systemd 'Gentoo — discovered systemd stage3'
            ;;
        armhf)
            bedrock_aok_discovery_gentoo_variant gentoo arm stage3-armv7a-openrc 'Gentoo ARMv7 — discovered OpenRC stage3'
            ;;
    esac
}

bedrock_aok_discovery_collect() {
    bedrock_aok_discovery_alpine
    bedrock_aok_discovery_ubuntu
    bedrock_aok_discovery_void
    bedrock_aok_discovery_gentoo
}

bedrock_aok_discovery_refresh() {
    local dir tmp now rows
    dir=${BEDROCK_AOK_DISCOVERY_CACHE%/*}
    mkdir -p "$dir" || return 1
    tmp=$(mktemp "${SYSTUI_TMP:-${TMPDIR:-/tmp}}/bedrock-discovery.XXXXXX") || return 1
    now=$(bedrock_aok_discovery_now)
    rows=$(bedrock_aok_discovery_collect 2>/dev/null || true)
    {
        printf '# systui Bedrock web-discovery cache\n'
        printf '# generated=%s\n' "$now"
        printf '# tag|label|url|origin\n'
        [ -n "$rows" ] && printf '%s\n' "$rows"
    } > "$tmp"
    chmod 0644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$BEDROCK_AOK_DISCOVERY_CACHE"
    [ -n "$rows" ]
}

bedrock_aok_discovery_rows() {
    if ! bedrock_aok_discovery_cache_fresh; then
        bedrock_aok_discovery_refresh >/dev/null 2>&1 || true
    fi
    [ -r "$BEDROCK_AOK_DISCOVERY_CACHE" ] || return 0
    awk -F'|' 'NF >= 3 && $1 !~ /^#/ && $1 != "" {print}' "$BEDROCK_AOK_DISCOVERY_CACHE"
}

bedrock_aok_discovery_source_urls() { # <tag>
    local wanted="$1" tag label url origin
    while IFS='|' read -r tag label url origin; do
        [ "$tag" = "$wanted" ] || continue
        printf '%s\n' "$url"
    done <<< "$(bedrock_aok_discovery_rows)"
}

# Extend phase 81 source resolution with live web discoveries.
if declare -F bedrock_aok_extra_source_urls >/dev/null 2>&1 && ! declare -F _bedrock_aok_extra_source_urls_before_web >/dev/null 2>&1; then
    eval "$(declare -f bedrock_aok_extra_source_urls | sed '1s/^bedrock_aok_extra_source_urls[[:space:]]*()/_bedrock_aok_extra_source_urls_before_web ()/')"
fi
bedrock_aok_extra_source_urls() {
    local tag="$1"
    {
        _bedrock_aok_extra_source_urls_before_web "$tag" 2>/dev/null || true
        bedrock_aok_discovery_source_urls "$tag"
    } | awk 'NF && !seen[$0]++'
}

if declare -F bedrock_aok_extra_catalog_rows >/dev/null 2>&1 && ! declare -F _bedrock_aok_extra_catalog_rows_before_web >/dev/null 2>&1; then
    eval "$(declare -f bedrock_aok_extra_catalog_rows | sed '1s/^bedrock_aok_extra_catalog_rows[[:space:]]*()/_bedrock_aok_extra_catalog_rows_before_web ()/')"
fi
bedrock_aok_extra_catalog_rows() {
    local tag label url origin
    {
        _bedrock_aok_extra_catalog_rows_before_web 2>/dev/null || true
        while IFS='|' read -r tag label url origin; do
            [ -n "$tag" ] && printf '%s|%s\n' "$tag" "$label"
        done <<< "$(bedrock_aok_discovery_rows)"
    } | awk -F'|' 'NF >= 1 && $1 != "" && !seen[$1]++ {print}'
}

bedrock_aok_discovery_report() {
    local out="${SYSTUI_TMP:?}/bedrock-web-discovery"
    {
        echo 'Bedrock web-discovered distro sources'
        echo '======================================'
        echo "Cache: $BEDROCK_AOK_DISCOVERY_CACHE"
        echo "TTL  : $BEDROCK_AOK_DISCOVERY_TTL seconds"
        echo
        printf '%-18s %-18s %s\n' TAG ORIGIN URL
        printf '%-18s %-18s %s\n' '------------------' '------------------' '---'
        awk -F'|' 'NF >= 4 && $1 !~ /^#/ {printf "%-18s %-18s %s\n", $1, $4, $3}' "$BEDROCK_AOK_DISCOVERY_CACHE" 2>/dev/null || true
    } > "$out"
    tui_text "Bedrock web source discovery" "$out"
}

# Replace phase 81 sources menu with explicit web discovery controls.
bedrock_aok_sources_menu() {
    local c
    while true; do
        c=$(tui_menu "Bedrock distro sources" "Upstream first; Systui can discover additional official rootfs sources from the web." \
            discover "Scan distro web indexes now" \
            discovered "Show cached web-discovered sources" \
            list "Show built-in/custom fallback source help" \
            edit "Edit custom distro source registry" \
            refresh "Refresh Bedrock upstream/LXC URL cache" \
            back "Back") || return 0
        case "$c" in
            discover)
                if bedrock_aok_discovery_refresh; then tui_msg "Bedrock sources" "Web discovery completed and the distro picker cache was refreshed."
                else tui_msg "Bedrock sources" "Web discovery did not find new usable rootfs entries; the previous cache is retained only if still present."; fi
                ;;
            discovered) bedrock_aok_discovery_report ;;
            list) bedrock_aok_extra_sources_help ;;
            edit) bedrock_aok_extra_sources_edit ;;
            refresh) bedrock_aok_refresh_urls_resilient || true ;;
            back|'') return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
