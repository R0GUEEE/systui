Changelog
=========

All notable changes to systui. The version shown in the TUI, `install.sh
--version`, the man page and the iOS companion app all come from
`src/VERSION` + `project.yml`; a release tag must match it.

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
