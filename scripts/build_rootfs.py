#!/usr/bin/env python3
"""Build supported ARM64 Linux roots from OCI images or official rootfs archives."""
import argparse, gzip, hashlib, ipaddress, json, lzma, pathlib, re, shutil, subprocess, tarfile, tempfile, urllib.request

PACKAGE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+:/-]{0,127}$")
HOST = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$")
TIMEZONE = re.compile(r"^[A-Za-z0-9_+./-]{1,64}$")
OCI = {
    "Debian": {"trixie": "debian:trixie-slim", "bookworm": "debian:bookworm-slim"},
    "Ubuntu": {"24.04": "ubuntu:24.04", "22.04": "ubuntu:22.04"},
    "Kali Linux": {"rolling": "kalilinux/kali-rolling:latest"},
    "Alpine": {"v3.24": "alpine:3.24", "v3.23": "alpine:3.23", "v3.22": "alpine:3.22", "edge": "alpine:edge"},
    "Fedora": {"45": "fedora:45", "44": "fedora:44"},
    "openSUSE Leap": {"16.0": "opensuse/leap:16.0", "15.6": "opensuse/leap:15.6"},
    "openSUSE Tumbleweed": {"rolling": "opensuse/tumbleweed:latest"},
    "Gentoo": {"rolling": "gentoo/stage3:latest"},
    "Arch Linux ARM": {"rolling": "menci/archlinuxarm:latest"},
    "Void Linux": {"rolling": "ghcr.io/void-linux/void-glibc:latest"},
}
INIT_PACKAGE = {
    ("Debian", "systemd"): "systemd-sysv", ("Debian", "SysVinit"): "sysvinit-core",
    ("Ubuntu", "systemd"): "systemd-sysv", ("Ubuntu", "SysVinit"): "sysvinit-core",
    ("Kali Linux", "systemd"): "systemd-sysv", ("Kali Linux", "SysVinit"): "sysvinit-core",
    ("Devuan", "SysVinit"): "sysvinit-core", ("Devuan", "runit"): "runit",
    ("Alpine", "OpenRC"): "openrc", ("Arch Linux ARM", "systemd"): "systemd",
    ("Arch Linux ARM", "runit"): "runit", ("Fedora", "systemd"): "systemd",
    ("openSUSE Leap", "systemd"): "systemd", ("openSUSE Tumbleweed", "systemd"): "systemd",
    ("Gentoo", "OpenRC"): "sys-apps/openrc", ("Gentoo", "systemd"): "sys-apps/systemd",
    ("Void Linux", "runit"): "runit-void",
}

def run(cmd, **kw):
    print("+", " ".join(map(str, cmd)), flush=True)
    subprocess.run(cmd, check=True, **kw)

def get(url, timeout=90):
    req = urllib.request.Request(url, headers={"User-Agent": "SystuiRootfs/1.0"})
    with urllib.request.urlopen(req, timeout=timeout) as response: return response.read()

def import_tarball(path, tag):
    run(["docker", "import", str(path), tag])
    return tag

def lxc_rootfs(distro, release, work):
    base = f"https://images.linuxcontainers.org/images/{distro}/{release}/arm64/default/"
    html = get(base).decode("utf-8", "replace")
    stamps = re.findall(r'href="(20[0-9]{6}_[0-9]{2}%3A[0-9]{2})/"', html, re.I)
    if not stamps: raise SystemExit(f"No ARM64 rootfs snapshots at {base}")
    stamp = stamps[-1]; folder = base + stamp + "/"
    archive = work / "rootfs.tar.xz"
    archive.write_bytes(get(folder + "rootfs.tar.xz", 240))
    sums = get(folder + "SHA256SUMS").decode("ascii", "replace")
    match = re.search(r"^([0-9a-fA-F]{64})\s+\*?rootfs\.tar\.xz$", sums, re.M)
    if not match: raise SystemExit("LXC snapshot has no matching rootfs SHA-256 entry")
    digest = hashlib.sha256()
    with open(archive, "rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    actual = digest.hexdigest()
    if actual.lower() != match.group(1).lower(): raise SystemExit("LXC rootfs SHA-256 verification failed")
    return import_tarball(archive, f"systui-rootfs:{distro}-{release}")

def resolve_base(recipe, work):
    distro, release = recipe["distribution"], recipe["release"]
    if distro == "Devuan":
        if release not in ("excalibur", "daedalus"): raise SystemExit("Devuan release must be excalibur or daedalus")
        return lxc_rootfs("devuan", release, work)
    if distro == "Arch Linux ARM":
        if release != "rolling": raise SystemExit("Arch Linux ARM release must be rolling")
        return OCI[distro][release]
    try: return OCI[distro][release]
    except KeyError: raise SystemExit(f"Unsupported distribution/release: {distro} {release}")

def package_command(distro, packages, include_ssh, init):
    names = list(packages)
    ssh = {"Alpine":"openssh", "Void Linux":"openssh", "Arch Linux ARM":"openssh", "Gentoo":"net-misc/openssh"}.get(distro, "openssh-server")
    if include_ssh: names.append(ssh)
    initpkg = INIT_PACKAGE.get((distro, init))
    if not initpkg: raise SystemExit(f"Unsupported init system {init!r} for {distro}")
    names.append(initpkg)
    tzpkg = {"Gentoo":"sys-libs/timezone-data", "openSUSE Leap":"timezone", "openSUSE Tumbleweed":"timezone"}.get(distro, "tzdata")
    names.append(tzpkg)
    names = list(dict.fromkeys(names)); p = " ".join(names)
    if distro in ("Debian", "Ubuntu", "Devuan", "Kali Linux"):
        return f"export DEBIAN_FRONTEND=noninteractive; apt-get update; apt-get install -y --no-install-recommends {p}; apt-get clean; rm -rf /var/lib/apt/lists/*"
    if distro == "Alpine": return f"apk update; apk add --no-cache {p}; rm -rf /var/cache/apk/*"
    if distro == "Fedora": return f"dnf install -y {p}; dnf clean all"
    if distro.startswith("openSUSE"): return f"zypper --non-interactive refresh; zypper --non-interactive install --no-recommends {p}; zypper clean --all"
    if distro == "Arch Linux ARM": return "sed -i 's/^#DisableSandbox/DisableSandbox/' /etc/pacman.conf; pacman -Sy --noconfirm; pacman -S --noconfirm --needed " + p + "; pacman -Scc --noconfirm"
    if distro == "Gentoo": return f"emerge --sync; emerge --ask=n {p}; rm -rf /var/cache/distfiles/*"
    if distro == "Void Linux": return f"xbps-install -Suy xbps; xbps-install -y {p}; rm -rf /var/cache/xbps/*"
    raise SystemExit("No package manager adapter for " + distro)

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--recipe", required=True); ap.add_argument("--output", required=True); args = ap.parse_args()
    recipe = json.load(open(args.recipe, encoding="utf-8"))
    if recipe.get("schemaVersion") != 1: raise SystemExit("Unsupported recipe schema")
    distro, release = recipe.get("distribution"), recipe.get("release")
    if not isinstance(distro,str) or not isinstance(release,str): raise SystemExit("distribution and release are required")
    if distro == "Bedrock Linux": raise SystemExit("Bedrock is a meta-distribution requiring an existing base plus FUSE hijack; not a standalone target")
    if recipe.get("architecture") != "aarch64": raise SystemExit("Only aarch64 rootfs builds are supported")
    packages = recipe.get("packages", [])
    if isinstance(packages,str): packages = [x.strip() for x in re.split(r"[,\n]",packages) if x.strip()]
    if not isinstance(packages,list) or not all(isinstance(x,str) and PACKAGE.fullmatch(x) for x in packages): raise SystemExit("Invalid package list")
    hostname = recipe.get("hostname","ish-aok"); timezone = recipe.get("timezone","UTC"); dns = recipe.get("dns","1.1.1.1")
    if not isinstance(hostname,str) or not HOST.fullmatch(hostname): raise SystemExit("Invalid hostname")
    if not isinstance(timezone,str) or not TIMEZONE.fullmatch(timezone) or ".." in timezone: raise SystemExit("Invalid timezone")
    try: ipaddress.ip_address(dns)
    except (ValueError,TypeError): raise SystemExit("DNS must be one IPv4 or IPv6 address")
    compression = recipe.get("compression","gzip")
    if compression not in ("gzip","xz"): raise SystemExit("compression must be gzip or xz")
    init = recipe.get("initSystem","systemd")
    out = pathlib.Path(args.output); out.parent.mkdir(parents=True,exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="systui-rootfs-") as td:
        work=pathlib.Path(td); image=resolve_base(recipe,work)
        if subprocess.run(["docker","image","inspect",image],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode != 0:
            run(["docker","pull","--platform","linux/arm64",image])
        name="systui-rootfs-build"; subprocess.run(["docker","rm","-f",name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        run(["docker","create","--platform","linux/arm64","--name",name,image,"sh","-c","while :; do sleep 3600; done"])
        try:
            run(["docker","start",name])
            command=package_command(distro,packages,bool(recipe.get("includeSSH")),init)
            run(["docker","exec",name,"sh","-ec",command])
            config_cmd='printf "%s\\n" "$SYSTUI_HOSTNAME" > /etc/hostname; printf "nameserver %s\\n" "$SYSTUI_DNS" > /etc/resolv.conf; printf "%s\\n" "$SYSTUI_TZ" > /etc/timezone; printf "%s\\n" "Root filesystem built by Systui Rootfs." > /etc/motd; if [ -e "/usr/share/zoneinfo/$SYSTUI_TZ" ]; then ln -snf "/usr/share/zoneinfo/$SYSTUI_TZ" /etc/localtime; fi'
            run(["docker","exec","-e",f"SYSTUI_HOSTNAME={hostname}","-e",f"SYSTUI_DNS={dns}","-e",f"SYSTUI_TZ={timezone}",name,"sh","-ec",config_cmd])
            raw=work/"rootfs.tar"
            with open(raw,"wb") as f: run(["docker","export","-o",str(raw),name])
        finally: subprocess.run(["docker","rm","-f",name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        suffix=".tar.gz" if compression=="gzip" else ".tar.xz"; final=out if str(out).endswith(suffix) else pathlib.Path(str(out)+suffix)
        if compression=="gzip":
            with open(raw,"rb") as src,gzip.open(final,"wb",compresslevel=6) as dst: shutil.copyfileobj(src,dst)
        else:
            with open(raw,"rb") as src,lzma.open(final,"wb",preset=6) as dst: shutil.copyfileobj(src,dst)
        with tarfile.open(final,"r:*") as tf: roots={m.name.lstrip("./").split("/")[0] for m in tf.getmembers() if m.name.lstrip("./")}
        missing={"etc","bin","usr"}-roots
        if missing: raise SystemExit("Archive missing required root entries: "+", ".join(sorted(missing)))
        print(f"built {final} ({final.stat().st_size} bytes); root entries: {', '.join(sorted(roots))}")

if __name__ == "__main__": main()
