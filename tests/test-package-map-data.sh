#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
file="$ROOT/share/packages.tsv"
[ -s "$file" ]

declare -A seen=()
line_no=0
while IFS=$'\t' read -r canonical alpine arch fedora void extra || [ -n "${canonical:-}" ]; do
    line_no=$((line_no + 1))
    case "${canonical:-}" in ''|'#'*) continue;; esac
    [ -z "${extra:-}" ] || { echo "packages.tsv:$line_no: too many columns" >&2; exit 1; }
    for v in "$canonical" "$alpine" "$arch" "$fedora" "$void"; do
        [ -n "$v" ] || { echo "packages.tsv:$line_no: empty required field" >&2; exit 1; }
        case "$v" in *$'\n'*|*$'\r'*) echo "packages.tsv:$line_no: invalid newline" >&2; exit 1;; esac
    done
    [ -z "${seen[$canonical]:-}" ] || { echo "packages.tsv:$line_no: duplicate key: $canonical" >&2; exit 1; }
    seen[$canonical]=1
done < "$file"

[ "${#seen[@]}" -ge 20 ]
printf 'package map data checks passed (%s rows)\n' "${#seen[@]}"
