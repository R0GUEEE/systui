#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
F="$ROOT/src/features/77-host-native-install-default.sh"
LOAD="$ROOT/src/features/.load-order"

[ -r "$F" ]
bash -n "$F"
grep -Fq '77-host-native-install-default.sh' "$LOAD"

a=$(grep -nFx '76-sysconfig-multi-init-services.sh' "$LOAD" | cut -d: -f1)
b=$(grep -nFx '77-host-native-install-default.sh' "$LOAD" | cut -d: -f1)
c=$(grep -nFx '90-install-guard-final.sh' "$LOAD" | cut -d: -f1)
[ "$a" -lt "$b" ] && [ "$b" -lt "$c" ]

# Load only the policy with small stubs so package resolution can be tested
# deterministically without touching the runner's package manager.
log() { :; }
declare -gA PKG_MAP=(
    [fzf]='fzf fzf fzf fzf'
    [neovim]='neovim neovim neovim neovim'
)
systui_detect_pm() { :; }
. "$F"

PM=apk
[ "$(systui_native_pkg_name go)" = go ]
[ "$(systui_native_pkg_name node)" = nodejs ]
[ "$(systui_native_pkg_name pip)" = py3-pip ]
[ "$(systui_native_pkg_name fzf)" = fzf ]

PM=apt
[ "$(systui_native_pkg_name go)" = golang-go ]
[ "$(systui_native_pkg_name docker)" = docker.io ]
[ "$(systui_native_pkg_name pip)" = python3-pip ]

PM=pacman
[ "$(systui_native_pkg_name node)" = nodejs ]
[ "$(systui_native_pkg_name neovim)" = neovim ]

PM=dnf
[ "$(systui_native_pkg_name go)" = golang ]
[ "$(systui_native_pkg_name node)" = nodejs ]

PM=xbps
[ "$(systui_native_pkg_name node)" = nodejs ]
[ "$(systui_native_pkg_name fzf)" = fzf ]

PM=apk
if systui_native_pkg_name brew >/dev/null 2>&1; then
    echo 'brew must not claim a dependable native Alpine package' >&2
    exit 1
fi

# Native success prevents the specialized fallback.
called=''
systui_native_install() { called=native; return 0; }
fallback_test() { called=fallback; return 0; }
systui_install_native_first fzf fallback_test
[ "$called" = native ]

# Native failure reaches the existing specialized fallback.
called=''
systui_native_install() { called=native; return 1; }
fallback_test() { called=fallback; return 0; }
systui_install_native_first fzf fallback_test
[ "$called" = fallback ]

# Representative specialized menus are wrapped by the policy.
grep -Fq 'systui_wrap_native_installer menu_go_install go' "$F"
grep -Fq 'systui_wrap_native_installer menu_docker_install docker' "$F"
grep -Fq 'systui_wrap_native_installer menu_neovim_install neovim' "$F"
grep -Fq 'systui_wrap_native_installer menu_nushell_install nushell' "$F"

printf 'ok - installs prefer the host-native package manager with specialized fallbacks\n'
