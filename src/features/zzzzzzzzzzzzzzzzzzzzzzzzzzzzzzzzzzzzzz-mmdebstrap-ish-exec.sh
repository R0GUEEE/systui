# shellcheck shell=bash
###############################################################################
# ROOTFS — iSH-safe mmdebstrap executable shim
#
# Systui's older mmdebstrap wrapper was a Bash function. build_debfamily invokes
# mmdebstrap through `env ... mmdebstrap`, so env performs a fresh PATH lookup
# and bypasses shell functions entirely. Install a process-local executable shim
# ahead of the real binary instead.
###############################################################################

_systui_mmdebstrap_real=""
if command -v mmdebstrap >/dev/null 2>&1; then
    _systui_mmdebstrap_real=$(command -v mmdebstrap)
fi

rootfs_install_mmdebstrap_ish_shim() {
    [ "${SYSTUI_UNSHARE_SUPPORTED:-1}" = 0 ] || return 0
    [ -n "${_systui_mmdebstrap_real:-}" ] || return 0

    local dir="${SYSTUI_TMP:-/tmp}/mmdebstrap-ish-bin" shim="$dir/mmdebstrap"
    mkdir -p "$dir" || return 1

    cat > "$shim" <<EOF
#!/bin/sh
REAL_MMDEBSTRAP='${_systui_mmdebstrap_real}'

# iSH-AOK has no mount namespaces/CAP_SYS_ADMIN. Root mode can still build a
# directory tree if mmdebstrap does not try to probe or mount pseudo-filesystems.
# Device nodes are omitted and Systui creates/mounts runtime /dev later.
set -- \
    --skip=check/canmount \
    --skip=chroot/mount \
    --skip=output/mknod \
    "\$@"

# Recovery can target a non-empty partial rootfs. mmdebstrap's setup stage tries
# to populate /dev and treats EEXIST from mknod as fatal, so remove stale device
# nodes/directories created by an earlier failed pass. Only touch targets under
# Systui's rootfs workspace and never remove an active mount.
target=''
for arg in "\$@"; do
    case "\$arg" in
        /opt/rootfs/*) target="\$arg" ;;
    esac
done
if [ -n "\$target" ] && [ -d "\$target/dev" ]; then
    mounted=0
    if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "\$target/dev" 2>/dev/null; then mounted=1; fi
    if [ "\$mounted" -eq 0 ]; then
        rm -f "\$target/dev/console" "\$target/dev/null" "\$target/dev/zero" \
              "\$target/dev/full" "\$target/dev/random" "\$target/dev/urandom" \
              "\$target/dev/tty" "\$target/dev/ptmx" 2>/dev/null || true
        mkdir -p "\$target/dev" "\$target/dev/pts" 2>/dev/null || true
    fi
fi

exec "\$REAL_MMDEBSTRAP" "\$@"
EOF
    chmod 0755 "$shim" || return 1

    case ":$PATH:" in
        *":$dir:"*) ;;
        *) PATH="$dir:$PATH"; export PATH ;;
    esac
    log "mmdebstrap: installed iSH-safe executable shim (no unshare/mount/mknod)"
}

rootfs_install_mmdebstrap_ish_shim || true

# The recovery function may be called after environment changes; make sure the
# executable shim is still first on PATH immediately before bootstrap recovery.
if declare -F rootfs_recover_deb_base >/dev/null 2>&1 && \
   ! declare -F _systui_base_rootfs_recover_deb_base_mmexec >/dev/null 2>&1; then
    eval "$(declare -f rootfs_recover_deb_base | sed '1s/^rootfs_recover_deb_base[[:space:]]*()/_systui_base_rootfs_recover_deb_base_mmexec ()/')"
fi
rootfs_recover_deb_base() {
    rootfs_install_mmdebstrap_ish_shim || {
        tui_msg "mmdebstrap compatibility" "Could not prepare the iSH-safe mmdebstrap launcher."
        return 1
    }
    _systui_base_rootfs_recover_deb_base_mmexec "$@"
}

export -f rootfs_install_mmdebstrap_ish_shim rootfs_recover_deb_base
