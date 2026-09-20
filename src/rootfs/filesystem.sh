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

###############################################################################
# IN-TREE PATH RESOLUTION AND SHELL INSPECTION
###############################################################################
#
# A rootfs regularly contains symlinks whose targets are absolute paths *inside
# the rootfs* ("/bin/sh -> /usr/bin/dash"). Testing that entry with the host's
# [ -x "$t/bin/sh" ] makes the kernel resolve the link against the HOST root,
# where /usr/bin/dash usually does not exist, so a perfectly healthy rootfs was
# reported as having no executable /bin/sh — and, because the same expression
# gates the "incomplete Debian bootstrap" predicate, it could even be sent to
# the bootstrap recovery.
#
# These helpers resolve link chains inside the tree, lexically, with no process
# spawned and without executing anything from it.

SYSTUI_ROOTFS_SHELL_CANDIDATES="/bin/dash /usr/bin/dash /bin/bash /usr/bin/bash /bin/ash /usr/bin/ash /bin/busybox /usr/bin/busybox /bin/ksh /usr/bin/ksh /bin/zsh /usr/bin/zsh /bin/mksh /usr/bin/mksh"

systui_rootfs_normpath() { # <path> -> lexically normalised absolute path
    local rest="${1:-}" out="" part
    case "$rest" in /*) ;; *) rest="/$rest" ;; esac
    while [ -n "$rest" ]; do
        rest="${rest#/}"
        part="${rest%%/*}"
        case "$part" in
            ''|.) ;;
            ..) out="${out%/*}" ;;
            *) out="$out/$part" ;;
        esac
        [ "$rest" = "$part" ] && break
        rest="${rest#"$part"}"
    done
    [ -n "$out" ] || out="/"
    printf '%s\n' "$out"
}

# Resolve <in-tree path> inside <target>, following links as the ROOTFS would.
# 0 + resolved in-tree path, 1 = target missing, 2 = symlink loop.
systui_rootfs_resolve_in_tree() { # <target> <in-tree path>
    local t="${1%/}" path="${2:-}" link depth=0
    [ -n "$t" ] || return 64
    [ -n "$path" ] || return 64
    path=$(systui_rootfs_normpath "$path")
    while [ "$depth" -lt 24 ]; do
        if [ -L "$t$path" ]; then
            link=$(readlink -- "$t$path" 2>/dev/null) || return 1
            case "$link" in
                /*) ;;
                *)  link="${path%/*}/$link" ;;
            esac
            path=$(systui_rootfs_normpath "$link")
            depth=$((depth + 1))
            continue
        fi
        [ -e "$t$path" ] || return 1
        printf '%s\n' "$path"
        return 0
    done
    return 2
}

# Does the link chain at <in-tree path> loop? Only consulted when the resolver
# reports a failure, so the common path stays cheap.
systui_rootfs_symlink_cycle() { # <target> <in-tree path>
    local t="${1%/}" path="${2:-}" seen="" link depth=0
    while [ "$depth" -lt 24 ]; do
        [ -L "$t$path" ] || return 1
        case " $seen " in *" $path "*) return 0 ;; esac
        seen="$seen $path"
        link=$(readlink -- "$t$path" 2>/dev/null) || return 1
        case "$link" in
            /*) path="$link" ;;
            *)  path="${path%/*}/$link" ;;
        esac
        path=$(systui_rootfs_normpath "$path")
        depth=$((depth + 1))
    done
    return 0
}

systui_rootfs_path_is_dir() { # <target> <in-tree path>
    local resolved
    resolved=$(systui_rootfs_resolve_in_tree "$1" "$2") || return 1
    [ -d "$1${resolved%/}" ]
}

# Does this file carry an execute bit? `test -x` asks the kernel for access and
# is unreliable in both directions here: running as root on iSH it can report
# success for a file with no execute bit at all (and then chroot fails with
# "Permission denied"). Read the mode bits instead, with GNU/BusyBox then BSD
# stat, falling back to `test -x` only when neither is available.
systui_rootfs_exec_mode_ok() { # <host path>
    local f="${1:-}" mode=""
    [ -f "$f" ] || return 1
    mode=$(stat -c '%a' -- "$f" 2>/dev/null) || mode=""
    case "$mode" in ''|*[!0-7]*) mode=$(stat -f '%Lp' -- "$f" 2>/dev/null) || mode="" ;; esac
    case "$mode" in ''|*[!0-7]*) mode="" ;; esac
    if [ -z "$mode" ]; then
        [ -x "$f" ] && return 0
        return 1
    fi
    case "$(printf '%o' "$(( 8#$mode & 8#111 ))")" in
        0) return 1 ;;
        *) return 0 ;;
    esac
}

systui_rootfs_shell_candidate() { # <target> -> in-tree path of a shell binary
    local t="${1%/}" c resolved
    for c in $SYSTUI_ROOTFS_SHELL_CANDIDATES; do
        resolved=$(systui_rootfs_resolve_in_tree "$t" "$c") || continue
        [ -f "$t$resolved" ] && { printf '%s\n' "$resolved"; return 0; }
    done
    return 1
}

# What state is this rootfs's /bin/sh entry in? Emits "status|path|detail" and
# returns 0 only for "ok". status is one of:
#   ok | missing | dangling | noexec | notfile | noshell | loop
systui_rootfs_shell_state() { # <target>
    local t="${1%/}" resolved link

    if ! systui_rootfs_path_is_dir "$t" /bin; then
        if [ -d "$t/usr/bin" ]; then
            printf 'missing|/bin|no /bin directory (a usrmerge link to usr/bin can be created)\n'
        else
            printf 'noshell|/bin|no /bin directory and no /usr/bin directory\n'
        fi
        return 1
    fi

    if [ ! -e "$t/bin/sh" ] && [ ! -L "$t/bin/sh" ]; then
        if resolved=$(systui_rootfs_shell_candidate "$t"); then
            printf 'missing|/bin/sh|no /bin/sh entry (%s is present in the rootfs)\n' "$resolved"
        else
            printf 'noshell|/bin/sh|no /bin/sh entry and no shell binary in the rootfs\n'
        fi
        return 1
    fi

    resolved=$(systui_rootfs_resolve_in_tree "$t" /bin/sh 2>/dev/null) || resolved=""
    if [ -z "$resolved" ]; then
        if systui_rootfs_symlink_cycle "$t" /bin/sh; then
            printf 'loop|/bin/sh|/bin/sh symlink chain does not terminate\n'
            return 1
        fi
        if [ -L "$t/bin/sh" ]; then
            link=$(readlink -- "$t/bin/sh" 2>/dev/null || true)
            printf 'dangling|/bin/sh|/bin/sh -> %s (target is missing inside the rootfs)\n' "$link"
        else
            printf 'dangling|/bin/sh|/bin/sh does not resolve\n'
        fi
        return 1
    fi

    if [ ! -f "$t$resolved" ]; then
        printf 'notfile|%s|/bin/sh resolves to %s, which is not a regular file\n' "$resolved" "$resolved"
        return 1
    fi
    if ! systui_rootfs_exec_mode_ok "$t$resolved"; then
        printf 'noexec|%s|/bin/sh resolves to %s, which has no execute bit\n' "$resolved" "$resolved"
        return 1
    fi

    printf 'ok|%s|\n' "$resolved"
    return 0
}

# Is there a usable /bin/sh in this tree? Never consults the host root.
systui_rootfs_shell_usable() { # <target>
    local state status
    state=$(systui_rootfs_shell_state "${1:-}") || true
    status="${state%%|*}"
    [ "$status" = ok ]
}

# Is <in-tree path> a file this tree can execute (links followed inside it)?
systui_rootfs_path_usable() { # <target> <in-tree path>
    local resolved
    resolved=$(systui_rootfs_resolve_in_tree "$1" "$2") || return 1
    systui_rootfs_exec_mode_ok "$1$resolved"
}

# Relative link target from <from-dir> to <to-file>, both in-tree paths.
systui_rootfs_relative_link() { # <from-dir> <to-file>
    local from="${1%/}" to="${2#/}" out="" part
    from="${from#/}"
    while [ -n "$from" ] && [ -n "$to" ]; do
        case "$to" in
            "$from"/*) to="${to#"$from"/}" ; from="" ;;
            *) break ;;
        esac
    done
    while [ -n "$from" ]; do
        part="${from%%/*}"
        [ -n "$part" ] && out="$out../"
        [ "$from" = "$part" ] && { from=""; break; }
        from="${from#"$part"}"
        from="${from#/}"
    done
    printf '%s\n' "${out}${to}"
}

# Compatibility wrappers for the feature stack.
rootfs_path_normalize() { systui_rootfs_normpath "$@"; }
rootfs_resolve_in_tree() { systui_rootfs_resolve_in_tree "$@"; }
rootfs_tree_path_usable() { systui_rootfs_path_usable "$@"; }
rootfs_tree_path_is_dir() { systui_rootfs_path_is_dir "$@"; }
rootfs_tree_shell_state() { systui_rootfs_shell_state "$@"; }
rootfs_tree_shell_usable() { systui_rootfs_shell_usable "$@"; }
rootfs_tree_shell_candidate() { systui_rootfs_shell_candidate "$@"; }
rootfs_relative_link() { systui_rootfs_relative_link "$@"; }
rootfs_symlink_cycle() { systui_rootfs_symlink_cycle "$@"; }
rootfs_tree_exec_ok() { systui_rootfs_exec_mode_ok "$@"; }
