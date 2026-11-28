Changelog
=========

All notable changes to systui. The version shown in the TUI, `install.sh
--version`, the man page and the iOS companion app all come from
`src/VERSION` + `project.yml`; a release tag must match it.

## 1.3.0 — 2026-11-27

### Ahead-of-time JIT — deep-analysis fixes

- **`Link AOT executable` dead-ended after one failure.** meson/make wrote
  straight into the output directory, so a failed attempt left it behind and
  the next attempt hit "Refusing to overwrite" with no way out. The step now
  asks before replacing an existing build, and removes its own output when the
  configure, build or artifact check fails, so it can always be retried.
- **`Record images` could destroy a good recording set.** Recording now goes
  into a staging directory that is swapped in only after all six artifacts
  verify; a failed or incomplete run keeps the previous set and leaves no
  staging directory behind.
- **The linked output path is validated before anything runs.** It reaches
  meson and make unquoted, and an unvalidated path containing `;` became a
  command — now rejected up front with the same rules as every other AOT path.
- **Guest preparation distinguishes its two failures.** "python3 is not
  installed" and "python3 cannot import zlib" are reported separately (they
  need different fixes), and the probe no longer depends on the shell
  supporting `-ec` combined options.
- **Status shows each artifact once**, with its path, instead of printing
  "Recordings" and "Evidence" twice.

### Guest rootfs import (Rootfs → iSH-AOK → iOS-linuxkit → Guest root filesystems)

- **"Download and import the pinned Alpine rootfs" no longer hangs at 100%.**
  The fetcher had no timeouts, so a server or proxy that stopped sending left
  `curl` waiting indefinitely with the progress bar already complete.
  Transfers now cap the connect phase (`--connect-timeout 20`), abandon a
  transfer that stops moving (`--speed-time`, `--speed-limit`), and have an
  absolute ceiling (`--max-time 1800`); all three are adjustable through
  `SYSTUI_IOSKIT_*` environment variables. `wget` gets the equivalent read
  timeout.
- **A re-run reuses the verified archive** instead of downloading again, and
  prints which archive it is using. A mismatched archive is fetched again.
- **Imports are atomic.** `fakefsify` now writes into a staging directory that
  is renamed into place only after it looks like a rootfs. A failed or
  interrupted import leaves no half-image (which previously *looked* installed,
  because any directory with `data/` or `bin/` counted), and replacing an
  existing image restores the previous one if the new import fails.
- **Both `fakefsify` argument shapes work.** The iSH-AOK build takes a flags
  directory first (`<flags dir> <tarball> <output> <flags…>`); the upstream
  tool takes `<tarball> <output>`. The importer asks the binary's usage line
  rather than guessing, and removes the flags directory afterwards.

### Ahead-of-time JIT (Rootfs → Ahead-of-time JIT)

- **`Configure paths` saved the wrong values.** The save loop iterated the
  directory *values* and then asked for `"${!p}"` by name, so all seven
  settings (`IOSKIT_AOT_DIR`, `_ROOT`, `_RECORDINGS_DIR`, `_OUTPUT_DIR`,
  `_GADGET_DIR`, `_RECORDER_DIR`, `_EVIDENCE_DIR`) ended up holding the last
  directory typed. Saving is now one explicit write per setting through
  `ios_aot_save_paths`, which updates the live variables only after the file
  is written.
- **`Install training guest packages` was inverted.** Answering *No* returned
  success and skipped the work; answering *Yes* ran it and then failed with a
  bare status 1 on any error. It now refuses on *No*, reports a real message on
  failure, and verifies `import zlib` inside the guest afterwards.
- **Builds honour the artifact path.** A target that ignores its output
  variable now has its `ish` adopted into the configured directory
  (`ios_aot_adopt_artifact`) instead of failing with "ish is missing"; an
  existing binary is never replaced.
- **Cancelling is side-effect free.** `Build`, `Record`, `Link` and `Validate`
  ask before creating their output directory instead of after.
- **Validation evidence must be fresh.** The old check passed whenever the
  evidence directory existed, which it always did. Validation now fails unless
  this run wrote a new file into it.
- **The guided workflow asks for paths once.** The second `Configure paths`
  pass (seven prompts to re-point one rootfs) became `ios_aot_paths_root_only`.
- **One AOT menu instead of two competing ones.** Rootfs → Ahead-of-time JIT is
  now an index — Status / Guided workflow / Run one stage / Toolchain /
  Shell / About — with the stages in pipeline order one level down. The saved
  toolchain menu (Bun workspace, recorder build, gate checks) is reachable as
  *Toolchain* rather than being shadowed.

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
