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

# Loader decides constrained-runtime scrubbing once per manifest and batches the
# scrub (re-enumerating the whole function table after every feature costs
# seconds on constrained hosts). SYSTUI_SCRUB_INTERVAL=1 restores the historical
# after-every-feature behaviour.
mkdir -p "$tmp/lib/src/features"
for name in a b c d e f; do printf ':\n' > "$tmp/lib/src/features/$name.sh"; done
printf 'a.sh\nb.sh\nc.sh\nd.sh\ne.sh\nf.sh\n' > "$tmp/manifest"
cat > "$tmp/loader-check.sh" <<EOF
set -e
SYSTUI_LIBDIR="$tmp/lib"
SYSTUI_TMP="$tmp"
. "$LOADER"
systui_should_scrub_function_exports() { printf x >> "$tmp/scrub-decisions"; return 0; }
systui_unexport_all_functions() { printf x >> "$tmp/scrub-runs"; }

# Historical behaviour: one scrub per feature.
SYSTUI_SCRUB_INTERVAL=1 systui_load_features "$tmp/manifest"
[ "\$(wc -c < "$tmp/scrub-decisions")" -eq 1 ]
[ "\$(wc -c < "$tmp/scrub-runs")" -eq 6 ]

# Batched default: scrubs at each interval boundary plus a final one.
rm -f "$tmp/scrub-runs"
SYSTUI_SCRUB_INTERVAL=4 systui_load_features "$tmp/manifest"
[ "\$(wc -c < "$tmp/scrub-runs")" -eq 2 ]

# A shorter manifest still gets exactly one final scrub.
rm -f "$tmp/scrub-runs"
printf 'a.sh\nb.sh\n' > "$tmp/short-manifest"
SYSTUI_SCRUB_INTERVAL=4 systui_load_features "$tmp/short-manifest"
[ "\$(wc -c < "$tmp/scrub-runs")" -eq 1 ]

# An unusable interval falls back to the default instead of failing.
SYSTUI_SCRUB_INTERVAL=bogus systui_load_features "$tmp/short-manifest"
EOF
bash "$tmp/loader-check.sh"

# Feature bootstrap must define detection wrappers without eagerly running them.
! grep -Eq '^detect_(pm|init|distro)[[:space:]]+2>/dev/null' "$BOOTSTRAP"

# The loader's export scrub must not create a process-substitution Bash child.
! grep -Fq '< <(declare -Fx)' "$LOADER"

printf 'ok - startup probes and loader scrubbing are bounded\n'
