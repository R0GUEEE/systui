#!/usr/bin/env python3
"""Rewrite `eval "$(declare -f FN | sed '1s/^FN...()/NEW ()/')"` into pure bash.

Every such site forks a subshell plus sed during startup, purely to rename a
function body. Bash parameter expansion does the same work with no fork:

    _systui_alias_def=$(declare -f fn)
    _systui_alias_def=${_systui_alias_def/#fn ()/new_fn ()}
    eval "$_systui_alias_def"

Only the exact single-line rename form is rewritten; anything else (multi-line
awk filters, conditional edits) is left untouched.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

SITE = re.compile(
    r'^(?P<indent>[ \t]*)eval "\$\(declare -f (?P<old>[A-Za-z_][A-Za-z0-9_]*)'
    r" \| sed '(?P<expr>1s/\^(?P<old2>[A-Za-z_][A-Za-z0-9_]*)"
    r"(?:\[\[:space:\]\]\*)?\(\)/(?P<new>[A-Za-z_][A-Za-z0-9_]*) ?\(\)/)'\)\"[ \t]*$"
)


def rewrite(path: Path) -> int:
    lines = path.read_text().splitlines(keepends=True)
    out, changed = [], 0
    for line in lines:
        stripped = line.rstrip("\n")
        m = SITE.match(stripped)
        if not m or m.group("old") != m.group("old2"):
            out.append(line)
            continue
        indent = m.group("indent")
        old = m.group("old")
        new = m.group("new")
        out.append(f"{indent}_systui_alias_def=$(declare -f {old})\n")
        out.append(f"{indent}_systui_alias_def=${{_systui_alias_def/#{old} ()/{new} ()}}\n")
        out.append(f'{indent}eval "$_systui_alias_def"\n')
        out.append(f"{indent}unset _systui_alias_def\n")
        changed += 1
    if changed:
        path.write_text("".join(out))
    return changed


def main() -> int:
    targets = sorted(ROOT.glob("src/features/*.sh"))
    total = 0
    for path in targets:
        n = rewrite(path)
        if n:
            print(f"{n:3d}  {path.relative_to(ROOT)}")
            total += n
    print(f"\nrewrote {total} fork-based function renames")
    return 0


if __name__ == "__main__":
    sys.exit(main())
