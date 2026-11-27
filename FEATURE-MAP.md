# Systui Rootfs iOS feature map

This app adapts portable Systui rootfs-build and post-configuration features to a recipe + ARM64 GitHub Actions builder. It does not attempt to embed the shell TUI or manage the host phone.

## Implemented from Systui

- **Distribution/release/build target:** 11 tested ARM64 distro roots, release-specific presets, init-system selection; Bedrock is described as a base-hijacking meta-distro rather than a standalone root.
- **Package profiles:** core CLI, editors, developer tools, languages, network diagnostics, server, web services, security, storage, and terminal utilities; package aliases map to distro-native names. Manual native package names remain available.
- **Init/services:** OpenRC, SysVinit, runit, and systemd choices where applicable; optional SSH, cron, and nginx package installation and boot enablement.
- **Accounts and shell:** optional user creation, bash/zsh/fish login shell, sudo/wheel membership, and default editor. No password is embedded in recipe JSON; set account passwords after importing.
- **Post-build configuration:** hostname/hosts, DNS resolvers, timezone/localtime, locale, login environment, SSH port and key-oriented root policy, package-cache cleanup, and embedded `/etc/systui-rootfs.json` build metadata.
- **Recipe workflow:** versioned JSON export/import, migration defaults for older recipes, locally saved draft, reproducible per-distro presets, gzip/xz archive, ARM64 archive-layout validation.
- **Native package managers:** apt, apk, pacman, dnf, zypper, emerge, and xbps. Devuan rootfs snapshots are SHA-256 verified before import.

## Not ported from Systui yet

Systui’s host-only TUI features—live system health and process/network diagnostics, repository editing against the running host, chroot workbench/rootfs manager, Bedrock strata management, service start/status, and host package-manager operations—do not map directly to an iOS recipe builder. Full package catalogue search, arbitrary repository/key management, more architecture targets, custom post-build scripts, and Bedrock/FUSE creation remain future work. The generated tarballs have passed build and structural checks but have not been boot-tested on every iSH-AOK version.

## Build

Use **Actions → Build rootfs tarball** with a recipe JSON under `recipes/`. The iOS app is built by the macOS **Build iOS app** workflow; its IPA artifact is unsigned.
