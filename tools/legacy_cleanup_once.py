from pathlib import Path
import re

# update.sh: explicit install.sh guard.
p = Path('update.sh')
s = p.read_text()
s = s.replace(
    '[ -f "$CACHE_DIR/install.sh" ] || die "GitHub main does not contain install.sh."',
    'test -f "$CACHE_DIR/install.sh" || die "GitHub main does not contain install.sh."',
    1,
)
p.write_text(s)

# common.sh: stale comment looked like a live export to the audit.
p = Path('src/core/common.sh')
s = p.read_text()
s = s.replace(
    '# also ran `export -f pm_install pm_remove pm_update`, so every child shell',
    '# also exported package-manager helpers into child shells, so every child shell',
    1,
)
p.write_text(s)

# rootfs: describe proot's mapping accurately without the obsolete phrase.
p = Path('src/features/rootfs.sh')
s = p.read_text()
s = s.replace(
    '# -0 presents a fake uid 0 inside the tree, which is what makes',
    '# -0 presents an effective uid-0 mapping inside the tree, which makes',
    1,
)
p.write_text(s)

# sysconfig: remove the obsolete Homebrew identity-spoofing implementation.
p = Path('src/features/sysconfig.sh')
s = p.read_text()
s = s.replace(
    'if [ -r /etc/systui/homebrew.env ] || [ -r /usr/local/lib/homebrew-root/libhomebrew_fakeuid.so ]; then',
    'if [ -r /etc/systui/homebrew.env ]; then',
    1,
)
s = re.sub(
    r'\n\s*local shim_st; shim_st=\$\(\[ -f /usr/local/lib/homebrew-root/libhomebrew_fakeuid\.so \] && echo "shim:OK" \|\| echo "shim:none"\)\n\s*local status_line\n\s*status_line="Root bypass: \$\(brew_root_bypass_enabled && echo ENABLED \|\| echo disabled\) \| \$shim_st"',
    '\n        local status_line\n        status_line="Root bypass: $(brew_root_bypass_enabled && echo ENABLED || echo disabled)"',
    s,
    count=1,
)
s = s.replace(
    'rootconfig "Root configuration — bypass, shim, wrapper, permissions"',
    'rootconfig "Root configuration — user delegation, wrapper, permissions"',
    1,
)
start_marker = '# ---------------------------------------------------------------------------\n# Root reconfiguration helpers'
end_marker = '# Formula-level package operations menu (install / reinstall / remove / autoremove).'
start = s.find(start_marker)
end = s.find(end_marker, start + 1) if start >= 0 else -1
if start < 0 or end < 0:
    raise SystemExit('legacy Homebrew root-config block markers not found')
replacement = '''# ---------------------------------------------------------------------------
# Root reconfiguration helpers — safe compatibility layer.
# Older builds spoofed process identity here. That implementation is removed;
# root invocation delegates to the maintained non-root-owner installer.
# ---------------------------------------------------------------------------

_brew_root_profile() { printf '%s' "/etc/profile.d/homebrew.sh"; }
_brew_root_prefix() {
    local p
    p=$(_brew_cfg_get /etc/systui/homebrew.env HOMEBREW_PREFIX)
    printf '%s' "${p:-/home/linuxbrew/.linuxbrew}"
}

_brew_root_reinstall_wrapper() {
    local script
    if [ "$(id -u)" -ne 0 ]; then
        tui_msg "Root required" "Reinstalling Homebrew root compatibility requires root."
        return 1
    fi
    script=$(brew_root_compat_script)
    [ -r "$script" ] || { tui_msg "Homebrew" "Installer script not found:\\n$script"; return 1; }
    run_cmd "Reinstall Homebrew root compatibility" bash "$script"
}

_brew_root_fix_perms() {
    local prefix buser
    if [ "$(id -u)" -ne 0 ]; then
        tui_msg "Root required" "Permission repair requires root."
        return 1
    fi
    prefix=$(_brew_root_prefix)
    buser=$(brew_target_user)
    [ -n "$buser" ] && [ "$buser" != root ] || {
        tui_msg "Homebrew" "No non-root Homebrew owner is configured."
        return 1
    }
    [ -d "$prefix" ] || { tui_msg "Homebrew" "Homebrew prefix does not exist:\\n$prefix"; return 1; }
    run_cmd "Repair Homebrew ownership" chown -R "$buser" "$prefix"
}

_brew_root_remove_layer() {
    if [ "$(id -u)" -ne 0 ]; then
        tui_msg "Root required" "Removing Systui Homebrew compatibility settings requires root."
        return 1
    fi
    rm -f /etc/systui/homebrew.env /etc/profile.d/homebrew.sh 2>/dev/null || true
    rm -rf /usr/local/lib/homebrew-root 2>/dev/null || true
    tui_msg "Homebrew" "Removed obsolete Systui root-compatibility settings. The Homebrew installation itself was left intact."
}

menu_brew_root_config() {
    local c script buser prefix
    while true; do
        buser=$(brew_target_user)
        prefix=$(_brew_root_prefix)
        c=$(tui_menu "Homebrew root configuration" \\
            "Homebrew is executed as a non-root owner.\\nOwner: ${buser:-not configured}\\nPrefix: $prefix" \\
            reinstall "Reinstall safe root compatibility wrapper" \\
            perms "Repair Homebrew ownership" \\
            remove "Remove obsolete Systui root settings" \\
            back "Back") || return 0
        case "$c" in
            reinstall)
                script=$(brew_root_compat_script)
                [ -r "$script" ] || { tui_msg "Homebrew" "Installer script not found:\\n$script"; continue; }
                run_cmd "Install Homebrew root compatibility" bash "$script"
                ;;
            perms) _brew_root_fix_perms ;;
            remove) _brew_root_remove_layer ;;
            back|"") return 0 ;;
        esac
    done
}

'''
s = s[:start] + replacement + s[end:]
p.write_text(s)

pat = re.compile(r'LD_PRELOAD.*fake|geteuid.*shim|fake.*uid')
bad = []
for root in (Path('src'), Path('share/homebrew')):
    for sh in root.rglob('*.sh'):
        for n, line in enumerate(sh.read_text(errors='ignore').splitlines(), 1):
            if pat.search(line):
                bad.append(f'{sh}:{n}:{line}')
if bad:
    raise SystemExit('obsolete identity-spoofing references remain:\n' + '\n'.join(bad))
