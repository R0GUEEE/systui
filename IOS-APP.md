# Systui Rootfs iOS app

Systui Rootfs is a native iOS recipe editor and GitHub Actions rootfs builder. It currently offers ARM64/aarch64 recipes for Debian, Devuan, Ubuntu, Alpine, Arch Linux ARM, Fedora, Kali, openSUSE Leap, openSUSE Tumbleweed, Gentoo and Void Linux. Choose the distro and release, init system, package list, SSH option, hostname, timezone, DNS resolver and tar compression in the app.

The Linux runner builds native ARM64 roots, validates the resulting archive layout, and publishes the tarball as a workflow artifact. Base roots come from multi-architecture OCI images or upstream Linux Containers snapshots (Devuan); the Arch Linux ARM OCI image is community maintained. Package installation runs through each distro’s own manager. Build outputs are intended for iSH-AOK import.

Bedrock Linux is intentionally excluded as a standalone recipe: it is a meta-distribution that hijacks a base root and needs FUSE. This builder does not perform that operation. Rootfs output targets aarch64; other architectures are not enabled in this workflow.

## Build a rootfs

1. Export a JSON recipe in the app, then add it under `recipes/` in this repository. Presets for each supported distro are already in that folder.
2. Open **Actions → Build rootfs tarball**, select the recipe path and artifact name, and run the workflow.
3. Download the artifact from the completed run and select its `.tar.gz` or `.tar.xz` in iSH-AOK’s rootfs import flow.

The workflow tests structural archive integrity, not boot or runtime compatibility on every iSH-AOK release. It cannot install packages that are absent from a distro’s current ARM64 repositories.

## Build the iOS app

XcodeGen project, iOS 16 minimum. Download `SystuiRootfs-unsigned-IPA` from a successful **Build iOS app** run. The IPA is unsigned and needs a supported signing/install path.
