from pathlib import Path
import re

root = Path('src/features/rootfs.sh')
s = root.read_text()

# Remove the interactive build preset stage. The builder continues using the
# existing preset-to-package mapping, but the selected preset is always minimal.
pat = re.compile(
    r'    preset=\$\(tui_radio "Rootfs Builder 6/13".*?\)\s*\|\|\s*return 0\n',
    re.S,
)
replacement = '''    # Rootfs builds default to the smallest viable base. Distro/backend-specific\n    # requirements are added later by the existing init/backend logic.\n    preset=minimal\n'''
s, n = pat.subn(replacement, s, count=1)
if n != 1:
    raise SystemExit(f'build preset block replacement count={n}')

old = '''        local _choice\n        _choice=$(tui_menu "Rootfs Bootstrap Tools" \\\n            "Select a package to install, uninstall, or configure:" \\\n            "${_items[@]}" "back" "← Back") || return 0\n\n        [ "$_choice" = "back" ] && return 0\n        [ -z "$_choice" ] && continue\n\n        # Show submenu for selected package\n        _menu_bs_package "$_choice" "$_BS_PKGS" "$_BS_CATALOGUE" || true\n'''
new = '''        local _choice\n        _choice=$(tui_menu "Rootfs Bootstrap Tools" \\\n            "Installed state includes Bedrock strata when present. Choose multi-install to select several tools with SPACE." \\\n            multi "Install multiple bootstrap tools (SPACE to select)" \\\n            "${_items[@]}" "back" "← Back") || return 0\n\n        [ "$_choice" = "back" ] && return 0\n        [ -z "$_choice" ] && continue\n\n        if [ "$_choice" = "multi" ]; then\n            local _selected _pkg _state\n            local -a _check_items=()\n            while IFS='|' read -r _tag _lbl _desc; do\n                [ -n "$_tag" ] || continue\n                if rootfs_bs_installed "$_tag"; then\n                    _state="installed"\n                else\n                    _state="not installed"\n                fi\n                _check_items+=("$_tag" "$_lbl — $_state" off)\n            done <<< "$_BS_CATALOGUE"\n\n            _selected=$(tui_check "Install bootstrap tools" \\\n                "SPACE selects one or more tools; ENTER installs every selected missing tool:" \\\n                "${_check_items[@]}") || continue\n            _selected=${_selected//\\\"/}\n            [ -n "${_selected//[[:space:]]/}" ] || continue\n\n            for _tag in $_selected; do\n                if rootfs_bs_installed "$_tag"; then\n                    continue\n                fi\n                _pkg=$(_bs_pkg "$_tag")\n                _bs_install "$_tag" "$_pkg" "$_BS_PKGS" || true\n            done\n            continue\n        fi\n\n        # Show submenu for a selected package for uninstall/configuration or a\n        # single-tool install.\n        _menu_bs_package "$_choice" "$_BS_PKGS" "$_BS_CATALOGUE" || true\n'''
if old not in s:
    raise SystemExit('bootstrap menu choice block not found')
s = s.replace(old, new, 1)
root.write_text(s)

test = Path('tests/test-regressions.sh')
t = test.read_text()
marker = '# Rootfs bootstrap tools menu checks\n'
addition = '''# Rootfs build preset and bootstrap multi-install behavior\ncheck "rootfs builder no longer prompts for a build preset" not_contains \\\n    "$PROJECT_DIR/src/features/rootfs.sh" "Build preset (SPACE to select):"\ncheck "rootfs builder automatically uses the minimal preset" contains \\\n    "$PROJECT_DIR/src/features/rootfs.sh" "preset=minimal"\ncheck "bootstrap menu exposes multi-select installation" contains \\\n    "$PROJECT_DIR/src/features/rootfs.sh" "Install multiple bootstrap tools (SPACE to select)"\ncheck "bootstrap multi-install uses tui_check" contains \\\n    "$PROJECT_DIR/src/features/rootfs.sh" 'tui_check "Install bootstrap tools"'\ncheck "bootstrap multi-install uses Bedrock-aware installed detection" contains \\\n    "$PROJECT_DIR/src/features/rootfs.sh" 'if rootfs_bs_installed "$_tag"; then'\n\n'''
if addition not in t:
    if marker not in t:
        raise SystemExit('bootstrap regression marker not found')
    t = t.replace(marker, addition + marker, 1)
test.write_text(t)
