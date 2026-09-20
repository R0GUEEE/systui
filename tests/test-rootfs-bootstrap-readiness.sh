#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FEATURE="$ROOT/src/features/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-rootfs-bootstrap-recovery.sh"

# Source only the bootstrap predicates; the feature file is safe to source in
# isolation because its late wrappers are guarded by declare -F checks.
# shellcheck source=/dev/null
source "$FEATURE"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

mkbase() {
    local t="$1"
    mkdir -p "$t/bin" "$t/usr/bin" "$t/usr/lib/aarch64-linux-gnu" "$t/var/lib/dpkg"
    : > "$t/bin/sh"
    : > "$t/usr/bin/dpkg"
    : > "$t/usr/bin/apt-get"
    chmod +x "$t/bin/sh" "$t/usr/bin/dpkg" "$t/usr/bin/apt-get"
}

# Missing apt-get must still be considered an incomplete bootstrap.
t="$tmp/missing-apt"
mkbase "$t"
rm -f "$t/usr/bin/apt-get"
: > "$t/usr/lib/aarch64-linux-gnu/libc.so.6"
rootfs_deb_base_incomplete "$t" || {
    echo "FAIL: missing apt-get was not detected" >&2
    exit 1
}

# A physically present libc runtime is sufficient to permit dpkg/APT repair,
# even if dpkg status is empty or libc6 is only unpacked.
t="$tmp/unpacked-libc"
mkbase "$t"
: > "$t/usr/lib/aarch64-linux-gnu/libc.so.6"
cat > "$t/var/lib/dpkg/status" <<'EOF'
Package: libc6
Status: install ok unpacked
Architecture: arm64
EOF
if rootfs_deb_base_incomplete "$t"; then
    echo "FAIL: unpacked libc6 with runtime present was treated as missing" >&2
    exit 1
fi

# A dpkg record alone is not enough when the actual runtime vanished.
t="$tmp/missing-libc-files"
mkbase "$t"
cat > "$t/var/lib/dpkg/status" <<'EOF'
Package: libc6
Status: install ok installed
Architecture: arm64
EOF
rootfs_deb_base_incomplete "$t" || {
    echo "FAIL: missing libc runtime files were not detected" >&2
    exit 1
}

echo "rootfs bootstrap readiness regression tests: PASS"
