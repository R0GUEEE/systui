# shellcheck shell=bash
# Only advertise the unshare execution engine when the host kernel actually
# supports the namespace combination Systui uses. Having /usr/bin/unshare is
# not sufficient on iSH-AOK, restricted containers, or kernels built without
# the required namespace support.

_systui_unshare_probe() {
    command -v unshare >/dev/null 2>&1 || return 1
    command -v chroot >/dev/null 2>&1 || return 1

    # Probe the same namespace features used by rootfs_wb_engine_argv().
    # `true` exits immediately, so successful probes leave no persistent
    # namespace or mount state behind.
    unshare --mount --uts --ipc --pid --fork --mount-proc true >/dev/null 2>&1
}

# Cache the capability result for this Systui process. Namespace support cannot
# appear during a normal session unless the host itself changes underneath us.
if _systui_unshare_probe; then
    SYSTUI_UNSHARE_SUPPORTED=1
else
    SYSTUI_UNSHARE_SUPPORTED=0
fi
readonly SYSTUI_UNSHARE_SUPPORTED

if declare -F rootfs_wb_engine_available >/dev/null 2>&1; then
    eval "$(declare -f rootfs_wb_engine_available | sed '1s/^rootfs_wb_engine_available[[:space:]]*()/_systui_base_rootfs_wb_engine_available ()/')"

    rootfs_wb_engine_available() { # <engine>
        if [ "$1" = unshare ]; then
            [ "${SYSTUI_UNSHARE_SUPPORTED:-0}" = 1 ]
            return
        fi
        _systui_base_rootfs_wb_engine_available "$1"
    }
fi
