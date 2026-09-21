# shellcheck shell=bash
# Bedrock-aware Rootfs Bootstrap tool detection.
#
# rootfs.sh detects tools on the current host.  On Bedrock Linux, however, a
# bootstrap utility may be installed in any stratum and still be intentionally
# available to the overall system.  This final feature layer preserves native
# detection and then scans every installed stratum directly.


# standalone safety: pull in the alias helper when this feature is sourced
# without core/common.sh (tests, reduced builds).
if ! declare -F systui_alias_function >/dev/null 2>&1; then
    _systui_alias_mod="${SYSTUI_LIBDIR:-$(cd "${BASH_SOURCE[0]%/*}/../.." && pwd)}/src/core/alias.sh"
    [ -r "$_systui_alias_mod" ] && . "$_systui_alias_mod"
    unset _systui_alias_mod
fi
if declare -F rootfs_bs_installed >/dev/null 2>&1 \
    && ! declare -F _systui_native_rootfs_bs_installed >/dev/null 2>&1; then
    systui_alias_function rootfs_bs_installed _systui_native_rootfs_bs_installed
fi

bedrock_bootstrap_strata_root() {
    printf '%s\n' "${SYSTUI_BEDROCK_STRATA_ROOT:-/bedrock/strata}"
}

bedrock_bootstrap_active() {
    local root
    root=$(bedrock_bootstrap_strata_root)

    # The override is primarily useful for tests and unusual Bedrock layouts.
    if [ -n "${SYSTUI_BEDROCK_STRATA_ROOT:-}" ]; then
        [ -d "$root" ]
        return
    fi

    if declare -F bedrock_sysconfig_active >/dev/null 2>&1 \
        && bedrock_sysconfig_active; then
        return 0
    fi

    [ -d "$root" ]
}

bedrock_bootstrap_strata() {
    local root
    root=$(bedrock_bootstrap_strata_root)

    # Honour an explicit root instead of calling helpers that assume
    # /bedrock/strata.  Otherwise reuse the canonical Bedrock enumeration.
    if [ -n "${SYSTUI_BEDROCK_STRATA_ROOT:-}" ]; then
        [ -d "$root" ] || return 0
        find "$root" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null \
            | sed 's#.*/##' | LC_ALL=C sort
    elif declare -F bedrock_sysconfig_strata >/dev/null 2>&1; then
        bedrock_sysconfig_strata
    elif [ -d "$root" ]; then
        find "$root" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null \
            | sed 's#.*/##' | LC_ALL=C sort
    fi
}

# Convert a bootstrap catalogue/package tag into the executable that proves
# the tool is usable.  Reuse rootfs.sh's mapping when available.
bedrock_bootstrap_command() { # <tag>
    if declare -F rootfs_bs_command >/dev/null 2>&1; then
        rootfs_bs_command "$1"
        return
    fi

    case "$1" in
        arch-install-scripts) printf 'pacstrap\n' ;;
        systemd-container)    printf 'systemd-nspawn\n' ;;
        xbps-tools)           printf 'xbps-install\n' ;;
        xz-utils)             printf 'xz\n' ;;
        binfmt-support)       printf 'update-binfmts\n' ;;
        *)                    printf '%s\n' "$1" ;;
    esac
}

bedrock_bootstrap_stratum_has() { # <stratum> <tag>
    local st="$1" tag="$2" root cmd dir q
    root="$(bedrock_bootstrap_strata_root)/$st"
    [ -d "$root" ] || return 1

    case "$tag" in
        qemu-user-static)
            for q in \
                "$root"/usr/local/bin/qemu-*-static \
                "$root"/usr/bin/qemu-*-static \
                "$root"/bin/qemu-*-static; do
                [ -x "$q" ] && return 0
            done
            return 1
            ;;
        *)
            cmd=$(bedrock_bootstrap_command "$tag")
            [ -n "$cmd" ] || return 1
            for dir in \
                usr/local/sbin usr/local/bin usr/sbin usr/bin sbin bin; do
                [ -x "$root/$dir/$cmd" ] && return 0
            done
            return 1
            ;;
    esac
}

# Print every stratum containing the requested bootstrap.  This is kept as a
# public helper so other Systui menus can show the owning stratum later without
# duplicating the filesystem scan.
# Menu status rendering may ask about twenty bootstrap tools in one pass. Keep
# the Bedrock stratum enumeration and per-tool result in memory for that pass
# instead of running find/sed/sort once per tool.
declare -gA SYSTUI_BOOTSTRAP_STATUS_CACHE=() 2>/dev/null || true
SYSTUI_BEDROCK_STRATA_CACHE_VALID=0
SYSTUI_BEDROCK_STRATA_CACHE=""

systui_bootstrap_status_cache_clear() {
    SYSTUI_BOOTSTRAP_STATUS_CACHE=()
    SYSTUI_BEDROCK_STRATA_CACHE_VALID=0
    SYSTUI_BEDROCK_STRATA_CACHE=""
}

systui_bedrock_strata_cache_ensure() {
    [ "${SYSTUI_BEDROCK_STRATA_CACHE_VALID:-0}" = 1 ] && return 0
    SYSTUI_BEDROCK_STRATA_CACHE=$(bedrock_bootstrap_strata 2>/dev/null || true)
    SYSTUI_BEDROCK_STRATA_CACHE_VALID=1
}

bedrock_bootstrap_locations() { # <tag>
    local tag="$1" st
    bedrock_bootstrap_active || return 1
    systui_bedrock_strata_cache_ensure
    while IFS= read -r st; do
        [ -n "$st" ] || continue
        bedrock_bootstrap_stratum_has "$st" "$tag" && printf '%s\n' "$st"
    done <<< "$SYSTUI_BEDROCK_STRATA_CACHE"
    return 0
}

# Host/native detection remains authoritative. Only when it misses do we scan
# Bedrock. Cache both positive and negative results until an install/remove path
# explicitly invalidates the status cache.
rootfs_bs_installed() { # <tag>
    local tag="$1" st cached
    if [[ -v "SYSTUI_BOOTSTRAP_STATUS_CACHE[$tag]" ]]; then
        cached=${SYSTUI_BOOTSTRAP_STATUS_CACHE[$tag]}
        [ "$cached" = 1 ]
        return
    fi

    if declare -F _systui_native_rootfs_bs_installed >/dev/null 2>&1 \
        && _systui_native_rootfs_bs_installed "$tag"; then
        SYSTUI_BOOTSTRAP_STATUS_CACHE["$tag"]=1
        return 0
    fi

    if ! bedrock_bootstrap_active; then
        SYSTUI_BOOTSTRAP_STATUS_CACHE["$tag"]=0
        return 1
    fi

    systui_bedrock_strata_cache_ensure
    while IFS= read -r st; do
        [ -n "$st" ] || continue
        if bedrock_bootstrap_stratum_has "$st" "$tag"; then
            SYSTUI_BOOTSTRAP_STATUS_CACHE["$tag"]=1
            return 0
        fi
    done <<< "$SYSTUI_BEDROCK_STRATA_CACHE"

    SYSTUI_BOOTSTRAP_STATUS_CACHE["$tag"]=0
    return 1
}

return 0 2>/dev/null || true
