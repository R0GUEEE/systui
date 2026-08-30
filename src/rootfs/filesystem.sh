#!/bin/bash
# Rootfs filesystem, archive, report, and download primitives.
# This module is authoritative for migrated callers and intentionally exports no
# Bash function bodies.

systui_rootfs_report_file() {
    printf '%s/rootfs-report\n' "${SYSTUI_TMP:?private workspace is not initialized}"
}

systui_rootfs_rm_tree() { # <path>
    local path="${1:-}"
    [ -n "$path" ] || return 64
    [ "$path" != / ] || return 64
    if rm --one-file-system -rf -- /nonexistent-systui-probe 2>/dev/null; then
        rm -rf --one-file-system -- "$path"
    else
        rm -rf -- "$path"
    fi
}

systui_rootfs_du_summary() { # <path>
    local path="${1:-}"
    [ -n "$path" ] || return 64
    if du -xh --max-depth=1 "$path" >/dev/null 2>&1; then
        du -xh --max-depth=1 "$path" 2>/dev/null
    elif du -xh -d 1 "$path" >/dev/null 2>&1; then
        du -xh -d 1 "$path" 2>/dev/null
    else
        du -sh "$path" 2>/dev/null
    fi | { sort -hr 2>/dev/null || sort -r; }
}

systui_rootfs_tar_supports() { # <option>
    tar "$1" --help >/dev/null 2>&1 || tar --help 2>&1 | grep -q -- "$1"
}

systui_rootfs_tar_create() { # <gz|xz|zst> <src> <out> [tar args...]
    local fmt="$1" src="$2" out="$3"; shift 3
    local -a flags=("$@")

    [ -d "$src" ] || return 66
    [ -n "$out" ] || return 64
    systui_rootfs_tar_supports --numeric-owner && flags+=(--numeric-owner)
    if systui_rootfs_tar_supports --sparse; then
        flags+=(--sparse)
    elif tar -S /dev/null >/dev/null 2>&1; then
        flags+=(-S)
    fi

    case "$fmt" in
        gz) tar -C "$src" "${flags[@]}" -czf "$out" . ;;
        xz)
            if systui_rootfs_tar_supports -J; then
                tar -C "$src" "${flags[@]}" -cJf "$out" .
            else
                command -v xz >/dev/null 2>&1 || return 127
                ( set -o pipefail; tar -C "$src" "${flags[@]}" -cf - . | xz -zc > "$out" )
            fi
            ;;
        zst)
            if systui_rootfs_tar_supports --zstd; then
                tar --zstd -C "$src" "${flags[@]}" -cf "$out" .
            else
                command -v zstd >/dev/null 2>&1 || return 127
                ( set -o pipefail; tar -C "$src" "${flags[@]}" -cf - . | zstd -c > "$out" )
            fi
            ;;
        *) return 2 ;;
    esac
}

systui_rootfs_archive_missing_tool() { # <gz|xz|zst>
    case "$1" in
        gz) return 0 ;;
        xz) systui_rootfs_tar_supports -J || command -v xz >/dev/null 2>&1 || printf 'xz\n' ;;
        zst) systui_rootfs_tar_supports --zstd || command -v zstd >/dev/null 2>&1 || printf 'zstd\n' ;;
        *) return 2 ;;
    esac
}

systui_rootfs_fetch_text() { # <url>
    local url="${1:-}"
    case "$url" in https://*|http://*) ;; *) return 64 ;; esac
    if command -v curl >/dev/null 2>&1; then
        curl -4 -LfsS --connect-timeout 10 --max-time 120 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -4 -qO- -T 120 "$url"
    else
        return 127
    fi
}

systui_rootfs_fetch_file() { # <url> <destination>
    local url="${1:-}" dest="${2:-}"
    case "$url" in https://*|http://*) ;; *) return 64 ;; esac
    [ -n "$dest" ] || return 64
    if command -v curl >/dev/null 2>&1; then
        curl -4 -fL --retry 3 --connect-timeout 10 --max-time 600 -o "$dest" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -4 -q -T 600 -O "$dest" "$url"
    else
        return 127
    fi
}

# Compatibility names used by the existing rootfs feature stack. These wrappers
# are deliberately tiny so old callers can migrate incrementally.
rootfs_report_file() { systui_rootfs_report_file "$@"; }
rootfs_rm_tree() { systui_rootfs_rm_tree "$@"; }
rootfs_du_summary() { systui_rootfs_du_summary "$@"; }
rootfs_tar_supports() { systui_rootfs_tar_supports "$@"; }
rootfs_tar_create() { systui_rootfs_tar_create "$@"; }
rootfs_archive_missing_tool() { systui_rootfs_archive_missing_tool "$@"; }
rootfs_fetch_text() { systui_rootfs_fetch_text "$@"; }
rootfs_fetch_file() { systui_rootfs_fetch_file "$@"; }
