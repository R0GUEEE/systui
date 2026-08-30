#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
F="$ROOT/src/features/94-universal-software-catalogue.sh"
ORDER="$ROOT/src/features/.load-order"

[ -f "$F" ]
bash -n "$F"

grep -q '^systui_catalogue_pm()' "$F"
grep -q '^systui_catalogue_map_one()' "$F"
grep -q '^local_pkg_map()' "$F"
grep -q '^app_native_name()' "$F"
grep -q '^pkg_show_info()' "$F"
grep -q '^pkg_list_files()' "$F"
grep -q '^pkg_reinstall()' "$F"
grep -q '^pkg_catalogue()' "$F"

p93=$(grep -n '^93-runtime-routing-cleanup\.sh$' "$ORDER" | cut -d: -f1)
p94=$(grep -n '^94-universal-software-catalogue\.sh$' "$ORDER" | cut -d: -f1)
[ -n "$p93" ] && [ -n "$p94" ] && [ "$p93" -lt "$p94" ]

bash -c '
set -euo pipefail

declare -A APT_CANDIDATES=([firefox]="firefox firefox-esr")
map_packages() {
    local family="$1" key="$2"
    case "$family:$key" in
        alpine:python3-pip) echo py3-pip ;;
        alpine:firefox) echo firefox ;;
        alpine:unsupported) echo SKIP ;;
        arch:python3-pip) echo python-pip ;;
        arch:firefox) echo firefox ;;
        fedora:python3-pip) echo python3-pip ;;
        fedora:firefox) echo firefox ;;
        void:python3-pip) echo python3-pip ;;
        void:firefox) echo firefox ;;
        *) echo "$key" ;;
    esac
}
is_pkg_installed() { return 1; }
tui_msg() { :; }
tui_menu() { return 1; }
source "$1"

[ "$(systui_catalogue_map_one apt go)" = golang-go ]
[ "$(systui_catalogue_map_one apk python3-pip)" = py3-pip ]
[ "$(systui_catalogue_map_one pacman python3-pip)" = python-pip ]
[ "$(systui_catalogue_map_one dnf python3-pip)" = python3-pip ]
[ "$(systui_catalogue_map_one yum firefox)" = firefox ]
[ "$(systui_catalogue_map_one xbps python3-pip)" = python3-pip ]
[ "$(systui_catalogue_map_one zypper openssh-server)" = openssh ]
[ "$(systui_catalogue_map_one zypper build-essential)" = patterns-devel-base-devel_basis ]
[ "$(systui_catalogue_map_one emerge openssh-server)" = net-misc/openssh ]
[ "$(systui_catalogue_map_one emerge python3-pip)" = dev-python/pip ]
[ "$(systui_catalogue_map_one unknown firefox)" = SKIP ]

PM=apk
[ "$(local_pkg_map firefox python3-pip unsupported)" = "firefox py3-pip" ]
PM=zypper
[ "$(app_native_name openssh-server)" = openssh ]
PM=emerge
[ "$(app_native_name docker.io)" = app-containers/docker ]
' _ "$F"

echo "ok: software catalogue resolves packages per native distro package manager"
