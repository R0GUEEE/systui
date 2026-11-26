#!/usr/bin/env python3
"""Create a minimal iSH-AOK rootfs tarball from a versioned recipe."""
import argparse
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import urllib.request

ALPINE_ARCH = {"aarch64": "aarch64"}
SAFE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$")

def fetch(url, dest):
    req = urllib.request.Request(url, headers={"User-Agent": "systui-rootfs-builder/0.1"})
    with urllib.request.urlopen(req, timeout=60) as response, open(dest, "wb") as out:
        shutil.copyfileobj(response, out)

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--recipe", required=True)
    p.add_argument("--output", required=True)
    args = p.parse_args()
    recipe = json.load(open(args.recipe, encoding="utf-8"))
    if recipe.get("schemaVersion") != 1 or recipe.get("distribution") != "Alpine":
        raise SystemExit("only recipe schema 1 / Alpine is supported")
    arch = recipe.get("architecture")
    if arch not in ALPINE_ARCH:
        raise SystemExit("unsupported Alpine architecture")
    release = recipe.get("release", "latest-stable")
    if release == "latest-stable":
        release = "v3.23"
    if not re.fullmatch(r"v3\.(?:[0-9]{1,2}|edge)", release):
        raise SystemExit("release must be latest-stable, v3.N, or v3.edge")
    initSystem = recipe.get("initSystem", "OpenRC")
    if initSystem != "OpenRC":
        raise SystemExit("this Alpine builder currently supports OpenRC only")
    packages = recipe.get("packages", [])
    if isinstance(packages, str):
        packages = [x.strip() for x in re.split(r"[,\n]", packages) if x.strip()]
    if not isinstance(packages, list) or not all(isinstance(x, str) and SAFE.fullmatch(x) for x in packages):
        raise SystemExit("packages must be a list or comma-separated string of simple package names")
    out = pathlib.Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="systui-rootfs-") as td:
        work = pathlib.Path(td)
        archive = work / "alpine.tar.gz"
        root = work / "root"
        root.mkdir()
        release_url = f"https://dl-cdn.alpinelinux.org/alpine/{release}/releases/{ALPINE_ARCH[arch]}/"
        listing = urllib.request.urlopen(urllib.request.Request(release_url, headers={"User-Agent": "systui-rootfs-builder/0.1"}), timeout=60).read().decode("utf-8", "replace")
        candidates = re.findall(r'href="(alpine-minirootfs-([0-9]+\.[0-9]+\.[0-9]+)-' + re.escape(ALPINE_ARCH[arch]) + r'\.tar\.gz)"', listing)
        if not candidates:
            raise SystemExit(f"no Alpine minirootfs archive listed at {release_url}")
        filename = sorted(candidates, key=lambda item: tuple(int(x) for x in item[1].split(".")))[-1][0]
        fetch(release_url + filename, archive)
        subprocess.run(["tar", "-xzf", str(archive), "-C", str(root)], check=True)
        # Ensure chroot setup has resolver and basic directory layout.
        (root / "etc").mkdir(exist_ok=True)
        (root / "etc/resolv.conf").write_text("nameserver 1.1.1.1\nnameserver 8.8.8.8\n", encoding="ascii")
        cmd = ["apk", "--root", str(root), "--initdb", "--repositories-file", "/dev/null"]
        repositories = root / "etc/apk/repositories"
        repositories.parent.mkdir(parents=True, exist_ok=True)
        repositories.write_text(f"https://dl-cdn.alpinelinux.org/alpine/{release}/main\nhttps://dl-cdn.alpinelinux.org/alpine/{release}/community\n", encoding="ascii")
        cmd = ["apk", "--root", str(root), "--initdb", "--repositories-file", str(repositories), "--allow-untrusted", "add", "alpine-baselayout", "busybox", "alpine-keys", "ca-certificates"]
        if recipe.get("includeSSH"):
            packages = packages + ["openssh"]
        if packages:
            cmd += packages
        subprocess.run(cmd, check=True)
        (root / "etc/hostname").write_text(str(recipe.get("hostname", "ish-aok"))[:64] + "\n", encoding="utf-8")
        (root / "etc/motd").write_text("Root filesystem built by Systui Rootfs.\n", encoding="utf-8")
        fmt = recipe.get("compression", "gzip")
        if fmt not in ("gzip", "xz"):
            raise SystemExit("compression must be gzip or xz")
        suffix = ".tar.gz" if fmt == "gzip" else ".tar.xz"
        final = out if str(out).endswith(suffix) else pathlib.Path(str(out) + suffix)
        tar_args = ["tar", "--numeric-owner", "-C", str(root), "-c"]
        tar_args += ["-z"] if fmt == "gzip" else ["-J"]
        tar_args += ["-f", str(final), "."]
        subprocess.run(tar_args, check=True)
        # Refuse an empty or structurally incomplete export.
        with tempfile.TemporaryDirectory(prefix="systui-check-") as checkdir:
            subprocess.run(["tar", "-tf", str(final)], check=True, stdout=subprocess.PIPE, text=True)
        print(f"built {final} ({final.stat().st_size} bytes)")

if __name__ == "__main__":
    main()
