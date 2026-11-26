# Systui Rootfs iOS app

Native SwiftUI companion for configuring Linux root filesystem builds intended for import into iSH-AOK.

## App scope

Configure distribution/release/architecture/init/packages/SSH/archive compression and export recipe JSON through the iOS Files exporter. Linux rootfs construction is a separate builder step; iOS does not execute Linux package managers. GitHub Actions compiles an unsigned IPA on macOS.

The upstream Systui shell/TUI remains intact. The exported JSON is the first handoff format; the next phase can add a Linux builder workflow that consumes recipes, assembles and validates tarballs, and publishes import artifacts.

## Build

XcodeGen project, iOS 16 minimum. Download `SystuiRootfs-unsigned-IPA` from a successful Actions run. The IPA is unsigned and requires a supported signing/install path.
