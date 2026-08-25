# shellcheck shell=bash
# Bedrock rootfs build hardening.
#
# This file intentionally sorts after rootfs.sh in src/features/*.sh so these
# definitions override the generic implementations without duplicating the
# large rootfs feature module.  Bedrock's upstream installer requires a real
# Linux kernel environment with FUSE, mount/chroot privileges, xattrs and file
# capabilities; validate as much of that as possible before bootstrapping the
# Debian base, then keep one stable mount set alive for the entire hijack.

rootfs_bedrock_preflight() { # <target> -> 0 when host/target can run hijack
    local target="$1" fuse_reg=0 dev_fuse=0 probe rc=0

    if [ "$(id -u)" != 0 ]; then
        tui_msg "Bedrock requires root" \
"Bedrock Linux hijack must run as root because it needs chroot, bind mounts,
FUSE, extended attributes and Linux file capabilities."
        return 1
    fi

    if [ -r /proc/sys/kernel/osrelease ] && grep -qi 'microsoft' /proc/sys/kernel/osrelease; then
        tui_msg "Unsupported Bedrock host" \
"Windows Subsystem for Linux does not provide the kernel environment Bedrock
Linux requires. Build this rootfs on native Linux or a Linux VM instead."
        return 1
    fi

    for _cmd in chroot mount umount; do
        if ! command -v "$_cmd" >/dev/null 2>&1; then
            tui_msg "Missing Bedrock host tool" "Required host command is missing: $_cmd"
            return 1
        fi
    done

    command -v modprobe >/dev/null 2>&1 && modprobe fuse 2>/dev/null || true
    [ -r /proc/filesystems ] && grep -qw fuse /proc/filesystems && fuse_reg=1
    [ -c /dev/fuse ] && dev_fuse=1
    if [ "$fuse_reg" = 0 ] || [ "$dev_fuse" = 0 ]; then
        local why
        if [ "$fuse_reg" = 0 ]; then
            why="/proc/filesystems does not list fuse."
        else
            why="/dev/fuse is missing or is not a character device."
        fi
        tui_msg "FUSE is required for Bedrock" \
"Bedrock Linux cannot be hijacked on this host.

$why

On native Linux, load/enable FUSE and retry:
    modprobe fuse
    grep -w fuse /proc/filesystems
    ls -l /dev/fuse

On iSH/iSH-AOK or another userspace-emulated kernel, FUSE cannot be added from
inside the environment; build Bedrock on a native Linux host or VM."
        return 1
    fi

    mkdir -p "$target" || return 1
    probe=$(mktemp -d "$target/.systui-bedrock-preflight.XXXXXX") || {
        tui_msg "Bedrock filesystem check failed" "Could not create a probe directory under:\n$target"
        return 1
    }

    # A successful bind mount proves the caller has the mount capability the
    # hijack needs.  Merely being uid 0 is insufficient in restricted
    # containers/user namespaces.
    mkdir -p "$probe/src" "$probe/dst"
    : > "$probe/src/probe"
    if ! mount --bind "$probe/src" "$probe/dst" 2>/dev/null; then
        rm -rf "$probe"
        tui_msg "Bedrock mount check failed" \
"Systui cannot create a bind mount on this host. Bedrock hijack needs real
kernel mount privileges (CAP_SYS_ADMIN); restricted containers, iSH and many
sandboxed environments cannot provide them."
        return 1
    fi
    umount "$probe/dst" 2>/dev/null || umount -l "$probe/dst" 2>/dev/null || true

    # Test user xattrs when a syscall-capable helper is available. Bedrock ships
    # its own setfattr/getfattr binaries, so absence of these host helpers is not
    # itself a build failure; inability to set an xattr is.
    if command -v setfattr >/dev/null 2>&1 && command -v getfattr >/dev/null 2>&1; then
        if ! setfattr -n user.systui.bedrock -v ok "$probe/src/probe" 2>/dev/null ||
           [ "$(getfattr --only-values -n user.systui.bedrock "$probe/src/probe" 2>/dev/null)" != ok ]; then
            rc=1
        fi
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$probe/src/probe" >/dev/null 2>&1 <<'PY' || rc=1
import os, sys
p = sys.argv[1]
os.setxattr(p, b'user.systui.bedrock', b'ok')
assert os.getxattr(p, b'user.systui.bedrock') == b'ok'
PY
    fi
    if [ "$rc" != 0 ]; then
        rm -rf "$probe"
        tui_msg "Bedrock xattr check failed" \
"The filesystem containing $target does not allow the extended attributes
Bedrock Linux requires. Choose a filesystem/mount with user xattr support."
        return 1
    fi

    # File capabilities are another upstream hard requirement. Probe them when
    # setcap/getcap are installed; otherwise leave the definitive check to the
    # embedded Bedrock installer rather than introducing a false dependency.
    if command -v setcap >/dev/null 2>&1 && command -v getcap >/dev/null 2>&1; then
        cp "$(command -v true)" "$probe/cap-probe" 2>/dev/null || cp /bin/true "$probe/cap-probe" 2>/dev/null || true
        if [ -f "$probe/cap-probe" ]; then
            if ! setcap cap_sys_chroot=ep "$probe/cap-probe" 2>/dev/null ||
               ! getcap "$probe/cap-probe" 2>/dev/null | grep -q 'cap_sys_chroot'; then
                rm -rf "$probe"
                tui_msg "Bedrock capability check failed" \
"The filesystem/kernel combination at $target does not preserve Linux file
capabilities. Bedrock requires file capabilities to operate."
                return 1
            fi
        fi
    fi

    rm -rf "$probe"
    return 0
}

# Keep the legacy public helper, but make it use the stronger host checks when
# no target is available yet.
rootfs_bedrock_preflight_fuse() {
    local tmp
    tmp=$(mktemp -d "${SYSTUI_TMP:-${TMPDIR:-/tmp}}/bedrock-preflight.XXXXXX") || return 1
    rootfs_bedrock_preflight "$tmp"
    local rc=$?
    rm -rf "$tmp"
    return "$rc"
}

build_bedrock() { # release arch mirror target pkgs use_qemu backend
    local release="$1" arch="$2" mirror="$3" target="$4" pkgs="$5" use_qemu="$6" backend="$7"
    local base_suite="trixie" asset_arch ver installer_url workdir name mounts="" rc=0

    asset_arch=$(rootfs_bedrock_asset_arch "$arch")
    if [ -z "$asset_arch" ]; then
        tui_msg "Unsupported architecture" "No Bedrock Linux installer exists for arch '$arch'."
        return 1
    fi
    ver=$(rootfs_bedrock_release_version "$release")
    installer_url="https://github.com/bedrocklinux/bedrocklinux-userland/releases/download/${ver}/bedrock-linux-${ver}-${asset_arch}.sh"
    name="bedrock-linux-${ver}-${asset_arch}.sh"

    # Reject impossible environments before spending time/network on Debian.
    if ! rootfs_bedrock_preflight "$target"; then
        rootfs_set_build_stage "$target" bedrock-host-incompatible
        return 1
    fi

    if ! build_debfamily debian "$base_suite" "$arch" "$mirror" "$target" "$pkgs" "$use_qemu" "$backend"; then
        warn "Bedrock base (Debian $base_suite) bootstrap failed."
        return 1
    fi

    # Upstream refuses to hijack a system with no init entrypoint. Minimal
    # bootstrap variants can omit it, so catch this with a useful message.
    if [ ! -e "$target/sbin/init" ]; then
        tui_msg "Bedrock base has no init" \
"The Debian base was created successfully, but /sbin/init is missing.
Bedrock's hijack installer requires an init system to take over.

Choose a rootfs preset/init that installs an init package, then retry."
        rootfs_set_build_stage "$target" bedrock-init-missing
        return 1
    fi

    workdir=$(mktemp -d "${SYSTUI_TMP:-${TMPDIR:-/tmp}}/systui-bedrock.XXXXXX") || return 1
    if ! rootfs_fetch_file "$installer_url" "$workdir/$name"; then
        tui_msg "Download failed" "Could not fetch the Bedrock hijack installer:\n$installer_url"
        rm -rf "$workdir"
        return 1
    fi

    mkdir -p "$target/tmp"
    cp "$workdir/$name" "$target/tmp/bedrock-installer.sh" || { rm -rf "$workdir"; return 1; }

    # Mount once and retain exactly this mount list for the full hijack. Calling
    # rootfs_chroot_exec here used to mount a second time and overwrite global
    # mount bookkeeping, which could hide /dev/fuse or leak mounts on failure.
    rootfs_mount_chroot_fs "$target" || true
    mounts="${ROOTFS_ACTIVE_MOUNTS:-}"

    if ! grep -qw fuse "$target/proc/filesystems" 2>/dev/null || [ ! -c "$target/dev/fuse" ]; then
        rootfs_set_build_stage "$target" bedrock-fuse-unavailable
        rc=1
    else
        rootfs_set_build_stage "$target" bedrock-hijack
        run_cmd "Bedrock hijack install (${ver}, $asset_arch)" \
            rootfs_exec_raw "$target" /bin/sh -c \
            "printf 'Not reversible!\\n' | /bin/sh /tmp/bedrock-installer.sh --hijack bedrock" || rc=$?
    fi

    rootfs_unmount_chroot_fs "$target" "$mounts" >/dev/null 2>&1 || true
    rm -f "$target/tmp/bedrock-installer.sh"
    rm -rf "$workdir"

    if [ "$rc" != 0 ]; then
        warn "Bedrock hijack installer failed. Review $LOGFILE."
        rootfs_set_build_stage "$target" bedrock-hijack-failed
        return 1
    fi

    local bstrata barch bextra
    bstrata=$(rootfs_state_get "$target" BEDROCK_STRATA 2>/dev/null || true)
    if [ -n "$bstrata" ]; then
        barch=$(rootfs_state_get "$target" BEDROCK_ARCH 2>/dev/null || true)
        bextra=$(rootfs_state_get "$target" BEDROCK_EXTRA 2>/dev/null || true)
        if ! rootfs_bedrock_fetch_strata "$target" "$bstrata" "$bextra" "$barch" "$use_qemu" "$arch"; then
            warn "One or more Bedrock strata could not be fetched. The base Bedrock rootfs is intact; add strata later with: brl fetch"
            rootfs_set_build_stage "$target" bedrock-hijacked-strata-failed
            return 1
        fi
        rootfs_set_build_stage "$target" bedrock-hijacked-strata-complete
    fi

    rootfs_set_build_stage "$target" bedrock-hijacked
    return 0
}
