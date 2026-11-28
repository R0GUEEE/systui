#!/bin/sh
# shellcheck shell=sh
# shellcheck disable=SC3043
# Verify that every command the dependency manifest promises really exists on
# this host. Used by CI inside one container per distribution, and usable on a
# real machine to explain why a menu reports its tool as unavailable.
#
#   tools/deps-verify.sh <apt|apk|pacman|dnf|xbps|emerge> [manifest]
#   tools/deps-verify.sh --list-packages <family>
#
# Exit status: 0 when every mandatory command is present, 1 otherwise.
# Advisory commands (after "|" in the manifest) are reported, never fatal.
set -u

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
MANIFEST="$SCRIPT_DIR/../share/systui-deps.tsv"
TAB=$(printf '\t')

usage() {
    cat <<'USAGE'
Usage: tools/deps-verify.sh <family> [manifest]
       tools/deps-verify.sh --list-packages <family>

family: apt | apk | pacman | dnf | zypper | xbps | emerge
USAGE
}

[ "$#" -ge 1 ] || { usage >&2; exit 2; }

LIST_ONLY=0
if [ "$1" = "--list-packages" ]; then
    LIST_ONLY=1
    shift
fi
[ "$#" -ge 1 ] || { usage >&2; exit 2; }

family=$1
[ "$#" -lt 2 ] || MANIFEST=$2

case "$family" in
    apt|apk|pacman|dnf|zypper|xbps|emerge) ;;
    *) printf 'unknown family: %s\n' "$family" >&2; usage >&2; exit 2 ;;
esac

[ -r "$MANIFEST" ] || { printf 'manifest not readable: %s\n' "$MANIFEST" >&2; exit 2; }

list_packages() { # <family>
    sed -n 's/^#.*//; /^[[:space:]]*$/d; p' "$MANIFEST" | while IFS=$TAB read -r canonical apt apk pacman dnf xbps emerge _tier cmds zypper; do
        case "$family" in
            apt) pkg=$apt ;; apk) pkg=$apk ;; pacman) pkg=$pacman ;;
            dnf) pkg=$dnf ;; xbps) pkg=$xbps ;; emerge) pkg=$emerge ;;
            zypper)
                pkg=${zypper:-}
                [ -n "$pkg" ] && [ "$pkg" != "-" ] || pkg=$dnf
                ;; 
        esac
        [ -n "${pkg:-}" ] || continue
        [ "$pkg" = "-" ] && continue
        old_ifs=$IFS
        IFS='+'
        for one in $pkg; do
            [ -n "$one" ] && printf '%s\n' "$one"
        done
        IFS=$old_ifs
    done
}

if [ "$LIST_ONLY" -eq 1 ]; then
    list_packages "$family"
    exit 0
fi

missing=""
advisory_missing=""
checked=0

check_group() { # <prefix> <comma-list>
    local prefix="$1" list="$2" cmd
    while [ -n "$list" ]; do
        case "$list" in
            *,*) cmd=${list%%,*}; list=${list#*,} ;;
            *)   cmd=$list; list='' ;;
        esac
        cmd=$(printf '%s' "$cmd" | tr -d ' ')
        [ -n "$cmd" ] || continue
        checked=$((checked + 1))
        if command -v "$cmd" >/dev/null 2>&1; then
            printf '  ok      %s\n' "$cmd"
        elif [ "$prefix" = advisory ]; then
            printf '  advisory %s (not provided)\n' "$cmd"
            advisory_missing="$advisory_missing $cmd"
        else
            printf '  MISSING %s\n' "$cmd"
            missing="$missing $cmd"
        fi
    done
}

while IFS=$TAB read -r canonical apt apk pacman dnf xbps emerge _tier cmds _zypper; do
    case "$canonical" in ''|'#'*) continue ;; esac
    case "${cmds:-}" in ''|'-') continue ;; esac
    mandatory=${cmds%%|*}
    advisory=''
    case "$cmds" in
        *'|'*) advisory=${cmds#*|} ;;
    esac
    printf '%s\n' "$canonical"
    check_group mandatory "$mandatory"
    [ -n "$advisory" ] && check_group advisory "$advisory"
done < "$MANIFEST"

printf '\n%s: %s commands checked, %s missing\n' \
    "$family" "$checked" "$(printf '%s' "$missing" | wc -w | tr -d ' ')"

if [ -n "$missing" ]; then
    printf 'MISSING:%s\n' "$missing" >&2
    exit 1
fi
if [ -n "$advisory_missing" ]; then
    printf 'advisory commands not provided:%s\n' "$advisory_missing"
fi
exit 0
