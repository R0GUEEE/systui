#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
F="$ROOT/src/features/78-bedrock-init-compatibility.sh"
LOAD="$ROOT/src/features/.load-order"

[ -r "$F" ]
bash -n "$F"

grep -Fq 'bedrock_aok_init_provider()' "$F"
grep -Fq 'bedrock_aok_init_sync_config()' "$F"
grep -Fq 'bedrock_aok_init_service_action()' "$F"
grep -Fq 'systemctl "$action" "$svc"' "$F"
grep -Fq 'rc-service "$bare" "$action"' "$F"
grep -Fq 'sv restart "$bare"' "$F"
grep -Fq 'service "$bare" "$action"' "$F"
grep -Fq 'update-rc.d "$bare" defaults' "$F"
grep -Fq 'rc-update add "$bare" default' "$F"

a=$(grep -nFx '77-host-native-install-default.sh' "$LOAD" | cut -d: -f1)
b=$(grep -nFx '78-bedrock-init-compatibility.sh' "$LOAD" | cut -d: -f1)
c=$(grep -nFx '90-install-guard-final.sh' "$LOAD" | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ]
[ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]

# Provider normalization checks do not need a real init daemon.
for pair in 'systemd systemd' 'ish-systemd-compat systemd' 'systemd-offline systemd' 'openrc openrc' 'runit runit' 'sysvinit sysvinit' 's6 s6'; do
    set -- $pair
    provider=$1 expected=$2
    got=$(bash -c '
        SYSTUI_INIT_PROVIDER=$1
        systui_detect_init(){ :; }
        . "$2"
        bedrock_aok_init_provider
    ' _ "$provider" "$F")
    [ "$got" = "$expected" ] || { echo "provider $provider -> $got, expected $expected" >&2; exit 1; }
done

# Verify config synchronization replaces only the [init] manager value.
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bedrock/etc" "$tmp/work"
cat > "$tmp/bedrock/etc/bedrock.conf" <<'EOF'
[miscellaneous]
color = true

[init]
manager = systemd

[cross]
enable = true
EOF
sed "s|cfg=\${BEDROCK_AOK_CONFIG:-/bedrock/etc/bedrock.conf}|cfg=\${BEDROCK_AOK_CONFIG:-$tmp/bedrock/etc/bedrock.conf}|" "$F" > "$tmp/phase.sh"
# The phase writes state only when /bedrock exists; config sync itself is what matters here.
bash -c '
    SYSTUI_TMP=$1
    SYSTUI_INIT_PROVIDER=openrc
    systui_detect_init(){ :; }
    log(){ :; }
    . "$2"
    BEDROCK_AOK_CONFIG=$3
    bedrock_aok_init_sync_config
    grep -qx "manager = openrc" "$3"
    grep -qx "enable = true" "$3"
' _ "$tmp/work" "$F" "$tmp/bedrock/etc/bedrock.conf"

printf 'ok - Bedrock init compatibility is provider-neutral across systemd/OpenRC/runit/SysVinit\n'
