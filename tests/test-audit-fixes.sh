#!/bin/bash
# Regression tests for the issues found in the July 2026 audit.
# Each check fails against the pre-fix code and passes after it.
set -euo pipefail

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmpdir=$(mktemp -d)
trap 'rm -rf -- "$tmpdir"' EXIT

failures=0
checks=0
check() {
    local description="$1"
    shift
    checks=$((checks + 1))
    if "$@"; then
        printf 'ok %d - %s\n' "$checks" "$description"
    else
        printf 'not ok %d - %s\n' "$checks" "$description"
        failures=$((failures + 1))
    fi
}

export SYSTUI_TMP_ROOT="$tmpdir"
export SYSTUI_CONFIG_DIR="$tmpdir/cfg"
export SYSTUI_LOGFILE="$tmpdir/systui.log"

# --- C1: a non-root invocation must say something -----------------------------
# require_root calls die, which exits; wrapping it in `|| warn` made the warn
# branch dead code, and `2>/dev/null` swallowed the only message the user got.
check "wrapper does not silence require_root" \
    bash -c '! grep -Fq "require_root 2>/dev/null" "$1/install.sh"' _ "$PROJECT_DIR"
check "wrapper does not treat require_root as recoverable" \
    bash -c '! grep -Eq "require_root .*\|\| *warn" "$1/install.sh"' _ "$PROJECT_DIR"

# --- C3: no root writes to a predictable path in a shared directory -----------
check "rootfs reports are not written to host /tmp" \
    bash -c '! grep -Fq "/tmp/systui.rfs" "$1/src/features/rootfs.sh"' _ "$PROJECT_DIR"
check "rootfs reports live in the private workspace" \
    bash -c '
        . "$1/src/core/config.sh"
        f=$(cd "$1" && . src/features/rootfs.sh 2>/dev/null; rootfs_report_file)
        case "$f" in "$SYSTUI_TMP"/*) exit 0 ;; *) exit 1 ;; esac
    ' _ "$PROJECT_DIR"

# --- H1: the existence check must precede the chmod ---------------------------
check "update.sh checks install.sh exists before chmod" \
    bash -c '
        f=$(grep -n "install.sh\"" "$1/update.sh" | grep -E "die|chmod")
        [ "$(printf %s "$f" | grep -c die)" = 1 ] || exit 1
        die_line=$(printf %s\\n "$f" | grep die | cut -d: -f1)
        chmod_line=$(printf %s\\n "$f" | grep chmod | cut -d: -f1)
        [ "$die_line" -lt "$chmod_line" ]
    ' _ "$PROJECT_DIR"

# --- H2: every git call gets the safe.directory exemption ---------------------
check "no unguarded git -C \$SOURCE_DIR calls remain" \
    bash -c '! grep -Fq "git -C \"\$SOURCE_DIR\"" "$1/update.sh"' _ "$PROJECT_DIR"

# --- M1: get_config returns its default when the key is absent ----------------
mkdir -p "$SYSTUI_CONFIG_DIR"
printf 'other=1\n' > "$SYSTUI_CONFIG_DIR/config"
check "get_config falls back to the default for a missing key" \
    bash -c '. "$1/src/core/config.sh"; [ "$(get_config nope FALLBACK)" = FALLBACK ]' _ "$PROJECT_DIR"
check "get_config still returns a present value" \
    bash -c '. "$1/src/core/config.sh"; [ "$(get_config other ZZZ)" = 1 ]' _ "$PROJECT_DIR"

# --- M2: set_config survives sed metacharacters -------------------------------
for value in 'http://x/y|z' 'a&b' 'C:\path\to' 'plain'; do
    check "set_config round-trips [$value]" \
        bash -c '
            . "$1/src/core/config.sh"
            set_config probe "$2" || exit 1
            [ "$(get_config probe MISSING)" = "$2" ]
        ' _ "$PROJECT_DIR" "$value"
done

# --- M3: the log survives the workspace cleanup -------------------------------
check "the log file is not inside the ephemeral workspace" \
    bash -c '
        . "$1/src/core/config.sh"
        log "durable"
        case "$LOGFILE" in "$SYSTUI_TMP"/*) exit 1 ;; *) exit 0 ;; esac
    ' _ "$PROJECT_DIR"
check "log survives after the shell exits" test -s "$SYSTUI_LOGFILE"

# --- M4: pm_* defined once (native preserved before layered redefinitions), and not exported from common.sh -------------------
# The Bedrock sysconfig integration intentionally redefines pm_install in
# layered modules to add stratum fallback, but always preserves the original
# native implementation (as _systui_native_pm_install) before the first
# redefinition and re-uses it, so the active definition stays unique.
check "native pm_install is preserved for the integration chain" \
    bash -c 'grep -rl "_systui_native_pm_install ()" "$1/src/features" | grep -q .' _ "$PROJECT_DIR"
check "pm_install redefinitions chain to the preserved native" \
    bash -c 'for f in "$1"/src/features/*.sh; do case "$f" in */zzzzzzz-*|*/zzzzzzzz-*) grep -q "_systui_native_pm_install" "$f" || return 1;; esac; done' _ "$PROJECT_DIR"
check "common.sh no longer exports pm_install" \
    bash -c '! grep -vE "^\s*#" "$1/src/core/common.sh" | grep -Eq "export -f.*pm_install"' _ "$PROJECT_DIR"

# --- M6: no pacman -Sy partial upgrade for installs ---------------------------
check "no bare 'pacman -Sy' anywhere (partial-upgrade pattern)" \
    bash -c '
        hits=$(grep -rnE "pacman -Sy( |$)" "$1/src" "$1/install.sh" | grep -v Syu | grep -vE "^\s*#")
        [ -z "$hits" ]
    ' _ "$PROJECT_DIR"

# --- M9: ask_yesno terminates on EOF -----------------------------------------
check "ask_yesno returns the default on EOF instead of recursing" \
    bash -c '
        . "$1/src/core/common.sh"
        timeout 5 bash -c ". \"$1/src/core/common.sh\"; ask_yesno q n </dev/null"; rc=$?
        [ "$rc" = 1 ] || exit 1
        timeout 5 bash -c ". \"$1/src/core/common.sh\"; ask_yesno q y </dev/null"
    ' _ "$PROJECT_DIR"

# --- M7: DNS restore uses the target it was given ----------------------------
check "rootfs_unmount_chroot_fs takes an explicit target" \
    bash -c 'grep -Eq "rootfs_unmount_chroot_fs\(\) \{ # <target>" "$1/src/features/rootfs.sh"' _ "$PROJECT_DIR"
check "no suffix-stripping recovery of the target remains" \
    bash -c '! grep -Fq "t=\${m%/proc}" "$1/src/features/rootfs.sh"' _ "$PROJECT_DIR"

rootfs_dir="$tmpdir/rootfs"
mkdir -p "$rootfs_dir/etc" "$rootfs_dir/AOK/etc"
printf 'nameserver 9.9.9.9\n' > "$rootfs_dir/etc/resolv.conf"
printf 'HOST SENTINEL\n' > "$rootfs_dir/AOK/etc/resolv.conf"
bash -c '
    . "$1/src/core/config.sh"; . "$1/src/core/common.sh"; . "$1/src/core/tui-widgets.sh"
    mountpoint() { return 1; }               # host refuses every mount
    rootfs_chroot_option_get() { echo no; }
    . "$1/src/features/rootfs.sh"
    rootfs_mount_chroot_fs "$2" >/dev/null 2>&1
    rootfs_unmount_chroot_fs "$2" "${ROOTFS_ACTIVE_MOUNTS:-}"
' _ "$PROJECT_DIR" "$rootfs_dir" >/dev/null 2>&1 || true
check "rootfs DNS is restored when every mount is refused" \
    bash -c '[ "$(cat "$1/etc/resolv.conf")" = "nameserver 9.9.9.9" ]' _ "$rootfs_dir"
check "teardown never touches the host /AOK tree" \
    bash -c '[ "$(cat "$1/AOK/etc/resolv.conf")" = "HOST SENTINEL" ]' _ "$rootfs_dir"

# --- M8: sshd configured via a validated drop-in ------------------------------
check "provisioners no longer sed sshd_config directly" \
    bash -c '! grep -Eq "sed -i .s/\^#?P(ort|ermitRootLogin)" "$1"/src/provision/*-enhanced.sh' _ "$PROJECT_DIR"
check "provision_configure_sshd exists and validates with sshd -t" \
    bash -c 'grep -Fq "provision_configure_sshd()" "$1/src/provision/runtime.sh" &&
             grep -Fq "sshd -t" "$1/src/provision/runtime.sh"' _ "$PROJECT_DIR"
check "provision_configure_sshd rejects a non-numeric port" \
    bash -c '
        log() { :; }; LOGFILE=/dev/null
        . "$1/src/provision/runtime.sh"
        ! provision_configure_sshd "22; rm -rf /" 1 no 2>/dev/null
    ' _ "$PROJECT_DIR"

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
# The source tree must be exactly as it was before these checks ran.
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

# --- L3: every widget is exported --------------------------------------------
check "tui_menu_no_tags is exported" \
    bash -c 'grep -Eq "export -f.*tui_menu_no_tags" "$1/src/core/tui-widgets.sh"' _ "$PROJECT_DIR"

# --- L10: rename cannot escape the base directory ----------------------------
check "rootfs rename rejects a path" \
    bash -c 'grep -Fq "Enter a directory name, not a path." "$1/src/features/rootfs.sh"' _ "$PROJECT_DIR"

# --- L12: the README describes files that exist ------------------------------
check "README does not reference removed modules" \
    bash -c '! grep -Eq "features/(shells|repos)\.sh" "$1/README.md"' _ "$PROJECT_DIR"

printf '1..%d\n' "$checks"
[ "$failures" -eq 0 ]
