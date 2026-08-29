# shellcheck shell=bash
###############################################################################
# ROOTFS BUILDER — Ubuntu Resolute/iSH coreutils compatibility
#
# Ubuntu Resolute's essential coreutils meta package may select the Rust/uutils
# provider. rust-coreutils currently aborts on iSH-AOK while probing auxv, which
# can break maintainer scripts before the rootfs reaches post-configuration.
# Force the GNU provider during bootstrap so dpkg never has to run those scripts
# with the incompatible implementation installed.
###############################################################################

rootfs_ish_host_builtin_detect() {
    local v=''
    [ -r /proc/version ] && IFS= read -r v < /proc/version 2>/dev/null || true
    case "$v" in
        *-ish*|*ish_aok*|*iSH-AOK*|*iSH*) return 0 ;;
    esac
    [ -e /proc/ish ]
}

rootfs_ish_ubuntu_needs_gnu_coreutils() { # <distro> <release>
    [ "$1" = ubuntu ] || return 1
    rootfs_ish_host_builtin_detect || return 1
    case "$2" in
        resolute|26.04|26.04*) return 0 ;;
    esac
    return 1
}

rootfs_ish_append_word() { # <current> <word>
    local current="$1" word="$2"
    case " $current " in
        *" $word "*) printf '%s\n' "$current" ;;
        *) printf '%s\n' "${current:+$current }$word" ;;
    esac
}

# Preserve the canonical Debian-family builder and alter only the package
# resolver inputs for the affected Ubuntu/iSH combination.
if declare -F build_debfamily >/dev/null 2>&1 && \
   ! declare -F _systui_base_build_debfamily >/dev/null 2>&1; then
    eval "$(declare -f build_debfamily | sed '1s/^build_debfamily[[:space:]]*()/_systui_base_build_debfamily ()/')"
fi

build_debfamily() {
    local distro="$1" release="$2"
    local saved_include="${ROOTFS_BACKEND_INCLUDE:-}" saved_exclude="${ROOTFS_BACKEND_EXCLUDE:-}" rc=0

    if rootfs_ish_ubuntu_needs_gnu_coreutils "$distro" "$release"; then
        ROOTFS_BACKEND_INCLUDE=$(rootfs_ish_append_word "$saved_include" coreutils-from-gnu)
        # Do not explicitly install the incompatible provider. The essential
        # `coreutils` meta package is satisfied by coreutils-from-gnu instead.
        ROOTFS_BACKEND_EXCLUDE=$(rootfs_ish_append_word "$saved_exclude" coreutils-from-uutils)
        ROOTFS_BACKEND_EXCLUDE=$(rootfs_ish_append_word "$ROOTFS_BACKEND_EXCLUDE" rust-coreutils)
        log "rootfs: forcing coreutils-from-gnu for Ubuntu $release on iSH-AOK"
    fi

    _systui_base_build_debfamily "$@" || rc=$?

    ROOTFS_BACKEND_INCLUDE="$saved_include"
    ROOTFS_BACKEND_EXCLUDE="$saved_exclude"
    return "$rc"
}

export -f rootfs_ish_host_builtin_detect rootfs_ish_ubuntu_needs_gnu_coreutils build_debfamily
