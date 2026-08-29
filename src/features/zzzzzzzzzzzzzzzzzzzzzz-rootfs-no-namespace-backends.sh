# shellcheck shell=bash
# Namespace-less kernels (notably iSH/iSH-AOK) cannot support mmdebstrap's
# root/unshare execution paths reliably.  Do not advertise mmdebstrap or
# bdebstrap there; let the normal backend resolver fall through to classic
# debootstrap/cdebootstrap/multistrap backends instead.

rootfs_backend_available() { # <backend>
    case "$1" in
        mmdebstrap)
            [ "${SYSTUI_UNSHARE_SUPPORTED:-1}" = 1 ] || return 1
            command -v mmdebstrap >/dev/null 2>&1
            ;;
        bdebstrap)
            [ "${SYSTUI_UNSHARE_SUPPORTED:-1}" = 1 ] || return 1
            command -v bdebstrap >/dev/null 2>&1 && command -v mmdebstrap >/dev/null 2>&1
            ;;
        debootstrap|cdebootstrap|multistrap|pacstrap|dnf|zypper|rinse)
            command -v "$1" >/dev/null 2>&1
            ;;
        qemu-debootstrap)
            command -v qemu-debootstrap >/dev/null 2>&1 &&
                command -v debootstrap >/dev/null 2>&1
            ;;
        alpine-chroot-install)
            command -v alpine-chroot-install >/dev/null 2>&1
            ;;
        apk-static)
            command -v tar >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1 &&
                { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; }
            ;;
        arch-bootstrap|archriscv-tarball)
            command -v tar >/dev/null 2>&1 && command -v zstd >/dev/null 2>&1 &&
                { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; }
            ;;
        alarm-tarball)
            command -v tar >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1 &&
                { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; }
            ;;
        bedrock-hijack)
            command -v tar >/dev/null 2>&1 && command -v sha1sum >/dev/null 2>&1 &&
                { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; }
            ;;
        gentoo-stage3|void-tarball)
            command -v tar >/dev/null 2>&1 && command -v xz >/dev/null 2>&1 &&
                { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; }
            ;;
        *) return 1 ;;
    esac
}
