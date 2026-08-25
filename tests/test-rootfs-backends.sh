#!/bin/bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=../src/features/rootfs.sh
source "$PROJECT_DIR/src/features/rootfs.sh"

failures=0
checks=0

check() {
    local description="$1"
    shift
    checks=$((checks + 1))
    if "$@"; then
        printf 'ok %d - %s\n' "$checks" "$description"
    else
        printf 'not ok %d - %s\n' "$checks" "$description"
        failures=$((failures + 1))
    fi
}

equals() { [ "$1" = "$2" ]; }
contains() { grep -Fq -- "$2" "$1"; }
rejects_backend() { ! rootfs_backend_supported "$1" "$2"; }
rejects_resolution() { ! rootfs_resolve_backend "$1" "$2" >/dev/null; }

check "Debian accepts mmdebstrap" rootfs_backend_supported debian mmdebstrap
check "Ubuntu accepts qemu-debootstrap" rootfs_backend_supported ubuntu qemu-debootstrap
check "Arch rejects debootstrap" rejects_backend arch debootstrap
check "explicit incompatible backend is rejected" rejects_resolution alpine multistrap
check "explicit compatible backend is retained" equals "$(rootfs_resolve_backend kali cdebootstrap)" cdebootstrap

# --- catalogue is the single source of truth for distro/arch compatibility ---
catalogue_tags() { rootfs_backend_catalog "$1" "${2:-}" | cut -d'|' -f1 | tr '\n' ' '; }
lists_backend()  { rootfs_backend_catalog "$1" "${2:-}" | cut -d'|' -f1 | grep -qx -- "$3"; }
omits_backend()  { ! lists_backend "$@"; }

no_catalogue()   { ! rootfs_backend_catalog "$1" "${2:-}" >/dev/null 2>&1; }
no_resolution()  { ! rootfs_resolve_backend "$1" "$2" "${3:-}" >/dev/null 2>&1; }
unsupported()    { ! rootfs_backend_supported "$1" "$2" "${3:-}"; }

check "unknown distro yields no backends" no_catalogue notadistro
check "every deb backend is offered for Debian" equals \
    "$(catalogue_tags debian)" "mmdebstrap debootstrap cdebootstrap multistrap qemu-debootstrap "
check "Alpine prefers apk-static" equals "$(catalogue_tags alpine)" "apk-static alpine-chroot-install "
check "rinse is offered for RPM distros"     lists_backend fedora "" rinse
check "rinse is offered for openSUSE"        lists_backend opensuse "" rinse
check "rinse is not offered for Debian"      omits_backend debian "" rinse
check "bdebstrap is Debian-family only"      omits_backend alpine "" bdebstrap
check "Void only offers its ROOTFS tarball" equals "$(catalogue_tags void)" "void-tarball "

# qemu-debootstrap was a wrapper that re-executed debootstrap and was dropped
# from qemu-user-static in trixie: it is only worth offering for a foreign arch.
check "qemu-debootstrap is hidden for a native build" \
    omits_backend debian "$(host_debarch)" qemu-debootstrap
check "debootstrap is still offered for a native build" \
    lists_backend debian "$(host_debarch)" debootstrap
foreign_arch=amd64; [ "$(host_debarch)" = amd64 ] && foreign_arch=arm64
check "qemu-debootstrap is offered for a foreign arch" \
    lists_backend debian "$foreign_arch" qemu-debootstrap
check "arch-qualified support check tracks the catalogue" \
    unsupported debian qemu-debootstrap "$(host_debarch)"

# Arch Linux: x86_64 uses the official repos; ARM uses Arch Linux ARM.
check "Arch offers pacstrap on amd64" lists_backend arch amd64 pacstrap
check "Arch offers the ARM tarball on arm64" lists_backend arch arm64 alarm-tarball
check "Arch offers the ARM tarball on armhf" lists_backend arch armhf alarm-tarball
check "Arch does not offer pacstrap on arm64" omits_backend arch arm64 pacstrap
check "Arch rejects pacstrap on a non-x86_64 resolution" no_resolution arch pacstrap arm64

# --- Bedrock Linux (meta-distro; hijacks a Debian base) ---------------------
bedrock_has_candidate() { rootfs_release_candidates bedrock x86_64 | grep -qx "$1"; }
check "Bedrock offers the Debian-family backends" lists_backend bedrock "" mmdebstrap
check "Bedrock has amd64/arm64/armhf/i386 arch candidates" \
    equals "$(rootfs_distro_archs bedrock | cut -d'|' -f1 | tr '\n' ' ')" "amd64 arm64 armhf i386 "
check "Bedrock asset arch maps amd64 to x86_64" equals "$(rootfs_bedrock_asset_arch amd64)" x86_64
check "Bedrock asset arch maps i386 to i686"    equals "$(rootfs_bedrock_asset_arch i386)" i686
check "Bedrock current release resolves"        equals "$(rootfs_bedrock_release_version current)" 0.7.31
check "Bedrock release candidates include a version" bedrock_has_candidate 0.7.31

# Strata: the fetch runner executes `brl fetch <distro>` per selected distro.
strata_show() {
    rootfs_unmount_chroot_fs() { :; }
    rootfs_mount_chroot_fs() { :; }
    local sdir cmds=""
    sdir=$(mktemp -d); mkdir -p "$sdir/etc"
    rootfs_chroot_exec() { cmds="$cmds|$3"; return 0; }
    rootfs_bedrock_fetch_strata "$sdir" "debian arch" "artix" "" 0 ""
    rm -rf "$sdir"
    printf '%s' "$cmds"
}
has_brl_fetch() { [ -n "$(strata_show | grep -o 'brl fetch  *"debian"')" ]; }
has_extra_brl() { [ -n "$(strata_show | grep -o '"artix"')" ]; }
check "strata runner issues brl fetch per distro" has_brl_fetch
check "strata runner includes extra/custom names" has_extra_brl

# Auto-resolution must still name this distro's preferred tool on a host where
# nothing is installed, so the caller can say what to install.
check "auto resolution always names a compatible backend" \
    rootfs_backend_supported alpine "$(rootfs_resolve_backend alpine auto)"
check "auto resolution fails for an unknown distro" rejects_resolution notadistro auto

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# --- Bedrock strata management -------------------------------------------------
mkdir -p "$tmpdir/nonbedrock/bedrock/bin"
: > "$tmpdir/nonbedrock/bedrock/bin/brl"; chmod +x "$tmpdir/nonbedrock/bedrock/bin/brl"
not_bedrock_dir() { ! rootfs_is_bedrock "$tmpdir/empty"; }
check "strata manager exposes is_bedrock"  declare -F rootfs_is_bedrock
check "is_bedrock flags a bedrock layout"  rootfs_is_bedrock "$tmpdir/nonbedrock"
check "is_bedrock false for an empty root" not_bedrock_dir

# --- Bedrock world file -----------------------------------------------------
# The world submenu builds pmm world flags; menu returns "back" so no loop.
world_cmds() {
    rootfs_chroot_exec() { :; }
    tui_menu() { echo back; }
    rootfs_bedrock_world_menu "$tmpdir/nonbedrock" >/dev/null 2>&1
}
check "world menu function is exposed"    declare -F rootfs_bedrock_world_menu
check "strata manager exposes fuse preflight" declare -F rootfs_bedrock_preflight_fuse
check "world menu terminates on back"     world_cmds
world_flag_ok() { grep -q -- "--${1:-diff}-world" src/features/rootfs.sh; }
check "world diff/update/apply flags wired" world_flag_ok diff

all_managers_have_hints() {
    local tag bin label
    while IFS='|' read -r tag bin label; do
        [ -n "$tag" ] || continue
        [ -n "$(rootfs_dm_install_hint "$tag")" ] || return 1
    done < <(rootfs_dm_managers)
}
chroot_store_is_known() {
    # Upstream documents /data/local/chroot-distro as the fixed path.
    declare -f rootfs_dm_store_default | grep -q '/data/local/chroot-distro'
}

dm_is_rootless()   { ! rootfs_dm_runs_as_root "$1"; }
dm_has_no_store()  { ! rootfs_dm_store "$1" >/dev/null 2>&1; }

no_engine_argv()    { ! rootfs_wb_engine_argv "$wb_root" "$1" /bin/true >/dev/null 2>&1; }
proot_is_rootless() { ! rootfs_wb_engine_needs_root proot; }
not_kernel_mounts() { ! rootfs_wb_engine_uses_kernel_mounts "$1"; }
bind_rejected()     { ! rootfs_wb_bind_valid "$1" "$2"; }
pack_excludes_are_applied() {
    local arc="$tmpdir/excl.tar.gz"
    echo keep > "$wb_root/etc/keep.conf"
    echo drop > "$wb_root/var/log/drop.log"
    rootfs_tar_create gz "$wb_root" "$arc" --exclude=./var/log/\* >/dev/null 2>&1 || return 1
    tar -tzf "$arc" | grep -qx ./etc/keep.conf || return 1
    ! tar -tzf "$arc" | grep -qx ./var/log/drop.log
}

archive_format_rejected() {
    local out
    out=$(mktemp "$tmpdir/arch.XXXXXX")
    ! rootfs_tar_create notaformat "$tmpdir" "$out" 2>/dev/null
}

# Guards the "trailing [ -n ... ] && warn" bug: a build function must not end
# on a bare test, whose false result would become its exit status and turn a
# successful build into a reported failure. Assert that every optional-package
# warning is followed by an explicit success return. (declare -f re-prints the
# body with trailing semicolons, hence the optional ";".)
tail_returns_explicitly() {
    declare -f "$1" | grep -A1 -E '^[[:space:]]*\[ -n "\$\{(pkgs|mapped)// \}" \] && warn ' |
        grep -qE '^[[:space:]]*return 0;?$'
}

rootfs_backend_config_defaults ubuntu mmdebstrap
ROOTFS_BACKEND_INCLUDE="ca-certificates curl"
ROOTFS_BACKEND_EXCLUDE="documentation"
ROOTFS_MMDEBSTRAP_MODE=unshare
rootfs_backend_config_write "$tmpdir"
rootfs_backend_config_defaults debian debootstrap
rootfs_backend_config_load "$tmpdir" ubuntu mmdebstrap
check "saved package includes round-trip" equals "$ROOTFS_BACKEND_INCLUDE" "ca-certificates curl"
check "saved package excludes round-trip" equals "$ROOTFS_BACKEND_EXCLUDE" documentation
check "saved mmdebstrap mode round-trips" equals "$ROOTFS_MMDEBSTRAP_MODE" unshare

ROOTFS_MULTISTRAP_CLEANUP=yes
ROOTFS_MULTISTRAP_MARKAUTO=yes
ROOTFS_MULTISTRAP_IMPORTANT=no
export ROOTFS_MULTISTRAP_CLEANUP ROOTFS_MULTISTRAP_MARKAUTO ROOTFS_MULTISTRAP_IMPORTANT
multistrap_conf="$tmpdir/multistrap.conf"
rootfs_multistrap_config_write "$multistrap_conf" arm64 /opt/rootfs/test \
    https://deb.debian.org/debian trixie "main,contrib,non-free-firmware" \
    "ca-certificates curl" debian-archive-keyring
check "multistrap config includes selected components" contains "$multistrap_conf" \
    "source=https://deb.debian.org/debian main contrib non-free-firmware"
check "multistrap config includes selected architecture" contains "$multistrap_conf" "arch=arm64"
check "multistrap config includes selected packages" contains "$multistrap_conf" "packages=ca-certificates curl"

# --- config menu radios must reflect the value actually in effect -----------
# They used to hard-code the first option "on", so opening the menu and
# pressing ENTER silently discarded rootfs_backend_auto_optimize's choice.
# rootfs.sh's logging helpers live in core/config.sh, which this test does not
# source; stub them the way the other test files do.
log() { :; }; warn() { :; }; LOGFILE=/dev/null
rootfs_backend_auto_optimize ubuntu mmdebstrap
check "Ubuntu+mmdebstrap is auto-tuned to the apt variant" \
    equals "$ROOTFS_BACKEND_VARIANT" apt
check "the tuned variant is the preselected radio entry" \
    equals "$(_rootfs_radio_state "$ROOTFS_BACKEND_VARIANT" apt)" on
check "a non-current variant is not preselected" \
    equals "$(_rootfs_radio_state "$ROOTFS_BACKEND_VARIANT" minbase)" off

# --- archive helpers --------------------------------------------------------
check "gz never reports a missing archive tool" \
    equals "$(rootfs_archive_missing_tool gz)" ""
check "an unknown archive format is rejected instead of silently succeeding" \
    archive_format_rejected

# --- builds must not report success/failure from a trailing test ------------
check "build_gentoo ends with an explicit return" \
    tail_returns_explicitly build_gentoo
check "build_arch ends with an explicit return" \
    tail_returns_explicitly build_arch

###############################################################################
# Chroot workbench
###############################################################################
wb_root="$tmpdir/wb"
mkdir -p "$wb_root"/{bin,etc,proc,sys,dev,root,var/log}
: > "$wb_root/bin/sh"; chmod +x "$wb_root/bin/sh"

# Engines: every advertised engine must be classified, and the argv builder
# must emit one argument per line for each of them.
engine_argv_starts_with() { # <engine> <expected first word>
    local first
    first=$(rootfs_wb_engine_argv "$wb_root" "$1" /bin/true | head -n1)
    [ "$first" = "$2" ]
}
engine_argv_ends_with_command() { # <engine>
    local last
    last=$(rootfs_wb_engine_argv "$wb_root" "$1" /bin/true | tail -n1)
    [ "$last" = /bin/true ]
}
check "chroot argv starts with chroot"   engine_argv_starts_with chroot chroot
check "proot argv starts with proot"     engine_argv_starts_with proot proot
check "nspawn argv starts with nspawn"   engine_argv_starts_with nspawn systemd-nspawn
check "unshare argv starts with unshare" engine_argv_starts_with unshare unshare
for _e in chroot proot nspawn unshare; do
    check "$_e argv ends with the command" engine_argv_ends_with_command "$_e"
done
check "an unknown engine is rejected" no_engine_argv notanengine
check "proot is the rootless engine"  proot_is_rootless
check "chroot requires root"          rootfs_wb_engine_needs_root chroot

# Only chroot needs kernel mounts; mounting for proot/nspawn/unshare would
# leave real host mounts inside a tree those engines think they own.
check "chroot uses kernel mounts"     rootfs_wb_engine_uses_kernel_mounts chroot
check "proot does not use kernel mounts"   not_kernel_mounts proot
check "nspawn does not use kernel mounts"  not_kernel_mounts nspawn
check "unshare does not use kernel mounts" not_kernel_mounts unshare

# Bind validation must reject anything that could mount over the host.
check "a valid bind is accepted"        rootfs_wb_bind_valid /tmp /mnt/t
check "a relative source is rejected"   bind_rejected tmp /mnt/t
check "a relative target is rejected"   bind_rejected /tmp mnt/t
check "a traversing target is rejected" bind_rejected /tmp /mnt/../../etc
check "a missing source is rejected"    bind_rejected /nonexistent-systui /mnt/t

# Binds round-trip through the rootfs's own config file.
rootfs_chroot_option_set "$wb_root" BINDS "/tmp>/mnt/a /var>/mnt/b"
check "binds round-trip from config"  equals "$(rootfs_wb_binds_get "$wb_root" | tr '\n' ',')" "/tmp>/mnt/a,/var>/mnt/b,"
check "binds convert to proot syntax" equals "$(rootfs_wb_binds_as_proot "$wb_root" | tr '\n' ',')" "/tmp:/mnt/a,/var:/mnt/b,"

# An unmounted tree reports zero live mounts and is therefore safe to pack.
check "an unmounted tree reports no mounts" equals "$(rootfs_wb_mount_count "$wb_root")" 0

# Packing honours excludes, which is what keeps caches out of shipped images.
check "tar excludes are applied" pack_excludes_are_applied

# --- Distro managers are not bootstrap backends -----------------------------
# They own their rootfs store and accept no target/mirror/release, so putting
# them in the catalogue would mean silently ignoring four wizard steps.
check "proot-distro is not a backend"  unsupported debian proot-distro
check "chroot-distro is not a backend" unsupported debian chroot-distro
check "proot-distro must not run as root" dm_is_rootless proot-distro
check "distrobox must not run as root"    dm_is_rootless distrobox
check "chroot-distro runs as root"        rootfs_dm_runs_as_root chroot-distro
check "distrobox exposes no plain tree"   dm_has_no_store distrobox

# --- Distro manager distribution parsing ------------------------------------
# Each tool reports its catalogue differently; parse real output shapes rather
# than a hardcoded list that would drift out of date with the tool.
dm_fixture_proot() {
    cat <<'FIX'
Alpine Linux (edge)

  Alias: alpine
  Installed: no

Debian (bookworm)

  Alias: debian
  Installed: no
FIX
}
dm_fixture_chroot() {
    cat <<'FIX'
List of available linux distributions:

ubuntu
debian
alpine
FIX
}
parses_proot_aliases() {
    rootfs_dm_capture() { dm_fixture_proot; }
    [ "$(rootfs_dm_parse_distros proot-distro | cut -d'|' -f1 | tr '\n' ',')" = "alpine,debian," ]
}
keeps_proot_descriptions() {
    rootfs_dm_capture() { dm_fixture_proot; }
    rootfs_dm_parse_distros proot-distro | grep -q '^alpine|Alpine Linux (edge)$'
}
parses_chroot_aliases() {
    rootfs_dm_capture() { dm_fixture_chroot; }
    [ "$(rootfs_dm_parse_distros chroot-distro | cut -d'|' -f1 | tr '\n' ',')" = "alpine,debian,ubuntu," ]
}
drops_chroot_header() {
    rootfs_dm_capture() { dm_fixture_chroot; }
    ! rootfs_dm_parse_distros chroot-distro | grep -qi 'list of'
}
check "proot-distro Alias: lines are parsed"   parses_proot_aliases
check "proot-distro keeps distro descriptions" keeps_proot_descriptions
check "chroot-distro identifiers are parsed"   parses_chroot_aliases
check "chroot-distro header is not an alias"   drops_chroot_header

# --- Manager installation ----------------------------------------------------
PM=apt
has_package()   { [ -n "$(rootfs_dm_package "$1")" ]; }
no_package()    { [ -z "$(rootfs_dm_package "$1")" ]; }
check "proot-distro has an apt package"     has_package proot-distro
check "distrobox has a package"             has_package distrobox
check "schroot has a package"               has_package schroot
# chroot-distro is a Magisk module, so there is deliberately no package.
check "chroot-distro has no package"        no_package chroot-distro
check "every manager has an install hint"   all_managers_have_hints

# --- Store locations ---------------------------------------------------------
check "chroot-distro store is documented"   chroot_store_is_known
check "container-based managers expose no tree" dm_has_no_store distrobox
check "toolbx exposes no plain tree"        dm_has_no_store toolbx

printf '1..%d\n' "$checks"
[ "$failures" -eq 0 ]
