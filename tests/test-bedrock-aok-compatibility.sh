#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

fail=0
check() {
    local name="$1"; shift
    if "$@"; then printf 'ok - %s\n' "$name"; else printf 'not ok - %s\n' "$name"; fail=1; fi
}

# Provide the install function that the phase hook preserves.
bedrock_aok_install() { printf 'base\n' >> "$tmp/order"; }
warn() { :; }
log() { :; }
export SYSTUI_TMP="$tmp/work"
mkdir -p "$SYSTUI_TMP"

# shellcheck source=../src/features/64-bedrock-aok-compatibility.sh
. "$ROOT/src/features/64-bedrock-aok-compatibility.sh"

check "fallback for bind mounts uses crossfs-compatible symlinks" \
    test "$(bedrock_aok_compat_fallback bind_mount)" = symlink-crossfs
check "fallback for mount namespaces is explicit" \
    test "$(bedrock_aok_compat_fallback mount_ns)" = shared-host-mounts
check "fallback for seccomp never claims filtering" \
    test "$(bedrock_aok_compat_fallback seccomp)" = no-seccomp-filter

# Force an incapable host and verify state reporting does not fake native
# support for namespace/bind/seccomp features.
bedrock_aok_compat_probe_bind_mount() { return 1; }
bedrock_aok_compat_probe_namespace() { return 1; }
bedrock_aok_compat_probe_seccomp() { return 1; }
bedrock_aok_compat_probe_cgroup() { return 1; }
check "missing bind mount reports fallback" test "$(bedrock_aok_compat_capability_state bind_mount)" = fallback
check "missing user namespace reports fallback" test "$(bedrock_aok_compat_capability_state user_ns)" = fallback
check "missing pid namespace reports fallback" test "$(bedrock_aok_compat_capability_state pid_ns)" = fallback
check "missing net namespace reports fallback" test "$(bedrock_aok_compat_capability_state net_ns)" = fallback
check "missing ipc namespace reports fallback" test "$(bedrock_aok_compat_capability_state ipc_ns)" = fallback
check "missing cgroup namespace reports fallback" test "$(bedrock_aok_compat_capability_state cgroup_ns)" = fallback
check "missing seccomp reports unsupported" test "$(bedrock_aok_compat_capability_state seccomp)" = unsupported

profile="$tmp/bedrock-capabilities.conf"
SYSTUI_ENVIRONMENT=ish bedrock_aok_compat_write_config "$profile"
check "profile records schema" grep -qx 'schema=1' "$profile"
check "profile records runtime" grep -qx 'runtime=ish' "$profile"
check "profile records bind fallback state" grep -qx 'bind_mount=fallback' "$profile"
check "profile records bind fallback mode" grep -qx 'bind_mount_fallback=symlink-crossfs' "$profile"
check "profile records seccomp unsupported" grep -qx 'seccomp=unsupported' "$profile"

# Verify installation ordering: compatibility preparation must happen before the
# preserved installer and finalization after it.
: > "$tmp/order"
bedrock_aok_compat_prepare() { printf 'prepare\n' >> "$tmp/order"; }
bedrock_aok_compat_finalize() { printf 'finalize\n' >> "$tmp/order"; }
bedrock_aok_install
check "install hook order is prepare/base/finalize" \
    bash -c '[ "$(cat "$1")" = "prepare
base
finalize" ]' _ "$tmp/order"

check "compatibility phase passes Bash syntax" bash -n "$ROOT/src/features/64-bedrock-aok-compatibility.sh"

exit "$fail"
