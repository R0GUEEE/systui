# Systui Rootfs iOS app

Native SwiftUI companion for configuring Linux root filesystem builds intended for import into iSH-AOK.

## App scope

The iOS app configures rootfs recipe parameters (distribution/release/architecture/init/packages/SSH/archive compression) and exports recipe JSON via Files. Linux rootfs construction is a separate builder step; iOS does not run Linux package managers. GitHub Actions compiles an unsigned iOS IPA.

The upstream Systui shell/TUI remains in this repository. The app sources and XcodeGen project are at the repository root. The exported recipe is the initial handoff format; a subsequent phase can add a Linux build workflow that consumes recipes, builds and validates tarballs, then publishes them for iSH-AOK import.

## Build

XcodeGen project, iOS 16 minimum. Download `SystuiRootfs-unsigned-IPA` from a successful Actions run. The IPA is unsigned and requires a supported signing/install path.
