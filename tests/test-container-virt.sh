#!/usr/bin/env bash
# Container & virtualization module: catalogue, configuration rendering,
# distro-manager wiring and the Rootfs menu entry.
#
# Everything runs against a temporary config directory and temporary
# configuration files — no engine, no daemon and no /etc write is required.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

export SYSTUI_TMP_ROOT="$tmp"
export SYSTUI_TMP="$tmp/tmp"
export SYSTUI_LOGFILE="$tmp/systui.log"
export SYSTUI_CONFIG_DIR="$tmp/cfg"
export HOME="$tmp/home"
mkdir -p "$SYSTUI_TMP" "$SYSTUI_CONFIG_DIR" "$HOME"

export SYSTUI_DOCKER_DAEMON_JSON="$tmp/daemon.json"
export SYSTUI_REGISTRIES_CONF="$tmp/registries.conf"
export SYSTUI_CONTAINERS_CONF="$tmp/containers.conf"
export SYSTUI_STORAGE_CONF="$tmp/storage.conf"
export SYSTUI_LXC_CONF="$tmp/lxc-default.conf"
export PM=apt

# shellcheck source=../src/core/config.sh
. "$ROOT/src/core/config.sh"
# shellcheck source=../src/core/tui-widgets.sh
. "$ROOT/src/core/tui-widgets.sh"
# shellcheck source=../src/core/common.sh
. "$ROOT/src/core/common.sh"

# Interactive layer stubs: menus auto-cancel, prompts return their default.
tui_msg() { :; }
tui_text() { :; }
tui_yesno() { return 0; }
tui_input() { printf '%s\n' "${3:-}"; }
tui_menu_no_tags() { return 1; }
tui_check() { return 1; }
tui_capture_menu() { local d="$1"; printf -v "$d" '%s' ''; return 0; }
run_cmd() { local _d="$1"; shift; "$@" >/dev/null 2>&1; }
log() { :; }

# The distro-manager stack in its real load order: base menu, command map,
# docker image normalisation, distrobox final layer, then the extensions.
# shellcheck source=../src/features/rootfs.sh
. "$ROOT/src/features/rootfs.sh"
# shellcheck source=../src/features/zz-rootfs-distro-managers.sh
. "$ROOT/src/features/zz-rootfs-distro-managers.sh"
# shellcheck source=../src/features/60-rootfs-docker-image-normalization.sh
. "$ROOT/src/features/60-rootfs-docker-image-normalization.sh"
# shellcheck source=../src/features/99-distro-manager-distrobox-final.sh
. "$ROOT/src/features/99-distro-manager-distrobox-final.sh"
# shellcheck source=../src/features/zzzzzzzzzzzzzzzzzzzzzzzzz-rootfs-workbench-manage.sh
. "$ROOT/src/features/zzzzzzzzzzzzzzzzzzzzzzzzz-rootfs-workbench-manage.sh"
# shellcheck source=../src/features/zzz-rootfs-container-virt.sh
. "$ROOT/src/features/zzz-rootfs-container-virt.sh"
# shellcheck source=../src/features/zzz-rootfs-distro-managers-extended.sh
. "$ROOT/src/features/zzz-rootfs-distro-managers-extended.sh"

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
equals() { [ "$1" = "$2" ] || { printf '    expected: %s\n    actual  : %s\n' "$2" "$1"; return 1; }; }
contains() { grep -Fq -- "$2" "$1" || { printf '    missing in %s: %s\n' "$1" "$2"; return 1; }; }
has_container_tools() { local t; for t in "$@"; do rootfs_dm_container_tools | grep -qx "$t" || return 1; done; }
not_contains() { ! grep -Fq -- "$2" "$1"; }

# ---------------------------------------------------------------------------
# Catalogue integrity
# ---------------------------------------------------------------------------
check "catalogue has 12 tools" equals "$(cn_tools | wc -l | tr -d ' ')" "12"
check "catalogue tags are unique" equals "$(cn_tools | cut -d'|' -f1 | sort -u | wc -l | tr -d ' ')" "12"
check "catalogue provides a binary per tool" equals \
    "$(cn_tools | awk -F'|' '$2 == "" { c++ } END { print c + 0 }')" "0"
check "catalogue provides a label per tool" equals \
    "$(cn_tools | awk -F'|' '$3 == "" { c++ } END { print c + 0 }')" "0"
check "docker is known" equals "$(cn_tool_bin docker)" "docker"
check "nerdctl binary maps to containerd" equals "$(cn_tool_bin containerd)" "nerdctl"
unknown_tool_has_no_binary() { [ -z "$(cn_tool_bin nosuchtool)" ]; }
check "unknown tool has no binary" unknown_tool_has_no_binary

# ---------------------------------------------------------------------------
# Package names per package manager
# ---------------------------------------------------------------------------
check "apt docker package" equals "$(PM=apt cn_tool_packages docker | head -1)" "docker.io"
check "apk docker package" equals "$(PM=apk cn_tool_packages docker | head -1)" "docker"
check "pacman docker package" equals "$(PM=pacman cn_tool_packages docker | head -1)" "docker"
apt_podman_pulls_helpers() { PM=apt cn_tool_packages podman | grep -qx fuse-overlayfs; }
check "apt podman pulls rootless helpers" apt_podman_pulls_helpers
check "emerge podman uses the category path" equals \
    "$(PM=emerge cn_tool_packages podman | head -1)" "app-containers/podman"
check "waydroid is not claimed for apk" equals "$(PM=apk cn_tool_packages waydroid)" ""

# ---------------------------------------------------------------------------
# daemon.json rendering
# ---------------------------------------------------------------------------
cn_conf_set docker_data_root /srv/docker
cn_conf_set docker_storage_driver overlay2
cn_conf_set docker_log_driver json-file
cn_conf_set docker_log_max_size 20m
cn_conf_set docker_log_max_file 5
cn_conf_set docker_registry_mirrors "https://mirror.example:5000 https://mirror2.example"
cn_conf_set docker_insecure_registries "registry.lan:5000"
cn_conf_set docker_dns "1.1.1.1 9.9.9.9"
cn_conf_set docker_pool_base 172.31.0.0/16
cn_conf_set docker_pool_size 24
cn_conf_set docker_live_restore true
cn_conf_set docker_iptables true
cn_conf_set docker_ip6tables false
cn_conf_set docker_userland_proxy true
cn_conf_set docker_userns_remap default
cn_conf_set docker_builder_gc 10GB

cn_write_docker_daemon
daemon=$(cn_docker_daemon_file)
check "daemon.json is written to the override path" test -s "$daemon"
check "daemon.json is valid JSON" python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$daemon"
check "daemon.json carries data-root" contains "$daemon" '"/srv/docker"'
check "daemon.json carries the storage driver" contains "$daemon" '"overlay2"'
check "daemon.json carries log rotation" contains "$daemon" '"max-size": "20m"'
check "daemon.json carries the max-file count" contains "$daemon" '"max-file": "5"'
check "daemon.json carries both registry mirrors" equals \
    "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["registry-mirrors"]))' "$daemon")" "2"
check "daemon.json carries insecure registries" contains "$daemon" '"registry.lan:5000"'
check "daemon.json carries DNS" contains "$daemon" '"1.1.1.1"'
check "daemon.json default-address-pools base" contains "$daemon" '"172.31.0.0/16"'
check "daemon.json pool size is numeric" contains "$daemon" '"size": 24'
check "daemon.json booleans are unquoted" contains "$daemon" '"live-restore": true'
check "daemon.json keeps userns-remap" contains "$daemon" '"userns-remap": "default"'
check "daemon.json carries the builder cache limit" contains "$daemon" '"defaultKeepStorage": "10GB"'
check "daemon.json keeps buildkit" not_contains "$daemon" 'buildkit'

# Empty settings must not produce empty arrays or null values.
rm -f "$daemon"
cn_reset_settings docker_
check "reset clears the saved docker settings" equals "$(cn_conf_get docker_registry_mirrors)" ""
cn_write_docker_daemon
check "empty configuration still yields valid JSON" python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$daemon"
check "empty configuration has no nulls" not_contains "$daemon" 'null'
check "empty configuration has no empty arrays" not_contains "$daemon" '[]'

# ---------------------------------------------------------------------------
# Podman files
# ---------------------------------------------------------------------------
cn_conf_set podman_registry_mirrors "https://mirror.example"
cn_conf_set podman_insecure_registries "registry.lan:5000"
cn_conf_set podman_search_registries "docker.io quay.io"
cn_conf_set podman_graphroot /srv/containers
cn_conf_set podman_storage_driver overlay
cn_conf_set podman_runtime crun
cn_conf_set podman_cgroup systemd
cn_write_registries_conf
cn_write_containers_conf
cn_write_storage_conf

check "registries.conf declares search order" contains "$(cn_registries_file)" 'unqualified-search-registries = ["docker.io", "quay.io"]'
check "registries.conf declares the mirror" contains "$(cn_registries_file)" 'location = "https://mirror.example"'
check "registries.conf marks the insecure registry" contains "$(cn_registries_file)" 'insecure = true'
check "containers.conf names the runtime" contains "$(cn_containers_conf_file)" 'runtime = "crun"'
check "containers.conf names the cgroup manager" contains "$(cn_containers_conf_file)" 'cgroup_manager = "systemd"'
check "storage.conf carries the graph root" contains "$(cn_storage_conf_file)" 'graphroot = "/srv/containers"'
check "storage.conf carries the driver" contains "$(cn_storage_conf_file)" 'driver = "overlay"'
check "apply writes all four files" cn_apply_engine_config all

# ---------------------------------------------------------------------------
# LXC default profile
# ---------------------------------------------------------------------------
cn_conf_set lxc_gateway 10.0.9.1
cn_conf_set lxc_netmode veth
cn_write_lxc_conf
check "lxc default.conf uses the configured gateway" contains "$(cn_lxc_conf_file)" 'lxc.net.0.ipv4.gateway = 10.0.9.1'
cn_conf_set lxc_netmode none
cn_write_lxc_conf
check "lxc can be configured without a network" contains "$(cn_lxc_conf_file)" 'lxc.net.0.type = empty'

# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------
check "bool normalization" equals "$(cn_bool yes)" "true"
check "bool normalization of off" equals "$(cn_bool off)" "false"
check "valid path accepted" cn_valid_path /var/lib/docker
relative_path_rejected() { ! cn_valid_path var/lib/docker; }
bad_cidr_rejected() { ! cn_valid_cidr 172.17.0.0; }
cross_engine_driver_rejected() { ! cn_valid_driver docker fuse-overlayfs; }
check "relative path rejected" relative_path_rejected
check "CIDR accepted" cn_valid_cidr 172.17.0.0/16
check "bad CIDR rejected" bad_cidr_rejected
check "docker driver accepted" cn_valid_driver docker overlay2
check "podman driver accepted" cn_valid_driver podman fuse-overlayfs
check "cross-engine driver rejected" cross_engine_driver_rejected
check "list split de-duplicates" equals "$(cn_split_list 'a, b a;c' | tr '\n' ' ')" "a b c "

# ---------------------------------------------------------------------------
# Distro-manager wiring
# ---------------------------------------------------------------------------
has_managers() { local t; for t in "$@"; do rootfs_dm_managers | cut -d'|' -f1 | grep -qx "$t" || return 1; done; }
lxc_not_engine_backed() { ! rootfs_dm_needs_engine lxc; }
check "distro-manager catalogue keeps only systui-owned managers" has_managers \
    proot-distro chroot-distro distrobox toolbx schroot udocker machinectl arch-chroot
container_tool_not_duplicated() { ! rootfs_dm_managers | cut -d'|' -f1 | grep -qx "$1"; }
check "podman is not duplicated in the distro-manager catalogue" container_tool_not_duplicated podman
check "docker is not duplicated in the distro-manager catalogue" container_tool_not_duplicated docker
check "lxc is not duplicated in the distro-manager catalogue" container_tool_not_duplicated lxc
check "incus is not duplicated in the distro-manager catalogue" container_tool_not_duplicated incus
check "container tools are still addressable" has_container_tools podman docker lxc incus
check "distrobox is treated as engine-backed" rootfs_dm_needs_engine distrobox
check "lxc is not engine-backed" lxc_not_engine_backed

CALLS=""
rootfs_dm_run() {
    local tag="$1" desc="$2"; shift 2
    CALLS+="$tag|$*"$'\n'
}
cn_conf_set dm_podman_pull always
CALLS=""; rootfs_dm_install_image podman docker.io/library/debian:stable-slim deb-test
check "podman pulls then creates" equals "$CALLS" 'podman|pull docker.io/library/debian:stable-slim
podman|create --name deb-test -it docker.io/library/debian:stable-slim
'
cn_conf_set dm_podman_pull missing
CALLS=""; rootfs_dm_install_image podman alpine:latest alpine-test
check "pull policy can be relaxed" equals "$CALLS" 'podman|create --name alpine-test -it alpine:latest
'
cn_conf_set dm_podman_args "--network host -v /:/host"
CALLS=""; rootfs_dm_install_image podman alpine:latest alpine-test
check "extra create arguments are applied" equals "$CALLS" 'podman|create --name alpine-test --network host -v /:/host alpine:latest
'
cn_conf_set dm_podman_args ""
CALLS=""; rootfs_dm_install_image lxc debian/12 lxc-test
check "lxc launches from an image alias" equals "$CALLS" 'lxc|launch debian/12 lxc-test
'
CALLS=""; rootfs_dm_install_image incus debian/12 inc-test
check "incus prefixes the images remote" equals "$CALLS" 'incus|launch images:debian/12 inc-test
'
CALLS=""; rootfs_dm_install_image distrobox docker.io/library/alpine:latest box-test
check "existing managers still use the earlier command map" equals "$CALLS" \
    'distrobox|create --yes --name box-test --image docker.io/library/alpine:latest
'

# ---------------------------------------------------------------------------
# Menu wiring
# ---------------------------------------------------------------------------
rootfs_menu_has_entry() { declare -f menu_rootfs | grep -Fq 'containers'; }
rootfs_menu_dispatches() { declare -f menu_rootfs | grep -Fq 'menu_rootfs_containers'; }
dm_menu_links_engines() { declare -f menu_rootfs_distro_managers | grep -Fq 'menu_rootfs_containers'; }
dm_menu_has_defaults() { declare -f menu_rootfs_distro_managers | grep -Fq 'rootfs_dm_settings_menu'; }
dm_menu_has_bulk() { declare -f menu_rootfs_distro_managers | grep -Fq 'rootfs_dm_install_multiple_managers'; }
dm_config_has_no_prefix() { ! declare -f rootfs_dm_config_menu | grep -Fq 'dm_install_prefix'; }
rootfs_menu_has_no_manage() { ! declare -f menu_rootfs | grep -Eq '^\s+manage\)'; }
workbench_has_more() { declare -f rootfs_wb_menu_for | grep -Fq 'rootfs_wb_more_menu'; }
engine_menus_share_impl() { declare -f cn_docker_menu | grep -Fq 'cn_engine_menu docker' &&
                            declare -f cn_podman_menu | grep -Fq 'cn_engine_menu podman'; }
fn_defined() { declare -F "$1" >/dev/null 2>&1; }
check "Rootfs menu defines the container entry" rootfs_menu_has_entry
check "Rootfs menu dispatches to the container utility" rootfs_menu_dispatches
check "distro-manager menu links the engine front door" dm_menu_links_engines
check "distro-manager menu offers shared defaults" dm_menu_has_defaults
check "distro-manager menu offers bulk install" dm_menu_has_bulk
check "distro-manager config no longer repeats the install prefix" dm_config_has_no_prefix
check "rootfs menu no longer offers the duplicate manage entry" rootfs_menu_has_no_manage
check "workbench exposes the merged 'more' actions" workbench_has_more
check "engine menu is shared by docker and podman" engine_menus_share_impl
check "container menu is defined" fn_defined menu_rootfs_containers
check "docker menu is defined" fn_defined cn_docker_menu
check "podman menu is defined" fn_defined cn_podman_menu
check "libvirt menu is defined" fn_defined cn_libvirt_menu
check "waydroid menu is defined" fn_defined cn_waydroid_menu
check "sandbox menu is defined" fn_defined cn_sandbox_menu

manifest="$ROOT/src/features/.load-order"
check "container module is in the load manifest" grep -Fxq 'zzz-rootfs-container-virt.sh' "$manifest"
check "distro-manager extension is in the load manifest" grep -Fxq 'zzz-rootfs-distro-managers-extended.sh' "$manifest"
loads_after_distrobox() {
    local a b
    a=$(awk '$0 == "zzz-rootfs-distro-managers-extended.sh" { print NR; exit }' "$manifest")
    b=$(awk '$0 == "99-distro-manager-distrobox-final.sh" { print NR; exit }' "$manifest")
    [ -n "$a" ] && [ -n "$b" ] && [ "$a" -gt "$b" ]
}
check "extension loads after the distrobox final layer" loads_after_distrobox

# The image browser must reach the container-backed managers (it used to be a
# silent no-op for them).
tui_input() { printf '%s\n' "${3:-}"; }
rootfs_dm_select_catalog_entries() { printf '%s\n' "docker.io/library/debian:stable-slim"; }
CALLS=""
rootfs_dm_browse_install docker >/dev/null 2>&1
check "browse creates a container for docker" equals "$CALLS" 'docker|pull docker.io/library/debian:stable-slim
docker|create --name debian -it docker.io/library/debian:stable-slim
'
CALLS=""
rootfs_dm_browse_install lxc >/dev/null 2>&1
check "browse launches an LXC container" equals "$CALLS" 'lxc|launch docker.io/library/debian:stable-slim debian
'

printf '%s checks, %s failures\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
