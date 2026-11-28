# Systui Rootfs iOS app

Systui Rootfs is a native SwiftUI recipe editor and GitHub Actions rootfs builder. It offers ARM64/aarch64 presets for Debian, Devuan, Ubuntu, Alpine, Arch Linux ARM, Fedora, Kali, openSUSE Leap/Tumbleweed, Gentoo and Void Linux. The app carries over Systui’s portable rootfs options: distro-native package profiles and manual packages, init selection, SSH/cron/nginx services, user and shell creation, sudo/wheel membership, editor, hostname, DNS, timezone, locale, and tar compression. Recipes can be imported/exported and drafts persist locally.

The ARM64 Linux runner builds, applies configuration, embeds the recipe under `/etc/systui-rootfs.json`, validates the archive layout and publishes a workflow artifact. Package installation uses the distro’s native manager. Devuan snapshots are SHA-256 verified; the Arch Linux ARM OCI source is community-maintained.

Bedrock Linux is intentionally excluded as a standalone recipe: it hijacks a base root and requires FUSE. Other architectures are not enabled in this workflow.

## Build a rootfs

1. Export a JSON recipe in the app, then add it under `recipes/` in this repository. Presets for each supported distro are already in that folder.
2. Open **Actions → Build rootfs tarball**, select the recipe path and artifact name, and run the workflow.
3. Download the artifact from the completed run and select its `.tar.gz` or `.tar.xz` in iSH-AOK’s rootfs import flow.

The workflow tests structural archive integrity, not boot or runtime compatibility on every iSH-AOK release. It cannot install packages that are absent from a distro’s current ARM64 repositories.

## Build the iOS app

XcodeGen project, iOS 16 minimum. Download `SystuiRootfs-unsigned-IPA` from a successful **Build iOS app** run. The IPA is unsigned and needs a supported signing/install path.

## Where the app ends and systui begins

This app adapts portable systui rootfs-build and post-configuration features to a
recipe + ARM64 builder. It does not embed the shell TUI and does not manage the
host phone.

**Carried over from systui**

- Distribution/release/build target: 11 tested ARM64 distro roots, release-specific
  presets, init-system selection. Bedrock is shown as a base-hijacking meta-distro
  rather than a standalone root.
- Package profiles: core CLI, editors, developer tools, languages, network
  diagnostics, server, web services, security, storage and terminal utilities.
  Aliases map to distro-native names; manual native package names stay available.
- Init/services: OpenRC, SysVinit, runit and systemd where applicable; optional
  SSH, cron and nginx installation and boot enablement.
- Accounts and shell: optional user creation, bash/zsh/fish login shell,
  sudo/wheel membership and default editor. No password is embedded in recipe
  JSON — set account passwords after importing.
- Post-build configuration: hostname/hosts, DNS resolvers, timezone/localtime,
  locale, login environment, SSH port and key-oriented root policy, package-cache
  cleanup and embedded `/etc/systui-rootfs.json` metadata.
- Recipe workflow: versioned JSON export/import, migration defaults for older
  recipes, locally saved draft, reproducible presets, gzip/xz archive and ARM64
  archive-layout validation.
- Native package managers: apt, apk, pacman, dnf, zypper, emerge and xbps.

**Not ported (host-only in systui)**

Live system health and process/network diagnostics, repository editing against
the running host, the chroot workbench/rootfs manager, Bedrock strata management,
service start/status, and host package-manager operations do not map to an iOS
recipe builder. Full package-catalogue search, arbitrary repository/key
management, more architecture targets, custom post-build scripts and
Bedrock/FUSE creation remain future work. Generated tarballs pass build and
structural checks but have not been boot-tested on every iSH-AOK version.
