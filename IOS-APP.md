# Systui Rootfs iOS app

Systui Rootfs is a native SwiftUI recipe editor and GitHub Actions rootfs builder. It offers ARM64/aarch64 presets for Debian, Devuan, Ubuntu, Alpine, Arch Linux ARM, Fedora, Kali, openSUSE Leap/Tumbleweed, Gentoo and Void Linux. The app carries over Systui’s portable rootfs options: distro-native package profiles and manual packages, init selection, SSH/cron/nginx services, user and shell creation, sudo/wheel membership, editor, hostname, DNS, timezone, locale, and tar compression. Recipes can be imported/exported and drafts persist locally. See [FEATURE-MAP.md](FEATURE-MAP.md) for the boundary between app features and Systui host-only features.

The ARM64 Linux runner builds, applies configuration, embeds the recipe under `/etc/systui-rootfs.json`, validates the archive layout and publishes a workflow artifact. Package installation uses the distro’s native manager. Devuan snapshots are SHA-256 verified; the Arch Linux ARM OCI source is community-maintained.

Bedrock Linux is intentionally excluded as a standalone recipe: it hijacks a base root and requires FUSE. Other architectures are not enabled in this workflow.

## Build a rootfs

1. Export a JSON recipe in the app, then add it under `recipes/` in this repository. Presets for each supported distro are already in that folder.
2. Open **Actions → Build rootfs tarball**, select the recipe path and artifact name, and run the workflow.
3. Download the artifact from the completed run and select its `.tar.gz` or `.tar.xz` in iSH-AOK’s rootfs import flow.

The workflow tests structural archive integrity, not boot or runtime compatibility on every iSH-AOK release. It cannot install packages that are absent from a distro’s current ARM64 repositories.

## Build the iOS app

XcodeGen project, iOS 16 minimum. Download `SystuiRootfs-unsigned-IPA` from a successful **Build iOS app** run. The IPA is unsigned and needs a supported signing/install path.
