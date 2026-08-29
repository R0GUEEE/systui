from pathlib import Path

p = Path("src/features/rootfs.sh")
s = p.read_text()
marker = "\nmenu_rootfs_bootstrap_tools() {\n"
helper = r'''# Resolve bootstrap catalogue tags to the executable that proves the tool is
# actually usable. Several catalogue tags are package names rather than command
# names, so `command -v "$tag"` is not sufficient.
rootfs_bs_command() { # <tag>
    case "$1" in
        arch-install-scripts) printf 'pacstrap\n' ;;
        systemd-container)    printf 'systemd-nspawn\n' ;;
        xbps-tools)           printf 'xbps-install\n' ;;
        xz-utils)             printf 'xz\n' ;;
        binfmt-support)       printf 'update-binfmts\n' ;;
        *)                    printf '%s\n' "$1" ;;
    esac
}

rootfs_bs_has_command() { # <command>
    local cmd="$1" dir
    command -v "$cmd" >/dev/null 2>&1 && return 0
    for dir in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
        [ -x "$dir/$cmd" ] && return 0
    done
    return 1
}

rootfs_bs_installed() { # <tag>
    local tag="$1" cmd q
    case "$tag" in
        qemu-user-static)
            for q in /usr/local/bin/qemu-*-static /usr/bin/qemu-*-static /bin/qemu-*-static; do
                [ -x "$q" ] && return 0
            done
            return 1
            ;;
        *)
            cmd=$(rootfs_bs_command "$tag")
            rootfs_bs_has_command "$cmd"
            ;;
    esac
}
'''

if "rootfs_bs_installed() {" not in s:
    if s.count(marker) != 1:
        raise SystemExit(f"bootstrap menu marker count={s.count(marker)}")
    s = s.replace(marker, "\n" + helper + marker, 1)

old = '''    # Build menu items: "tag  [INSTALLED|NOT INSTALLED]  description"
    local _items=() _tag
    while IFS='|' read -r _tag _lbl _desc; do
        [ -n "$_tag" ] || continue
        local _status
        if command -v "$_tag" >/dev/null 2>&1; then
            _status="✓ INSTALLED"
        else
            _status="○ not installed"
        fi
        _items+=("$_tag" "$_status  $_lbl")
    done <<< "$_BS_CATALOGUE"

    # Main bootstrap tools menu loop
    while true; do
        local _choice
'''
new = '''    # Main bootstrap tools menu loop. Rebuild the items on every pass so
    # returning from an install/uninstall submenu immediately refreshes status.
    local _items=() _tag _lbl _desc _status
    while true; do
        _items=()
        while IFS='|' read -r _tag _lbl _desc; do
            [ -n "$_tag" ] || continue
            if rootfs_bs_installed "$_tag"; then
                _status="✓ INSTALLED"
            else
                _status="○ not installed"
            fi
            _items+=("$_tag" "$_status  $_lbl")
        done <<< "$_BS_CATALOGUE"

        local _choice
'''
if old not in s:
    raise SystemExit("bootstrap menu status block not found")
s = s.replace(old, new, 1)

old_sub = '''    if command -v "$_tag" >/dev/null 2>&1; then
        _status="installed"
    else
        _status="not installed"
    fi

    while true; do
        # Refresh install status in case it changed
        if command -v "$_tag" >/dev/null 2>&1; then
            _status="installed"
        else
            _status="not installed"
        fi
'''
new_sub = '''    if rootfs_bs_installed "$_tag"; then
        _status="installed"
    else
        _status="not installed"
    fi

    while true; do
        # Refresh install status in case it changed
        if rootfs_bs_installed "$_tag"; then
            _status="installed"
        else
            _status="not installed"
        fi
'''
if old_sub not in s:
    raise SystemExit("submenu status block not found")
s = s.replace(old_sub, new_sub, 1)

old_install = '''    if command -v "$_tag" >/dev/null 2>&1; then
        tui_msg "$_tag" "$_tag is already installed."
        return 0
    fi
'''
new_install = '''    if rootfs_bs_installed "$_tag"; then
        tui_msg "$_tag" "$_tag is already installed."
        return 0
    fi
'''
if old_install not in s:
    raise SystemExit("install precheck not found")
s = s.replace(old_install, new_install, 1)

old_un = '''    if ! command -v "$_tag" >/dev/null 2>&1; then
        tui_msg "$_tag" "$_tag is not installed."
        return 0
    fi
'''
new_un = '''    if ! rootfs_bs_installed "$_tag"; then
        tui_msg "$_tag" "$_tag is not installed."
        return 0
    fi
'''
if old_un not in s:
    raise SystemExit("uninstall precheck not found")
s = s.replace(old_un, new_un, 1)
p.write_text(s)

t = Path("tests/test-regressions.sh")
ts = t.read_text()
anchor = '''check "bootstrap tools menu maps packages via _bs_pkg" contains \\
    "$PROJECT_DIR/src/features/rootfs.sh" "_bs_pkg"
'''
addition = '''check "bootstrap detection helper exists" function_exists rootfs_bs_installed
check "bootstrap detection maps pacstrap package to command" bash -c \\
    '. "$1/src/features/rootfs.sh" 2>/dev/null; [ "$(rootfs_bs_command arch-install-scripts)" = pacstrap ]' _ "$PROJECT_DIR"
check "bootstrap detection maps systemd-container to nspawn" bash -c \\
    '. "$1/src/features/rootfs.sh" 2>/dev/null; [ "$(rootfs_bs_command systemd-container)" = systemd-nspawn ]' _ "$PROJECT_DIR"
check "bootstrap detection maps xbps-tools to xbps-install" bash -c \\
    '. "$1/src/features/rootfs.sh" 2>/dev/null; [ "$(rootfs_bs_command xbps-tools)" = xbps-install ]' _ "$PROJECT_DIR"
check "bootstrap detection maps xz-utils to xz" bash -c \\
    '. "$1/src/features/rootfs.sh" 2>/dev/null; [ "$(rootfs_bs_command xz-utils)" = xz ]' _ "$PROJECT_DIR"
check "bootstrap menu status uses executable-aware detection" contains \\
    "$PROJECT_DIR/src/features/rootfs.sh" 'rootfs_bs_installed "$_tag"'
'''
if "bootstrap detection helper exists" not in ts:
    if anchor not in ts:
        raise SystemExit("test anchor not found")
    ts = ts.replace(anchor, anchor + addition, 1)
t.write_text(ts)
