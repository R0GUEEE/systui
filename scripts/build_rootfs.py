#!/usr/bin/env python3
"""Build supported ARM64 Linux roots from OCI images or official rootfs archives."""
import argparse, gzip, hashlib, ipaddress, json, lzma, pathlib, re, shutil, subprocess, tarfile, tempfile, urllib.request

PROFILE_KEYS = {"core", "editors", "developer", "languages", "network", "server", "web", "security", "storage", "terminal"}
PROFILE_ITEMS = {
    "core": ["bash", "bash-completion", "curl", "wget", "ca-certificates", "less", "file", "procps", "iproute2", "iputils-ping"],
    "editors": ["nano", "vim"],
    "developer": ["git", "build-tools", "cmake", "ninja", "pkgconfig", "gdb", "strace"],
    "languages": ["python", "pip", "node", "npm", "golang", "rust"],
    "network": ["nmap", "tcpdump", "traceroute", "mtr", "netcat", "socat", "dnsutils", "whois"],
    "server": ["sudo", "rsyslog", "cron", "chrony", "logrotate", "nftables"],
    "web": ["nginx", "sqlite", "mariadb-client", "postgresql-client"],
    "security": ["gnupg", "openssl", "nmap", "tcpdump", "socat"],
    "storage": ["rsync", "rclone", "unzip", "zip", "xz", "zstd", "parted", "e2fsprogs", "dosfstools"],
    "terminal": ["tmux", "screen", "htop", "btop", "jq", "tree", "ncdu"],
}
DISTRO_ALIASES = {
    "Debian": {"build-tools":"build-essential","ninja":"ninja-build","pkgconfig":"pkg-config","python":"python3","pip":"python3-pip","dnsutils":"dnsutils","mtr":"mtr-tiny","netcat":"netcat-openbsd","sqlite":"sqlite3","mariadb-client":"mariadb-client","postgresql-client":"postgresql-client","cron":"cron"},
    "Devuan": {"build-tools":"build-essential","ninja":"ninja-build","pkgconfig":"pkg-config","python":"python3","pip":"python3-pip","dnsutils":"dnsutils","mtr":"mtr-tiny","netcat":"netcat-openbsd","sqlite":"sqlite3","mariadb-client":"mariadb-client","postgresql-client":"postgresql-client","cron":"cron"},
    "Ubuntu": {"build-tools":"build-essential","ninja":"ninja-build","pkgconfig":"pkg-config","python":"python3","pip":"python3-pip","dnsutils":"dnsutils","mtr":"mtr-tiny","netcat":"netcat-openbsd","sqlite":"sqlite3","mariadb-client":"mariadb-client","postgresql-client":"postgresql-client","cron":"cron"},
    "Kali Linux": {"build-tools":"build-essential","ninja":"ninja-build","pkgconfig":"pkg-config","python":"python3","pip":"python3-pip","dnsutils":"dnsutils","mtr":"mtr-tiny","netcat":"netcat-openbsd","sqlite":"sqlite3","mariadb-client":"mariadb-client","postgresql-client":"postgresql-client","cron":"cron"},
    "Alpine": {"bash-completion":"bash-completion","procps":"procps","iputils-ping":"iputils","build-tools":"build-base","ninja":"ninja","pkgconfig":"pkgconf","python":"python3","pip":"py3-pip","node":"nodejs","npm":"nodejs-npm","dnsutils":"bind-tools","netcat":"netcat-openbsd","sqlite":"sqlite","mtr":"mtr","cron":"cronie","nftables":"nftables","postgresql-client":"postgresql-client"},
    "Arch Linux ARM": {"procps":"procps-ng","build-tools":"base-devel","pkgconfig":"pkgconf","python":"python","pip":"python-pip","dnsutils":"bind","netcat":"openbsd-netcat","cron":"cronie","sqlite":"sqlite","postgresql-client":"postgresql-libs"},
    "Fedora": {"procps":"procps-ng","iputils-ping":"iputils","vim":"vim-enhanced","build-tools":"gcc gcc-c++ make","ninja":"ninja-build","pkgconfig":"pkgconf-pkg-config","python":"python3","pip":"python3-pip","dnsutils":"bind-utils","netcat":"nmap-ncat","cron":"cronie","sqlite":"sqlite","mariadb-client":"mariadb","postgresql-client":"postgresql"},
    "openSUSE Leap": {"build-tools":"gcc gcc-c++ make","pkgconfig":"pkg-config","python":"python3","pip":"python3-pip","dnsutils":"bind-utils","sqlite":"sqlite3","mariadb-client":"mariadb-client","postgresql-client":"postgresql"},
    "openSUSE Tumbleweed": {"build-tools":"gcc gcc-c++ make","pkgconfig":"pkg-config","python":"python3","pip":"python3-pip","dnsutils":"bind-utils","sqlite":"sqlite3","mariadb-client":"mariadb-client","postgresql-client":"postgresql"},
    "Gentoo": {"bash":"app-shells/bash","bash-completion":"app-shells/bash-completion","curl":"net-misc/curl","ca-certificates":"app-misc/ca-certificates","less":"app-misc/less","file":"app-misc/file","procps":"sys-process/procps","iproute2":"net-misc/iproute2","iputils-ping":"net-misc/iputils","nano":"app-editors/nano","vim":"app-editors/vim","zsh":"app-shells/zsh","fish":"app-shells/fish","neovim":"app-editors/neovim","micro":"app-editors/micro","git":"dev-vcs/git","gdb":"dev-debug/gdb","strace":"dev-debug/strace","rsyslog":"app-admin/rsyslog","logrotate":"app-admin/logrotate","sudo":"app-admin/sudo","nftables":"net-firewall/nftables","chrony":"net-misc/chrony","gnupg":"app-crypt/gnupg","openssl":"dev-libs/openssl","rsync":"net-misc/rsync","rclone":"net-misc/rclone","unzip":"app-arch/unzip","zip":"app-arch/zip","xz":"app-arch/xz-utils","zstd":"app-arch/zstd","parted":"sys-block/parted","e2fsprogs":"sys-fs/e2fsprogs","dosfstools":"sys-fs/dosfstools","tmux":"app-misc/tmux","screen":"app-misc/screen","htop":"sys-process/htop","btop":"sys-process/btop","jq":"app-misc/jq","tree":"app-text/tree","ncdu":"sys-apps/ncdu","build-tools":"sys-devel/gcc sys-devel/make","cmake":"dev-build/cmake","ninja":"dev-build/ninja","pkgconfig":"dev-util/pkgconf","python":"dev-lang/python","pip":"dev-python/pip","node":"net-libs/nodejs","npm":"net-libs/nodejs","golang":"dev-lang/go","rust":"dev-lang/rust","dnsutils":"net-dns/bind-tools","netcat":"net-analyzer/netcat","mtr":"net-analyzer/mtr","sqlite":"dev-db/sqlite","cron":"sys-process/cronie","nginx":"www-servers/nginx","postgresql-client":"dev-db/postgresql"},
    "Void Linux": {"procps":"procps-ng","iputils-ping":"iputils","build-tools":"base-devel","pkgconfig":"pkg-config","python":"python3","pip":"python3-pip","dnsutils":"bind-utils","netcat":"netcat","cron":"cronie","sqlite":"sqlite","mariadb-client":"mariadb-client","postgresql-client":"postgresql"},
}

PACKAGE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+:/-]{0,127}$")
HOST = re.compile(r"^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$")
USERNAME = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
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
LOCALE_PACKAGE = {
    "Debian":"locales", "Devuan":"locales", "Ubuntu":"locales", "Kali Linux":"locales",
    "Alpine":"musl-locales", "Arch Linux ARM":"glibc", "Fedora":"glibc-langpack-en",
    "openSUSE Leap":"glibc-locale", "openSUSE Tumbleweed":"glibc-locale",
    "Gentoo":"sys-libs/glibc", "Void Linux":"glibc-locales",
}
SERVICE_PACKAGES = {
    "Debian":{"cron":"cron","nginx":"nginx"}, "Devuan":{"cron":"cron","nginx":"nginx"},
    "Ubuntu":{"cron":"cron","nginx":"nginx"}, "Kali Linux":{"cron":"cron","nginx":"nginx"},
    "Alpine":{"cron":"cronie","nginx":"nginx"}, "Arch Linux ARM":{"cron":"cronie","nginx":"nginx"},
    "Fedora":{"cron":"cronie","nginx":"nginx"}, "openSUSE Leap":{"cron":"cron","nginx":"nginx"},
    "openSUSE Tumbleweed":{"cron":"cron","nginx":"nginx"}, "Gentoo":{"cron":"sys-process/cronie","nginx":"www-servers/nginx"},
    "Void Linux":{"cron":"cronie","nginx":"nginx"},
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

def expand_packages(distro, packages, profiles, user_shell, editor):
    aliases = DISTRO_ALIASES[distro]
    names = list(packages)
    for profile in profiles:
        for item in PROFILE_ITEMS[profile]:
            names.extend(aliases.get(item, item).split())
    if user_shell != "/bin/sh":
        shell = pathlib.PurePosixPath(user_shell).name
        names.extend(aliases.get(shell, shell).split())
    if editor != "none":
        names.extend(aliases.get(editor, editor).split())
    return list(dict.fromkeys(names))

def package_command(distro, packages, profiles, include_ssh, services, init, user_shell, editor, user_sudo, locale):
    names = expand_packages(distro, packages, profiles, user_shell, editor)
    ssh = {"Alpine":"openssh", "Void Linux":"openssh", "Arch Linux ARM":"openssh", "Gentoo":"net-misc/openssh"}.get(distro, "openssh-server")
    if include_ssh: names.append(ssh)
    for service in services:
        if service != "sshd": names.append(SERVICE_PACKAGES[distro][service])
    if user_sudo: names.append("sudo")
    initpkg = INIT_PACKAGE.get((distro, init))
    if not initpkg: raise SystemExit(f"Unsupported init system {init!r} for {distro}")
    names.append(initpkg)
    tzpkg = {"Gentoo":"sys-libs/timezone-data", "openSUSE Leap":"timezone", "openSUSE Tumbleweed":"timezone"}.get(distro, "tzdata")
    names.append(tzpkg)
    if locale != "C.UTF-8": names.append(LOCALE_PACKAGE[distro])
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

def configure_rootfs(distro, init, hostname, timezone, dns, locale, user, user_shell, user_sudo, editor, services, ssh_port):
    commands = [
        'printf "%s\\n" "$SYSTUI_HOSTNAME" > /etc/hostname',
        'printf "%s" "$SYSTUI_RESOLV" > /etc/resolv.conf',
        'printf "%s\\n" "$SYSTUI_TZ" > /etc/timezone',
        'printf "%s\\n" "LANG=$SYSTUI_LOCALE" > /etc/locale.conf',
        'printf "%s\\n" "LANG=$SYSTUI_LOCALE" > /etc/default/locale',
        'mkdir -p /etc/profile.d; printf "export LANG=%s\\n" "$SYSTUI_LOCALE" > /etc/profile.d/90-systui-locale.sh; chmod 644 /etc/profile.d/90-systui-locale.sh',
        'printf "%s\\n" "Root filesystem built by Systui Rootfs." > /etc/motd',
        'printf "127.0.0.1\\tlocalhost\\n127.0.1.1\\t%s\\n::1\\tlocalhost ip6-localhost\\n" "$SYSTUI_HOSTNAME" > /etc/hosts',
        'if [ -e "/usr/share/zoneinfo/$SYSTUI_TZ" ]; then ln -snf "/usr/share/zoneinfo/$SYSTUI_TZ" /etc/localtime; fi',
    ]
    if editor != "none":
        commands.append('mkdir -p /etc/profile.d; printf "%s\\n" "export EDITOR=\\$SYSTUI_EDITOR" "export VISUAL=\\$SYSTUI_EDITOR" > /etc/profile.d/90-systui-editor.sh; chmod 644 /etc/profile.d/90-systui-editor.sh')
    if locale == "en_US.UTF-8":
        commands.append('case "$SYSTUI_DISTRO" in Debian|Devuan|Ubuntu|Kali\\ Linux|Arch\\ Linux\\ ARM) sed -i -E "s/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen; locale-gen ;; Alpine) : ;; Void\\ Linux) xbps-reconfigure -f glibc-locales || true ;; *) localedef -i en_US -f UTF-8 en_US.UTF-8 || true ;; esac')
    if user:
        group = "wheel" if distro in ("Alpine", "Arch Linux ARM", "Fedora", "Gentoo", "Void Linux") else "sudo"
        create = 'if [ "$SYSTUI_DISTRO" = Alpine ]; then adduser -D -s "$SYSTUI_SHELL" "$SYSTUI_USER"; else useradd -m -s "$SYSTUI_SHELL" "$SYSTUI_USER"; fi'
        add_group = f'if [ "$SYSTUI_SUDO" = 1 ]; then if [ "$SYSTUI_DISTRO" = Alpine ]; then addgroup -S {group} >/dev/null 2>&1 || true; addgroup "$SYSTUI_USER" {group}; else usermod -aG {group} "$SYSTUI_USER"; fi; fi'
        commands.append(f'if ! id "$SYSTUI_USER" >/dev/null 2>&1; then {create}; fi; {add_group}')
    if user_sudo:
        group = "wheel" if distro in ("Alpine", "Arch Linux ARM", "Fedora", "Gentoo", "Void Linux") else "sudo"
        commands.append(f'mkdir -p /etc/sudoers.d; printf "%s\\n" "%{group} ALL=(ALL:ALL) ALL" > /etc/sudoers.d/90-systui; chmod 440 /etc/sudoers.d/90-systui')
    if "sshd" in services:
        commands.append('mkdir -p /etc/ssh/sshd_config.d; printf "%s\\n" "Port $SYSTUI_SSH_PORT" "PermitRootLogin prohibit-password" > /etc/ssh/sshd_config.d/90-systui.conf')
    if services:
        service_map = {
            "sshd": "ssh" if distro in ("Debian", "Ubuntu", "Devuan", "Kali Linux") else "sshd",
            "cron": "crond" if distro in ("Alpine", "Arch Linux ARM", "Fedora", "Gentoo", "Void Linux") else "cron",
            "nginx": "nginx",
        }
        for selected in services:
            service = service_map[selected]
            commands.append(f'''case "$SYSTUI_INIT" in
              systemd) systemctl --root=/ --no-reload enable {service}.service || true ;;
              SysVinit) if command -v update-rc.d >/dev/null 2>&1; then update-rc.d {service} defaults || true; fi ;;
              OpenRC) if command -v rc-update >/dev/null 2>&1; then rc-update add {service} default || true; fi ;;
              runit) for candidate in "/etc/sv/{service}" "/etc/sv/{selected}"; do if [ -d "$candidate" ]; then mkdir -p /var/service; ln -snf "$candidate" "/var/service/{service}"; break; fi; done ;;
            esac''')
    return "; ".join(commands)

def main():
    ap = argparse.ArgumentParser(); ap.add_argument("--recipe", required=True); ap.add_argument("--output", required=True); args = ap.parse_args()
    recipe = json.load(open(args.recipe, encoding="utf-8"))
    if recipe.get("schemaVersion") != 1: raise SystemExit("Unsupported recipe schema")
    distro, release = recipe.get("distribution"), recipe.get("release")
    if not isinstance(distro,str) or not isinstance(release,str): raise SystemExit("distribution and release are required")
    if distro == "Bedrock Linux": raise SystemExit("Bedrock is a meta-distribution requiring an existing base plus FUSE hijack; not a standalone target")
    if recipe.get("architecture") != "aarch64": raise SystemExit("Only aarch64 rootfs builds are supported")
    hostname = recipe.get("hostname", "ish-aok")
    timezone = recipe.get("timezone", "UTC")
    if not isinstance(hostname,str) or not HOST.fullmatch(hostname): raise SystemExit("Invalid hostname")
    if not isinstance(timezone,str) or not TIMEZONE.fullmatch(timezone) or ".." in timezone: raise SystemExit("Invalid timezone")
    packages = recipe.get("packages", [])
    if isinstance(packages,str): packages = [x.strip() for x in re.split(r"[,\n]",packages) if x.strip()]
    if not isinstance(packages,list) or not all(isinstance(x,str) and PACKAGE.fullmatch(x) for x in packages): raise SystemExit("Invalid package list")
    user = recipe.get("username", "")
    if not isinstance(user,str) or (user and (not USERNAME.fullmatch(user) or user in ("root", "nobody"))): raise SystemExit("Username must be a non-reserved lowercase account name")
    user_shell = recipe.get("userShell", "/bin/sh")
    if user_shell not in ("/bin/sh", "/bin/bash", "/bin/zsh", "/usr/bin/fish"): raise SystemExit("Unsupported login shell")
    editor = recipe.get("defaultEditor", "nano")
    if editor not in ("none", "nano", "vim", "neovim", "micro"): raise SystemExit("Unsupported default editor")
    profiles = recipe.get("packageProfiles", [])
    if not isinstance(profiles,list) or not all(isinstance(x,str) and x in PROFILE_KEYS for x in profiles): raise SystemExit("Invalid package profile selection")
    user_sudo = recipe.get("userSudo",False)
    include_ssh = recipe.get("includeSSH",False)
    enable_cron = recipe.get("enableCron",False); enable_nginx = recipe.get("enableNginx",False)
    if not all(isinstance(x,bool) for x in (user_sudo,include_ssh,enable_cron,enable_nginx)): raise SystemExit("service and sudo options must be booleans")
    services = (["sshd"] if include_ssh else []) + (["cron"] if enable_cron else []) + (["nginx"] if enable_nginx else [])
    ssh_port = recipe.get("sshPort",22)
    if not isinstance(ssh_port,int) or isinstance(ssh_port,bool) or not 1 <= ssh_port <= 65535: raise SystemExit("SSH port must be between 1 and 65535")
    locale = recipe.get("locale", "C.UTF-8")
    if locale not in ("C.UTF-8", "en_US.UTF-8"): raise SystemExit("Supported locales: C.UTF-8 and en_US.UTF-8")
    dns = recipe.get("dns", "1.1.1.1")
    if isinstance(dns,str): dns = [x.strip() for x in dns.split(",") if x.strip()]
    if not isinstance(dns,list) or not dns or len(dns)>4: raise SystemExit("DNS requires one to four resolver IPs")
    try:
        for address in dns: ipaddress.ip_address(address)
    except (ValueError,TypeError): raise SystemExit("DNS entries must be IPv4 or IPv6 addresses")
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
            command=package_command(distro,packages,profiles,include_ssh,services,init,user_shell,editor,user_sudo,locale)
            run(["docker","exec",name,"sh","-ec",command])
            resolv="\n".join(f"nameserver {address}" for address in dns)+"\n"
            config_cmd=configure_rootfs(distro,init,hostname,timezone,dns,locale,user,user_shell,user_sudo,editor,services,ssh_port)
            env=["docker","exec","-e",f"SYSTUI_HOSTNAME={hostname}","-e",f"SYSTUI_RESOLV={resolv}","-e",f"SYSTUI_TZ={timezone}","-e",f"SYSTUI_LOCALE={locale}","-e",f"SYSTUI_USER={user}","-e",f"SYSTUI_SHELL={user_shell}","-e",f"SYSTUI_SUDO={int(user_sudo)}","-e",f"SYSTUI_EDITOR={editor}","-e",f"SYSTUI_INIT={init}","-e",f"SYSTUI_DISTRO={distro}","-e",f"SYSTUI_SSH_PORT={ssh_port}"]
            run(env+[name,"sh","-ec",config_cmd])
            metadata=work/"systui-rootfs.json"
            metadata.write_text(json.dumps(recipe,indent=2,sort_keys=True)+"\n",encoding="utf-8")
            run(["docker","cp",str(metadata),f"{name}:/etc/systui-rootfs.json"])
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
