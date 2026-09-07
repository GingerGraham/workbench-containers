# workbench-containers

Docker / Podman / Kubernetes aliases and installers for the
[`workbench`](https://github.com/GingerGraham/workbench-core) ecosystem.

An **ecosystem module** (`workbench-core` ARCHITECTURE.md §2) — meaningless
standalone. Requires `workbench-core` installed first:

```sh
wb add containers
```

## What this gives you

- Docker (`d`/`dps`/`dpsa`/`di`/`drm`/`drmi`/`dex`/`dlog`) and Podman
  (`pd`/`pdps`/`pdpsa`/`pdi`) aliases. `docker` aliases to `podman` when
  Podman is present and Docker is not (rootless-first).
- `k` (kubectl), `kube-version`, and `set-kubectl` for pinning a specific
  kubectl release.
- kubectl shell completions (version-stamped cache).
- `install-helm` — via `wb tools update`.

## Requires

Docker/Podman/kubectl themselves are assumed pre-installed or
package-managed — this module doesn't install them (matching the
precursor: no installer existed for any of the three there either).
`install-helm` is the only `install-*` function this module provides.
