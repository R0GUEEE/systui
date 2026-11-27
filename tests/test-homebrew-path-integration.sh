#!/usr/bin/env bash
# Homebrew PATH integration: installed formulae must be runnable without a
# re-login. Covers the mirror helper's behaviour in a sandbox prefix and the
# wiring that keeps it in step with brew install/uninstall.
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
HELPER="$PROJECT_DIR/share/homebrew/systui-brew-path.sh"
INSTALLER="$PROJECT_DIR/share/homebrew/install-homebrew-root.sh"
SYSCONFIG="$PROJECT_DIR/src/features/sysconfig.sh"

tmpdir=$(mktemp -d)
trap 'rm -rf -- "$tmpdir"' EXIT

checks=0
failures=0
check() {
    local name="$1"; shift
    checks=$((checks + 1))
    if "$@"; then printf 'ok %d - %s\n' "$checks" "$name"
    else printf 'not ok %d - %s\n' "$checks" "$name"; failures=$((failures + 1)); fi
}
contains()     { grep -Fq "$2" "$1"; }
not_contains() { ! grep -Fq "$2" "$1"; }

# --- fixtures ---------------------------------------------------------------
prefix="$tmpdir/prefix"
lbin="$tmpdir/lbin"
lsbin="$tmpdir/lsbin"
mkdir -p "$prefix/bin" "$prefix/sbin" "$lbin" "$lsbin"
mkbin() { printf '#!/bin/sh\nexit 0\n' > "$1"; chmod 0755 "$1"; }
mkbin "$prefix/bin/brew-fake-tool"
mkbin "$prefix/bin/brew-fake-other"
mkbin "$prefix/sbin/brew-fake-daemon"
# A name the host already provides system-wide: must never be mirrored over
# the distribution's binary.
mkbin "$prefix/bin/sh"

run_helper() {
    SYSTUI_BREW_PREFIX="$prefix" \
    SYSTUI_BREW_PATH_LINK_DIR="$lbin" \
    SYSTUI_BREW_PATH_SBIN_DIR="$lsbin" \
        bash "$HELPER" "$@"
}

# --- static wiring ----------------------------------------------------------
check "PATH mirror helper exists"                  test -x "$HELPER"
check "helper mirrors into /usr/local/bin"         contains "$HELPER" '/usr/local/bin'
check "helper prunes links of removed formulae"    contains "$HELPER" 'prune_stale'
check "helper never overwrites foreign links"      contains "$HELPER" 'link owned by something else'
check "installer ships the helper"                 contains "$INSTALLER" 'systui-brew-path.sh'
check "installer installs the helper"              contains "$INSTALLER" 'readonly PATH_HELPER="/usr/local/bin/systui-brew-path"'
check "installer runs the mirror after install"    contains "$INSTALLER" '"$PATH_HELPER" --quiet'
check "installer writes the login profile"         contains "$INSTALLER" 'readonly PROFILE_FILE="/etc/profile.d/homebrew.sh"'
check "installer hooks non-login shells"           contains "$INSTALLER" 'write_hook_block /etc/bash.bashrc'
check "installer hook block is marked"             contains "$INSTALLER" 'HOOK_BEGIN="# >>> systui homebrew >>>"'
check "wrapper refreshes PATH after mutations"     contains "$INSTALLER" 'install|uninstall|remove|upgrade|reinstall|link|unlink|pin|unpin|tap|untap|cleanup|update'
check "wrapper still drops root privileges"        bash -c 'grep -Fq "runuser -u" "$1" || grep -Fq "sudo -H -u" "$1"' _ "$INSTALLER"
check "wrapper no longer execs past the hook"      not_contains "$INSTALLER" 'exec runuser -u "\$BREW_USER" -- env'
check "sysconfig exposes brew_refresh_path"        contains "$SYSCONFIG" 'brew_refresh_path() {'
check "sysconfig refreshes after brew mutations"   contains "$SYSCONFIG" 'brew_refresh_path --quiet'
check "sysconfig has a PATH integration menu"      contains "$SYSCONFIG" 'menu_brew_path() {'
check "uninstall removes the mirrors"              contains "$SYSCONFIG" 'brew_refresh_path --remove'
check "uninstall removes the helper"               contains "$SYSCONFIG" 'rm -f /usr/local/bin/systui-brew-path'

# --- behaviour --------------------------------------------------------------
run_helper --quiet >/dev/null
check "installed formula is mirrored"              test -L "$lbin/brew-fake-tool"
check "sbin formula goes to the sbin mirror"       test -L "$lsbin/brew-fake-daemon"
check "mirror points at the formula binary" \
    test "$(readlink "$lbin/brew-fake-tool")" = "$prefix/bin/brew-fake-tool"
check "system-owned name is not mirrored over"     test ! -e "$lbin/sh"
check "mirrored binary is executable"              test -x "$lbin/brew-fake-tool"

SYSTUI_BREW_PREFIX="$prefix" SYSTUI_BREW_PATH_LINK_DIR="$lbin" SYSTUI_BREW_PATH_SBIN_DIR="$lsbin" \
    SYSTUI_BREW_PATH_SHADOW=1 bash "$HELPER" --quiet >/dev/null
check "shadow opt-in mirrors the system name"      test -L "$lbin/sh"

# A formula version bump re-points the existing link instead of failing.
mkdir -p "$prefix/bin/nested"
mkbin "$prefix/bin/brew-fake-tool"
before=$(readlink "$lbin/brew-fake-tool")
run_helper --quiet >/dev/null
check "refresh keeps a valid link stable"          test "$(readlink "$lbin/brew-fake-tool")" = "$before"

status_out=$(run_helper --status)
check "status reports the mirrors"                 bash -c 'printf %s "$1" | grep -q "brew-fake-tool"' _ "$status_out"

# brew uninstall: the target disappears, the mirror must follow.
rm -f "$prefix/bin/brew-fake-other"
run_helper --quiet >/dev/null
check "uninstalled formula loses its mirror"       test ! -e "$lbin/brew-fake-other" -a ! -L "$lbin/brew-fake-other"
check "surviving formula keeps its mirror"         test -L "$lbin/brew-fake-tool"

# An unrelated link in the mirror directory is untouched.
ln -s /bin/true "$lbin/unrelated-link"
run_helper --quiet >/dev/null
check "foreign links survive a refresh"            test -L "$lbin/unrelated-link"

# --remove drops only Homebrew-owned mirrors.
run_helper --remove >/dev/null
check "remove deletes Homebrew mirrors"            test ! -L "$lbin/brew-fake-tool"
check "remove keeps foreign links"                 test -L "$lbin/unrelated-link"

# Missing prefix must not fail: a fresh system has no /home/linuxbrew yet.
check "helper tolerates a missing prefix" bash -c \
    'SYSTUI_BREW_PREFIX="$1/nope" SYSTUI_BREW_PATH_LINK_DIR="$1/lbin2" SYSTUI_BREW_PATH_SBIN_DIR="$1/lsbin2" bash "$2" --quiet' \
    _ "$tmpdir" "$HELPER"

printf '\n%d checks, %d failure(s)\n' "$checks" "$failures"
[ "$failures" -eq 0 ]
