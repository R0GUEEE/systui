Changelog
=========

All notable changes to systui. The version shown in the TUI, `install.sh
--version`, the man page and the iOS companion app all come from
`src/VERSION` + `project.yml`; a release tag must match it.

## 1.3.0 — 2026-11-27

### Containers & virtualization (new Rootfs utility)

- **Rootfs > Containers & virtualization** is a full front door for the
  runtimes the rest of systui depends on: Docker, Podman, containerd/nerdctl,
  LXC, LXD, Incus, libvirt + QEMU/KVM, Waydroid, Apptainer, bubblewrap and
  systemd-nspawn — plus a status dashboard, shared configuration and pruning.
- **Configuration is generated, not memorised**: settings live in systui's own
  config file (`cn_*` keys) and are rendered into the tool's native file —
  `daemon.json`, `registries.conf`, `containers.conf`, `storage.conf`,
  `lxc/default.conf`, `apptainer.conf`. Every value is escaped and the result
  is validated as JSON before Docker is restarted. Rendered paths honour
  `SYSTUI_*_FILE` overrides.
- **Comprehensive engine options**: registry mirrors and insecure registries,
  data-root (with an assisted migration), storage driver, log driver and
  rotation, default address pools, DNS, live-restore, iptables/ip6tables,
  userland-proxy, userns-remap, builder cache limits, Podman graph/run root,
  OCI runtime, cgroup manager, default subnet, API socket and the
  podman-docker shim.
- **Rootless Podman properly set up**: `/etc/subuid` and `/etc/subgid` ranges
  (only when absent), linger, `fuse-overlayfs`, and a status view that shows
  the mapping, the kernel namespace limits and what `podman info` reports.
- **Service control works on every init**: systemd, OpenRC, runit, SysVinit,
  and a clear message when the host has no service manager at all (iSH).
- Install paths per distribution (`apt`, `apk`, `pacman`, `dnf`, `zypper`,
  `xbps`, `emerge`) plus upstream channels (get.docker.com, nerdctl-full,
  Zabbly Incus, Waydroid repo, snap for LXD). Packages a distribution does not
  carry are skipped instead of failing the whole transaction.

### Distro managers

- **Four more managers**: `podman`, `docker`, `lxc` and `incus`, each with the
  same browse → create → enter → stop/remove workflow as the existing ones
  (static image catalogues for LXC/Incus, `docker search` for the engines).
- **Engine wiring**: Distrobox, Toolbx and the container managers now call
  `cn_ensure_engine`, which detects a working engine, tries to start an
  installed one, or installs rootless Podman — instead of only printing a hint.
  A shared `dm_engine` preference (auto/podman/docker) is honoured.
- **Configuration grew past "where is the store"**: image pull policy
  (`always`/`missing`/`never`), extra `create` arguments, LXC/Incus bridge and
  autostart, engine preference with a live check, a "show every saved setting"
  view, and direct links into the engine configuration.
- The Distro managers menu shows the detected engines and links to the new
  Containers & virtualization utility; bulk install still uses SPACE.

### Tests

- `tests/test-container-virt.sh` (75 checks): catalogue integrity, per-PM
  package names, daemon.json/registries/storage/containers/LXC rendering
  (including empty configurations), validation helpers, the new managers'
  exact commands and the Rootfs menu wiring.

## 1.2.0 — 2026-11-27

### Homebrew

- Every installed formula is on the default PATH the moment it finishes
  installing — no re-login, no `eval "$(brew shellenv)"`. The mirror walks
  `bin/`, `sbin/` **and** `opt/<formula>/{bin,sbin}`, so keg-only packages
  (openjdk, sqlite, node, postgresql@16, python@3.12) are covered too; those
  are never linked into `bin/` and were previously invisible.
- Resolution policy is explicit and persisted in `/etc/systui/brew-path.conf`:
  a distribution command keeps priority by default, `--prefer-brew` lets
  Homebrew win, `--prefer-system` restores the default *and* removes the
  mirrors that were shadowing. Shells, `apk`, `su`, `env`, `mount` and the
  other load-bearing names are never shadowed.
- Precedence between formulae is stable (linked `bin` first, then
  `opt/<formula>` alphabetically) and an existing valid mirror is never
  repointed, so the winner does not change on every refresh.

### Repositories

- **Distro Repos works on every supported host**, not just APT ones: apk
  (managed block in `/etc/apk/repositories`), pacman (sections edited in place,
  never duplicated), dnf (`config-manager` toggles), zypper (`modifyrepo`),
  xbps (drop-in conf) and portage (`repos.conf`). APT hosts keep the
  cross-distribution browser. Managed blocks are rewritten between
  `# >>> systui distro repos >>>` markers, so options never stack.
- **Popular repositories**: 40 curated APT entries and native lists for dnf,
  zypper, pacman (Chaotic-AUR, BlackArch, CachyOS, EndeavourOS, archlinuxcn,
  ArcoLinux) and apk.
- **PPAs**: 37 catalogue entries grouped by category with an "All" view;
  Launchpad search results are HTML-decoded and ranked by published binary
  count instead of arriving alphabetically.
- **Signing keys are requirement-driven**: the menu reads the sources
  configured on the machine and lists the distros whose keyring is actually
  needed first, pre-selected. Existing sources gain `[signed-by=…]` after an
  install (merged into an existing option group), and the Distro Repos writer
  refuses to emit an entry it cannot verify.

### Fixes

- `pacman` refreshes never perform a partial upgrade.
- Native repository writers decide by directory writability instead of uid, so
  they work from a non-root shell where the target is writable.

## 1.1.0 — 2026-11-26

- ARM64 rootfs builder with recipes for Debian, Devuan, Ubuntu, Alpine, Arch
  Linux ARM, Fedora, Kali, openSUSE Leap/Tumbleweed, Gentoo and Void.
- iOS companion app (`SystuiRootfs`) with recipe import/export.
- Homebrew root-compatibility layer.
