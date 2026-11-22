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
  `docker` binary is (rootless-first). An alias is not defined when your shell
  already has an alias or function of that name; yours is kept, and `wb status`
  lists what was left alone.
- `dc` — your `DOCKER_COMPOSE_CMD` if set, otherwise `docker-compose`, then the
  `docker compose` plugin (only with a real `docker` binary), then
  `podman-compose`; chosen when the shell starts.
- `k` (kubectl), `kube-version`, and `set-kubectl` for pinning a specific
  kubectl release (`set-kubectl -v 1.31.2`, or `-l` for the latest stable).
  It downloads into `~/.local/bin/k8s/kubectl-<version>/`, verified against
  `dl.k8s.io`'s published SHA-256, and points `~/.local/bin/kubectl` at it.
  A kubectl installed elsewhere (Homebrew, a distro package) is left alone.
- kubectl shell completions (version-stamped cache).
- Installers, via `wb tools install <name>` (and `wb tools upgrade <name>`):
  `docker`, `podman`, `helm`, and `kubectl` (latest stable, through
  `set-kubectl -l`).

## Docker and Podman installers

Supported: Fedora/RHEL (dnf), Debian/Ubuntu (apt), Arch (pacman) and macOS
(brew). Other distros are refused with a message.

`wb tools install docker`

- Linux: **rootless** Docker CE. Fedora/RHEL and Debian/Ubuntu get Docker's own
  repository, with its signing key pinned in this module; Arch uses its
  official packages. Then `dockerd-rootless-setuptool.sh install`, a per-user
  `docker.service`, linger (so the daemon survives logout and starts at boot)
  and the `rootless` Docker CLI context. There is no system `docker.service`
  and no `docker` group: a fresh install turns the system daemon off. An
  existing Docker gets its packages updated and nothing else changed.
- Missing `/etc/subuid` or `/etc/subgid` ranges for your user are added with
  `usermod`. Without a systemd user session (a container, WSL2 without
  systemd) the packages install and the installer prints the command to
  finish the setup later.
- A `podman-docker` package conflicts with Docker (both own `/usr/bin/docker`).
  The installer asks before removing it, and stops if you say no or there is no
  terminal to ask on.
- macOS: Docker Desktop (`brew install --cask docker`).

`wb tools install podman`

- Installs `podman`, `toolbox` (`podman-toolbox` on Debian/Ubuntu; Linux only)
  and `podman-compose`. A distro without toolbox or podman-compose gets a
  warning and carries on.
- If there is no `docker` command at all, it asks whether to install
  `podman-docker`, a `docker` command that runs podman. The answer defaults to
  no, and with no terminal to ask on it is no. Running
  `wb tools install docker podman` (in that order) installs Docker first, so
  the question never comes up.
- macOS: `podman` and `podman-compose` through brew. Podman runs containers in
  a VM there, so run `podman machine init && podman machine start` once; the
  installer does not.

## Requires

kubectl can come from `wb tools install kubectl` or from your package manager.
Docker and Podman can come from `wb tools install docker|podman` or from your
package manager.
