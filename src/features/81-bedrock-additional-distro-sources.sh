# shellcheck shell=bash
# PHASE 81 — independent Bedrock distro-source fallbacks.
# Upstream/LXC resolution remains first priority.  When it cannot resolve or
# fetch a stratum, Systui may use distro-maintained rootfs archives or explicit
# user-defined sources from /bedrock/etc/systui-distro-sources.conf.

BEDROCK_AOK_EXTRA_SOURCES=${BEDROCK_AOK_EXTRA_SOURCES:-/bedrock/etc/systui-distro-sources.conf}

bedrock_aok_extra_arch() { # <family>
    local family="$1" a
    a=$(bedrock_aok_host_arch 2>/dev/null || true)
    case "$family:$a" in
        alpine:arm64|void:arm64|gentoo:arm64) printf 'aarch64\n' ;;
        alpine:amd64|void:amd64|gentoo:amd64) printf 'x86_64\n' ;;
        ubuntu:arm64) printf 'arm64\n' ;;
        ubuntu:amd64) printf 'amd64\n' ;;
        arch:arm64) printf 'aarch64\n' ;;
        *) return 1 ;;
    esac
}

bedrock_aok_extra_http_index_latest() { # <url> <extended-regex>
    local url="$1" regex="$2" html
    html=$(bedrock_aok_http_text "$url" 2>/dev/null || true)
    [ -n "$html" ] || return 1
    printf '%s\n' "$html" \
        | grep -Eo "$regex" 2>/dev/null \
        | LC_ALL=C sort -Vu \
        | tail -n 1
}

bedrock_aok_extra_builtin_urls() { # <tag>
    local tag="$1" a base file listing
    case "$tag" in
        alpine)
            a=$(bedrock_aok_extra_arch alpine) || return 1
            base="https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$a"
            file=$(bedrock_aok_extra_http_index_latest "$base/" "alpine-minirootfs-[0-9][0-9A-Za-z._-]*-$a\\.tar\\.gz") || return 1
            printf '%s/%s\n' "$base" "$file"
            ;;
        ubuntu)
            a=$(bedrock_aok_extra_arch ubuntu) || return 1
            printf 'https://cdimage.ubuntu.com/ubuntu-base/releases/26.04/release/ubuntu-base-26.04-base-%s.tar.gz\n' "$a"
            ;;
        void)
            a=$(bedrock_aok_extra_arch void) || return 1
            base='https://repo-default.voidlinux.org/live/current'
            file=$(bedrock_aok_extra_http_index_latest "$base/" "void-[0-9][0-9A-Za-z._-]*-$a-ROOTFS\\.tar\\.xz") || return 1
            printf '%s/%s\n' "$base" "$file"
            ;;
        gentoo)
            a=$(bedrock_aok_extra_arch gentoo) || return 1
            case "$a" in aarch64) a=arm64 ;; x86_64) a=amd64 ;; esac
            base="https://distfiles.gentoo.org/releases/$a/autobuilds/current-stage3-$a-openrc"
            listing=$(bedrock_aok_http_text "$base/latest-stage3-$a-openrc.txt" 2>/dev/null || true)
            file=$(printf '%s\n' "$listing" | awk '!/^#/ && $1 ~ /stage3-.*\\.tar\\.xz$/ {print $1; exit}')
            [ -n "$file" ] || {
                file=$(bedrock_aok_extra_http_index_latest "$base/" "stage3-$a-openrc-[0-9TZ]+\\.tar\\.xz") || return 1
            }
            printf '%s/%s\n' "$base" "$file"
            ;;
        arch)
            a=$(bedrock_aok_extra_arch arch) || return 1
            [ "$a" = aarch64 ] || return 1
            printf 'http://os.archlinuxarm.org/os/ArchLinuxARM-aarch64-latest.tar.gz\n'
            ;;
        *) return 1 ;;
    esac
}

bedrock_aok_extra_user_rows() {
    local line tag label url
    [ -r "$BEDROCK_AOK_EXTRA_SOURCES" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        IFS='|' read -r tag label url <<EOF
$line
EOF
        case "$tag" in ''|*[!A-Za-z0-9+._-]*) continue ;; esac
        [ -n "$url" ] || continue
        [ -n "$label" ] || label="$tag (custom source)"
        printf '%s|%s|%s\n' "$tag" "$label" "$url"
    done < "$BEDROCK_AOK_EXTRA_SOURCES"
}

bedrock_aok_extra_expand_url() { # <url-template>
    local url="$1" arch
    arch=$(bedrock_aok_host_arch 2>/dev/null || true)
    url=${url//\{arch\}/$arch}
    printf '%s\n' "$url"
}

bedrock_aok_extra_source_urls() { # <tag>
    local tag="$1" rtag label url built
    built=$(bedrock_aok_extra_builtin_urls "$tag" 2>/dev/null || true)
    [ -n "$built" ] && printf '%s\n' "$built"
    while IFS='|' read -r rtag label url; do
        [ "$rtag" = "$tag" ] || continue
        bedrock_aok_extra_expand_url "$url"
    done <<< "$(bedrock_aok_extra_user_rows)"
}

bedrock_aok_extra_catalog_rows() {
    printf '%s\n' \
        'alpine|Alpine Linux — official minirootfs fallback' \
        'ubuntu|Ubuntu — official Ubuntu Base fallback' \
        'void|Void Linux — official ROOTFS fallback' \
        'gentoo|Gentoo — official OpenRC stage3 fallback' \
        'arch|Arch Linux ARM — official rootfs fallback'
    local tag label url
    while IFS='|' read -r tag label url; do
        [ -n "$tag" ] && printf '%s|%s\n' "$tag" "$label"
    done <<< "$(bedrock_aok_extra_user_rows)"
}

if declare -F bedrock_aok_available_strata >/dev/null 2>&1 && ! declare -F _bedrock_aok_available_strata_before_extra_sources >/dev/null 2>&1; then
    eval "$(declare -f bedrock_aok_available_strata | sed '1s/^bedrock_aok_available_strata[[:space:]]*()/_bedrock_aok_available_strata_before_extra_sources ()/')"
fi
bedrock_aok_available_strata() {
    {
        _bedrock_aok_available_strata_before_extra_sources 2>/dev/null || true
        bedrock_aok_extra_catalog_rows
    } | awk -F'|' 'NF >= 1 && $1 != "" && !seen[$1]++ { print $0 }'
}

if declare -F bedrock_aok_fetch_stratum_resilient >/dev/null 2>&1 && ! declare -F _bedrock_aok_fetch_stratum_before_extra_sources >/dev/null 2>&1; then
    eval "$(declare -f bedrock_aok_fetch_stratum_resilient | sed '1s/^bedrock_aok_fetch_stratum_resilient[[:space:]]*()/_bedrock_aok_fetch_stratum_before_extra_sources ()/')"
fi
bedrock_aok_fetch_stratum_resilient() { # <stratum>
    local tag="$1" url brl tried=0
    _bedrock_aok_fetch_stratum_before_extra_sources "$tag" && return 0
    brl=$(bedrock_aok_brl) || return 1
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        tried=$((tried + 1))
        log "bedrock-aok: trying independent fallback source for $tag: $url"
        bedrock_aok_cache_set_url "$tag" "$url" 2>/dev/null || true
        if run_cmd "Fetching $tag from alternate distro source" "$brl" fetch-url "$tag" "$url"; then
            log "bedrock-aok: fetched $tag from independent source $url"
            return 0
        fi
    done <<< "$(bedrock_aok_extra_source_urls "$tag")"
    [ "$tried" -gt 0 ] && tui_msg "Stratum download failed" "Upstream, mirrors, and $tried independent fallback source(s) failed for '$tag'." || true
    return 1
}

bedrock_aok_extra_sources_help() {
    local out="${SYSTUI_TMP:?}/bedrock-extra-sources-help"
    cat > "$out" <<EOF
Additional Bedrock distro sources
==================================

Systui always tries Bedrock/upstream and LinuxContainers mirrors first.
Independent distro-maintained rootfs sources are fallback-only.

Built-in fallbacks:
  alpine  - Alpine official minirootfs
  ubuntu  - Ubuntu official Ubuntu Base
  void    - Void official ROOTFS archive
  gentoo  - Gentoo official OpenRC stage3
  arch    - Arch Linux ARM official rootfs

Custom source file:
  $BEDROCK_AOK_EXTRA_SOURCES

Format:
  tag|Menu label|https://example/rootfs-{arch}.tar.xz

Multiple rows with the same tag are allowed. {arch} expands to Bedrock's
normalized host architecture (arm64, amd64, riscv64, armhf).
EOF
    tui_text "Bedrock additional sources" "$out"
}

bedrock_aok_extra_sources_edit() {
    mkdir -p "${BEDROCK_AOK_EXTRA_SOURCES%/*}" || return 1
    [ -e "$BEDROCK_AOK_EXTRA_SOURCES" ] || {
        printf '# tag|Menu label|rootfs URL (supports {arch})\n' > "$BEDROCK_AOK_EXTRA_SOURCES"
    }
    if declare -F safe_edit >/dev/null 2>&1; then safe_edit "$BEDROCK_AOK_EXTRA_SOURCES"; else "${EDITOR:-vi}" "$BEDROCK_AOK_EXTRA_SOURCES"; fi
}

bedrock_aok_sources_menu() {
    local c
    while true; do
        c=$(tui_menu "Bedrock distro sources" "Upstream first; independent sources are automatic fallbacks." \
            list "Show built-in and custom fallback sources" \
            edit "Edit custom distro source registry" \
            refresh "Refresh Bedrock upstream/LXC URL cache" \
            back "Back") || return 0
        case "$c" in
            list) bedrock_aok_extra_sources_help ;;
            edit) bedrock_aok_extra_sources_edit ;;
            refresh) bedrock_aok_refresh_urls_resilient || true ;;
            back|'') return 0 ;;
        esac
    done
}

if declare -F bedrock_aok_strata_menu >/dev/null 2>&1 && ! declare -F _bedrock_aok_strata_menu_before_extra_sources >/dev/null 2>&1; then
    eval "$(declare -f bedrock_aok_strata_menu | sed '1s/^bedrock_aok_strata_menu[[:space:]]*()/_bedrock_aok_strata_menu_before_extra_sources ()/')"
fi
bedrock_aok_strata_menu() {
    local c
    while true; do
        c=$(tui_menu "Bedrock-AOK strata" "Manage Bedrock-AOK distributions:" \
            fetch "Fetch distributions (upstream + alternate sources)" \
            sources "Manage alternate distro sources" \
            existing "Other stratum management actions" \
            back "Back") || return 0
        case "$c" in
            fetch) bedrock_aok_fetch_menu ;;
            sources) bedrock_aok_sources_menu ;;
            existing) _bedrock_aok_strata_menu_before_extra_sources ;;
            back|'') return 0 ;;
        esac
    done
}

return 0 2>/dev/null || true
