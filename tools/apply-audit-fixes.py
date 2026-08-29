#!/usr/bin/env python3
from pathlib import Path


def once(path: str, old: str, new: str) -> None:
    p = Path(path)
    s = p.read_text()
    n = s.count(old)
    if n != 1:
        raise SystemExit(f"{path}: expected exactly one match, found {n}: {old[:100]!r}")
    p.write_text(s.replace(old, new, 1))


once(
    "src/core/config.sh",
    'SYSTUI_VERSION="1.0.0"\nSYSTUI_TITLE="systui — Linux System TUI"',
    '''if [ -r "$SYSTUI_LIBDIR/src/VERSION" ]; then
    SYSTUI_VERSION=$(head -n1 "$SYSTUI_LIBDIR/src/VERSION" | tr -d '[:space:]')
else
    SYSTUI_VERSION="dev"
fi
SYSTUI_TITLE="systui — Linux System TUI"''',
)

once(
    "src/core/config.sh",
    '''        for _f in "$SYSTUI_LIBDIR"/src/features/*.sh; do
            [ -f "$_f" ] || continue
            . "$_f" || exit 1
        done''',
    '''        _manifest="$SYSTUI_LIBDIR/src/features/.load-order"
        [ -r "$_manifest" ] || { echo "systui: missing feature load manifest" >&2; exit 1; }
        while IFS= read -r _rel || [ -n "$_rel" ]; do
            case "$_rel" in ''|'#'*) continue ;; esac
            _f="$SYSTUI_LIBDIR/src/features/$_rel"
            [ -f "$_f" ] || { echo "systui: manifest references missing feature: $_rel" >&2; exit 1; }
            . "$_f" || exit 1
        done < "$_manifest"''',
)

once(
    "install.sh",
    'PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\nINSTALL_PREFIX=',
    'PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"\nSYSTUI_VERSION=$(head -n1 "$PROJECT_DIR/src/VERSION" 2>/dev/null | tr -d \'[:space:]\')\n[ -n "$SYSTUI_VERSION" ] || SYSTUI_VERSION=dev\nINSTALL_PREFIX=',
)

once(
    "install.sh",
    '''for feature in "$LIBDIR/src/features"/*.sh; do
    [ -f "$feature" ] || continue
    . "$feature" || { echo "systui: failed to load $feature" >&2; exit 1; }
done''',
    '''manifest="$LIBDIR/src/features/.load-order"
[ -r "$manifest" ] || { echo "systui: missing feature load manifest: $manifest" >&2; exit 1; }
while IFS= read -r rel || [ -n "$rel" ]; do
    case "$rel" in ''|'#'*) continue ;; esac
    feature="$LIBDIR/src/features/$rel"
    [ -f "$feature" ] || { echo "systui: feature manifest references missing file: $rel" >&2; exit 1; }
    . "$feature" || { echo "systui: failed to load $feature" >&2; exit 1; }
done < "$manifest"''',
)

once("install.sh", 'echo "Version: 1.0.0"', 'echo "Version: $SYSTUI_VERSION"')
once(
    "install.sh",
    '.TH SYSTUI 1 "2026-07-29" "systui 1.0.0" "User Commands"',
    '.TH SYSTUI 1 "2026-08-29" "systui __SYSTUI_VERSION__" "User Commands"',
)
once(
    "install.sh",
    '''MANPAGE
    
    success "Man page created at $INSTALL_PREFIX/share/man/man1/systui.1"''',
    '''MANPAGE
    sed -i "s/__SYSTUI_VERSION__/$SYSTUI_VERSION/g" "$INSTALL_PREFIX/share/man/man1/systui.1"
    
    success "Man page created at $INSTALL_PREFIX/share/man/man1/systui.1"''',
)

once(
    "src/features/zz-rootfs-distro-managers.sh",
    '''            command -v curl >/dev/null 2>&1 || pm_install curl
            run_cmd "Run the upstream distrobox installer" sh -c \\
                "curl -fsSL https://raw.githubusercontent.com/89luca89/distrobox/main/install | sh -s -- --prefix '$prefix'"''',
    '''            command -v curl >/dev/null 2>&1 || pm_install curl || return 1
            local installer="$SYSTUI_TMP/distrobox-install.sh"
            run_cmd "Download the upstream distrobox installer" curl -fsSL \\
                https://raw.githubusercontent.com/89luca89/distrobox/main/install -o "$installer" || return 1
            chmod 0700 "$installer"
            run_cmd "Run the upstream distrobox installer" sh "$installer" --prefix "$prefix"''',
)

once(
    "src/features/zz-rootfs-distro-managers.sh",
    '''    if selected=$(rootfs_dm_select_catalog_entries "$tag" "$query"); then
        :
    else
        # Search/catalogue parsing can fail because a manager changed output,
        # Docker Hub is unavailable, or the query had no hits. Keep a manual
        # path instead of guessing an image name.
        manual=$(tui_input "Install with $tag" \\
            "No selectable catalogue entries were returned. Enter an image/reference manually (blank cancels):" "") || return 0
        [ -n "$manual" ] || return 0
        selected="$manual"
    fi''',
    '''    local select_rc=0
    selected=$(rootfs_dm_select_catalog_entries "$tag" "$query") || select_rc=$?
    case "$select_rc" in
        0) ;;
        2) return 0 ;; # explicit Cancel/no selection
        *)
            # Search/catalogue parsing can fail because a manager changed output,
            # Docker Hub is unavailable, or the query had no hits. Keep a manual
            # path instead of guessing an image name.
            manual=$(tui_input "Install with $tag" \\
                "No selectable catalogue entries were returned. Enter an image/reference manually (blank cancels):" "") || return 0
            [ -n "$manual" ] || return 0
            selected="$manual"
            ;;
    esac''',
)
