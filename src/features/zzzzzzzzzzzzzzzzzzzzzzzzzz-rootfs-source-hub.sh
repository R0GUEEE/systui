# shellcheck shell=bash
###############################################################################
# ROOTFS DOWNLOAD ROUTING — Linux Containers catalogue only
###############################################################################
#
# Rootfs > Download intentionally exposes only the Linux Containers (LXC/LXD)
# image catalogue. Other direct distribution and OCI/container registry source
# adapters may remain in the codebase for internal/future use, but are not
# presented from the RootFS download workflow.

rootfs_download_source_hub() {
    if declare -F rootfs_download_live_catalogue >/dev/null 2>&1; then
        rootfs_download_live_catalogue
        return $?
    fi

    tui_msg "Rootfs download" "The Linux Containers image catalogue is unavailable in this build."
    return 1
}

# Final Rootfs > Download route: go directly to the LXC/Linux Containers
# distribution catalogue without showing an intermediate source menu.
rootfs_download() {
    rootfs_download_source_hub
}

return 0 2>/dev/null || true
