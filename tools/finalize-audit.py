#!/usr/bin/env python3
from pathlib import Path


def once(path: str, old: str, new: str) -> None:
    p = Path(path)
    s = p.read_text()
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {n}: {old[:120]!r}")
    p.write_text(s.replace(old, new, 1))

# Explicit feature manifests mean dynamically-created test features must also be
# registered in the copied manifest used by run_strict's child process.
once(
    "tests/test-audit-fixes.sh",
    '''strict_probe() { # <body> -> writes the probe module into the copied tree
    printf '%s\\n' "$1" > "$libcopy/src/features/zz-strict-probe.sh"
}''',
    '''strict_probe() { # <body> -> writes the probe module into the copied tree
    printf '%s\\n' "$1" > "$libcopy/src/features/zz-strict-probe.sh"
    grep -qxF 'zz-strict-probe.sh' "$libcopy/src/features/.load-order" 2>/dev/null ||
        printf '%s\\n' 'zz-strict-probe.sh' >> "$libcopy/src/features/.load-order"
}''',
)

# Installation should fail if copying managed content fails; avoid A&&B||C
# ambiguity and make the intent explicit.
once(
    "install.sh",
    '''    [ -d "$PROJECT_DIR/share" ] && cp -r "$PROJECT_DIR/share" "$LIB_DIR/" || true
    [ -d "$PROJECT_DIR/docs" ] && cp -r "$PROJECT_DIR/docs" "$LIB_DIR/" || true''',
    '''    if [ -d "$PROJECT_DIR/share" ]; then
        cp -r "$PROJECT_DIR/share" "$LIB_DIR/"
    fi
    if [ -d "$PROJECT_DIR/docs" ]; then
        cp -r "$PROJECT_DIR/docs" "$LIB_DIR/"
    fi''',
)

# Avoid shell-word-splitting a pacman package list through bash -c.
once(
    "src/features/health.sh",
    '''                pacman) run_cmd "Remove orphan packages" bash -c 'o=$(pacman -Qtdq 2>/dev/null); [ -z "$o" ] || pacman -Rns --noconfirm $o' ;;''',
    '''                pacman)
                    local orphans
                    local -a orphan_pkgs=()
                    orphans=$(pacman -Qtdq 2>/dev/null || true)
                    if [ -n "$orphans" ]; then
                        mapfile -t orphan_pkgs <<< "$orphans"
                        run_cmd "Remove orphan packages" pacman -Rns --noconfirm "${orphan_pkgs[@]}"
                    fi
                    ;;''',
)

once(
    "src/features/zz-rootfs-distro-managers.sh",
    '''        proot-distro|chroot-distro)
            [ "$(basename "$2")" = rootfs ] && basename "$(dirname "$2")" || basename "$2" ;;''',
    '''        proot-distro|chroot-distro)
            if [ "$(basename "$2")" = rootfs ]; then
                basename "$(dirname "$2")"
            else
                basename "$2"
            fi
            ;;''',
)

once(
    "src/features/zz-rootfs-distro-managers.sh",
    '''                [ -n "$d" ] && rootfs_dm_run distrobox "Enter $d" enter "$d" || true ;;''',
    '''                if [ -n "$d" ]; then
                    rootfs_dm_run distrobox "Enter $d" enter "$d" || true
                fi
                ;;''',
)

once(
    "share/homebrew/install-homebrew-root.sh",
    'The `brew` command may be invoked from a root shell, but systui will always',
    'The brew command may be invoked from a root shell, but systui will always',
)
