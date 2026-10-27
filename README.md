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
  (`pd`/`pdps`/`pdpsa`/`pdi`) aliases. The Docker ones need a real `docker`
  binary. `docker` aliases to `podman` when Podman is present and no
  `docker` binary is (rootless-first).
- `dc` — your `DOCKER_COMPOSE_CMD` if set, otherwise `docker-compose`, otherwise
  `podman-compose`; chosen when the shell starts.
- `k` (kubectl), `kube-version`, and `set-kubectl` for pinning a specific
  kubectl release (`set-kubectl -v 1.31.2`, or `-l` for the latest stable).
  It downloads into `~/.local/bin/k8s/kubectl-<version>/`, verified against
  `dl.k8s.io`'s published SHA-256, and points `~/.local/bin/kubectl` at it.
  A kubectl installed elsewhere (Homebrew, a distro package) is left alone.
- kubectl shell completions (version-stamped cache).
- Installers, via `wb tools install <name>` (and `wb tools upgrade <name>`):
  `helm`, and `kubectl` (latest stable, through `set-kubectl -l`).

## Requires

Docker/Podman themselves are assumed pre-installed or package-managed —
this module doesn't install them. kubectl can come from
`wb tools install kubectl` or from your package manager.
