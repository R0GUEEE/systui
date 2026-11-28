Changelog
=========

All notable changes to systui. The version shown in the TUI, `install.sh
--version`, the man page and the iOS companion app all come from
`src/VERSION` + `project.yml`; a release tag must match it.

## 1.3.0 — 2026-11-27

### Repository cleanup

- Removed `tools/rewrite-function-aliases.py`: it was a one-off migration that
  rewrote `eval "$(declare -f fn | sed …)"` into parameter expansion. No such
  call site is left, and nothing referenced the script.
- Removed a committed `__pycache__/*.pyc` build artifact and added a
  `.gitignore` (`__pycache__/`, `*.pyc`, `build/`, `dist/`, `*.ipa`, `*.log`,
  `Payload/`, `.DS_Store`).
- Merged `FEATURE-MAP.md` into `IOS-APP.md` as a "Where the app ends and systui
  begins" section — the two documents described the same boundary from two
  angles and only linked to each other.
- Deleted two feature modules whose every definition was already superseded by
  a later module in `.load-order`:
  `zz-rootfs-distro-manager-multiselect.sh` (its bulk installer and menu are
  provided by `zzzzzzzzzzzzzz-multi-install-optimizer.sh` and
  `zzz-rootfs-distro-managers-extended.sh`) and
  `zzzzzzzzzzzzzzzzzzzzzzzzz-provision-direct.sh` (its
  `menu_ultimate_provision` was replaced by the final provision module, and the
  `export -f` it carried is scrubbed by the loader on iSH anyway). The
  multiselect test went with it; the live behaviour stays covered by
  `tests/test-multi-install-optimizer.sh`.

### Dependencies

- **`docs/DEPENDENCIES.md` is generated from `share/systui-deps.tsv`** and
  checked in CI, so the documented package map, the one-line install command
  for every distribution and the manifest cannot drift apart.
- **`install.sh --print-deps`** prints the exact install command for the host
  it is run on, with no root and no network access — the thing to paste into a
  minimal image where you would rather not run the installer first.
- **`tools/deps-verify.sh <family>`** checks that every command the manifest
  promises really exists, and reports advisory ones separately.
- **`tools/deps-audit.py`** validates the manifest (field count, tiers,
  duplicate names, package/command syntax) and requires the commands systui's
  startup path needs to be provided by some row.
- **A package cell may list several packages with `+`** (Alpine ships
  `util-linux` in `util-linux` + `util-linux-misc`), and an optional tenth
  column overrides the dnf name on zypper hosts — openSUSE needs
  `ncurses-utils` and `procps` where Fedora has `ncurses` and `procps-ng`.
  `lsblk`/`findmnt` moved to advisory commands: Alpine does not ship them.
- **`.github/workflows/deps.yml`** installs the manifest set inside Debian 12,
  Ubuntu 24.04, Alpine 3.22, Arch, Fedora 41, openSUSE Tumbleweed and Void
  containers, then runs `tools/deps-verify.sh` in each. A wrong package name
  now fails CI instead of a user's install.

### Installer portability

- **`install.sh` and `update.sh` are plain POSIX sh.** `sh install.sh`,
  `dash install.sh`, `ash`/BusyBox, `bash`, `zsh`, `ksh` and `mksh` all run the
  real script — no Bash needed on the host, no re-exec trampoline, so an
  install no longer fails on a minimal image that has no bash yet (bash is
  still installed as a *runtime* dependency of systui itself).
- zsh is switched to sh semantics at the top of both scripts (`emulate -R sh`):
  without it an unquoted expansion is a single word in zsh and every package
  list would have been passed as one argument.
- Arrays became word lists, `$'\t'` became a `TAB` variable, `echo -e` became
  `printf %b`, `BASH_SOURCE` became `$0`, and the last `var+=` appends were
  spelled out. `set -Eeuo pipefail` is `set -eu`, with every pipeline already
  arranging for the status that matters to be the one tested.
- Tests now prove it instead of asserting the trampoline: a fake `bash` that
  exits 99 is first on PATH for every run, the dependency plan must be
  byte-identical across all shells, and the installer is exercised end to end
  from `dash` and `zsh` into a throw-away prefix.
- **Fixed: `install.sh: mktemp: not found` on a minimal host.** The dependency
  planner wrote its row list through `mktemp` before installing anything, so a
  system without coreutils died in the very step that was supposed to install
  coreutils. Both planner loops now read a here-document from the manifest
  command directly — no temporary file, no subshell, so the package lists
  survive the loop. `tests/test-install-dependencies.sh` covers it with a
  failing `mktemp` first on PATH.

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

### Menu cleanup

- **Containers & virtualization** lists eight grouped entries instead of
  twelve peers: engines (Docker/Podman/containerd), machines (LXC/LXD/Incus/
  libvirt/nspawn/Waydroid), sandboxes (Apptainer/bubblewrap), shared
  configuration, status, cleanup and about.
- **One engine menu** now serves Docker and Podman (they differ only in the
  service unit and configuration file); the duplicate copies had started to
  drift. Registry mirrors, insecure registries, DNS and the address pool live
  once, in the shared configuration; each engine menu keeps its own storage,
  firewall and security settings plus registry login.
- **Distro managers no longer duplicate the engines**: podman, docker, LXC and
  Incus were removed from that catalogue and its four thin per-engine menus
  were deleted — `Containers & virtualization` owns them, and the Distro
  managers menu links there. Fixes a real bug in the process: "browse images"
  was a silent no-op for those four, because the browse workflow only knew
  proot-distro/chroot-distro/distrobox/toolbx/udocker.
- **Shared distro-manager defaults** (install prefix, preferred engine, image
  pull policy) moved out of every manager's configuration menu into one
  `Defaults` entry.
- **Rootfs menu**: the separate `Manage existing rootfs` entry is gone. The
  Workbench already covered it; the actions only Manage had (backend
  reconfiguration, chroot entry options, Bedrock strata, build manifest,
  clone, rename) now live under `More` in the per-rootfs Workbench menu.

### Tests

- `tests/test-container-virt.sh` (86 checks): catalogue integrity, per-PM
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
