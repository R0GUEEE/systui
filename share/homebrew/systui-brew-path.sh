#!/usr/bin/env bash
# systui — keep Homebrew formulae on the default PATH.
#
# Homebrew links every installed formula's executables into
# $BREW_PREFIX/bin (and sbin). Those directories only reach a shell through
# the profile snippets written by install-homebrew-root.sh, so a shell that
# was already open — or a non-login shell, or a command run by the systui TUI
# — never sees a formula installed a second ago.
#
# This utility mirrors those links into /usr/local/bin and /usr/local/sbin,
# directories every mainstream distribution already puts on PATH. No PATH
# edit and no new shell is needed: install a formula, run this, the command
# resolves immediately for root and for every user.
#
# Environment overrides (also used by the test suite):
#   SYSTUI_BREW_PREFIX           brew prefix     (default /home/linuxbrew/.linuxbrew)
#   SYSTUI_BREW_PATH_LINK_DIR    bin mirror dir  (default /usr/local/bin)
#   SYSTUI_BREW_PATH_SBIN_DIR    sbin mirror dir (default /usr/local/sbin)
#   SYSTUI_BREW_PATH_SHADOW=1    mirror names that already exist elsewhere on PATH

set -uo pipefail

PREFIX=${SYSTUI_BREW_PREFIX:-/home/linuxbrew/.linuxbrew}
LINK_DIR=${SYSTUI_BREW_PATH_LINK_DIR:-/usr/local/bin}
SBIN_LINK_DIR=${SYSTUI_BREW_PATH_SBIN_DIR:-/usr/local/sbin}
SHADOW=${SYSTUI_BREW_PATH_SHADOW:-0}

usage() {
    cat <<'EOF_USAGE'
systui-brew-path [--quiet|--verbose] [--status] [--remove]

  (default)   refresh the /usr/local mirrors from the Homebrew prefix
  --quiet     refresh, print nothing
  --verbose   refresh, report every skipped or removed entry
  --status    list the mirrors currently owned by systui, change nothing
  --remove    delete every mirror owned by systui (component uninstall)
EOF_USAGE
}

mode=refresh
while [ $# -gt 0 ]; do
    case "$1" in
        -q|--quiet)   mode=quiet ;;
        -v|--verbose) mode=verbose ;;
        --status)     mode=status ;;
        --remove)     mode=remove ;;
        -h|--help)    usage; exit 0 ;;
        *)            printf 'systui-brew-path: unknown option %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

say()     { [ "$mode" = quiet ] || printf '%s\n' "$*"; }
verbose() { [ "$mode" = verbose ] && printf '%s\n' "$*"; return 0; }

# Prints the prefix a link points into when that prefix is Homebrew's own.
owned_link() { # <link>
    local target
    [ -L "$1" ] || return 1
    target=$(readlink "$1" 2>/dev/null) || return 1
    case "$target" in
        "$PREFIX"/*) printf '%s\n' "$PREFIX" ;;
        *) return 1 ;;
    esac
}

# A command that already exists outside Homebrew keeps priority: mirroring
# brew's git/python3/curl over a distribution binary would silently change
# what every system and init script runs. SYSTUI_BREW_PATH_SHADOW=1 opts out.
shadowed_by_system() { # <name> <mirror-dir>
    local name="$1" mirror="$2" dir abs
    local IFS=:
    for dir in $PATH; do
        [ -n "$dir" ] || continue
        abs=$(cd -P "$dir" 2>/dev/null && pwd) || continue
        [ "$abs" = "$mirror" ] && continue
        case "$abs" in "$PREFIX"|"$PREFIX"/*) continue ;; esac
        [ -x "$abs/$name" ] && return 0
    done
    return 1
}

mirror_from() { # <src-dir> <mirror-dir> <created-ref> <skipped-ref> <updated-ref>
    local src="$1" dst="$2" path name dest
    local -n _created=$3 _skipped=$4 _updated=$5
    [ -d "$src" ] || return 0
    install -d -m 0755 "$dst" 2>/dev/null || { say "cannot write $dst (root required)"; return 1; }
    for path in "$src"/*; do
        [ -e "$path" ] || continue
        name=${path##*/}
        dest="$dst/$name"
        if [ -L "$dest" ]; then
            if owned_link "$dest" >/dev/null; then
                if ln -sfn "$path" "$dest" 2>/dev/null; then _updated=$((_updated + 1)); fi
            else
                verbose "skip $name (link owned by something else)"
            fi
        elif [ -e "$dest" ]; then
            verbose "skip $name (already present in $dst)"
        elif [ "$SHADOW" != 1 ] && shadowed_by_system "$name" "$dst"; then
            _skipped=$((_skipped + 1))
            verbose "skip $name (system command takes priority)"
        elif ln -s "$path" "$dest" 2>/dev/null; then
            _created=$((_created + 1))
            verbose "link $name -> $path"
        fi
    done
    return 0
}

prune_stale() { # <mirror-dir> <removed-ref>
    local dst="$1" link
    local -n _removed=$2
    [ -d "$dst" ] || return 0
    for link in "$dst"/*; do
        [ -L "$link" ] || continue
        owned_link "$link" >/dev/null || continue
        [ -e "$link" ] && continue
        if rm -f -- "$link" 2>/dev/null; then
            _removed=$((_removed + 1))
            verbose "removed dangling ${link##*/}"
        fi
    done
    return 0
}

if [ "$mode" = remove ]; then
    removed=0
    for dir in "$LINK_DIR" "$SBIN_LINK_DIR"; do
        [ -d "$dir" ] || continue
        for link in "$dir"/*; do
            [ -L "$link" ] || continue
            owned_link "$link" >/dev/null || continue
            if rm -f -- "$link"; then removed=$((removed + 1)); fi
        done
    done
    say "removed $removed Homebrew PATH mirror(s)"
    exit 0
fi

if [ "$mode" = status ]; then
    count=0
    for dir in "$LINK_DIR" "$SBIN_LINK_DIR"; do
        [ -d "$dir" ] || continue
        for link in "$dir"/*; do
            [ -L "$link" ] || continue
            owned_link "$link" >/dev/null || continue
            count=$((count + 1))
            printf '%s -> %s\n' "$link" "$(readlink "$link")"
        done
    done
    printf '%d Homebrew PATH mirror(s) under %s and %s\n' "$count" "$LINK_DIR" "$SBIN_LINK_DIR"
    exit 0
fi

created=0 skipped=0 updated=0 removed=0
mirror_from "$PREFIX/bin"  "$LINK_DIR"      created skipped updated
mirror_from "$PREFIX/sbin" "$SBIN_LINK_DIR" created skipped updated
prune_stale "$LINK_DIR"      removed
prune_stale "$SBIN_LINK_DIR" removed

say "Homebrew PATH mirrors: $created linked, $updated refreshed, $removed removed, $skipped left to the system"
exit 0
