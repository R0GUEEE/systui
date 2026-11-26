#!/usr/bin/env bash
# Real Rootfs menu -> guided wizard; replace dialogs, package and build operations.
set -eu
repo=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf -- "$tmp"' EXIT
# Source only the build implementation and its target helper; the full feature
# intentionally initializes unrelated package catalogues and may perform host probes.
sed -n '/^rootfs_new_target_available()/,/^}/p; /^rootfs_builder()/,/^}/p; /^rootfs_builder_impl()/,/^}/p' "$repo/src/features/rootfs.sh" > "$tmp/builder-functions.sh"
source "$tmp/builder-functions.sh"
source "$repo/src/features/113-ish-aok-sysconfig-integration.sh"
ROOTFS_BASE="$tmp/base"; mkdir "$ROOTFS_BASE"
SYSTUI_TMP=$tmp; target_fixture="$ROOTFS_BASE/Devuan image"; confirm=no
run_strict() { shift; "$@"; }
tui_capture_menu() { local dest=$1; printf -v "$dest" '%s' "${menu_choice:-build}"; menu_choice=back; }
tui_msg() { :; }
tui_radio() { case $1 in *1/13*) echo devuan;; *2/13*|*Target\ architecture*) echo arm64;; *5/13*) echo sysvinit;; *12/13*) echo xz;; *) return 1;; esac; }
tui_input() { case $1 in *8/13) printf '%s\n' "$target_fixture";; *) printf '%s\n' "$3";; esac; }
tui_password() { :; }; tui_check() { :; }
tui_yesno() { [[ $1 == *13/13 && $confirm != no ]] || return 1; if [[ $confirm == race ]]; then mkdir "$target_fixture"; touch "$target_fixture/foreign"; fi; }
rootfs_distro_archs() { echo 'arm64|Arm'; }; rootfs_release_menu() { echo excalibur; }
rootfs_valid_mirror() { [[ $1 == http://* || $1 == https://* ]]; }
rootfs_backend_menu() { echo mmdebstrap; }; rootfs_backend_auto_optimize() { :; }; rootfs_backend_config_menu() { :; }
rootfs_check_host_deps() { :; }; needs_qemu() { return 1; }; rootfs_package_catalog() { echo sysvinit-core; }
rootfs_backend_config_summary() { echo fixture; }; rootfs_backend_config_write() { touch "$1/config"; }
rootfs_write_build_state() { [[ -f $1/config ]]; touch "$1/state"; }
rootfs_build_recovery() { [[ -f $1/state && $1 == "$target_fixture" && $2 == devuan && $3 == excalibur && $4 == arm64 && ${11} == mmdebstrap && ${24} == 22 && ${25} == arm64 ]] || { echo "wrong recovery argv" >&2; exit 1; }; printf 'recovery %s\n' "$1" >> "$tmp/calls"; }
menu_rootfs; [[ ! -e $target_fixture && ! -e $tmp/calls ]]
confirm=race; unset menu_choice; menu_rootfs; [[ -f $target_fixture/foreign && ! -e $target_fixture/config && ! -e $tmp/calls ]]
target_fixture="$ROOTFS_BASE/Fresh build"; confirm=yes; unset menu_choice; menu_rootfs; [[ $(cat "$tmp/calls") == "recovery $target_fixture" ]]
ln -s "$ROOTFS_BASE" "$tmp/link"; ! rootfs_new_target_available "$tmp/link/fresh" || exit 1
! rootfs_new_target_available "$ROOTFS_BASE/../new" || exit 1
source "$repo/src/features/zzzzzzzzzzzzzzz-rootfs-build-autoconfig.sh"; ROOTFS_BASE="$tmp/base"
tui_menu_no_tags() { echo next; }
[[ $(rootfs_target_collision_resolve devuan excalibur arm64 "$target_fixture") == "$target_fixture-2" && -f $target_fixture/state ]]
printf 'PASS rootfs build: cancel, concurrent collision, dispatch, symlinks and numbered alternative\n'
