# workbench-containers

Docker / Podman / Kubernetes aliases, installers and compose stacks for the
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
- Compose stacks (`stack-new`, `stack-add`, `stack-list`, `stack-up`,
  `stack-down`, `stack-logs`, `stack-compose`, `stack-path`, `stack-rm`): one
  folder per compose project under `~/.local/share/stacks/`, with a
  dockur/windows template. See [Stacks](#stacks).

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

## Stacks

A stack is one compose project in one folder. The compose file and the
project's data live together, so a stack runs the same from `stack-up`, from
a hand-run `compose up` in its folder, or on another machine after you copy
the folder over. Stacks keep multi-gigabyte VM disks (dockur's Windows) and
bind-mounted data in one place, instead of wherever compose happened to run.

```text
~/.local/share/stacks/
├── .wb/<name>.conf        workbench's record of each stack
├── win11/                 from a template: compose.yaml, .env, storage/, shared/
└── gitea -> ~/src/gitea   imported with stack-add (linked)
```

The root is not under `~/.local/share/workbench/` on purpose: removing
workbench removes that tree, and a stack's data is yours.

| Function | What it does |
|---|---|
| `stack-new [<template>] [--name <name>]` | Create a stack from a template. With no template it lists them. Doesn't start it. |
| `stack-add <folder\|file> [--name <name>] [--link\|--move\|--copy]` | Bring an existing compose project in. |
| `stack-list` | One line per stack: origin, whether it runs, where it is. |
| `stack-up <name> [args]` | `compose up -d` for the stack. |
| `stack-down <name> [args]` | `compose down` for the stack, with the template's stop timeout. |
| `stack-logs <name> [args]` | `compose logs`, e.g. `stack-logs win11 -f`. |
| `stack-compose <name> <args>` | Any compose command, run for the stack, e.g. `stack-compose win11 ps -a`. |
| `stack-path <name>` | Print the stack's folder: `cd "$(stack-path win11)"`. |
| `stack-rm <name> [--purge]` | Forget a stack. `--purge` deletes its folder. |

```sh
stack-new windows --name win11
stack-up win11
stack-logs win11 -f
stack-down win11
```

### Settings

Set these in `~/.config/workbench/local/settings.sh`, or export them.

| Variable | Default | Effect |
|---|---|---|
| `WORKBENCH_STACKS_DIR` | `${XDG_DATA_HOME:-~/.local/share}/stacks` | The stacks folder. |
| `WORKBENCH_STACKS_COMPOSE` | unset | `podman-compose`, `docker-compose` or `docker compose`. Anything else is an error. |
| `WORKBENCH_STACKS_SUBVOLUME` | unset | `yes` or `no` answers the btrfs question below in advance. |
| `WORKBENCH_STACKS_NOCOW` | `1` | `0` skips `chattr +C` on a template's disk folder. |

### Compose tool

A new stack uses `podman-compose` when `podman` and `podman-compose` are both
installed. Otherwise it uses Docker's compose plugin (`docker compose`), then
`docker-compose`, and only with a real Docker CLI, not `podman-docker`'s
`docker` script. Podman comes first so a stack's files belong to your user,
not to root. `dc` keeps its own order, which prefers `docker-compose`.

The choice is recorded per stack, in its `.wb/<name>.conf`. A project started
by one engine can't be managed by another, so installing Docker later doesn't
change an existing stack.

### `.env` beats the shell

Plain compose fills in `${VAR}` from your shell's environment ahead of the
folder's `.env`. The `stack-*` functions do the opposite: for every variable
the stack's `.env` defines, they ignore the same name exported in your shell,
and print one warning naming what they overrode. Without this, an exported
`VERSION` or `USERNAME` would silently replace a stack's value. It applies to
every stack, imported ones included, and to every compose tool.

The cost: a one-off `TAG=dev stack-up x` no longer reaches compose. Edit the
stack's `.env` instead. A hand-run `compose up` in the folder still behaves as
plain compose does.

Template variables are named after the template (`WINDOWS_*`). Imported
stacks keep their own variable names.

### Importing a project

`stack-add <folder>` links the folder into the stacks folder by default. It
doesn't move anything, and running containers keep their mounts.

- `--move` and `--copy` refuse while the project is running, and also when the
  container engine can't be asked.
- A lone compose file is copied, with any `.env` beside it. If compose then
  can't read the copy, it is removed again; the file probably refers to files
  beside the original, so add its folder instead.
- The project name is kept (`name:` in the file, otherwise the folder's name),
  because named volumes are keyed by it. `--name` overrides it, and becomes the
  project name.
- Named volumes are reported, not moved or rewritten. They stay in the
  engine's storage, and `stack-rm --purge` leaves them behind.

`stack-rm` on a linked stack removes the link and the record only. Your
folder stays.

### Windows template

`stack-new windows` creates a [dockur/windows](https://github.com/dockur/windows)
stack: Windows in a KVM virtual machine, driven by the stack's `compose.yaml`
and `.env`. The first `stack-up` downloads Windows (several GB) and installs
it unattended; follow it with `stack-logs <name> -f`. The folder is yours
once created and is never synced again.

- **KVM.** Needs a readable and writable `/dev/kvm`: Linux, or WSL2 with
  nested virtualisation. It doesn't work on macOS or Docker Desktop.
- **Networking.** The template uses `NETWORK: user` (passt user-mode
  networking), with no `/dev/net/tun` and no `NET_ADMIN`. SELinux hosts deny
  containers the tun device anyway, so this gives every host and engine the
  same behaviour with fewer privileges. RDP reaches Windows without extra
  configuration. Forwarding another port into Windows (SSH, WinRM) takes a
  `ports:` entry and a `USER_PORTS` entry under `environment:` in
  `compose.yaml`. To switch to NAT, set `WINDOWS_NETWORK=nat` in `.env`, add
  `/dev/net/tun` and `NET_ADMIN` to `compose.yaml`, and, on SELinux hosts,
  change the policy yourself; workbench doesn't.
- **Access.** Ports are published on `127.0.0.1`, and each stack gets its own
  free ports (8006 and 3389 first, then the next free ones). The web viewer has
  no password of its own, so think before changing `WINDOWS_BIND` in `.env`.
  `stack-up` warns when it isn't a loopback address.
- **Credentials.** `stack-new` writes your login name and a random 20-character
  password to the stack's `.env` (mode 0600) and never prints the password.
  They only apply when Windows is first installed; changing them later in
  `.env` doesn't change the account.
- **btrfs.** On btrfs, `storage/` gets `chattr +C` while it is still empty, so
  the VM disk created in it is not copy-on-write. dockur's own btrfs warning
  is expected and harmless once that is set. NOCOW also turns off btrfs
  checksums for that disk. `WORKBENCH_STACKS_NOCOW=0` opts out.

  The first time the stacks folder is created on btrfs, you are asked once
  whether to make it a subvolume. A plain folder (the default, and the answer
  with no terminal) is included in snapshots of `/home`, so each snapshot
  makes a VM disk copy-on-write again. A subvolume is skipped by `/home`
  snapshots, which also means snapshots, and backups taken from them, no
  longer cover your stacks. A folder can only become a subvolume when it is
  created, which is why it is asked then.
- **Stopping.** `stack-down` gives Windows 120 seconds to shut down.
  podman-compose ignores `stop_grace_period`, so the container's own stop
  timeout stays at 10 seconds: stop the VM with `stack-down` before shutting
  the host down. Under rootless podman, `restart: unless-stopped` doesn't
  start anything at boot unless `podman-restart.service` is enabled and
  lingering is on; workbench enables neither.
- **Rootful Docker.** Docker running as root writes the stack's files as root,
  so deleting them with `stack-rm --purge` needs `sudo`; it tells you the
  command and never runs `sudo` itself.
- **Pinning.** The image is `docker.io/dockurr/windows`, unpinned. To pin it,
  put a tag on `image:` in the stack's `compose.yaml`.
- **macOS.** A macOS template is planned separately.

## Requires

kubectl can come from `wb tools install kubectl` or from your package manager.
Docker and Podman can come from `wb tools install docker|podman` or from your
package manager.
