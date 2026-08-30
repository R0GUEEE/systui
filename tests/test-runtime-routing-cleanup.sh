#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
F="$ROOT/src/features/93-runtime-routing-cleanup.sh"
ORDER="$ROOT/src/features/.load-order"

[ -f "$F" ]
bash -n "$F"

grep -Fq 'systui_bedrock_cross_pkg_alias()' "$F"
grep -Fq 'tigervnc-standalone-server) canonical=tigervnc' "$F"
grep -Fq 'python3-pip|python-pip|py3-pip) canonical=pip' "$F"
grep -Fq 'menu_services()' "$F"
if grep -Fq 'current "Manage current provider' "$F"; then
    echo 'final Services menu must not duplicate the active provider' >&2
    exit 1
fi

p92=$(grep -n '^92-runtime-menu-cleanup.sh$' "$ORDER" | cut -d: -f1)
p93=$(grep -n '^93-runtime-routing-cleanup.sh$' "$ORDER" | cut -d: -f1)
[ -n "$p92" ] && [ -n "$p93" ] && [ "$p92" -lt "$p93" ]

bash -c '
systui_bedrock_pkg_name() {
  case "$1:$2" in
    apk:pip) echo py3-pip ;;
    apk:go) echo go ;;
    apk:tigervnc) echo tigervnc ;;
    *) echo "$2" ;;
  esac
}
source "$1"
[ "$(systui_bedrock_cross_pkg_alias apk python3-pip)" = py3-pip ]
[ "$(systui_bedrock_cross_pkg_alias apk golang-go)" = go ]
[ "$(systui_bedrock_cross_pkg_alias apk tigervnc-standalone-server)" = tigervnc ]
[ "$(systui_bedrock_cross_pkg_alias apk arbitrary-package)" = arbitrary-package ]
' _ "$F"

echo 'ok: final runtime routing cleanup'
