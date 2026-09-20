#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PLATFORM="$ROOT/src/core/platform.sh"
LOADER="$ROOT/src/core/loader.sh"
BOOTSTRAP="$ROOT/src/features/00-platform-bootstrap.sh"
ISH="$ROOT/src/features/zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-ish-systemd-offline-manager.sh"

bash -n "$PLATFORM"
bash -n "$LOADER"
bash -n "$BOOTSTRAP"
bash -n "$ISH"

# iSH init detection must not contact systemctl/D-Bus before the first menu.
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
cat > "$tmp/check.sh" <<EOF
set -e
SYSTUI_TMP="$tmp"
SYSTUI_ISH_AOK=1
systemctl() { echo called > "$tmp/systemctl-called"; return 99; }
. "$PLATFORM"
systui_pid1_name() { printf 'systemd\n'; }
systui_detect_init
[ "\$SYSTUI_INIT_PROVIDER" = systemd ]
[ "\$INIT" = ish-systemd-compat ]
[ ! -e "$tmp/systemctl-called" ]
EOF
bash "$tmp/check.sh"

grep -Fq 'Startup detection must never contact the systemd manager' "$ISH"
! grep -A8 '^sysconfig_ish_systemd_offline()' "$ISH" | grep -q 'systemctl is-system-running'

printf 'ok - iSH startup init detection is nonblocking\n'


# iSH identity is static for one SystUI process. Repeated checks must not spawn
# repeated uname probes.
cat > "$tmp/cache-check.sh" <<EOF
set -e
calls="$tmp/uname-calls"
: > "\$calls"
uname() { printf 'probe\n' >> "\$calls"; printf 'Linux localhost 5.20.66-ish_aok aarch64 GNU/Linux\n'; }
unset SYSTUI_ISH_AOK SYSTUI_IS_ISH_CACHE
. "$PLATFORM"
systui_is_ish
systui_is_ish
[ "\$(wc -l < "\$calls")" -eq 1 ]
EOF
bash "$tmp/cache-check.sh"

# Loader decides constrained-runtime scrubbing once per manifest, while still
# performing the scrub after every loaded feature when enabled.
mkdir -p "$tmp/lib/src/features"
printf ':\n' > "$tmp/lib/src/features/a.sh"
printf ':\n' > "$tmp/lib/src/features/b.sh"
printf 'a.sh\nb.sh\n' > "$tmp/manifest"
cat > "$tmp/loader-check.sh" <<EOF
set -e
SYSTUI_LIBDIR="$tmp/lib"
SYSTUI_TMP="$tmp"
. "$LOADER"
systui_should_scrub_function_exports() { printf x >> "$tmp/scrub-decisions"; return 0; }
systui_unexport_all_functions() { printf x >> "$tmp/scrub-runs"; }
systui_load_features "$tmp/manifest"
[ "\$(wc -c < "$tmp/scrub-decisions")" -eq 1 ]
[ "\$(wc -c < "$tmp/scrub-runs")" -eq 2 ]
EOF
bash "$tmp/loader-check.sh"

# Feature bootstrap must define detection wrappers without eagerly running them.
! grep -Eq '^detect_(pm|init|distro)[[:space:]]+2>/dev/null' "$BOOTSTRAP"

# The loader's export scrub must not create a process-substitution Bash child.
! grep -Fq '< <(declare -Fx)' "$LOADER"

printf 'ok - startup probes and loader scrubbing are bounded\n'
