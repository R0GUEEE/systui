# shellcheck shell=bash
# PHASE 73 — final Debian-family rootfs package install path.
#
# Successful installs return immediately. Repair is attempted only after a real
# apt failure, and the original apt status is preserved across the repair pass.

rootfs_install_deb_packages() { # target "space separated packages"
    local target pkgs script rc pkg
    local -a pkg_args=()
    target="$1"
    pkgs="$2"
    script="$target/tmp/systui-install-packages.sh"
    [ -n "${pkgs//[[:space:]]/}" ] || return 0

    pkgs=$(rootfs_sanitize_packages "$pkgs") || return 1
    for pkg in $pkgs; do pkg_args+=("$pkg"); done

    mkdir -p "$target/tmp" "$target/usr/sbin" "$target/var/log"
    cat >"$target/usr/sbin/policy-rc.d" <<'EOF'
#!/bin/sh
exit 101
EOF
    chmod 755 "$target/usr/sbin/policy-rc.d"

    cat >"$script" <<'EOF'
#!/bin/sh
set -u
export DEBIAN_FRONTEND=noninteractive
export DEBCONF_NONINTERACTIVE_SEEN=true
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1

apt_common='-o Acquire::ForceIPv4=true -o Acquire::Retries=3 -o Dpkg::Use-Pty=0 -o Dpkg::Options::=--force-confold -o DPkg::Lock::Timeout=30'

printf '%s\n' '>>> rootfs packages: updating apt metadata'
# shellcheck disable=SC2086
apt-get $apt_common update </dev/null || exit $?

available=""
skipped=""
for pkg in "$@"; do
    [ -n "$pkg" ] || continue
    if apt-cache show "$pkg" >/dev/null 2>&1; then
        available="$available $pkg"
    else
        skipped="$skipped $pkg"
    fi
done

if [ -n "$skipped" ]; then
    printf '%s\n' "$skipped" > /var/log/systui-skipped-packages.log
fi

if [ -z "$available" ]; then
    printf '%s\n' '>>> rootfs packages: nothing available to install'
    exit 0
fi

printf '%s\n' ">>> rootfs packages: installing:$available"
# shellcheck disable=SC2086
if apt-get $apt_common --no-install-recommends install -y $available </dev/null; then
    printf '%s\n' '>>> rootfs packages: install complete'
    exit 0
else
    rc=$?
fi

printf '%s\n' ">>> rootfs packages: apt install failed ($rc); attempting one bounded repair pass" >&2
dpkg --configure -a </dev/null || true
# shellcheck disable=SC2086
apt-get $apt_common -f install -y </dev/null || true
printf '%s\n' '>>> rootfs packages: repair pass complete; returning original install failure' >&2
exit "$rc"
EOF
    chmod 755 "$script"

    rootfs_set_build_stage "$target" packages-running 2>/dev/null || true
    rootfs_chroot_exec_args "$target" "Install selected Debian-family packages" \
        /tmp/systui-install-packages.sh "${pkg_args[@]}"
    rc=$?

    rm -f "$script" "$target/usr/sbin/policy-rc.d"
    if [ -s "$target/var/log/systui-skipped-packages.log" ]; then
        warn "Some packages are unavailable for this release/architecture: $(xargs < "$target/var/log/systui-skipped-packages.log")"
    fi

    if [ "$rc" = 0 ]; then
        rootfs_set_build_stage "$target" packages-complete 2>/dev/null || true
        log "rootfs: Debian-family package installation completed cleanly"
    else
        rootfs_set_build_stage "$target" packages-failed 2>/dev/null || true
        log "rootfs: Debian-family package installation failed rc=$rc"
    fi
    return "$rc"
}

return 0 2>/dev/null || true
