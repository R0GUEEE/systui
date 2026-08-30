# shellcheck shell=bash
# PHASE 83 — OCI/container-registry fallback sources for Bedrock.
# Used only after normal Bedrock/LXC/direct-rootfs sources fail.

BEDROCK_AOK_OCI_SOURCES=${BEDROCK_AOK_OCI_SOURCES:-/bedrock/etc/systui-oci-sources.conf}

bedrock_aok_oci_builtin_rows() {
    cat <<'EOF'
nixos|NixOS/Nix — official NixOS Nix image fallback|docker.io/nixos/nix:latest
manjaro|Manjaro — project base image fallback|docker.io/manjarolinux/base:latest
opensuse|openSUSE Tumbleweed — project image fallback|docker.io/opensuse/tumbleweed:latest
rockylinux|Rocky Linux 9 — official image fallback|docker.io/rockylinux:9
almalinux|AlmaLinux 9 — official image fallback|docker.io/almalinux:9
fedora|Fedora — Fedora registry fallback|registry.fedoraproject.org/fedora:latest
centos|CentOS Stream 9 — CentOS registry fallback|quay.io/centos/centos:stream9
archlinux|Arch Linux — official image fallback|docker.io/archlinux:latest
debian|Debian stable — official image fallback|docker.io/debian:stable-slim
ubuntu|Ubuntu — official image fallback|docker.io/ubuntu:latest
alpine|Alpine — official image fallback|docker.io/alpine:latest
EOF
}

bedrock_aok_oci_user_rows() {
    local line tag label image
    [ -r "$BEDROCK_AOK_OCI_SOURCES" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in ''|'#'*) continue ;; esac
        IFS='|' read -r tag label image <<EOF
$line
EOF
        case "$tag" in ''|*[!A-Za-z0-9+._-]*) continue ;; esac
        [ -n "$image" ] || continue
        [ -n "$label" ] || label="$tag (OCI fallback)"
        printf '%s|%s|%s\n' "$tag" "$label" "$image"
    done < "$BEDROCK_AOK_OCI_SOURCES"
}

bedrock_aok_oci_rows() {
    { bedrock_aok_oci_builtin_rows; bedrock_aok_oci_user_rows; } \
        | awk -F'|' 'NF >= 3 && !seen[$1 FS $3]++ { print }'
}

bedrock_aok_oci_images_for() { # <tag>
    local wanted="$1" tag label image
    while IFS='|' read -r tag label image; do
        [ "$tag" = "$wanted" ] && printf '%s\n' "$image"
    done <<< "$(bedrock_aok_oci_rows)"
}

bedrock_aok_oci_catalog_rows() {
    local tag label image
    while IFS='|' read -r tag label image; do
        [ -n "$tag" ] && printf '%s|%s\n' "$tag" "$label"
    done <<< "$(bedrock_aok_oci_rows)"
}

bedrock_aok_oci_try_install_tools() {
    command -v skopeo >/dev/null 2>&1 && command -v umoci >/dev/null 2>&1 && return 0
    if declare -F pm_install >/dev/null 2>&1; then
        pm_install skopeo umoci >/dev/null 2>&1 || true
    fi
    command -v skopeo >/dev/null 2>&1 && command -v umoci >/dev/null 2>&1
}

bedrock_aok_oci_unpack() { # <image> <rootfs-dir>
    local image="$1" rootfs="$2" work oci bundle
    work=$(mktemp -d "${SYSTUI_TMP:-${TMPDIR:-/tmp}}/bedrock-oci.XXXXXX") || return 1
    oci="$work/image"
    bundle="$work/bundle"
    if ! bedrock_aok_oci_try_install_tools; then
        rm -rf "$work"
        return 127
    fi
    if ! skopeo copy --retry-times 3 "docker://$image" "oci:$oci:latest"; then
        rm -rf "$work"
        return 1
    fi
    if ! umoci unpack --image "$oci:latest" "$bundle"; then
        rm -rf "$work"
        return 1
    fi
    [ -d "$bundle/rootfs" ] || { rm -rf "$work"; return 1; }
    mkdir -p "$rootfs" || { rm -rf "$work"; return 1; }
    cp -a "$bundle/rootfs/." "$rootfs/" || { rm -rf "$work"; return 1; }
    rm -rf "$work"
}

bedrock_aok_oci_install_stratum() { # <tag> <image>
    local tag="$1" image="$2" brl staging target backup
    brl=$(bedrock_aok_brl) || return 1
    target="/bedrock/strata/$tag"
    staging="/bedrock/strata/.${tag}.oci.$$"
    backup="/bedrock/strata/.${tag}.pre-oci.$$"
    rm -rf "$staging"
    mkdir -p /bedrock/strata "$staging" || return 1
    log "bedrock-aok: importing OCI fallback $image as stratum $tag"
    if ! bedrock_aok_oci_unpack "$image" "$staging"; then
        rm -rf "$staging"
        return 1
    fi
    [ -x "$staging/bin/sh" ] || [ -x "$staging/usr/bin/sh" ] || {
        rm -rf "$staging"
        return 1
    }
    if [ -e "$target" ]; then
        mv "$target" "$backup" || { rm -rf "$staging"; return 1; }
    fi
    if ! mv "$staging" "$target"; then
        [ -e "$backup" ] && mv "$backup" "$target" 2>/dev/null || true
        return 1
    fi
    "$brl" fix "$tag" >/dev/null 2>&1 || true
    "$brl" enable "$tag" >/dev/null 2>&1 || true
    "$brl" reload >/dev/null 2>&1 || true
    rm -rf "$backup"
    return 0
}

if declare -F bedrock_aok_available_strata >/dev/null 2>&1 && ! declare -F _bedrock_aok_available_strata_before_oci >/dev/null 2>&1; then
    eval "$(declare -f bedrock_aok_available_strata | sed '1s/^bedrock_aok_available_strata[[:space:]]*()/_bedrock_aok_available_strata_before_oci ()/')"
fi
bedrock_aok_available_strata() {
    { _bedrock_aok_available_strata_before_oci 2>/dev/null || true; bedrock_aok_oci_catalog_rows; } \
        | awk -F'|' 'NF >= 1 && $1 != "" && !seen[$1]++ { print }'
}

if declare -F bedrock_aok_fetch_stratum_resilient >/dev/null 2>&1 && ! declare -F _bedrock_aok_fetch_stratum_before_oci >/dev/null 2>&1; then
    eval "$(declare -f bedrock_aok_fetch_stratum_resilient | sed '1s/^bedrock_aok_fetch_stratum_resilient[[:space:]]*()/_bedrock_aok_fetch_stratum_before_oci ()/')"
fi
bedrock_aok_fetch_stratum_resilient() { # <tag>
    local tag="$1" image tried=0
    _bedrock_aok_fetch_stratum_before_oci "$tag" && return 0
    while IFS= read -r image; do
        [ -n "$image" ] || continue
        tried=$((tried + 1))
        if bedrock_aok_oci_install_stratum "$tag" "$image"; then
            tui_msg "Bedrock OCI fallback" "Installed '$tag' from OCI fallback:\n$image"
            return 0
        fi
    done <<< "$(bedrock_aok_oci_images_for "$tag")"
    [ "$tried" -gt 0 ] && log "bedrock-aok: all $tried OCI fallback(s) failed for $tag"
    return 1
}

bedrock_aok_oci_sources_edit() {
    mkdir -p "${BEDROCK_AOK_OCI_SOURCES%/*}" || return 1
    [ -e "$BEDROCK_AOK_OCI_SOURCES" ] || printf '# tag|Menu label|registry/image:tag\n' > "$BEDROCK_AOK_OCI_SOURCES"
    if declare -F safe_edit >/dev/null 2>&1; then safe_edit "$BEDROCK_AOK_OCI_SOURCES"; else "${EDITOR:-vi}" "$BEDROCK_AOK_OCI_SOURCES"; fi
}

return 0 2>/dev/null || true
