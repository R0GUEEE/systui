#!/bin/bash
# Data-backed package-map overlay. common.sh keeps the historical built-in map
# as a compatibility fallback while mappings migrate to share/packages.tsv.

systui_package_map_load() {
    local file="$SYSTUI_LIBDIR/share/packages.tsv" canonical alpine arch fedora void extra
    [ -r "$file" ] || return 0
    declare -p PKG_MAP >/dev/null 2>&1 || return 0

    while IFS=$'\t' read -r canonical alpine arch fedora void extra || [ -n "${canonical:-}" ]; do
        case "${canonical:-}" in ''|'#'*) continue;; esac
        [ -z "${extra:-}" ] || {
            declare -F warn >/dev/null 2>&1 && warn "package map: extra columns ignored for $canonical"
        }
        [ -n "${alpine:-}" ] && [ -n "${arch:-}" ] && [ -n "${fedora:-}" ] && [ -n "${void:-}" ] || {
            declare -F warn >/dev/null 2>&1 && warn "package map: incomplete row skipped for $canonical"
            continue
        }
        PKG_MAP["$canonical"]="$alpine $arch $fedora $void"
    done < "$file"
}

systui_package_map_load
export -n -f systui_package_map_load 2>/dev/null || true
