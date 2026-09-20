#!/usr/bin/env python3
"""Static audit of systui menus.

For every menu widget call site (literal arguments only) extract the option
tags, then compare them with the case arms of the nearest enclosing dispatch
loop.  Reports:
  * menu entries whose tag has no case handler  (dead entry / "nothing happens")
  * case handlers whose tag is never offered    (unreachable code)
  * functions invoked by menus that are not defined anywhere
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FEATURES = ROOT / "src" / "features"
CORE = ROOT / "src" / "core"

WIDGETS = ("tui_menu_no_tags", "tui_menu", "tui_radio", "tui_check")

FUNC_DEF = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{?\s*$", re.M)
CALL = re.compile(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*(?:\(\))?")
ARG = re.compile(r'"((?:[^"\\]|\\.)*)"|\'([^\']*)\'|(\S+)')


def files():
    out = []
    for base in (FEATURES, CORE):
        out.extend(sorted(base.glob("*.sh")))
    return out


def read(p: Path) -> str:
    return p.read_text(errors="ignore")


def shlex_args(text: str) -> list[str] | None:
    """Split a widget argument list into raw tokens (quoted or bare)."""
    args, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c in " \t\n\\":
            if c == "\\":
                i += 2
                continue
            i += 1
            continue
        if c == '"':
            j, buf = i + 1, []
            while j < n:
                if text[j] == "\\":
                    buf.append(text[j + 1] if j + 1 < n else "")
                    j += 2
                    continue
                if text[j] == '"':
                    break
                buf.append(text[j])
                j += 1
            args.append("Q" + "".join(buf))
            i = j + 1
            continue
        if c == "'":
            j = text.find("'", i + 1)
            args.append("Q" + text[i + 1:j])
            i = j + 1
            continue
        j = i
        while j < n and text[j] not in " \t\n":
            j += 1
        args.append(text[i:j])
        i = j
    return args


def widget_calls(src: str):
    """Yield (lineno, widget, args) for widget calls with balanced args."""
    for m in re.finditer(r"\b(" + "|".join(WIDGETS) + r")\b", src):
        widget = m.group(1)
        i = m.end()
        if i >= len(src) or src[i] not in " \t":
            continue
        depth = 0
        j = i
        while j < len(src):
            c = src[j]
            if c == "\\":
                j += 2
                continue
            if c == '"':
                q, j = c, j + 1
                inner = 0
                while j < len(src):
                    ch = src[j]
                    if ch == "\\":
                        j += 2
                        continue
                    if ch == "$" and j + 1 < len(src) and src[j + 1] == "(":
                        inner += 1
                        j += 2
                        continue
                    if inner and ch == ")":
                        inner -= 1
                        j += 1
                        continue
                    if ch == q and inner == 0:
                        j += 1
                        break
                    j += 1
                continue
            if c == "'":
                j = src.find("'", j + 1)
                j = len(src) if j < 0 else j + 1
                continue
            if c == "$" and j + 1 < len(src) and src[j + 1] == "(":
                depth += 1
                j += 2
                continue
            if c == "(":
                depth += 1
            elif c == ")":
                if depth == 0:
                    break
                depth -= 1
            elif c == "\n" and depth == 0:
                break
            j += 1
        body = src[i:j]
        body = re.sub(r"^\s*", "", body)
        if not body.strip():
            continue
        # Determine which variable captures this widget's output so dispatch
        # arms can be matched to the right `case` statement.
        line_start = src.rfind("\n", 0, m.start()) + 1
        prefix = src[line_start:m.start()]
        var = ""
        cap = re.search(r"\b([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\$\(\s*$", prefix)
        if cap:
            var = cap.group(1)
        else:
            cap = re.search(r"tui_capture_menu\s+([A-Za-z_][A-Za-z0-9_]*)\s+$", prefix)
            if cap:
                var = cap.group(1)
        yield src.count("\n", 0, m.start()) + 1, widget, body, var


def menu_tags(body: str, widget: str):
    """Return literal option tags, or None when the list is dynamic."""
    args = shlex_args(body)
    if not args:
        return None
    step = 2 if widget in ("tui_menu", "tui_menu_no_tags") else 3
    head = 2 if widget in ("tui_menu", "tui_menu_no_tags") else 2
    # tui_radio "title" "text" tag "label" on tag "label" off ...
    if widget == "tui_menu_no_tags":
        pass
    elif widget == "tui_radio":
        step = 3
    elif widget == "tui_check":
        step = 3
    opts = args[head:]
    if len(opts) % step != 0:
        return None
    dynamic = False
    for tok in opts:
        if tok.startswith("Q"):
            if "$" in tok or "`" in tok:
                dynamic = True
            continue
        if "$" in tok or "`" in tok or tok in ("||", "&&", "|", ";", "then", "else", "fi"):
            dynamic = True
    if dynamic:
        return None
    tags = []
    for k in range(0, len(opts), step):
        tok = opts[k]
        if tok.startswith("Q"):
            continue
        if tok.startswith('"') or tok.startswith("'"):
            continue
        if not re.fullmatch(r"[A-Za-z0-9_.:*|+/-]+", tok):
            return None
        tags.append(tok)
    return tags or None


def enclosing_function(lines, lineno):
    name = None
    for i in range(lineno - 1, -1, -1):
        m = FUNC_DEF.match(lines[i])
        if m:
            name = m.group(1)
            break
    return name


def function_span(lines, name):
    start = None
    for i, line in enumerate(lines):
        if re.match(r"^\s*" + re.escape(name) + r"\s*\(\)", line):
            start = i
            break
    if start is None:
        return None
    for j in range(start, len(lines)):
        if re.match(r"^\}\s*$", lines[j]):
            return start, j
    return start, len(lines) - 1


def direct_handlers(lines, start, end, var):
    """Tags handled by [ \"$var\" = tag ] comparisons, outside a case block."""
    text = "\n".join(lines[start:end + 1])
    out = set()
    pat = re.compile(r"\[\s+\"?\$\{?" + re.escape(var.lstrip("$")) + r"\}?\"?\s*(?:=|==)\s*\"?([A-Za-z0-9_.:*+/-]+)\"?\s*\]")
    for m in pat.finditer(text):
        out.add(m.group(1))
    return out


def case_tags(lines, start, end, var):
    """Collect case patterns for `case $var in` inside a span.

    Nested `case ... esac` blocks are skipped so their arms and `;;` markers
    never leak into the outer pattern list.
    """
    text = "\n".join(lines[start:end + 1])
    tags = set()
    pat = re.compile(r"\bcase\s+\"?\$\{?" + re.escape(var.lstrip("$")) + r"\}?\"?[^\n]*?\bin\b")
    for m in pat.finditer(text):
        seg = text[m.end():]
        depth = 1
        i, n = 0, len(seg)
        buf = []

        def flush(chunk):
            # A chunk is the text between `;;` markers: "pat1 | pat2) body".
            # Drop comment-only lines first: their text can contain parentheses
            # (e.g. `# eval "$(...)"`) that would otherwise be mistaken for the
            # end of the pattern list.
            lines_ = [ln for ln in chunk.split("\n") if not ln.strip().startswith("#")]
            body = "\n".join(lines_)
            end = len(body)
            for i, ch in enumerate(body):
                if ch == ")" and (i + 1 >= len(body) or body[i + 1] in " \t\n"):
                    end = i
                    break
            head = body[:end]
            for p in head.split("|"):
                p = p.strip().strip('"').strip("'")
                if p and not p.startswith("$") and p not in ("", "*", ")"):
                    tags.add(p)

        while i < n:
            if seg.startswith("case", i) and re.match(r"case\b", seg[i:]):
                depth += 1
                i += 4
                continue
            if seg.startswith("esac", i):
                depth -= 1
                i += 4
                if depth == 0:
                    flush("".join(buf))
                    break
                continue
            if depth == 1 and seg.startswith(";;", i):
                flush("".join(buf))
                buf = []
                i += 2
                continue
            buf.append(seg[i])
            i += 1
    return tags


def load_order_index():
    """Map feature filename -> position in the load manifest."""
    manifest = FEATURES / ".load-order"
    order = {}
    if manifest.is_file():
        for i, line in enumerate(manifest.read_text(errors="ignore").splitlines()):
            rel = line.strip()
            if not rel or rel.startswith("#"):
                continue
            order[rel] = i
    return order


def final_definitions(srcs, order):
    """function name -> (path, lineno) for the last-loaded definition."""
    latest: dict[str, tuple[int, int, Path]] = {}
    for path in srcs:
        idx = order.get(path.name, -1)
        src = srcs[path]
        for m in re.finditer(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{?\s*$", src, re.M):
            name = m.group(1)
            lineno = src.count("\n", 0, m.start()) + 1
            key = (idx, lineno)
            cur = latest.get(name)
            if cur is None or key > (cur[0], cur[1]):
                latest[name] = (idx, lineno, path)
    return {n: (p, ln) for n, (i, ln, p) in latest.items()}


def main():
    check_mode = "--check" in sys.argv
    srcs = {p: read(p) for p in files()}
    order = load_order_index()
    final_defs = final_definitions(srcs, order)
    defined = set(final_defs)

    defined.update({
        # builtins / engine helpers referenced by menus
        "printf", "echo", "true", "false", "return", "set", "shift", "unset",
        "declare", "local", "eval", "export", "read", "case", "while", "for",
        "if", "then", "else", "fi", "do", "done", "esac", "source", "cd",
        "exec", "command", "type", "test", "[", "[[", "sleep", "kill", "wait",
    })

    dead, unreachable, calls_missing = [], [], []

    def final_here(fn, path, lineno):
        entry = final_defs.get(fn)
        if not entry:
            return False
        fpath, fline = entry
        return fpath == path and fline <= lineno

    # First pass: per-function map of literal widget option tags.
    func_calls: dict[tuple[Path, str], list[tuple[int, set[str]]]] = {}
    call_index: dict[tuple[Path, str], list[int]] = {}
    for path, src in srcs.items():
        lines = src.splitlines()
        for lineno, widget, body, var in widget_calls(src):
            tags = menu_tags(body, widget)
            if not tags:
                continue
            fn = enclosing_function(lines, lineno)
            if not fn or not final_here(fn, path, lineno):
                continue
            key = (path, fn)
            func_calls.setdefault(key, []).append((lineno, set(tags), var))
            call_index.setdefault(key, []).append(lineno)

    for path, src in srcs.items():
        lines = src.splitlines()
        for lineno, widget, body, var in widget_calls(src):
            tags = menu_tags(body, widget)
            if not tags:
                continue
            fn = enclosing_function(lines, lineno)
            if not fn or not final_here(fn, path, lineno):
                continue
            span = function_span(lines, fn)
            if not span:
                continue
            span = (max(span[0], final_defs[fn][1] - 1), span[1])
            # Only consider dispatch arms that follow this widget call, for the
            # variable this widget result is actually captured into.
            cstart = max(span[0], lineno - 1)
            varnames = [v for v in (var, "c", "choice") if v]
            handled = set()
            for v in varnames:
                handled |= case_tags(lines, cstart, span[1], v)
                handled |= direct_handlers(lines, cstart, span[1], v)
            # Suppress only when the captured value is consumed as an argument
            # to a command (e.g. `useradd -s "$sh_"`), not when it is merely
            # re-tested by case/[ ] dispatch, which is what we audit.
            if var:
                consumed = False
                for line in lines[lineno:span[1] + 1]:
                    probe = line.strip()
                    if not probe or probe.startswith("case ") or probe.startswith("[") or probe.startswith("[["):
                        continue
                    if re.search(r'"\$\{?' + re.escape(var) + r'\}?"', probe) and not re.match(r"^\s*\S+=\$", probe):
                        consumed = True
                        break
                if consumed:
                    continue
            for t in tags:
                if t in ("back", "cancel", "skip", "quit"):
                    continue
                if not handled:
                    continue
                if t not in handled:
                    dead.append((path.relative_to(ROOT), lineno, fn, t))

    # Unreachable arms: compare the function's whole set of offered tags against
    # arms in its dispatch blocks.
    for (path, fn), calls in func_calls.items():
        source = srcs[path]
        lines = source.splitlines()
        span = function_span(lines, fn)
        if not span:
            continue
        span = (max(span[0], final_defs[fn][1] - 1), span[1])
        offered = set()
        varnames = set()
        for _, tags, var in calls:
            offered |= tags
            if var:
                varnames.add(var)
        handled = set()
        for v in varnames or {"c"}:
            handled |= case_tags(lines, span[0], span[1], v)
        for h in handled:
            if h in offered:
                continue
            if h in ("back", "cancel", "skip", "quit", "*", "''", '""'):
                continue
            if re.fullmatch(r"[A-Za-z0-9_.:*|+/-]+", h):
                unreachable.append((path.relative_to(ROOT), calls[0][0], fn, h))

    # Called-but-undefined helpers used in menu dispatch bodies
    for path, src in srcs.items():
        for lineno, widget, body, var in widget_calls(src):
            pass

    # Dispatch targets that are not defined anywhere.
    known = set(defined)
    known |= {
        "apt", "apk", "pacman", "dnf", "yum", "zypper", "xbps-install", "emerge",
        "apt-get", "dpkg", "rpm", "systemctl", "service", "sh", "bash", "curl",
        "wget", "git", "sed", "awk", "grep", "find", "mount", "umount", "chmod",
        "chown", "ln", "rm", "mv", "cp", "ls", "mkdir", "touch", "printf", "echo",
        "read", "local", "return", "exit", "true", "false", "set", "unset",
        "export", "declare", "eval", "source", "shift", "case", "for", "while",
        "if", "then", "else", "fi", "do", "done", "esac", "break", "continue",
        "zcat", "zgrep", "head", "tail", "sort", "cut", "tr", "wc", "tee",
        "rmdir", "ln", "install", "test", "[", "[[", ":", "clear", "hostname",
        "date", "sleep", "kill", "id", "getent", "usermod", "useradd", "userdel",
        "chage", "passwd", "visudo", "openssl", "python3", "pip", "npm", "node",
        "go", "cargo", "gem", "composer", "brew", "nix", "snap", "flatpak", "brl",
    }
    missing_calls = []
    for path, src in srcs.items():
        lines = src.splitlines()
        for lineno, widget, body, var in widget_calls(src):
            tags = menu_tags(body, widget)
            if not tags:
                continue
            fn = enclosing_function(lines, lineno)
            if not fn:
                continue
            refs = re.findall(r"tui_call_menu\s+([A-Za-z_][A-Za-z0-9_]*)", "\n".join(lines[lineno - 1:lineno + 40]))
            for r in refs:
                if r not in known:
                    missing_calls.append((path.relative_to(ROOT), lineno, fn, r))

    def emit(title, rows):
        print(f"\n=== {title} ({len(rows)}) ===")
        for r in rows:
            print("  %s:%s  %s -> %s" % r)

    emit("menu entries with no case handler (dead entries)", dead)
    emit("case handlers never offered by the menu", unreachable)
    emit("tui_call_menu targets that are not defined", sorted(set(missing_calls)))

    print("\n=== summary ===")
    print(f"features: {len(srcs)}  defined functions: {len(defined)}")
    total = len(dead) + len(unreachable) + len(set(missing_calls))
    print(f"dead entries: {len(dead)}  unreachable handlers: {len(unreachable)}  missing dispatch targets: {len(set(missing_calls))}")
    if check_mode:
        return 1 if total else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
