#!/usr/bin/env bash
# systui — put every installed Homebrew formula on the default PATH.
#
# Homebrew links a *linked* formula's executables into $BREW_PREFIX/bin
# (and sbin). A keg-only formula — openjdk, sqlite, node, curl@8,
# postgresql@16, python@3.12, most versioned packages — is never linked
# there at all, and its commands only exist under $BREW_PREFIX/opt/<formula>.
# Neither location reaches a shell that is already running, a non-login
# shell, a script started by cron, or a child process spawned by the systui
# TUI: all of those only ever see the PATH they inherited.
#
# This utility mirrors every executable Homebrew owns — $PREFIX/bin,
# $PREFIX/sbin and each $PREFIX/opt/<formula>/{bin,sbin} — into
# /usr/local/bin and /usr/local/sbin, directories every mainstream
# distribution already puts on PATH. Install a formula, the utility runs,
# the command resolves immediately for root and for every user. No PATH
# edit, no re-login, no new shell.
#
# A name the distribution already provides (git, curl, python3) is left to
# the system by default so init scripts and package-manager hooks keep
# running the binary they were written for. --prefer-brew flips that, and
# the choice is remembered in the policy file below.
#
# Environment overrides (also used by the test suite):
#   SYSTUI_BREW_PREFIX           brew prefix     (default /home/linuxbrew/.linuxbrew)
#   SYSTUI_BREW_PATH_LINK_DIR    bin mirror dir  (default /usr/local/bin)
#   SYSTUI_BREW_PATH_SBIN_DIR    sbin mirror dir (default /usr/local/sbin)
#   SYSTUI_BREW_PATH_SHADOW      1 = brew wins over a system command
#   SYSTUI_BREW_PATH_KEG         0 = skip the keg-only opt/* scan
#   SYSTUI_BREW_PATH_CONF        policy file     (default /etc/systui/brew-path.conf)

set -uo pipefail

PREFIX=${SYSTUI_BREW_PREFIX:-/home/linuxbrew/.linuxbrew}
LINK_DIR=${SYSTUI_BREW_PATH_LINK_DIR:-/usr/local/bin}
SBIN_LINK_DIR=${SYSTUI_BREW_PATH_SBIN_DIR:-/usr/local/sbin}
CONF=${SYSTUI_BREW_PATH_CONF:-/etc/systui/brew-path.conf}
KEG=${SYSTUI_BREW_PATH_KEG:-1}

usage() {
    cat <<'EOF_USAGE'
systui-brew-path [--quiet|--verbose] [--status] [--remove]
                 [--prefer-brew|--prefer-system] [--no-keg]

  (default)       refresh the /usr/local mirrors from every installed formula
  --quiet         refresh, print nothing
  --verbose       refresh, report every skipped, kept or removed entry
  --status        show the policy and the mirrors currently owned by systui
  --remove        delete every mirror owned by systui (component uninstall)
  --prefer-brew   let Homebrew's version of a command win over the system one
  --prefer-system restore the default: the distribution binary keeps priority
  --no-keg        mirror only the linked bin/sbin dirs, skip keg-only formulae

A formula that Homebrew does not link (keg-only: openjdk, sqlite, node,
postgresql@16, ...) lives in opt/<formula>/; its executables are picked up
automatically, which is what makes those packages usable after install.
EOF_USAGE
}

# ---- policy ----------------------------------------------------------------
# Homebrew outranks a distribution command only when asked for. The policy
# file is a plain KEY=VALUE list so it can be read without executing it.
conf_value() { # <key>
    [ -r "$CONF" ] || return 0
    sed -n "s/^$1=//p" "$CONF" 2>/dev/null | tail -n 1
}

if [ -z "${SYSTUI_BREW_PATH_SHADOW:-}" ]; then
    SHADOW=$(conf_value PREFER_BREW)
    SHADOW=${SHADOW:-0}
else
    SHADOW=$SYSTUI_BREW_PATH_SHADOW
fi

# Never shadowed, whatever the policy: these are load-bearing for the shell,
# for the init system and for the package manager. A Homebrew copy of sh or
# apk on the front of PATH turns a working system into an unbootable one.
protected_name() {
    case "$1" in
        sh|bash|dash|ash|busybox|apk|env|init|login|su|sudo|mount|umount|passwd)
            return 0 ;;
    esac
    return 1
}

write_policy() { # <0|1>
    local tmp
    if ! install -d -m 0755 "$(dirname "$CONF")" 2>/dev/null; then
        printf 'systui-brew-path: cannot create %s (root required)\n' "$(dirname "$CONF")" >&2
        return 1
    fi
    tmp=$(mktemp "$(dirname "$CONF")/.brew-path.XXXXXX" 2>/dev/null) || {
        printf 'systui-brew-path: cannot write %s (root required)\n' "$CONF" >&2
        return 1
    }
    {
        printf '# systui — Homebrew PATH policy, read by systui-brew-path.\n'
        printf '# PREFER_BREW=1 lets a Homebrew command win over the system one.\n'
        printf 'PREFER_BREW=%s\n' "$1"
    } > "$tmp" && chmod 0644 "$tmp" && mv -f "$tmp" "$CONF" || {
        rm -f "$tmp"
        printf 'systui-brew-path: cannot write %s (root required)\n' "$CONF" >&2
        return 1
    }
    return 0
}

mode=refresh
persist=
while [ $# -gt 0 ]; do
    case "$1" in
        -q|--quiet)    mode=quiet ;;
        -v|--verbose)  mode=verbose ;;
        --status)      mode=status ;;
        --remove)      mode=remove ;;
        --prefer-brew)   SHADOW=1; persist=1 ;;
        --prefer-system) SHADOW=0; persist=0 ;;
        --no-keg)      KEG=0 ;;
        -h|--help)     usage; exit 0 ;;
        *)             printf 'systui-brew-path: unknown option %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

say()     { [ "$mode" = quiet ] || printf '%s\n' "$*"; }
verbose() { [ "$mode" = verbose ] && printf '%s\n' "$*"; return 0; }

policy_text() { [ "$SHADOW" = 1 ] && printf 'brew wins over system commands' || printf 'system commands keep priority'; }

if [ -n "$persist" ]; then
    write_policy "$persist" || exit 1
    say "PATH policy saved to $CONF: $(policy_text)"
fi

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

# A command the distribution already provides keeps priority by default:
# mirroring brew's git/python3/curl over a distribution binary would change
# what every system and init script runs. --prefer-brew opts out, except for
# the protected names above.
shadowed_by_system() { # <name> <mirror-dir>
    local name="$1" mirror="$2" dir abs
    protected_name "$name" && return 0
    [ "$SHADOW" = 1 ] && return 1
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

# link_into <src-dir> <mirror-dir> <created-ref> <skipped-ref> <updated-ref>
#
# Every source directory is walked in a fixed order (linked bin first, then
# opt/<formula> alphabetically), so a name offered by two formulae always
# resolves to the same one. An existing valid link is never repointed — that
# would make the winner depend on whichever formula was installed last — and
# a link that is not Homebrew's is never touched.
link_into() {
    local src="$1" dst="$2" path name dest cur
    local -n _created=$3 _skipped=$4 _updated=$5
    [ -d "$src" ] || return 0
    install -d -m 0755 "$dst" 2>/dev/null || { say "cannot write $dst (root required)"; return 1; }
    for path in "$src"/*; do
        [ -e "$path" ] || continue
        [ -x "$path" ] || continue      # skip directories and data files
        name=${path##*/}
        dest="$dst/$name"
        if [ -L "$dest" ]; then
            if ! owned_link "$dest" >/dev/null; then
                verbose "skip $name (link owned by something else)"
                continue
            fi
            cur=$(readlink "$dest" 2>/dev/null) || cur=""
            if [ "$cur" = "$path" ]; then
                _updated=$((_updated + 1))
            elif [ -e "$dest" ]; then
                # Another formula already owns this name and still resolves.
                verbose "skip $name (already provided by ${cur##*/})"
                _skipped=$((_skipped + 1))
            elif ln -sfn "$path" "$dest" 2>/dev/null; then
                _updated=$((_updated + 1))
                verbose "relink $name -> $path"
            fi
        elif [ -e "$dest" ]; then
            verbose "skip $name (already present in $dst)"
            _skipped=$((_skipped + 1))
        elif shadowed_by_system "$name" "$dst"; then
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

# Switching back to system priority has to give the name back, otherwise the
# policy is cosmetic: an owned mirror of `git` or `curl` keeps winning until it
# is removed. Only links systui owns are touched.
unshadow_owned() { # <mirror-dir> <removed-ref>
    local dst="$1" link name
    local -n _removed=$2
    [ -d "$dst" ] || return 0
    for link in "$dst"/*; do
        [ -L "$link" ] || continue
        owned_link "$link" >/dev/null || continue
        name=${link##*/}
        shadowed_by_system "$name" "$dst" || continue
        if rm -f -- "$link" 2>/dev/null; then
            _removed=$((_removed + 1))
            verbose "removed shadowing ${name} (system command takes priority)"
        fi
    done
    return 0
}

# Every dir that holds formula executables, in resolution order. Built as an
# array: process substitution needs /dev/fd, which not every sandbox provides.
collect_sources() { # <array-name>
    local opt
    local -n _srcs=$1
    _srcs=("$PREFIX/bin" "$PREFIX/sbin")
    [ "$KEG" = 1 ] || return 0
    [ -d "$PREFIX/opt" ] || return 0
    for opt in "$PREFIX"/opt/*; do
        [ -d "$opt" ] || continue
        _srcs+=("$opt/bin" "$opt/sbin")
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
    printf 'policy : %s (from %s)\n' "$(policy_text)" "$CONF"
    printf 'prefix : %s\n' "$PREFIX"
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
srcs=()
collect_sources srcs
for src in ${srcs[@]+"${srcs[@]}"}; do
    case "$src" in
        */sbin) link_into "$src" "$SBIN_LINK_DIR" created skipped updated ;;
        *)      link_into "$src" "$LINK_DIR"      created skipped updated ;;
    esac
done
if [ "$SHADOW" != 1 ]; then
    unshadow_owned "$LINK_DIR"      removed
    unshadow_owned "$SBIN_LINK_DIR" removed
fi
prune_stale "$LINK_DIR"      removed
prune_stale "$SBIN_LINK_DIR" removed

say "Homebrew PATH mirrors: $created linked, $updated refreshed, $removed removed, $skipped left to the system ($(policy_text))"
exit 0
