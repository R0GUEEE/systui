# shellcheck shell=bash
# Bedrock-aware Rootfs Bootstrap tool detection.
#
# rootfs.sh detects tools on the current host.  On Bedrock Linux, however, a
# bootstrap utility may be installed in any stratum and still be intentionally
# available to the overall system.  This final feature layer preserves native
# detection and then scans every installed stratum directly.

if declare -F rootfs_bs_installed >/dev/null 2>&1 \
    && ! declare -F _systui_native_rootfs_bs_installed >/dev/null 2>&1; then
    eval "$(declare -f rootfs_bs_installed | sed \
        '1s/^rootfs_bs_installed[[:space:]]*()/_systui_native_rootfs_bs_installed ()/')"
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
bedrock_bootstrap_locations() { # <tag>
    local tag="$1" st
    bedrock_bootstrap_active || return 1

    while IFS= read -r st; do
        [ -n "$st" ] || continue
        bedrock_bootstrap_stratum_has "$st" "$tag" && printf '%s\n' "$st"
    done <<< "$(bedrock_bootstrap_strata)"

    # A later non-matching stratum must not turn a successful scan into a
    # failure after earlier matches have already been printed.
    return 0
}

# Host/native detection remains authoritative.  Only when it misses do we scan
# Bedrock's installed strata.  This means the normal Rootfs > Bootstrap menu,
# its package submenu, install pre-check and uninstall pre-check all gain the
# same Bedrock-aware behavior automatically.
rootfs_bs_installed() { # <tag>
    local tag="$1" st

    if declare -F _systui_native_rootfs_bs_installed >/dev/null 2>&1 \
        && _systui_native_rootfs_bs_installed "$tag"; then
        return 0
    fi

    bedrock_bootstrap_active || return 1
    while IFS= read -r st; do
        [ -n "$st" ] || continue
        bedrock_bootstrap_stratum_has "$st" "$tag" && return 0
    done <<< "$(bedrock_bootstrap_strata)"

    return 1
}

return 0 2>/dev/null || true
