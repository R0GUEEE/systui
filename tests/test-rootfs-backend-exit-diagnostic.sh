#!/usr/bin/env bash
# Prove backend-picker failure is surfaced, not mistaken for a crash.
# No host build, package install or filesystem target operation is called.
set -euo pipefail
repo=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
. "$repo/src/features/rootfs.sh"
content=''

tui_radio() {
    case "$1" in
        'Rootfs Builder 1/13') printf 'debian\n' ;;
        'Rootfs Builder 2/13') printf 'amd64\n' ;;
        *) return 90 ;;
    esac
}
rootfs_release_menu() { printf 'trixie\n'; }
rootfs_backend_menu() { return 1; }
tui_msg() { content+="$1"$'\n'"$2"$'\n'; }

rootfs_builder_impl

case $content in
    *'Rootfs build paused'*) ;;
    *) printf 'FAIL builder returned to Rootfs menu without a diagnostic\n' >&2; exit 1 ;;
esac
case $content in
    *'debian trixie (amd64)'*) ;;
    *) printf 'FAIL diagnostic omitted selected distro/release/architecture\n' >&2; exit 1 ;;
esac
printf 'PASS backend failure is explicitly reported with selected target\n'
