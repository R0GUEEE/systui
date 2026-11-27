#!/usr/bin/env python3
"""Audit share/systui-deps.tsv and keep docs/DEPENDENCIES.md in sync.

The manifest is the single source of truth for what `install.sh` installs and
what `tools/deps-verify.sh` checks. This tool makes sure it stays complete for
every supported distribution and that the generated documentation says exactly
what the manifest says.

Usage:
    tools/deps-audit.py            audit and report
    tools/deps-audit.py --check    audit, and fail if the docs are stale
    tools/deps-audit.py --write    rewrite docs/DEPENDENCIES.md from the manifest
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "share" / "systui-deps.tsv"
DOCS = ROOT / "docs" / "DEPENDENCIES.md"

FAMILIES = [
    ("apt", "Debian, Ubuntu, Devuan, Kali, Mint", "apt"),
    ("apk", "Alpine", "apk"),
    ("pacman", "Arch, Manjaro, EndeavourOS, Arch ARM", "pacman"),
    ("dnf", "Fedora, RHEL, CentOS, Rocky, Alma", "dnf"),
    ("xbps", "Void", "xbps"),
    ("emerge", "Gentoo", "emerge"),
]

# Commands systui's own startup path cannot work without. They must appear as
# *mandatory* (before the "|") somewhere in the manifest.
REQUIRED_COMMANDS = [
    "bash", "dialog", "grep", "sed", "awk", "find", "xargs", "tar", "gzip",
    "gunzip", "xz", "unzip", "curl", "ps", "free", "mount", "umount", "less",
    "id", "mktemp", "head", "tr", "cut", "sort", "tee", "chmod", "rm", "date",
    "env", "stat", "readlink", "dirname", "basename", "diff", "tput", "clear",
]

PACKAGE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+@/-]*$")
COMMAND_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")

INSTALL_TEMPLATES = {
    "apt": "sudo apt-get update && sudo apt-get install -y --no-install-recommends {pkgs}",
    "apk": "sudo apk add {pkgs}",
    "pacman": "sudo pacman -S --needed --noconfirm {pkgs}",
    "dnf": "sudo dnf install -y {pkgs}",
    "zypper": "sudo zypper --non-interactive install {pkgs}",
    "xbps": "sudo xbps-install -Sy {pkgs}",
    "emerge": "sudo emerge --noreplace {pkgs}",
}


class Row:
    def __init__(self, canonical, packages, tier, commands, advisory, lineno):
        self.canonical = canonical
        self.packages = packages
        self.tier = tier
        self.commands = commands
        self.advisory = advisory
        self.lineno = lineno


def parse_manifest():
    rows, errors = [], []
    for number, line in enumerate(MANIFEST.read_text().splitlines(), 1):
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) not in (9, 10):
            errors.append(f"line {number}: expected 9 or 10 tab-separated fields, found {len(fields)}")
            continue
        canonical, apt, apk, pacman, dnf, xbps, emerge, tier, commands = fields[:9]
        zypper = fields[9] if len(fields) == 10 else ""
        packages = {"apt": apt, "apk": apk, "pacman": pacman, "dnf": dnf, "xbps": xbps, "emerge": emerge}
        for family, value in packages.items():
            if not value.strip():
                errors.append(f"line {number} ({canonical}): empty {family} package")
            elif value != "-":
                for single in value.split("+"):
                    if not PACKAGE_RE.match(single):
                        errors.append(f"line {number} ({canonical}): invalid {family} package {single!r}")
        if zypper and zypper != "-" and not PACKAGE_RE.match(zypper):
            errors.append(f"line {number} ({canonical}): invalid zypper package {zypper!r}")
        if tier != "core":
            errors.append(f"line {number} ({canonical}): unsupported tier {tier!r} (only 'core' is installed)")
        mandatory, _, advisory = commands.partition("|")
        cmd_list = [c for c in mandatory.split(",") if c and c != "-"]
        adv_list = [c for c in advisory.split(",") if c]
        for cmd in cmd_list + adv_list:
            if not COMMAND_RE.match(cmd):
                errors.append(f"line {number} ({canonical}): invalid command {cmd!r}")
        row = Row(canonical, packages, tier, cmd_list, adv_list, number)
        row.zypper = zypper
        rows.append(row)

    seen = {}
    for row in rows:
        if row.canonical in seen:
            errors.append(f"line {row.lineno}: duplicate package name {row.canonical!r} (first on line {seen[row.canonical]})")
        else:
            seen[row.canonical] = row.lineno

    mandatory = {c for row in rows for c in row.commands}
    for cmd in REQUIRED_COMMANDS:
        if cmd not in mandatory:
            errors.append(f"required command {cmd!r} is not provided as a mandatory command by any row")
    return rows, errors


def install_line(family, rows):
    pkgs = []
    for row in rows:
        if family == "zypper":
            value = getattr(row, "zypper", "") or row.packages["dnf"]
        else:
            value = row.packages[family]
        if value == "-":
            continue
        pkgs.extend(value.split("+"))
    template = INSTALL_TEMPLATES[family]
    return template.format(pkgs=" ".join(pkgs))


def render(rows):
    lines = []
    lines.append("# Dependencies")
    lines.append("")
    lines.append("What systui needs on a Linux host, generated from")
    lines.append("[`share/systui-deps.tsv`](../share/systui-deps.tsv) — the same manifest")
    lines.append("`install.sh` installs from and `tools/deps-verify.sh` checks against.")
    lines.append("")
    lines.append("```sh")
    lines.append("sh install.sh --print-deps    # exact install command for this host")
    lines.append("sh install.sh --deps-only     # install and verify the set below")
    lines.append("sh tools/deps-verify.sh apt   # check the declared commands are present")
    lines.append("```")
    lines.append("")
    lines.append("The installer and updater are plain POSIX sh: `sh`, `dash`, `ash`/BusyBox,")
    lines.append("`bash`, `zsh`, `ksh` and `mksh` all work, and Bash is not required to")
    lines.append("install. systui itself runs on Bash — it is the first row below, so the")
    lines.append("installer puts it in place before the TUI is ever started.")
    lines.append("")
    lines.append("Only the `core` tier is installed up front. Everything else systui can")
    lines.append("use (compilers, language managers, extra tooling) is installed on demand")
    lines.append("from the menus, and a package a distribution does not carry is reported")
    lines.append("and skipped rather than aborting the install.")
    lines.append("")
    lines.append("## One-line install per distribution")
    lines.append("")
    for family, title, _pm in FAMILIES:
        lines.append(f"- **{title}**")
        lines.append("")
        lines.append("  ```sh")
        lines.append("  " + install_line(family, rows))
        lines.append("  ```")
        lines.append("")
    lines.append("- **openSUSE, SLES**")
    lines.append("")
    lines.append("  ```sh")
    lines.append("  " + install_line("zypper", rows))
    lines.append("  ```")
    lines.append("")
    lines.append("openSUSE shares most names with the dnf column but not all: the")
    lines.append("manifest carries an optional tenth column that overrides the dnf name")
    lines.append("where zypper needs one (`ncurses-utils`, `procps`).")
    lines.append("")
    lines.append("## Package map")
    lines.append("")
    lines.append("| systui needs | apt | apk | pacman | dnf / zypper | xbps | emerge |")
    lines.append("| --- | --- | --- | --- | --- | --- | --- |")
    for row in rows:
        cells = [row.canonical] + [row.packages[f] for f, _, _ in FAMILIES]
        lines.append("| " + " | ".join(f"`{c}`" if c != "-" else "—" for c in cells) + " |")
    lines.append("")
    lines.append("A `+` joins packages that a distribution splits (Alpine ships `util-linux`")
    lines.append("in `util-linux` + `util-linux-misc`); both are installed.")
    lines.append("")
    lines.append("## Commands each package must provide")
    lines.append("")
    lines.append("| package | mandatory | advisory |")
    lines.append("| --- | --- | --- |")
    for row in rows:
        need = ", ".join(f"`{c}`" for c in row.commands) or "—"
        extra = ", ".join(f"`{c}`" for c in row.advisory) or "—"
        lines.append(f"| `{row.canonical}` | {need} | {extra} |")
    lines.append("")
    lines.append("Advisory commands are reported by `deps-verify.sh` and `install.sh")
    lines.append("--deps-only` but never fail an install: a distribution may ship an older")
    lines.append("or split package without them.")
    lines.append("")
    lines.append("## Optional, installed on demand")
    lines.append("")
    lines.append("| tool | why systui wants it |")
    lines.append("| --- | --- |")
    for tool, why in [
        ("git", "`update.sh` (it installs git itself before cloning)"),
        ("wget", "fallback fetcher when curl is absent"),
        ("iproute2 / ip", "network configuration menus"),
        ("shadow / passwd", "user and password management"),
        ("findmnt, lsblk", "storage views on systems whose util-linux ships them"),
        ("tmux, zsh, fish, starship", "shell and terminal features"),
        ("qemu-user-static", "foreign-architecture rootfs builds"),
        ("docker / podman / lxc", "containers & virtualization menus"),
    ]:
        lines.append(f"| `{tool}` | {why} |")
    lines.append("")
    lines.append("## Verification in CI")
    lines.append("")
    lines.append("`.github/workflows/deps.yml` installs the manifest set inside Debian,")
    lines.append("Ubuntu, Alpine, Arch, Fedora, openSUSE and Void containers and runs")
    lines.append("`tools/deps-verify.sh` there, so a wrong or missing package name fails CI")
    lines.append("instead of a user's install.")
    lines.append("")
    return "\n".join(lines)


def main(argv):
    check = "--check" in argv
    write = "--write" in argv
    rows, errors = parse_manifest()

    for message in errors:
        print("manifest: " + message, file=sys.stderr)

    text = render(rows)
    stale = False
    if DOCS.exists():
        stale = DOCS.read_text() != text
    else:
        stale = True

    if write and not errors:
        DOCS.write_text(text)
        print(f"wrote {DOCS.relative_to(ROOT)} ({len(rows)} packages)")

    if check:
        if stale and not write:
            print("docs/DEPENDENCIES.md is out of date; run tools/deps-audit.py --write", file=sys.stderr)
        if errors or (stale and not write):
            return 1

    if not write and not check:
        print(f"packages: {len(rows)}  errors: {len(errors)}  docs_current: {not stale}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
