#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
F="$ROOT/src/features/99-distro-manager-distrobox-final.sh"
LOAD="$ROOT/src/features/.load-order"

bash -n "$F"
grep -Fqx '99-distro-manager-distrobox-final.sh' "$LOAD"
grep -Fq 'rootfs_dm_distrobox_engine()' "$F"
grep -Fq 'rootfs_dm_distrobox_host_supported()' "$F"
grep -Fq 'rootfs_dm_distrobox_list_names()' "$F"
grep -Fq 'list --no-color' "$F"
grep -Fq 'stop --yes' "$F"
grep -Fq 'rm --force --yes' "$F"
grep -Fq 'quay.io/toolbx-images/debian-toolbox:13' "$F"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
cat > "$tmp/bin/distrobox" <<'EOF'
#!/bin/sh
if [ "$1" = list ]; then
cat <<'OUT'
ID           | NAME       | STATUS         | IMAGE
abcd1234     | deb-dev    | Up 2 minutes   | debian:13
1234abcd     | arch-test  | Exited         | archlinux:latest
OUT
exit 0
fi
exit 0
EOF
chmod +x "$tmp/bin/distrobox"

rootfs_dm_package(){ :; }
rootfs_dm_installed_names(){ :; }
rootfs_dm_install(){ :; }
rootfs_dm_capture(){ shift; command distrobox "$@"; }
tui_msg(){ :; }
tui_yesno(){ return 1; }
pm_install(){ :; }
rootfs_dm_label(){ printf '%s\n' "$1"; }
rootfs_dm_pick_installed(){ :; }
rootfs_dm_run(){ :; }
rootfs_dm_browse_install(){ :; }
rootfs_dm_show_command(){ :; }
rootfs_dm_config_menu(){ :; }
rootfs_dm_remove(){ :; }
tui_menu_no_tags(){ return 1; }
export PATH="$tmp/bin:$PATH"
# shellcheck source=/dev/null
source "$F"

names=$(rootfs_dm_distrobox_list_names)
grep -qx 'deb-dev' <<<"$names"
grep -qx 'arch-test' <<<"$names"

images=$(rootfs_dm_distrobox_static_images)
grep -q '^docker.io/library/ubuntu:latest|' <<<"$images"
grep -q '^registry.opensuse.org/opensuse/tumbleweed:latest|' <<<"$images"

printf 'ok - distrobox distro-manager final compatibility\n'
