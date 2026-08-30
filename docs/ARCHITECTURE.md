# Systui Architecture

Systui is migrating from a historical feature-override stack to explicit core modules and phase-based integrations. New code should follow this document even while legacy `zz...` features remain during the transition.

## Runtime layers

The installed wrapper loads:

1. `src/core/config.sh` — workspace, logging, basic detection, legacy compatibility.
2. `src/core/tui-widgets.sh` — responsive dialog/TUI primitives.
3. `src/core/common.sh` — package mapping and common utilities.
4. `src/core/loader.sh` — the single feature-manifest loader.
5. `src/features/.load-order` — compatibility/features in an explicit order.

`00-platform-bootstrap.sh` loads the modern internal modules:

- `src/core/platform.sh`
- `src/core/loader.sh`
- `src/core/strict-exec.sh`
- `src/core/package-map-data.sh`
- `src/rootfs/metadata.sh`
- `src/rootfs/api.sh`

## Naming

Public internal APIs use the `systui_` prefix:

```bash
systui_runtime_profile
systui_capability
systui_rootfs_exec
systui_rootfs_metadata_get
```

Private helpers should use `_systui_` where practical.

Legacy names remain callable while features migrate, but new code should not add additional generic names or redefine an existing function solely to patch one edge case.

## Feature phases

New feature modules use readable phase prefixes rather than increasing runs of `z` characters.

Current examples:

- `30-health-runtime-capabilities.sh`
- `40-rootfs-init-manager.sh`
- `90-install-guard-final.sh`
- `91-rootfs-exec-final.sh`

The manifest, not lexical filename sorting, is authoritative. Phase numbers communicate intent and make overrides visible during review.

Do not create a new `zzzz...-final.sh` file. If behavior belongs in a stable module, put it there. If a transition override is unavoidable, use a documented phase module and add a test.

## Function exports and iSH ARG_MAX

Modern core/rootfs modules must not use `export -f`.

Feature files are sourced into one Bash process and normally do not need function inheritance. Serialized `BASH_FUNC_*` definitions consume a large portion of iSH-AOK's constrained process argument/environment space.

Legacy exports still exist for compatibility. `src/core/loader.sh` automatically removes exported-function attributes after each feature on iSH so the environment does not grow throughout startup.

Any child process that needs Systui functions should source the required modules or use `run_strict`; it should not depend on exported Bash function bodies.

## Platform and capabilities

Do not scatter runtime probes throughout feature code. Use:

```bash
systui_runtime_profile
systui_capability <name>
systui_detect_init
```

Current profiles include:

- `native-linux`
- `ish-aok`
- `container`
- `proot`
- `wsl`

Current capability names include:

- `chroot`
- `mount`
- `namespaces`
- `proc`
- `sysfs`
- `systemd-runtime`
- `fuse`
- `binfmt`
- `qemu`
- `netlink`
- `argmax-constrained`

Menus should prefer hiding, disabling, or clearly labeling operations whose required capability is unavailable instead of letting them fail deep in execution.

## Rootfs execution

New code should call:

```bash
systui_rootfs_exec TARGET COMMAND [ARGS...]
```

or:

```bash
systui_rootfs_exec_guarded TIMEOUT TARGET COMMAND [ARGS...]
```

The legacy `rootfs_exec_raw` boundary remains during migration and is sanitized in phase 91. Callers should not prepend helper/function names manually or invoke `chroot` independently unless implementing the low-level backend itself.

## Rootfs metadata

Systui-managed roots use:

```text
/etc/systui/rootfs.conf
```

Schema version 1 supports:

```ini
schema=1
distro=debian
release=forky
arch=arm64
backend=mmdebstrap
init=systemd
runtime=ish-systemd-compat
created=...
updated=...
```

Use `src/rootfs/metadata.sh` rather than parsing or rewriting this file ad hoc. Metadata is authoritative when present; filesystem probing remains the fallback for older/external roots.

## Transactional mutations

Operations that can leave a rootfs unusable should follow:

1. validate
2. prepare/install
3. backup current state
4. apply the smallest atomic switch possible
5. verify/commit metadata
6. rollback on failure
7. remove backup after success

The phase-40 init manager is the first implementation of this pattern.

## Package map data

The historical associative `PKG_MAP` in `common.sh` remains the fallback. Migrated mappings live in:

```text
share/packages.tsv
```

Column order is:

```text
canonical    alpine    arch    fedora    void
```

`src/core/package-map-data.sh` overlays TSV entries onto the legacy map. Move mappings incrementally and keep the schema test green.

## TUI layout

Do not hard-code dialog dimensions. Use the helpers in `src/core/tui-widgets.sh`:

```bash
tui_rows
tui_cols
tui_geometry
```

The UI must remain usable on narrow iSH terminals.

## Testing requirements

Every new module must pass:

- `bash -n`
- ShellCheck error checks
- warning-level ShellCheck when added to a critical runtime path
- relevant `tests/test-*.sh`

Portability-sensitive modules must also pass the Alpine/BusyBox CI job.

New modern modules must not:

- export Bash functions
- use fixed dialog dimensions
- use an external `declare -f | sed/awk` pipeline to preserve functions

Prefer behavioral tests over string-only assertions.

## Migration direction

The long-term target is to shrink `src/features/rootfs.sh` and `src/features/sysconfig.sh` into domain modules such as:

```text
src/rootfs/
src/sysconfig/
```

and eventually remove most legacy `zz...` overrides. Migration should be incremental: move one coherent subsystem, preserve its public behavior, add regression tests, then remove the superseded override.
