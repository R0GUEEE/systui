#!/usr/bin/env python3
from pathlib import Path

p = Path('tests/test-regressions.sh')
s = p.read_text()
old = '''check "brew installer defines LD_PRELOAD shim" contains \\
    "$PROJECT_DIR/share/homebrew/install-homebrew-root.sh" "libhomebrew_fakeuid.so"'''
new = '''check "brew installer does not use LD_PRELOAD UID spoofing" not_contains \\
    "$PROJECT_DIR/share/homebrew/install-homebrew-root.sh" "libhomebrew_fakeuid.so"'''
if s.count(old) != 1:
    raise SystemExit(f'expected one obsolete Homebrew check, found {s.count(old)}')
p.write_text(s.replace(old, new, 1))
