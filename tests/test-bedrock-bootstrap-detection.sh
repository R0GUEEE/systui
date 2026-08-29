#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { printf 'ok: %s\n' "$1"; pass=$((pass + 1)); }
not_ok() { printf 'not ok: %s\n' "$1" >&2; fail=$((fail + 1)); }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else not_ok "$name"; fi; }

# Stand in for rootfs.sh's native host detector. The Bedrock layer must retain
# this result before checking any stratum.
rootfs_bs_installed() {
    [ "$1" = native-only ]
}

rootfs_bs_command() {
    case "$1" in
        arch-install-scripts) printf 'pacstrap\n' ;;
        systemd-container)    printf 'systemd-nspawn\n' ;;
        xbps-tools)           printf 'xbps-install\n' ;;
        xz-utils)             printf 'xz\n' ;;
        binfmt-support)       printf 'update-binfmts\n' ;;
        *)                    printf '%s\n' "$1" ;;
    esac
}

export SYSTUI_BEDROCK_STRATA_ROOT="$TMP/strata"
mkdir -p \
    "$SYSTUI_BEDROCK_STRATA_ROOT/debian/usr/bin" \
    "$SYSTUI_BEDROCK_STRATA_ROOT/arch/usr/bin" \
    "$SYSTUI_BEDROCK_STRATA_ROOT/void/usr/bin" \
    "$SYSTUI_BEDROCK_STRATA_ROOT/systemd/usr/bin" \
    "$SYSTUI_BEDROCK_STRATA_ROOT/qemu/usr/bin" \
    "$SYSTUI_BEDROCK_STRATA_ROOT/tools/usr/sbin"

for f in \
    "$SYSTUI_BEDROCK_STRATA_ROOT/debian/usr/bin/debootstrap" \
    "$SYSTUI_BEDROCK_STRATA_ROOT/debian/usr/bin/mmdebstrap" \
    "$SYSTUI_BEDROCK_STRATA_ROOT/arch/usr/bin/pacstrap" \
    "$SYSTUI_BEDROCK_STRATA_ROOT/void/usr/bin/xbps-install" \
    "$SYSTUI_BEDROCK_STRATA_ROOT/systemd/usr/bin/systemd-nspawn" \
    "$SYSTUI_BEDROCK_STRATA_ROOT/qemu/usr/bin/qemu-aarch64-static" \
    "$SYSTUI_BEDROCK_STRATA_ROOT/tools/usr/sbin/update-binfmts"; do
    : > "$f"
    chmod +x "$f"
done

# shellcheck source=/dev/null
source "$ROOT/src/features/zzzzzzzzzzz-bedrock-bootstrap-detection.sh"

check "native bootstrap detection is preserved" rootfs_bs_installed native-only
check "debootstrap is found in a Debian stratum" rootfs_bs_installed debootstrap
check "mmdebstrap is found in a Debian stratum" rootfs_bs_installed mmdebstrap
check "arch-install-scripts resolves to pacstrap in an Arch stratum" rootfs_bs_installed arch-install-scripts
check "xbps-tools resolves to xbps-install in a Void stratum" rootfs_bs_installed xbps-tools
check "systemd-container resolves to systemd-nspawn in a stratum" rootfs_bs_installed systemd-container
check "binfmt-support resolves to update-binfmts in sbin" rootfs_bs_installed binfmt-support
check "qemu-user-static detects per-architecture static QEMU binaries" rootfs_bs_installed qemu-user-static

if ! rootfs_bs_installed definitely-not-installed; then
    ok "missing bootstrap remains not installed"
else
    not_ok "missing bootstrap remains not installed"
fi

locations=$(bedrock_bootstrap_locations debootstrap)
if [ "$locations" = debian ]; then
    ok "bootstrap location reports owning stratum"
else
    not_ok "bootstrap location reports owning stratum"
fi

if grep -Fxq 'zzzzzzzzzzz-bedrock-bootstrap-detection.sh' "$ROOT/src/features/.load-order"; then
    ok "Bedrock bootstrap scanner is in explicit feature load order"
else
    not_ok "Bedrock bootstrap scanner is in explicit feature load order"
fi

printf '\nBedrock bootstrap detection: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
