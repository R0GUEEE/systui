# shellcheck shell=bash
# PHASE 68 — patch Bedrock-AOK's own stratum resolver/catalog refresh.

if declare -F bedrock_aok_patch_script >/dev/null 2>&1 \
    && ! declare -F _systui_base_bedrock_aok_patch_script_catalog >/dev/null 2>&1; then
    _systui_brl_patch_def=$(declare -f bedrock_aok_patch_script)
    _systui_brl_patch_def=${_systui_brl_patch_def/#bedrock_aok_patch_script ()/_systui_base_bedrock_aok_patch_script_catalog ()}
    eval "$_systui_brl_patch_def"
    unset _systui_brl_patch_def
fi

bedrock_aok_patch_catalog_resolver() { # <script>
    local f="$1" tmp insert
    [ -f "$f" ] || return 1
    grep -q '^# __SYSTUI_CATALOG_RESOLVER_PATCH__' "$f" 2>/dev/null && return 0
    grep -q '^lookup_url()' "$f" 2>/dev/null || return 0

    insert=$(mktemp "${SYSTUI_TMP:-${TMPDIR:-/tmp}}/systui-brl-insert.XXXXXX") || return 1
    cat > "$insert" <<'PATCH'
# __SYSTUI_CATALOG_RESOLVER_PATCH__
_systui_lxc_resolve() {
    _s_distro="$1"; _s_release="$2"; _s_arch="$(_lxc_arch)"
    for _s_front in https://images.linuxcontainers.org/images https://us.lxd.images.canonical.com/images https://uk.lxd.images.canonical.com/images; do
        _s_base="${_s_front}/${_s_distro}/${_s_release}/${_s_arch}/default"
        _s_html="$(fetch_text "${_s_base}/" 2>/dev/null || true)"
        [ -n "$_s_html" ] || continue
        _s_build="$(printf '%s\n' "$_s_html" | sed -n 's/.*href="\([0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]_[^"]*\)\/".*/\1/p' | sort | tail -n 1)"
        [ -n "$_s_build" ] || continue
        _s_dir="${_s_base}/${_s_build}"
        _s_files="$(fetch_text "${_s_dir}/" 2>/dev/null || true)"
        [ -n "$_s_files" ] || continue
        for _s_name in rootfs.tar.xz rootfs.tar.gz rootfs.tar.zst rootfs.tar; do
            case "$_s_files" in *"$_s_name"*) echo "${_s_dir}/${_s_name}"; return 0 ;; esac
        done
    done
    return 1
}
resolve_url() {
    _rrecipe="$(catalog_recipe "$1")"; [ -n "$_rrecipe" ] || return 1
    _rkind="${_rrecipe%%:*}"; _rrest="${_rrecipe#*:}"
    case "$_rkind" in
        fixed) _url_exists "$_rrest" && echo "$_rrest" || return 1 ;;
        lxc) _systui_lxc_resolve "${_rrest%%:*}" "${_rrest#*:}" ;;
        disc) _disc_url "$_rrest" ;;
        *) return 1 ;;
    esac
}
PATCH

    tmp=$(mktemp "${SYSTUI_TMP:-${TMPDIR:-/tmp}}/systui-brl-catalog.XXXXXX") || { rm -f "$insert"; return 1; }
    awk -v ins="$insert" '
        /^lookup_url\(\)/ && !done {
            while ((getline line < ins) > 0) print line
            close(ins)
            done=1
        }
        { print }
    ' "$f" > "$tmp" || { rm -f "$insert" "$tmp"; return 1; }
    rm -f "$insert"

    chmod --reference="$f" "$tmp" 2>/dev/null || chmod 0755 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$f" || return 1
    log "bedrock-aok: patched robust LXC catalog resolver into $(basename "$f")"
}

bedrock_aok_patch_script() {
    local f="$1"
    if declare -F _systui_base_bedrock_aok_patch_script_catalog >/dev/null 2>&1; then
        _systui_base_bedrock_aok_patch_script_catalog "$f" || return 1
    fi
    bedrock_aok_patch_catalog_resolver "$f"
}

bedrock_aok_repair_installed_catalog() {
    local brl backup
    brl=$(bedrock_aok_brl 2>/dev/null || true)
    [ -n "$brl" ] && [ -f "$brl" ] || return 1
    grep -q '^# __SYSTUI_CATALOG_RESOLVER_PATCH__' "$brl" 2>/dev/null && return 0
    backup="${brl}.systui-catalog.bak"
    cp -f -- "$brl" "$backup" || return 1
    chmod 0755 "$backup" 2>/dev/null || true
    if ! bedrock_aok_patch_catalog_resolver "$brl" || ! sh -n "$brl" >/dev/null 2>&1; then
        cp -f -- "$backup" "$brl" 2>/dev/null || true
        chmod 0755 "$brl" 2>/dev/null || true
        warn "bedrock-aok: catalog resolver patch failed validation; restored $backup"
        return 1
    fi
    chmod 0755 "$brl" 2>/dev/null || true
    log "bedrock-aok: repaired installed brl catalog resolver (backup: $backup)"
}

if declare -F bedrock_aok_refresh_urls_resilient >/dev/null 2>&1 \
    && ! declare -F _systui_base_bedrock_aok_refresh_urls_catalog >/dev/null 2>&1; then
    _systui_brl_refresh_def=$(declare -f bedrock_aok_refresh_urls_resilient)
    _systui_brl_refresh_def=${_systui_brl_refresh_def/#bedrock_aok_refresh_urls_resilient ()/_systui_base_bedrock_aok_refresh_urls_catalog ()}
    eval "$_systui_brl_refresh_def"
    unset _systui_brl_refresh_def
fi

bedrock_aok_refresh_urls_resilient() {
    bedrock_aok_repair_installed_catalog || true
    if declare -F _systui_base_bedrock_aok_refresh_urls_catalog >/dev/null 2>&1; then
        _systui_base_bedrock_aok_refresh_urls_catalog "$@"
    else
        local brl
        brl=$(bedrock_aok_brl) || return 1
        run_cmd "Refresh Bedrock-AOK stratum URLs" "$brl" update-urls
    fi
}

bedrock_aok_catalog_arch_note() {
    local tag="$1" arch
    arch=$(bedrock_aok_host_arch 2>/dev/null || uname -m 2>/dev/null || printf 'unknown')
    case "$arch:$tag" in
        arm64:amazonlinux|arm64:slackware)
            printf 'unavailable on arm64 (upstream image server does not publish this architecture)\n'
            ;;
        *) return 1 ;;
    esac
}

return 0 2>/dev/null || true
