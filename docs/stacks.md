# Stacks

A guide to the `stack-*` commands in workbench-containers: what a stack is,
every command and option, the Windows template, importing your own compose
projects, editing, settings, storage and troubleshooting.

In the shell, `stack-help` gives the short version, and `stack-help --full`
(or `wb module docs containers stacks`) shows this page.

## What a stack is

A stack is one compose project in one folder. The compose file and the
project's data live together, so a stack runs the same from `stack-up`, from
a hand-run `compose up` in its folder, or on another machine after you copy
the folder over. Multi-gigabyte VM disks and bind-mounted data stay in one
place instead of wherever compose happened to run.

Every stack lives under one root, `~/.local/share/stacks/` by default:

```text
~/.local/share/stacks/
├── .wb/<name>.conf        workbench's record of each stack
├── win11/                 from a template: compose.yaml, .env, storage/, shared/
└── gitea -> ~/src/gitea   imported with stack-import (linked)
```

The root is not under `~/.local/share/workbench/` on purpose: removing
workbench removes that tree, and a stack's data is yours.

## Quick start

A Windows virtual machine, in four commands:

```sh
stack-new windows          # creates the stack "windows"; doesn't start it
stack-up                   # with one stack, the name can be left out
stack-logs -f              # watch Windows download and install itself
stack-info                 # the web viewer URL, the RDP port, the user
```

Your own compose project, in two:

```sh
stack-import ~/src/myapp --dry-run   # look first; nothing changes
stack-import ~/src/myapp             # asks link, move or copy, then confirms
```

## Commands

**Leaving the name out.** `stack-up`, `stack-down`, `stack-logs`,
`stack-path`, `stack-info`, `stack-edit` and `stack-compose` take the stack's
name first, and it can be left out:

- with one stack, that stack is used, and a line on stderr says so
  (`using win11, the only stack`);
- with several, a numbered list of stacks, with whether each is running,
  appears on a terminal. Enter takes the first. After three answers that
  aren't on the list, the command stops with status 2;
- with several and no terminal (a script, a pipe), the command fails with
  status 2 and names the stacks;
- with none, it fails with `no stacks yet (stack-new or stack-import)`.

**`stack-rm` always needs the name,** even with one stack. Without it, it
prints its usage and the stacks' names and returns 2.

Stack names are compose project names: lowercase letters, digits, `-` and
`_`, starting with a letter or a digit, at most 63 characters.

Every command takes `-h` or `--help`.

### stack-new

```text
stack-new [<template>] [--name <name>] [--accept]
stack-new --list
```

Creates a stack from a template in the stacks folder. It doesn't start it.

- **No template:** on a terminal, a numbered list of templates; without one
  (or with `--list`), the list is printed and nothing is created.
- **Template names:** a template's own name, or one of its short names
  (`stack-new win` is `stack-new windows`). `stack-help templates` shows both.
- **`--name <name>`:** the stack's name. Without it, the template's name is
  suggested, or `<template>-2`, `<template>-3` and so on when that's taken.
  On a terminal you're asked, and Enter takes the suggestion; a name that's
  invalid or taken is asked again, three times at most. Without a terminal
  the suggestion is used, and a line says so. An explicit `--name` that's
  taken is an error.
- **`--accept`:** accepts the template's licence without asking. A template
  with a licence prints it either way; without a terminal, `--accept` is
  required.
- **Requirements:** a template can need KVM or a CPU with AVX2. `stack-new`
  checks before creating anything, and says what's missing.
- **Free space:** for a VM template, `stack-new` warns when the stacks
  folder's filesystem has less free space than the VM disk can grow to. It
  doesn't stop.

What it does: copies the template's `compose.yaml`, creates the template's
folders, picks free ports, writes `.env` (mode 0600) with your login name
and a random password, records the stack, and checks the result with
`compose config`. If anything fails, nothing is kept. At the end it prints
the ports, the user, where the password is, and the next commands.

```sh
stack-new windows --name win11
stack-new win                    # the same template, named windows (or windows-2)
```

### stack-import

```text
stack-import <folder|compose-file> [--name <name>] [--link|--move|--copy]
             [--stop-timeout <seconds>] [--dry-run] [--yes]
```

Brings a compose project you already have in as a stack. See
[Importing your own project](#importing-your-own-project) for the details.

- `--link`: leave the folder where it is; the stack is a symlink to it.
- `--move`: move the folder into the stacks folder.
- `--copy`: copy it there and leave the original.
- With none of the three, on a terminal, you're asked. Without a terminal,
  or with `--dry-run`, it links.
- `--name <name>`: the stack's name, which also becomes the compose project
  name.
- `--stop-timeout <seconds>`: how long `stack-down` waits for the containers
  to stop, a whole number of seconds, at least 1.
- `--dry-run`: show the summary and stop. Nothing is created.
- `--yes`: don't ask before importing.

```sh
stack-import ~/src/gitea
stack-import ~/src/gitea --copy --yes
stack-import ~/Downloads/compose.yaml --name scratch
```

### stack-list

```text
stack-list
```

One line per stack: its name, where it came from (`template:windows`,
`link`, `move`, `copy`, or `manual` for a folder with no record), whether it
runs (`running`, `stopped`, `unknown` when the engine can't be asked,
`missing` for a link whose folder is gone), and its folder.

### stack-info

```text
stack-info [<name>]
```

Everything about one stack, a line per fact that has a value:

```text
win11
  folder        /home/you/.local/share/stacks/win11
  origin        template:windows, created 2026-11-25T10:00:00Z
  state         stopped
  compose       podman-compose, compose.yaml, project win11
  web           http://127.0.0.1:8006/
  rdp           127.0.0.1:3389
  login         you; password: WINDOWS_PASSWORD in /home/you/.local/share/stacks/win11/.env
  stop timeout  120s
  needs         kvm
  size          12G
  volumes       none
```

- A linked stack shows `linked to`, with the folder it points at. A moved or
  copied stack shows `from`, the folder it came from.
- `compose` adds `(+ compose.override.yaml)` when there's an override file.
- Ports: a template stack shows each port with its label, and the web viewer
  as a URL. The address is the stack's bind address, with `0.0.0.0` shown as
  `127.0.0.1`. An imported stack shows each `*_PORT=` line in its `.env`.
- `login` names the user and where each secret is. It never prints a
  secret's value.
- `size` is the folder's size on disk (for a linked stack, the linked
  folder).

### stack-up

```text
stack-up [<name>] [compose up args...]
```

Starts the stack in the background (`compose up -d`), with any extra
arguments passed on. It checks the stack's requirements first (KVM, AVX2),
and warns when the stack's bind address isn't a loopback address.

```sh
stack-up win11
stack-up win11 --force-recreate
```

### stack-down

```text
stack-down [<name>] [compose down args...]
```

Stops the stack and removes its containers and network (`compose down`).
The folder and named volumes stay. When the stack has a stop timeout, it's
passed as `-t <seconds>`.

### stack-logs

```text
stack-logs [<name>] [compose logs args...]
```

The stack's logs. `stack-logs win11 -f` follows them; with one stack,
`stack-logs -f`.

### stack-edit

```text
stack-edit [<name>] [compose|env|override]
```

Opens one of the stack's files in your editor, then checks the stack with
`compose config`. See [Editing a stack](#editing-a-stack).

```sh
stack-edit win11          # asks which file when there's more than compose.yaml
stack-edit win11 env      # the stack's .env
```

### stack-compose

```text
stack-compose [<name>] <compose args...>
```

Any other compose command, run for the stack from its folder, with its
recorded compose tool, project and file.

The first word is taken as the stack only when a stack has that name.
Otherwise every word goes to compose, and the stack is chosen by the rule at
the top of this section, so with one stack `stack-compose ps -a` works.

```sh
stack-compose win11 ps -a
stack-compose win11 exec windows sh
```

### stack-path

```text
stack-path [<name>]
```

Prints the stack's folder, symlinks resolved: `cd "$(stack-path win11)"`.

### stack-rm

```text
stack-rm <name> [--purge]
```

Forgets a stack. It refuses while the stack is running.

- A linked stack loses its link and its record. Your folder stays, and
  `--purge` is refused: delete the folder yourself.
- A stack whose folder is in the stacks folder needs `--purge`, because the
  folder is its data. `--purge` needs a terminal and the stack's name typed
  back. It runs `compose down`, deletes the folder and the record, and lists
  any named volumes left behind with the command to remove each.

### stack-help

```text
stack-help [<topic>|<command>] [--full]
```

- `stack-help`: every command, in one screen.
- `stack-help import`: a walkthrough of importing.
- `stack-help templates`: each template's requirements, ports, login and
  licence. `stack-help templates <template>` adds the template's own notes
  on first start, getting in, files and settings.
- `stack-help commands`: the command table only.
- `stack-help <command>`: the same as `<command> --help`; `stack-help up` and
  `stack-help stack-up` both work.
- `stack-help --full`: this page, through `wb module docs containers stacks`.

## Templates

A template is a ready-made stack: a compose file, default settings, and what
`stack-new` needs to fill in (ports, a login, folders). `stack-new` with no
template lists them; `stack-help templates` describes each.

Once created, the stack's files are yours. A template is copied once and
never synced into the stack again.

### Windows

`stack-new windows` (or `stack-new win`) creates a
[dockur/windows](https://github.com/dockur/windows) stack: Windows 11 in a
KVM virtual machine.

**First start.** `stack-up <name>` downloads Windows from Microsoft (several
GB) and installs it without asking anything. Follow it with
`stack-logs <name> -f`. Windows is ready when the web viewer shows the
desktop.

**Getting in.**

- Web viewer: `http://127.0.0.1:<web port>/`, best while Windows installs.
- RDP: `127.0.0.1:<rdp port>`, as the user and password in the stack's
  `.env`, with GNOME Connections, Remmina or FreeRDP.
- `stack-info <name>` shows both ports, the user, and where the password is.

The first Windows stack gets ports 8006 and 3389; each further stack gets
the next free ones.

**Files.** The stack's `shared/` folder shows in Windows as "Shared" on the
desktop, and as drive `Z:`. The VM disk is in `storage/`.

**Settings.** Change them with `stack-edit <name> env`. They apply at the
next `stack-up`.

| Setting | Default | When it applies |
|---|---|---|
| `WINDOWS_VERSION` | `11` | First install only. Other values: `10`, `2022`, `tiny11` and others (dockur/windows docs). |
| `WINDOWS_RAM_SIZE` | `4G` | Next start. |
| `WINDOWS_CPU_CORES` | `2` | Next start. |
| `WINDOWS_DISK_SIZE` | `64G` | Next start. |
| `WINDOWS_NETWORK` | `user` | Next start. `user` is passt user-mode networking, with no extra privileges. |
| `WINDOWS_USERNAME` | your login name | First install only. |
| `WINDOWS_PASSWORD` | 20 random letters and digits | First install only. |
| `WINDOWS_BIND` | `127.0.0.1` | Next start. The address the ports are published on. |
| `WINDOWS_WEB_PORT` | `8006`, or the next free one | Next start. |
| `WINDOWS_RDP_PORT` | `3389`, or the next free one | Next start. |

Requirements and choices made by the template:

- **KVM.** It needs a readable and writable `/dev/kvm`: Linux, or WSL2 with
  nested virtualisation. It doesn't work on macOS or Docker Desktop.
- **Networking.** `NETWORK: user`, with no `/dev/net/tun` and no
  `NET_ADMIN`. SELinux hosts deny containers the tun device anyway. RDP
  reaches Windows without extra configuration. Forwarding another port into
  Windows (SSH, WinRM) takes a `ports:` entry and a `USER_PORTS` entry under
  `environment:` in `compose.yaml`. To switch to NAT, set
  `WINDOWS_NETWORK=nat`, add `/dev/net/tun` and `NET_ADMIN` to
  `compose.yaml`, and on SELinux hosts change the policy yourself.
- **Access.** The web viewer has no password of its own, which is why the
  ports are on `127.0.0.1`. `stack-up` warns when `WINDOWS_BIND` isn't a
  loopback address.
- **Stopping.** The stack's stop timeout is 120 seconds, so `stack-down`
  gives Windows two minutes to shut down.
- **Pinning.** The image is `docker.io/dockurr/windows`, unpinned. To pin it,
  put a tag on `image:` in the stack's `compose.yaml`.

### macOS

[dockur/macos](https://github.com/dockur/macos) stack: macOS in a KVM
virtual machine. Every option dockur/macos accepts, beyond the settings
below, is documented in that repository; `compose.yaml` and `.env` point
there too.

```sh
stack-new macos            # or: stack-new mac
```

**The licence.** macOS is Apple's software, and Apple's licence allows it
only on Apple-branded hardware. `stack-new` prints that notice and asks you
to accept it before it creates anything; without a terminal it needs
`--accept`. It also prints the maker the machine reports
(`/sys/class/dmi/id/sys_vendor`) and whether that's `Apple Inc.`, as a fact:
it doesn't refuse on a mismatch. The record's `ACCEPTED` holds the time you
accepted.

**First start.** `stack-up <name>` downloads macOS recovery from Apple. Open
the web viewer and wait: a progress bar shows while the rest of the
installer downloads, then the recovery menu appears. Unlike Windows, you
install macOS by hand:

1. **Disk Utility**: select the largest `Apple Inc. VirtIO Block Media`
   disk, click **Erase** (APFS, any name), and close Disk Utility.
2. **Reinstall macOS**, and install it on the disk you just erased.
3. Choose region, language and keyboard.
4. **Migration Assistant**: *Not now*. **Apple ID**: *Set Up Later*, then
   *Skip*.
5. **Create a Computer Account**: the user and password are yours to
   choose. The stack doesn't set them, so `.env` has no login or password.

**Getting in.**

- Web viewer: `http://127.0.0.1:<web port>/`.
- VNC: `127.0.0.1:<vnc port>`, with GNOME Connections, Remmina or TigerVNC.
- `stack-info <name>` shows both ports.

The first macOS stack gets ports 8006 and 5900; each further stack, and a
macOS stack beside a Windows one, gets the next free ones.

**Files.** The stack's `shared/` folder is shared with macOS. In macOS's
Terminal, run `sudo -S mount_9p shared`, then open Finder's **Go >
Computer**. The VM disk is in `storage/`.

**Settings.** Change them with `stack-edit <name> env`. They apply at the
next `stack-up`.

| Setting | Default | When it applies |
|---|---|---|
| `MACOS_VERSION` | `15` (Sequoia) | First install only. Other values: `14` (Sonoma), `13` (Ventura), `12` (Monterey), `11` (Big Sur). `26` (Tahoe) works but runs very slowly. |
| `MACOS_RAM_SIZE` | `4G` | Next start. On AMD hosts, keep it at `8G` or less until macOS is installed. |
| `MACOS_CPU_CORES` | `2` | Next start. |
| `MACOS_DISK_SIZE` | `64G` | Next start. Raising it grows the disk; then, in macOS, run `diskutil repairDisk disk2` and `diskutil apfs resizeContainer disk3 0`. |
| `MACOS_NETWORK` | `user` | Next start. `user` is passt user-mode networking, with no extra privileges. |
| `MACOS_BIND` | `127.0.0.1` | Next start. The address the ports are published on. |
| `MACOS_WEB_PORT` | `8006`, or the next free one | Next start. |
| `MACOS_VNC_PORT` | `5900`, or the next free one | Next start. |

Requirements and choices made by the template:

- **KVM and AVX2.** It needs a readable and writable `/dev/kvm`, and a CPU
  with AVX2 (Intel Haswell or AMD Zen, or newer). `stack-new` and `stack-up`
  refuse without either.
- **Disk space.** `stack-new` warns when the stacks folder has less free
  space than `MACOS_DISK_SIZE`. dockur/macos asks for at least 32 GB free.
- **Networking.** `NETWORK: user`, with no `/dev/net/tun` and no
  `NET_ADMIN`, as for Windows. Forwarding another port into macOS (SSH)
  takes a `ports:` entry and a `USER_PORTS` entry under `environment:` in
  `compose.yaml`.
- **Access.** The web viewer and VNC have no password of their own, which is
  why the ports are on `127.0.0.1`. `stack-up` warns when `MACOS_BIND` isn't
  a loopback address.
- **Stopping.** The stack's stop timeout is 120 seconds, so `stack-down`
  gives macOS two minutes to shut down.
- **Pinning.** The image is `docker.io/dockurr/macos`, unpinned. To pin it,
  put a tag on `image:` in the stack's `compose.yaml`.

## Importing your own project

`stack-import` turns a compose project you already have into a stack.

### Link, move or copy

| Mode | What happens | Use it when |
|---|---|---|
| `link` | The stack is a symlink to your folder. Nothing moves. | The project lives in a repository you work in, or it's running now. |
| `move` | The folder moves into the stacks folder. | You want the project and its data under the stacks folder, and only there. |
| `copy` | The folder is copied there; the original stays. | You want to try the stack without touching the original. |

`--move` and `--copy` refuse while the project is running, and when the
container engine can't be asked whether it is. Stop it first, or use
`--link`, which works while it runs.

Without a mode flag, on a terminal, `stack-import` asks. Without a
terminal, it links.

### The summary

Before it changes anything, `stack-import` shows what it's about to do, then
asks `Import it? [Y/n]` on a terminal (`--yes` skips the question):

```text
Import gitea
  from          /home/you/src/gitea (compose.yaml, + compose.override.yaml)
  how           copy — into /home/you/.local/share/stacks/gitea; the original stays
  size          1.2G
  project       gitea (named volumes are keyed by it)
  compose tool  podman-compose
  stop timeout  30s, from stop_grace_period
  volumes       gitea_db — kept by the engine, not in the folder
```

- `from`: the folder, the compose file, and the override file when there's
  one.
- `how`: the mode, and where the files end up.
- `size`: for move and copy only, what will be moved or copied.
- `project`: the compose project name.
- `compose tool`: the tool the stack will use, recorded with it.
- `stop timeout`: how long `stack-down` will wait. See
  [Stop timeouts](#stop-timeouts).
- `volumes`: the named volumes compose reports for the project, or
  `none found`. Not every compose tool can report them.

### Looking first: --dry-run

`stack-import <folder> --dry-run` shows the summary and stops. It doesn't
create the stacks folder, a record or a link. Compose does read the project,
to check it.

### The stack name and the project name

The stack's name is the compose file's top-level `name:`, or else the
folder's name, lowercased, with anything other than letters, digits, `-`
and `_` left out. `--name` chooses another, and also becomes the compose
project name.

Without `--name`, the compose project name doesn't change. That matters
because compose labels a project's named volumes with the project name: a
new project name would start with empty volumes.

### Named volumes

Named volumes stay in the engine's storage, not in the stack folder. Moving
or copying the folder doesn't move them, and `stack-rm --purge` leaves them,
listing the command to remove each.

### Stop timeouts

By default, compose gives containers 10 seconds to stop before it kills
them, which is too short for a VM to shut down. `stack-import` reads the
longest `stop_grace_period` in the compose file (for example `2m`, `90s` or
`1m30s`) and records it in seconds as the stack's stop timeout.
`stack-down` passes it to compose as `-t <seconds>`. `--stop-timeout
<seconds>` sets another time. With neither, compose's 10 seconds apply.

This also covers podman-compose, which ignores `stop_grace_period` on its
own.

### Override files

Compose reads `compose.override.yaml` (or `compose.override.yml`) beside
`compose.yaml`, and `docker-compose.override.yml` (or `.yaml`) beside
`docker-compose.yml`. The stack commands pass both files to compose, so an
override file is used, as it is when you run compose by hand.

### A lone compose file

`stack-import path/to/compose.yaml` copies the file, and any `.env` beside
it, into a new stack folder. It can only be copied. If compose can't read
the copy (the file refers to other files beside it), the copy is removed and
`stack-import` suggests importing the folder instead.

### What isn't checked

`stack-import` doesn't look at bind mounts. A bind mount to a path outside
the folder (`/srv/data:/data`, `../shared:/shared`) keeps pointing at that
path. After a move or copy, a relative mount that left the folder points
somewhere else.

## Editing a stack

`stack-edit [<name>] [compose|env|override]` opens one of the stack's files
in your editor.

- **Which file.** `compose`, `env` or `override` picks one. Without it, when
  the stack has only its compose file, that opens; when it also has a `.env`
  or an override file, you're asked which. A file that doesn't exist is an
  error: `stack-edit` never creates files.
- **The editor.** `VISUAL`, then `EDITOR`, then the first of `nano`, `vim`
  and `vi` found. A setting with arguments works (`EDITOR="code --wait"`).
  `stack-edit` needs a terminal.
- **The check.** After the editor exits, an unchanged file ends there, with
  `no changes`. A changed file is checked with `compose config`. When compose
  can't read the stack, its error is shown and you're asked
  `Edit again? [Y/n]`. Answering `n` leaves the file as it is, with a warning
  that `stack-up` will fail until it's fixed.
- **`.env` permissions.** If the file was mode 0600 and the editor saved it
  with other permissions, it's set back to 0600.
- **A running stack.** Changes apply at the next start. `stack-edit` says so,
  with the command (`stack-down <name> && stack-up <name>`), and doesn't
  restart anything.
- **GUI editors.** An editor that returns at once (`code` without `--wait`)
  makes the check run before you save. Use its wait option.

## Settings

Set these in `~/.config/workbench/local/settings.sh`, or export them.

| Setting | Default | Effect |
|---|---|---|
| `WORKBENCH_STACKS_DIR` | `${XDG_DATA_HOME:-~/.local/share}/stacks` | The stacks folder. |
| `WORKBENCH_STACKS_COMPOSE` | unset | `podman-compose`, `docker-compose` or `docker compose` for new stacks. Anything else is an error. |
| `WORKBENCH_STACKS_SUBVOLUME` | unset | `yes` or `no` answers the btrfs subvolume question in advance. |
| `WORKBENCH_STACKS_NOCOW` | `1` | `0` skips `chattr +C` on a template's disk folder. |

## Tab completion

Every stack command completes in bash and zsh:

| Command | Completes |
|---|---|
| `stack-new` | templates; options |
| `stack-import` | file and folder names; options |
| `stack-up`, `stack-down`, `stack-logs`, `stack-path`, `stack-info`, `stack-rm` | stack names; options |
| `stack-edit` | stack names, then `compose`, `env` or `override` |
| `stack-compose` | stack names, then compose commands (`ps`, `logs`, `exec`, ...) |
| `stack-help` | `import`, `templates`, `commands`; `--full` |

zsh shows a description beside each: a template's description, a stack's
origin. Completion doesn't wait on the container engine.

In zsh, a `compinit` run later in your `.zshrc`, or by a plugin manager
after the first prompt, would normally drop the completions. workbench
registers them again at the next prompt.

Completion needs a workbench-core newer than 2.32.2. With an older core the
stack commands still work, but nothing completes; `wb update` brings core up
to date.

## How stacks run

### The compose tool

A new stack uses `podman-compose` when `podman` and `podman-compose` are
both installed. Otherwise it uses Docker's compose plugin
(`docker compose`), then `docker-compose`, and those only with a real Docker
CLI, not `podman-docker`'s `docker` script. Podman comes first so a stack's
files belong to your user. `WORKBENCH_STACKS_COMPOSE` chooses for new
stacks.

The choice is recorded per stack. A project started by one engine can't be
managed by another, so installing Docker later doesn't change an existing
stack.

### The record

Each stack has a record, `.wb/<name>.conf` in the stacks folder. It's read
as data, never run.

| Key | Meaning |
|---|---|
| `ORIGIN` | `template:<template>`, `link`, `move` or `copy`. |
| `PROJECT` | The compose project name. |
| `COMPOSE` | The compose tool. |
| `COMPOSE_FILE` | The compose file's name in the folder. |
| `STOP_TIMEOUT` | Seconds `stack-down` waits; empty for compose's default. |
| `CREATED` / `ADDED` | When `stack-new` created it, or `stack-import` imported it. |
| `FROM` | For a moved or copied stack, the folder it came from. |
| `TEMPLATE_SHA` | The workbench-containers snapshot the template came from. |
| `REQUIRES` | The template's requirements, checked at each `stack-up`. |
| `BIND_VAR` | The `.env` variable holding the bind address. |
| `PORT_LABELS` | `<variable>:<label>` per port, for `stack-info`. |
| `LOGIN_VARS`, `SECRET_VARS` | The `.env` variables holding the user and the secrets. |
| `ACCEPTED` | When the template's licence was accepted, if it has one. |

### `.env` beats the shell

Plain compose fills in `${VAR}` from your shell's environment ahead of the
folder's `.env`. The stack commands do the opposite: for every variable the
stack's `.env` defines, they ignore the same name exported in your shell,
and print one warning naming what they overrode. Without this, an exported
`VERSION` or `USERNAME` would silently replace a stack's value. Variables
the tools themselves need (`PATH`, `HOME`, `DOCKER_HOST` and the like) keep
the shell's value.

The cost: a one-off `TAG=dev stack-up x` doesn't reach compose. Edit the
stack's `.env` instead. A hand-run `compose up` in the folder still behaves
as plain compose does.

Template variables are named after the template (`WINDOWS_*`), so a generic
exported name can't collide with them. Imported stacks keep their own
names.

### Your shell's cd hooks

The stack commands enter a stack's folder without running your shell's
`cd` hooks (zsh's `chpwd` functions), so direnv stays quiet and zoxide
doesn't record stack folders.

If you `cd` into a stack folder yourself, direnv with `load_dotenv` on
reports the stack's `.env` as blocked. Leave it blocked: `direnv allow`
would export the stack's settings, password included, into your shell.

### Ports

Template stacks publish their ports on `127.0.0.1`, so they're reachable
from this machine only. Each new stack gets free ports that no other stack
has claimed, running or not.

## Storage

- **btrfs and NOCOW.** On btrfs, a template's disk folder (`storage/` for
  Windows) gets `chattr +C` while it's still empty, so the VM disk created in
  it isn't copy-on-write and doesn't fragment. NOCOW also turns off btrfs
  checksums for that disk. `WORKBENCH_STACKS_NOCOW=0` opts out.
- **A subvolume or not.** The first time the stacks folder is created on
  btrfs, you're asked once whether to make it a subvolume, with an
  explanation. A plain folder (the default, and the answer without a
  terminal) is included in snapshots of `/home`, and each snapshot makes a
  VM disk copy-on-write again. A subvolume is left out of `/home` snapshots,
  which also means snapshots, and backups taken from them, no longer cover
  your stacks. It can only be asked then: a folder can't become a subvolume
  later.
- **Free space.** `stack-new` warns when the filesystem has less free space
  than a VM disk can grow to. It goes ahead anyway.
- **Sparse disks.** A VM disk is sparse: it takes the space it has used, not
  its full size. `du -sh` shows what it uses; `ls -l` shows its full size.
  `stack-info` shows `du`'s figure.
- **Rootful Docker.** Docker running as root writes a stack's files as root,
  so deleting them with `stack-rm --purge` needs `sudo`. It prints the
  command and never runs `sudo` itself. Under rootless podman it deletes them
  through `podman unshare`.
- **What `--purge` deletes.** The stack's folder and its record. Named
  volumes, images and anything a bind mount points at outside the folder
  stay.

## Troubleshooting

**KVM isn't available.** `stack-new` and `stack-up` say `needs KVM`. Check
virtualisation is on in the firmware, and that you can open `/dev/kvm`:
`sudo usermod -aG kvm $USER`, then log in again. On WSL2, set
`nestedVirtualization=true` under `[wsl2]` in `%UserProfile%\.wslconfig`,
then `wsl --shutdown`. macOS has no KVM.

**No AVX2.** A template that needs AVX2 refuses on a CPU that doesn't report
it in `/proc/cpuinfo` (older than Intel Haswell or AMD Zen, or a VM that
hides it).

**A requirement this version can't check.** `needs '<word>', which this
version of workbench-containers can't check`: the template is newer than
the module's code. `wb update containers`.

**SELinux denials.** The templates mount their folders with `:Z`, which
relabels them. If a container still can't read or write, look for denials:
`sudo ausearch -m avc -ts recent`.

**direnv says `.env` is blocked.** That's from your own `cd` into a stack
folder. Leave it blocked; see [Your shell's cd hooks](#your-shells-cd-hooks).

**A port is already in use.** `stack-new` picks free ports, but something
else can take one later. `stack-info <name>` shows the stack's ports;
`stack-edit <name> env` changes them; then `stack-up <name>`.

**A VM is killed at shutdown.** `stack-down` waits for the stack's stop
timeout, but shutting the host down stops containers with the engine's own
timeout, 10 seconds under podman-compose. Stop VM stacks with `stack-down`
before shutting the host down. For an imported VM with no
`stop_grace_period`, set one with `--stop-timeout` when importing, or add
`STOP_TIMEOUT=<seconds>` to its record.

**Nothing starts at boot under rootless podman.** `restart: unless-stopped`
only restarts containers at boot when `podman-restart.service` is enabled
for your user and lingering is on (`loginctl enable-linger`). workbench
enables neither.

**`stack-edit`'s check ran before you saved.** Your editor returned at once.
Use its wait option (`EDITOR="code --wait"`), or set `EDITOR` to a terminal
editor.
