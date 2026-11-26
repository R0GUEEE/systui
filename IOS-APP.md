# Systui Rootfs iOS app

Native SwiftUI companion for configuring Linux root filesystem builds intended for import into iSH-AOK.

## App scope

Configure distribution/release/architecture/init/packages/SSH/archive compression and export recipe JSON through the iOS Files exporter. Linux rootfs construction is a separate builder step; iOS does not execute Linux package managers. GitHub Actions compiles an unsigned IPA on macOS.

The upstream Systui shell/TUI remains intact. Rootfs assembly now has an on-demand GitHub Actions workflow for **Alpine/OpenRC**. Export the recipe from the app, add the JSON under `recipes/` in this repository, then run **Actions → Build rootfs tarball** and select its path. The workflow checks expected root entries and uploads the archive as an artifact.

The first builder supports Alpine on aarch64, armv7, and x86_64. Other distributions and init systems are not implemented yet. This produces a minimal Alpine rootfs, not the full distribution-specific configuration supported by Systui’s interactive Linux builder.

## Build

XcodeGen project, iOS 16 minimum. Download `SystuiRootfs-unsigned-IPA` from a successful Actions run. The IPA is unsigned and requires a supported signing/install path.
