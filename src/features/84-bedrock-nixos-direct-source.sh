# shellcheck shell=bash
# PHASE 84 — first-class NixOS Bedrock source.
#
# NixOS is not consistently present in the LinuxContainers catalog.  NixOS
# itself publishes real container rootfs tarballs through Hydra, so prefer
# those for the `nixos` stratum before falling back to the Nix-only OCI image.

bedrock_aok_nixos_arch() {
    local a
    a=$(bedrock_aok_host_arch 2>/dev/null || true)
    case "$a" in
        arm64) printf 'aarch64-linux\n' ;;
        amd64) printf 'x86_64-linux\n' ;;
        *) return 1 ;;
    esac
}

bedrock_aok_nixos_release_series() {
    local html releases
    html=$(bedrock_aok_http_text 'https://hydra.nixos.org/project/nixos' 2>/dev/null || true)
    releases=$(printf '%s\n' "$html" \
        | grep -Eo 'release-[0-9]{2}\.[0-9]{2}' 2>/dev/null \
        | sed 's/^release-//' \
        | LC_ALL=C sort -Vu \
        | tail -n 4 \
        | sort -Vr)
    if [ -n "$releases" ]; then
        printf '%s\n' "$releases"
    else
        # Safe known series if Hydra's project index is temporarily unavailable.
        printf '%s\n' 26.05 25.11
    fi
}

bedrock_aok_nixos_hydra_urls() {
    local arch rel
    arch=$(bedrock_aok_nixos_arch) || return 1
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        printf 'https://hydra.nixos.org/job/nixos/release-%s/nixos.containerTarball.%s/latest/download-by-type/file/system-tarball\n' "$rel" "$arch"
        # Proxmox/LXC image is another genuine NixOS container rootfs and can
        # survive changes to the generic containerTarball job name.
        printf 'https://hydra.nixos.org/job/nixos/release-%s/nixos.proxmoxLXC.%s/latest/download-by-type/file/system-tarball\n' "$rel" "$arch"
    done <<< "$(bedrock_aok_nixos_release_series)"
}

bedrock_aok_nixos_fetch_direct() {
    local brl url tried=0
    brl=$(bedrock_aok_brl) || return 1
    while IFS= read -r url; do
        [ -n "$url" ] || continue
        tried=$((tried + 1))
        log "bedrock-aok: trying official NixOS Hydra rootfs: $url"
        if "$brl" fetch-url nixos "$url"; then
            bedrock_aok_cache_set_url nixos "$url" 2>/dev/null || true
            "$brl" fix nixos >/dev/null 2>&1 || true
            "$brl" enable nixos >/dev/null 2>&1 || true
            "$brl" reload >/dev/null 2>&1 || true
            log "bedrock-aok: installed nixos from official Hydra container tarball"
            return 0
        fi
    done <<< "$(bedrock_aok_nixos_hydra_urls)"
    [ "$tried" -gt 0 ] && log "bedrock-aok: all $tried official NixOS Hydra rootfs candidates failed"
    return 1
}

# NixOS must always be visible even when brl/LXC does not advertise it.
if declare -F bedrock_aok_available_strata >/dev/null 2>&1 && ! declare -F _bedrock_aok_available_strata_before_nixos >/dev/null 2>&1; then
    eval "$(declare -f bedrock_aok_available_strata | sed '1s/^bedrock_aok_available_strata[[:space:]]*()/_bedrock_aok_available_strata_before_nixos ()/')"
fi
bedrock_aok_available_strata() {
    {
        printf 'nixos|NixOS — official Hydra container rootfs\n'
        _bedrock_aok_available_strata_before_nixos 2>/dev/null || true
    } | awk -F'|' 'NF >= 1 && $1 != "" && !seen[$1]++ { print }'
}

if declare -F bedrock_aok_fetch_stratum_resilient >/dev/null 2>&1 && ! declare -F _bedrock_aok_fetch_stratum_before_nixos >/dev/null 2>&1; then
    eval "$(declare -f bedrock_aok_fetch_stratum_resilient | sed '1s/^bedrock_aok_fetch_stratum_resilient[[:space:]]*()/_bedrock_aok_fetch_stratum_before_nixos ()/')"
fi
bedrock_aok_fetch_stratum_resilient() {
    local tag="$1"
    if [ "$tag" = nixos ]; then
        # Skip LinuxContainers for NixOS: Hydra is the authoritative source and
        # provides an actual NixOS container filesystem.
        if bedrock_aok_nixos_fetch_direct; then
            tui_msg "NixOS installed" "Installed the NixOS stratum from the official NixOS Hydra container rootfs."
            return 0
        fi
        # Preserve the OCI/Nix fallback as a final recovery path.
        _bedrock_aok_fetch_stratum_before_nixos "$tag"
        return $?
    fi
    _bedrock_aok_fetch_stratum_before_nixos "$tag"
}

return 0 2>/dev/null || true
