#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../src/features/rootfs.sh
source "$PROJECT_DIR/src/features/rootfs.sh"
# shellcheck source=../src/features/zz-rootfs-distro-managers.sh
source "$PROJECT_DIR/src/features/zz-rootfs-distro-managers.sh"

checks=0
failures=0
check() {
    local desc="$1"; shift
    checks=$((checks + 1))
    if "$@"; then
        printf 'ok %d - %s\n' "$checks" "$desc"
    else
        printf 'not ok %d - %s\n' "$checks" "$desc"
        failures=$((failures + 1))
    fi
}
equals() { [ "$1" = "$2" ]; }
contains_text() { grep -Fq -- "$2" <<< "$1"; }
not_contains_text() { ! grep -Fq -- "$2" <<< "$1"; }

# Capture exactly what would be passed to each manager.
CALLS=""
rootfs_dm_run() {
    local tag="$1" desc="$2"; shift 2
    CALLS+="$tag|$*\n"
}

CALLS=""; rootfs_dm_install_image proot-distro ubuntu:24.04
check "proot-distro uses install IMAGE" equals "$CALLS" 'proot-distro|install ubuntu:24.04\n'
check "proot-distro never emits download" not_contains_text "$CALLS" download

CALLS=""; rootfs_dm_install_image chroot-distro debian:bookworm
check "chroot-distro uses install IMAGE" equals "$CALLS" 'chroot-distro|install debian:bookworm\n'
check "chroot-distro never emits download" not_contains_text "$CALLS" download

CALLS=""; rootfs_dm_install_image distrobox docker.io/library/alpine:latest alpine-test
check "distrobox uses create --yes --name --image" equals "$CALLS" 'distrobox|create --yes --name alpine-test --image docker.io/library/alpine:latest\n'

distrobox_menu=$(declare -f rootfs_dm_menu_distrobox)
menu_has_distrobox_install() {
    grep -Eq 'install[[:space:]]+"Install or update distrobox"' <<< "$distrobox_menu"
}
check "distrobox menu exposes install/update" menu_has_distrobox_install
check "distrobox upstream source uses 89luca89 installer" contains_text \
    "$(declare -f rootfs_dm_install_upstream)" \
    'raw.githubusercontent.com/89luca89/distrobox/main/install'
check "distrobox install source names upstream repository" contains_text \
    "$(declare -f rootfs_dm_install)" '89luca89/distrobox (GitHub)'

CALLS=""; rootfs_dm_install_image toolbx quay.io/toolbx/ubuntu-toolbox:24.04 ubuntu-test
check "toolbox uses create --image IMAGE NAME" equals "$CALLS" 'toolbx|create --image quay.io/toolbx/ubuntu-toolbox:24.04 ubuntu-test\n'

CALLS=""; rootfs_dm_install_image udocker ubuntu:24.04 ubuntu-test
check "udocker pull/create sequence is correct" equals "$CALLS" 'udocker|pull ubuntu:24.04\nudocker|create --name=ubuntu-test ubuntu:24.04\n'

# Current proot-distro quiet search: one installable image per line.
rootfs_dm_capture() {
    if [ "$1" = proot-distro ] && [ "$2" = search ] && [ "$3" = --quiet ]; then
        printf 'ubuntu\nubuntu/nginx\n'
        return 0
    fi
    return 1
}
check "proot search results become installable entries" equals \
    "$(rootfs_dm_search_distros proot-distro ubuntu | cut -d'|' -f1 | tr '\n' ',')" \
    'ubuntu,ubuntu/nginx,'

# Current chroot-distro search table. Header/footer text must not become images.
rootfs_dm_capture() {
    if [ "$1" = chroot-distro ] && [ "$2" = search ]; then
        cat <<'FIX'
NAME                 STARS OFFICIAL DESCRIPTION
ubuntu               17000 [OK]     Ubuntu is a Debian based Linux operating system
ubuntu/nginx         130            Nginx on Ubuntu
Showing 2 results
FIX
        return 0
    fi
    return 1
}
check "chroot search table parses repository names" equals \
    "$(rootfs_dm_search_distros chroot-distro ubuntu | cut -d'|' -f1 | tr '\n' ',')" \
    'ubuntu/nginx,ubuntu,'

# Historical proot-distro versions exposed a static Alias catalogue via list.
rootfs_dm_capture() {
    cat <<'FIX'
Alpine Linux (edge)

  Alias: alpine
  Installed: no

Debian (bookworm)

  Alias: debian
  Installed: no
FIX
}
check "legacy proot Alias catalogue remains parseable" equals \
    "$(rootfs_dm_parse_distros proot-distro | cut -d'|' -f1 | tr '\n' ',')" \
    'alpine,debian,'

# The runtime menu exposes one combined browse/install action instead of the
# old separate list-offered and install-distribution actions.
menu_body=$(declare -f rootfs_dm_menu_proot_chroot)
check "combined browse/install menu exists" contains_text "$menu_body" 'Browse/select/install distributions (combined workflow)'
check "old list-offered menu entry is gone" not_contains_text "$menu_body" 'List distributions this tool offers'
check "old separate install menu entry is gone" not_contains_text "$menu_body" 'Install a distribution'

printf '%s checks, %s failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
