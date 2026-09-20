#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
FEATURE="$ROOT/src/features/110-zypper-full-package-functionality-final.sh"
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT

bash -n "$FEATURE"

mkdir -p "$tmp/bin"
cat > "$tmp/bin/zypper" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$tmp/bin/zypper"
PATH="$tmp/bin:$PATH"
export PATH SYSTUI_TMP="$tmp"

LOG="$tmp/commands"
: >"$LOG"
run_cmd() {
    printf '%s\n' "$*" >>"$LOG"
}
tui_msg() { :; }
tui_text() { :; }
tui_yesno() { return 0; }
tui_input() { printf '%s\n' ""; }
tui_capture_menu() { return 1; }

. "$FEATURE"

for fn in     menu_zypper_manager     systui_zypper_refresh systui_zypper_update systui_zypper_dist_upgrade     systui_zypper_install systui_zypper_remove systui_zypper_reinstall     systui_zypper_search systui_zypper_info systui_zypper_list_installed     systui_zypper_list_updates systui_zypper_verify systui_zypper_clean     systui_zypper_patches systui_zypper_patch_install systui_zypper_patterns     systui_zypper_locks_menu systui_zypper_repositories_menu
do
    declare -F "$fn" >/dev/null 2>&1 || {
        printf 'missing Zypper function: %s\n' "$fn" >&2
        exit 1
    }
done

systui_zypper_refresh
systui_zypper_update
systui_zypper_verify
systui_zypper_clean
systui_zypper_patch_install
systui_zypper_dist_upgrade

grep -Fq 'Zypper refresh zypper --non-interactive --gpg-auto-import-keys refresh' "$LOG"
grep -Fq 'Zypper update zypper --non-interactive update' "$LOG"
grep -Fq 'Zypper verify dependencies zypper --non-interactive verify' "$LOG"
grep -Fq 'Zypper clean caches zypper --non-interactive clean --all' "$LOG"
grep -Fq 'Install Zypper patches zypper --non-interactive patch' "$LOG"
grep -Fq 'Zypper distribution upgrade zypper --non-interactive dup' "$LOG"

for token in     'install --' 'remove --' 'install --force --' 'search -s --' 'info --'     'search --installed-only -s' 'list-updates' 'list-patches' 'patterns'     'addlock --' 'removelock --' 'cleanlocks' 'repos -d -u'     'addrepo --refresh' 'removerepo' 'modifyrepo --enable' 'modifyrepo --disable'
do
    grep -Fq "$token" "$FEATURE" || {
        printf 'missing Zypper operation: %s\n' "$token" >&2
        exit 1
    }
done

grep -Fxq '110-zypper-full-package-functionality-final.sh' "$ROOT/src/features/.load-order"

printf 'ok - full Zypper package functionality\n'
