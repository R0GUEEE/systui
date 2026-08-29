# shellcheck shell=bash
###############################################################################
# ROOTFS BUILDER — Ubuntu Questing/Resolute iSH coreutils compatibility
#
# Ubuntu Questing and Resolute can satisfy the essential coreutils meta package
# with the Rust/uutils provider. rust-coreutils currently aborts on iSH-AOK
# while probing auxv, which can break debootstrap maintainer scripts before the
# rootfs reaches post-configuration. Force the GNU provider during bootstrap so
# dpkg never has to run those scripts with the incompatible implementation.
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
        questing|25.10|25.10*|resolute|26.04|26.04*) return 0 ;;
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
        # The essential `coreutils` meta package can be satisfied by the GNU
        # provider. Prevent the incompatible Rust provider from being selected
        # as an additional package by bootstrap dependency resolution.
        ROOTFS_BACKEND_EXCLUDE=$(rootfs_ish_append_word "$saved_exclude" coreutils-from-uutils)
        ROOTFS_BACKEND_EXCLUDE=$(rootfs_ish_append_word "$ROOTFS_BACKEND_EXCLUDE" rust-coreutils)
        log "rootfs: forcing coreutils-from-gnu for Ubuntu $release on iSH-AOK"
    fi

    _systui_base_build_debfamily "$@" || rc=$?

    ROOTFS_BACKEND_INCLUDE="$saved_include"
    ROOTFS_BACKEND_EXCLUDE="$saved_exclude"
    return "$rc"
}

# Package installation runs `dpkg --configure -a`. If a partial/older bootstrap
# already selected uutils, activate the GNU-prefixed binaries before that point.
# This is host-side only and therefore remains safe even while dpkg is broken.
if declare -F rootfs_install_deb_packages >/dev/null 2>&1 && \
   ! declare -F _systui_base_rootfs_install_deb_packages >/dev/null 2>&1; then
    eval "$(declare -f rootfs_install_deb_packages | sed '1s/^rootfs_install_deb_packages[[:space:]]*()/_systui_base_rootfs_install_deb_packages ()/')"
fi

rootfs_install_deb_packages() { # <target> <packages>
    local target="$1" release
    if rootfs_ish_host_builtin_detect; then
        release=$(rootfs_ish_target_release "$target" 2>/dev/null || true)
        case "$release" in
            ubuntu\|questing\|*|ubuntu\|\|25.10*|ubuntu\|resolute\|*|ubuntu\|\|26.04*)
                rootfs_ish_activate_gnu_coreutils "$target" >/dev/null 2>&1 || true
                ;;
        esac
    fi
    _systui_base_rootfs_install_deb_packages "$@"
}

export -f rootfs_ish_host_builtin_detect rootfs_ish_ubuntu_needs_gnu_coreutils build_debfamily rootfs_install_deb_packages
