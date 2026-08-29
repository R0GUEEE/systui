#!/usr/bin/env python3
from pathlib import Path

p = Path("src/core/config.sh")
s = p.read_text()
old = '            case "$_rel" in \'\'|\'#\'*) continue ;; esac'
new = '            case "$_rel" in ""|\\#*) continue ;; esac'
if s.count(old) != 1:
    raise SystemExit(f"expected exactly one run_strict manifest case, found {s.count(old)}")
p.write_text(s.replace(old, new, 1))
