#!/bin/bash
# Rootfs bootstrap backend capability and release gating.

systui_rootfs_backend_available() { # <backend>
    case "${1:-}" in
        mmdebstrap|debootstrap|cdebootstrap|multistrap|pacstrap|dnf|zypper|rinse|bdebstrap)
            command -v "$1" >/dev/null 2>&1 ;;
        alpine-chroot-install)
            command -v alpine-chroot-install >/dev/null 2>&1 ;;
        qemu-debootstrap)
            command -v qemu-debootstrap >/dev/null 2>&1 && command -v debootstrap >/dev/null 2>&1 ;;
        apk-static|alarm-tarball)
            command -v tar >/dev/null 2>&1 && command -v gzip >/dev/null 2>&1 &&
                { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; } ;;
        arch-bootstrap|archriscv-tarball)
            command -v tar >/dev/null 2>&1 && command -v zstd >/dev/null 2>&1 &&
                { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; } ;;
        bedrock-hijack)
            command -v tar >/dev/null 2>&1 && command -v sha1sum >/dev/null 2>&1 &&
                { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; } ;;
        gentoo-stage3|void-tarball)
            command -v tar >/dev/null 2>&1 && command -v xz >/dev/null 2>&1 &&
                { command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; } ;;
        *) return 1 ;;
    esac
}

systui_rootfs_backend_status() {
    systui_rootfs_backend_available "$1" && printf 'available\n' || printf 'missing prerequisites\n'
}

systui_rootfs_backend_requirements() { # <backend>
    case "${1:-}" in
        mmdebstrap|debootstrap|cdebootstrap|multistrap|pacstrap|dnf|zypper|rinse|bdebstrap) printf '%s\n' "$1" ;;
        alpine-chroot-install) printf 'alpine-chroot-install (github.com/alpinelinux/alpine-chroot-install)\n' ;;
        qemu-debootstrap) printf 'qemu-debootstrap (qemu-user-static) and debootstrap\n' ;;
        apk-static) printf 'tar, gzip, and curl or wget\n' ;;
        arch-bootstrap) printf 'tar, zstd, and curl or wget\n' ;;
        archriscv-tarball) printf 'tar, zstd, and curl or wget (Arch Linux RISC-V rootfs tarball)\n' ;;
        alarm-tarball) printf 'tar, gzip, and curl or wget (Arch Linux ARM tarball)\n' ;;
        bedrock-hijack) printf 'tar, sha1sum, and curl or wget; FUSE + xattr filesystem on the build host\n' ;;
        gentoo-stage3|void-tarball) printf 'tar, xz, and curl or wget\n' ;;
        *) printf 'unknown prerequisites\n' ;;
    esac
}

systui_rootfs_alpine_release_supports_arch() { # <release> <arch>
    local release="${1:-}" arch="${2:-}"
    [ "$arch" = riscv64 ] || return 0
    [ "$release" = edge ] && return 0
    case "$release" in
        v3.2[1-9]|v3.[3-9][0-9]|v[4-9].*) return 0 ;;
        *) return 1 ;;
    esac
}

systui_rootfs_devuan_release_supports_arch() { # <release> <arch>
    [ "${2:-}" = riscv64 ] || return 0
    [ "${1:-}" = ceres ]
}

systui_rootfs_backend_release_supported() { # <distro> <backend> <release> [arch]
    local distro="${1:-}" backend="${2:-}" release="${3:-}" arch="${4:-}" suite dist
    [ -n "$release" ] || return 0

    case "$backend" in
        debootstrap|qemu-debootstrap)
            suite="$release"
            [ "$distro" = bedrock ] && suite=trixie
            if declare -F rootfs_validate_debootstrap_suite >/dev/null 2>&1; then
                rootfs_validate_debootstrap_suite "$suite" || return 1
            fi
            ;;
        rinse)
            case "$arch" in amd64|i386|'') ;; *) return 1 ;; esac
            command -v rinse >/dev/null 2>&1 || return 1
            case "$distro" in
                fedora) dist="fedora-core-$release" ;;
                opensuse) dist="opensuse-$release" ;;
                *) return 1 ;;
            esac
            rinse --list-distributions 2>/dev/null | awk '{print $1}' | grep -qx -- "$dist" || return 1
            ;;
    esac

    case "$distro" in
        alpine) systui_rootfs_alpine_release_supports_arch "$release" "$arch" || return 1 ;;
        devuan) systui_rootfs_devuan_release_supports_arch "$release" "$arch" || return 1 ;;
    esac
}

# Modern modules are sourced; never export function bodies.
