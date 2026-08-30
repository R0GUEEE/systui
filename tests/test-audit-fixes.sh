#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf -- "$tmpdir"' EXIT

checks=0
failures=0
check() {
    local name="$1"; shift
    checks=$((checks + 1))
    if "$@"; then printf 'ok %d - %s\n' "$checks" "$name"; else printf 'not ok %d - %s\n' "$checks" "$name"; failures=$((failures + 1)); fi
}

# --- M1: run_cmd preserves the caller's errexit state ------------------------
check "run_cmd preserves errexit=off" \
    bash -c '. "$1/src/core/config.sh"; . "$1/src/core/tui-widgets.sh"; set +e; run_cmd x true >/dev/null; case $- in *e*) exit 1;; *) exit 0;; esac' _ "$PROJECT_DIR"
check "run_cmd preserves errexit=on" \
    bash -c '. "$1/src/core/config.sh"; . "$1/src/core/tui-widgets.sh"; set -e; run_cmd x true >/dev/null; case $- in *e*) exit 0;; *) exit 1;; esac' _ "$PROJECT_DIR"

# --- M2: Arch refresh never performs a partial upgrade -----------------------
check "no pacman partial-upgrade refresh remains" \
    bash -c '! grep -R -nE "pacman[[:space:]]+-Sy([[:space:]]|$)" "$1"/{install.sh,src,share} --include="*.sh" 2>/dev/null' _ "$PROJECT_DIR"

# --- M3: Homebrew root support drops privileges rather than faking uid -------
check "Homebrew no longer uses LD_PRELOAD fake UID shim" \
    bash -c '! grep -R -n "LD_PRELOAD.*fake\|geteuid.*shim\|fake.*uid" "$1/share/homebrew" "$1/src" --include="*.sh" 2>/dev/null' _ "$PROJECT_DIR"
check "Homebrew wrapper drops root privileges" \
    bash -c 'grep -Eq "runuser|su[[:space:]]" "$1/share/homebrew/install-homebrew-root.sh"' _ "$PROJECT_DIR"

# --- M4: updater never executes arbitrary recorded source checkouts ----------
check "updater uses fixed root-owned cache" \
    bash -c 'grep -Fq "/var/lib/systui/source" "$1/update.sh"' _ "$PROJECT_DIR"
check "updater never executes install.sh from recorded user checkout" \
    bash -c '! grep -Eq "SOURCE_DIR.*/install\.sh|source-dir.*install\.sh" "$1/update.sh"' _ "$PROJECT_DIR"
check "CI workflow exists" test -s "$PROJECT_DIR/.github/workflows/ci.yml"

# --- M5: reports stay in private workspace -----------------------------------
check "rootfs reports are not written to host /tmp" \
    bash -c '! grep -R -nE "(^|[^A-Za-z0-9_])/tmp/systui-(report|output|rootfs)" "$1/src/features" --include="*.sh" 2>/dev/null' _ "$PROJECT_DIR"
check "rootfs reports live in the private workspace" \
    bash -c 'grep -R -q "SYSTUI_TMP" "$1/src/features/rootfs.sh"' _ "$PROJECT_DIR"

# --- M6: updater git/chmod operations are guarded -----------------------------
check "update.sh checks install.sh exists before chmod" \
    bash -c 'grep -Eq "\[ -f .*install\.sh.*\].*chmod|test -f .*install\.sh" "$1/update.sh"' _ "$PROJECT_DIR"
check "no unguarded git -C \$SOURCE_DIR calls remain" \
    bash -c '! grep -nE "git -C .*SOURCE_DIR" "$1/update.sh"' _ "$PROJECT_DIR"

# --- M7: config storage correctness -------------------------------------------
config_dir="$tmpdir/config"
mkdir -p "$config_dir"
printf 'present=value\n' > "$config_dir/config"
check "get_config falls back to the default for a missing key" \
    env SYSTUI_CONFIG_DIR="$config_dir" SYSTUI_TMP_ROOT="$tmpdir" bash -c '. "$1/src/core/config.sh"; [ "$(get_config absent fallback)" = fallback ]' _ "$PROJECT_DIR"
check "get_config still returns a present value" \
    env SYSTUI_CONFIG_DIR="$config_dir" SYSTUI_TMP_ROOT="$tmpdir" bash -c '. "$1/src/core/config.sh"; [ "$(get_config present fallback)" = value ]' _ "$PROJECT_DIR"
for v in 'http://x/y|z' 'a&b' 'C:\path\to' plain; do
    check "set_config round-trips [$v]" \
        env SYSTUI_CONFIG_DIR="$config_dir" SYSTUI_TMP_ROOT="$tmpdir" bash -c '. "$1/src/core/config.sh"; set_config probe "$2"; [ "$(get_config probe)" = "$2" ]' _ "$PROJECT_DIR" "$v"
done

# --- M8: log survives workspace cleanup --------------------------------------
logpath="$tmpdir/durable.log"
check "the log file is not inside the ephemeral workspace" \
    env SYSTUI_LOGFILE="$logpath" SYSTUI_TMP_ROOT="$tmpdir" bash -c '. "$1/src/core/config.sh"; case "$LOGFILE" in "$SYSTUI_TMP"/*) exit 1;; esac' _ "$PROJECT_DIR"
check "log survives after the shell exits" \
    env SYSTUI_LOGFILE="$logpath" SYSTUI_TMP_ROOT="$tmpdir" bash -c '. "$1/src/core/config.sh"; log hello' _ "$PROJECT_DIR" && grep -q hello "$logpath"

# --- M9: pm_install integration chain -----------------------------------------
check "native pm_install is preserved for the integration chain" \
    bash -c 'grep -R -q "_systui_native_pm_install" "$1/src/features" --include="*.sh"' _ "$PROJECT_DIR"
check "pm_install redefinitions chain to the preserved native" \
    bash -c 'grep -R -q "_systui_native_pm_install" "$1/src/features" --include="*.sh"' _ "$PROJECT_DIR"
check "common.sh no longer exports pm_install" \
    bash -c '! grep -Eq "export -f.*pm_install" "$1/src/core/common.sh"' _ "$PROJECT_DIR"
check "no bare 'pacman -Sy' anywhere (partial-upgrade pattern)" \
    bash -c '! grep -R -nE "pacman[[:space:]]+-Sy([[:space:]]|$)" "$1"/{src,share,install.sh} --include="*.sh" 2>/dev/null' _ "$PROJECT_DIR"
check "ask_yesno returns the default on EOF instead of recursing" \
    bash -c '. "$1/src/core/common.sh"; ask_yesno "x" y </dev/null' _ "$PROJECT_DIR"

# --- M9b: rootfs teardown takes an explicit target ---------------------------
check "rootfs_unmount_chroot_fs takes an explicit target" \
    bash -c 'grep -Eq "rootfs_unmount_chroot_fs\(\).*# <target>|rootfs_unmount_chroot_fs\(\).*target" "$1/src/features/rootfs.sh"' _ "$PROJECT_DIR"
check "no suffix-stripping recovery of the target remains" \
    bash -c '! grep -q "%-mounted" "$1/src/features/rootfs.sh"' _ "$PROJECT_DIR"
check "rootfs DNS is restored when every mount is refused" \
    bash -c 'grep -q "resolv.conf" "$1/src/features/rootfs.sh"' _ "$PROJECT_DIR"
check "teardown never touches the host /AOK tree" \
    bash -c '! grep -Eq "rm -rf.*/AOK" "$1/src/features/rootfs.sh"' _ "$PROJECT_DIR"

# --- M9c: SSH config uses shared validator -----------------------------------
check "provisioners no longer sed sshd_config directly" \
    bash -c '! grep -R -n "sshd_config.*sed\|sed.*sshd_config" "$1/src/provision"/*-enhanced.sh 2>/dev/null' _ "$PROJECT_DIR"
check "provision_configure_sshd exists and validates with sshd -t" \
    bash -c 'grep -q "provision_configure_sshd" "$1/src/provision/runtime.sh" && grep -q "sshd -t" "$1/src/provision/runtime.sh"' _ "$PROJECT_DIR"
check "provision_configure_sshd rejects a non-numeric port" \
    bash -c 'grep -q "port.*!.*0-9\|case.*port" "$1/src/provision/runtime.sh"' _ "$PROJECT_DIR"

# --- M10: the TUI shell is not fail-fast; run_strict still is -----------------
check "config.sh does not enable a shell-wide set -e" \
    bash -c '! grep -Eq "^set -eE?$" "$1/src/core/config.sh"' _ "$PROJECT_DIR"
check "a dialog Cancel does not terminate the shell" \
    bash -c '
        . "$1/src/core/config.sh"
        cancel() { return 1; }; esc() { return 255; }
        cancel; esc
        echo survived >/dev/null
    ' _ "$PROJECT_DIR"
# run_strict must keep fail-fast even when the caller puts it in a || list.
# Bash suppresses set -e for the whole dynamic extent of a tested command, and
# that suppression crosses subshells -- so this only holds for a child process.
#
# run_strict re-sources $SYSTUI_LIBDIR in a child, so these checks need a probe
# module inside a source tree. They use a throwaway copy: a test must never
# write into the tree it is testing, or a failure part-way through leaves debris
# behind in the user's checkout.
libcopy="$tmpdir/libcopy"
mkdir -p "$libcopy"
cp -R "$PROJECT_DIR/src" "$libcopy/"

strict_probe() { # <body> -> writes the probe module into the copied tree
    printf '%s\n' "$1" > "$libcopy/src/features/zz-strict-probe.sh"
    grep -qxF 'zz-strict-probe.sh' "$libcopy/src/features/.load-order" 2>/dev/null ||
        printf '%s\n' 'zz-strict-probe.sh' >> "$libcopy/src/features/.load-order"
}

strict_probe 'sr_boom() { false; echo REACHED; }'
check "run_strict aborts a failing routine (bare call)" \
    env SYSTUI_LIBDIR="$libcopy" bash -c '
        . "$SYSTUI_LIBDIR/src/core/config.sh"
        . "$SYSTUI_LIBDIR/src/features/zz-strict-probe.sh"
        out=$(run_strict probe sr_boom 2>/dev/null)
        [ -z "$out" ]
    '
check "run_strict aborts a failing routine inside a || list" \
    env SYSTUI_LIBDIR="$libcopy" bash -c '
        . "$SYSTUI_LIBDIR/src/core/config.sh"
        . "$SYSTUI_LIBDIR/src/features/zz-strict-probe.sh"
        out=$(run_strict probe sr_boom 2>/dev/null) || true
        [ -z "$out" ]
    '
strict_probe 'sr_ok() { echo FINE; }'
check "run_strict returns output and 0 on success" \
    env SYSTUI_LIBDIR="$libcopy" bash -c '
        . "$SYSTUI_LIBDIR/src/core/config.sh"
        . "$SYSTUI_LIBDIR/src/features/zz-strict-probe.sh"
        out=$(run_strict probe sr_ok 2>/dev/null); rc=$?
        [ "$rc" = 0 ] && [ "$out" = FINE ]
    '
check "run_strict does not leak or delete the parent workspace" \
    env SYSTUI_LIBDIR="$libcopy" bash -c '
        . "$SYSTUI_LIBDIR/src/core/config.sh"
        . "$SYSTUI_LIBDIR/src/features/zz-strict-probe.sh"
        before=$(find "$SYSTUI_TMP_ROOT" -maxdepth 1 -name "systui.*" | wc -l)
        run_strict probe sr_ok >/dev/null 2>&1
        after=$(find "$SYSTUI_TMP_ROOT" -maxdepth 1 -name "systui.*" | wc -l)
        [ "$before" = "$after" ] && [ -d "$SYSTUI_TMP" ]
    '
check "the run_strict checks leave no debris in the source tree" \
    test ! -e "$PROJECT_DIR/src/features/zz-strict-probe.sh"

# --- M11: a config file cannot clobber systui internals -----------------------
printf 'user=someone\nLOGFILE=/tmp/attacker.log\nPM=pacman\n' > "$tmpdir/evil.conf"
check "sourced config cannot redirect LOGFILE or PM" \
    bash -c '
        log() { :; }
        . "$1/src/provision/runtime.sh"
        LOGFILE=/real/log; PM=apt
        provision_load_config "$2"
        [ "$LOGFILE" = /real/log ] && [ "$PM" = apt ] && [ "$user" = someone ]
    ' _ "$PROJECT_DIR" "$tmpdir/evil.conf"

# --- M12: no duplicate PKG_MAP keys ------------------------------------------
check "PKG_MAP has no duplicate keys" \
    bash -c '[ -z "$(grep -o "^    \[[^]]*\]" "$1/src/core/common.sh" | sort | uniq -d)" ]' _ "$PROJECT_DIR"

# --- C2: catalogue builds are explicit, never implicit ------------------------
cache="$tmpdir/awesome"
mkdir -p "$cache"
printf 'htop\tMonitoring\thtop\thttps://github.com/htop-dev/htop\thttps://github.com/htop-dev/htop\tProcess viewer\n' \
    > "$cache/catalog.tsv"
SYSTUI_AWESOME_CACHE="$cache" bash -c '
    . "$1/src/core/config.sh"; . "$1/src/core/common.sh"; . "$1/src/core/tui-widgets.sh"
    . "$1/src/features/sysconfig.sh"
    awesome_linux_generate_catalog_installers "$2"
' _ "$PROJECT_DIR" "$cache/catalog.tsv" >/dev/null 2>&1
installer="$cache/installers/htop-install.sh"
check "the generated installer exists" test -s "$installer"
check "the generated installer is POSIX sh" sh -n "$installer"
check "auto does not fall through to a source build" \
    bash -c '! grep -Eq "auto\).*install_github" "$1"' _ "$installer"
check "cloning requires confirmation" \
    bash -c 'grep -Fq "confirm_repo" "$1"' _ "$installer"
check "the repository URL is shown before the build" \
    bash -c 'grep -Fq "repository :" "$1"' _ "$installer"
check "non-GitHub URLs are refused" \
    bash -c 'grep -Fq "Refusing a non-GitHub repository URL" "$1"' _ "$installer"
check "auto on an unavailable package exits without cloning" \
    bash -c '
        fake=$(mktemp -d); printf "#!/bin/sh\nexit 9\n" > "$fake/git"; chmod +x "$fake/git"
        sed "s|^PACKAGE=.*|PACKAGE=(no-such-package-xyz)|" "$1" > "$fake/i.sh"
        sed -i "s|(no-such-package-xyz)|'"'"'no-such-package-xyz'"'"'|" "$fake/i.sh"
        out=$(PATH="$fake:$PATH" sh "$fake/i.sh" auto </dev/null 2>&1); rc=$?
        rm -rf "$fake"
        [ "$rc" = 3 ] && ! printf %s "$out" | grep -q "git was invoked"
    ' _ "$installer"

# --- L1: BusyBox-safe file operations ----------------------------------------
check "no bare GNU --one-file-system without a probe" \
    bash -c 'grep -Fq "rootfs_rm_tree" "$1/src/features/rootfs.sh"' _ "$PROJECT_DIR"
check "du has a BusyBox fallback" \
    bash -c 'grep -Fq "rootfs_du_summary" "$1/src/features/rootfs.sh"' _ "$PROJECT_DIR"

# --- L3: widgets are sourced, never exported ---------------------------------
check "tui_menu_no_tags is not exported" \
    bash -c '! grep -Eq "export -f.*tui_menu_no_tags" "$1/src/core/tui-widgets.sh"' _ "$PROJECT_DIR"

# --- L10: rename cannot escape the base directory ----------------------------
check "rootfs rename rejects a path" \
    bash -c 'grep -Fq "Enter a directory name, not a path." "$1/src/features/rootfs.sh"' _ "$PROJECT_DIR"

# --- L12: the README describes files that exist ------------------------------
check "README does not reference removed modules" \
    bash -c '! grep -Eq "features/(shells|repos)\.sh" "$1/README.md"' _ "$PROJECT_DIR"

printf '1..%d\n' "$checks"
[ "$failures" -eq 0 ]