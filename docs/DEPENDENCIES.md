# Dependencies

What systui needs on a Linux host, generated from
[`share/systui-deps.tsv`](../share/systui-deps.tsv) — the same manifest
`install.sh` installs from and `tools/deps-verify.sh` checks against.

```sh
sh install.sh --print-deps    # exact install command for this host
sh install.sh --deps-only     # install and verify the set below
sh tools/deps-verify.sh apt   # check the declared commands are present
```

The installer and updater are plain POSIX sh: `sh`, `dash`, `ash`/BusyBox,
`bash`, `zsh`, `ksh` and `mksh` all work, and Bash is not required to
install. systui itself runs on Bash — it is the first row below, so the
installer puts it in place before the TUI is ever started.

Only the `core` tier is installed up front. Everything else systui can
use (compilers, language managers, extra tooling) is installed on demand
from the menus, and a package a distribution does not carry is reported
and skipped rather than aborting the install.

## One-line install per distribution

- **Debian, Ubuntu, Devuan, Kali, Mint**

  ```sh
  sudo apt-get update && sudo apt-get install -y --no-install-recommends bash dialog coreutils grep sed gawk findutils diffutils tar gzip bzip2 xz-utils unzip ca-certificates curl procps util-linux less ncurses-bin
  ```

- **Alpine**

  ```sh
  sudo apk add bash dialog coreutils grep sed gawk findutils diffutils tar gzip bzip2 xz unzip ca-certificates curl procps-ng util-linux util-linux-misc less ncurses
  ```

- **Arch, Manjaro, EndeavourOS, Arch ARM**

  ```sh
  sudo pacman -S --needed --noconfirm bash dialog coreutils grep sed gawk findutils diffutils tar gzip bzip2 xz unzip ca-certificates curl procps-ng util-linux less ncurses
  ```

- **Fedora, RHEL, CentOS, Rocky, Alma**

  ```sh
  sudo dnf install -y bash dialog coreutils grep sed gawk findutils diffutils tar gzip bzip2 xz unzip ca-certificates curl procps-ng util-linux less ncurses
  ```

- **Void**

  ```sh
  sudo xbps-install -Sy bash dialog coreutils grep sed gawk findutils diffutils tar gzip bzip2 xz unzip ca-certificates curl procps-ng util-linux less ncurses
  ```

- **Gentoo**

  ```sh
  sudo emerge --noreplace app-shells/bash dev-util/dialog sys-apps/coreutils sys-apps/grep sys-apps/sed sys-apps/gawk sys-apps/findutils sys-apps/diffutils app-arch/tar app-arch/gzip app-arch/bzip2 app-arch/xz-utils app-arch/unzip app-misc/ca-certificates net-misc/curl sys-process/procps sys-apps/util-linux sys-apps/less sys-libs/ncurses
  ```

- **openSUSE, SLES**

  ```sh
  sudo zypper --non-interactive install bash dialog coreutils grep sed gawk findutils diffutils tar gzip bzip2 xz unzip ca-certificates curl procps util-linux less ncurses-utils
  ```

openSUSE shares most names with the dnf column but not all: the
manifest carries an optional tenth column that overrides the dnf name
where zypper needs one (`ncurses-utils`, `procps`).

## Package map

| systui needs | apt | apk | pacman | dnf / zypper | xbps | emerge |
| --- | --- | --- | --- | --- | --- | --- |
| `bash` | `bash` | `bash` | `bash` | `bash` | `bash` | `app-shells/bash` |
| `dialog` | `dialog` | `dialog` | `dialog` | `dialog` | `dialog` | `dev-util/dialog` |
| `coreutils` | `coreutils` | `coreutils` | `coreutils` | `coreutils` | `coreutils` | `sys-apps/coreutils` |
| `grep` | `grep` | `grep` | `grep` | `grep` | `grep` | `sys-apps/grep` |
| `sed` | `sed` | `sed` | `sed` | `sed` | `sed` | `sys-apps/sed` |
| `gawk` | `gawk` | `gawk` | `gawk` | `gawk` | `gawk` | `sys-apps/gawk` |
| `findutils` | `findutils` | `findutils` | `findutils` | `findutils` | `findutils` | `sys-apps/findutils` |
| `diffutils` | `diffutils` | `diffutils` | `diffutils` | `diffutils` | `diffutils` | `sys-apps/diffutils` |
| `tar` | `tar` | `tar` | `tar` | `tar` | `tar` | `app-arch/tar` |
| `gzip` | `gzip` | `gzip` | `gzip` | `gzip` | `gzip` | `app-arch/gzip` |
| `bzip2` | `bzip2` | `bzip2` | `bzip2` | `bzip2` | `bzip2` | `app-arch/bzip2` |
| `xz-utils` | `xz-utils` | `xz` | `xz` | `xz` | `xz` | `app-arch/xz-utils` |
| `unzip` | `unzip` | `unzip` | `unzip` | `unzip` | `unzip` | `app-arch/unzip` |
| `ca-certificates` | `ca-certificates` | `ca-certificates` | `ca-certificates` | `ca-certificates` | `ca-certificates` | `app-misc/ca-certificates` |
| `curl` | `curl` | `curl` | `curl` | `curl` | `curl` | `net-misc/curl` |
| `procps` | `procps` | `procps-ng` | `procps-ng` | `procps-ng` | `procps-ng` | `sys-process/procps` |
| `util-linux` | `util-linux` | `util-linux+util-linux-misc` | `util-linux` | `util-linux` | `util-linux` | `sys-apps/util-linux` |
| `less` | `less` | `less` | `less` | `less` | `less` | `sys-apps/less` |
| `ncurses` | `ncurses-bin` | `ncurses` | `ncurses` | `ncurses` | `ncurses` | `sys-libs/ncurses` |

A `+` joins packages that a distribution splits (Alpine ships `util-linux`
in `util-linux` + `util-linux-misc`); both are installed.

## Commands each package must provide

| package | mandatory | advisory |
| --- | --- | --- |
| `bash` | `bash` | — |
| `dialog` | `dialog` | — |
| `coreutils` | `id`, `mktemp`, `head`, `tr`, `cut`, `sort`, `tee`, `chmod`, `rm`, `date`, `env`, `stat`, `readlink`, `dirname`, `basename` | — |
| `grep` | `grep` | — |
| `sed` | `sed` | — |
| `gawk` | `awk`, `gawk` | — |
| `findutils` | `find`, `xargs` | — |
| `diffutils` | `diff` | — |
| `tar` | `tar` | — |
| `gzip` | `gzip`, `gunzip`, `zcat` | — |
| `bzip2` | `bzip2`, `bunzip2` | — |
| `xz-utils` | `xz`, `unxz`, `xzcat` | — |
| `unzip` | `unzip` | — |
| `ca-certificates` | — | — |
| `curl` | `curl` | — |
| `procps` | `ps`, `top`, `free`, `pgrep`, `pkill` | — |
| `util-linux` | `mount`, `umount`, `blkid`, `flock`, `nsenter`, `unshare`, `getopt`, `script` | `lsblk`, `findmnt` |
| `less` | `less` | — |
| `ncurses` | `clear`, `tput` | `infocmp` |

Advisory commands are reported by `deps-verify.sh` and `install.sh
--deps-only` but never fail an install: a distribution may ship an older
or split package without them.

## Optional, installed on demand

| tool | why systui wants it |
| --- | --- |
| `git` | `update.sh` (it installs git itself before cloning) |
| `wget` | fallback fetcher when curl is absent |
| `iproute2 / ip` | network configuration menus |
| `shadow / passwd` | user and password management |
| `findmnt, lsblk` | storage views on systems whose util-linux ships them |
| `tmux, zsh, fish, starship` | shell and terminal features |
| `qemu-user-static` | foreign-architecture rootfs builds |
| `docker / podman / lxc` | containers & virtualization menus |

## Verification in CI

`.github/workflows/deps.yml` installs the manifest set inside Debian,
Ubuntu, Alpine, Arch, Fedora, openSUSE and Void containers and runs
`tools/deps-verify.sh` there, so a wrong or missing package name fails CI
instead of a user's install.
