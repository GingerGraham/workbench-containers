# Stack templates

How `stack-new`'s templates work, and how to add one. For using stacks, see
[stacks.md](stacks.md).

## The template folder

Each template is a folder under `stacks/templates/<template>/` in this
module. The folder's name is the template's name.

| File | Required | What it's for |
|---|---|---|
| `compose.yaml` | yes | Copied once into the new stack. From then on it's the user's file. |
| `env.default` | yes | The template's settings with their defaults. Becomes the start of the stack's `.env`. |
| `template.conf` | yes | What `stack-new` needs to know: requirements, folders, ports, login, licence. Read as data, never sourced. |
| `help.txt` | no | Plain text shown by `stack-help templates <template>`: first start, getting in, files, settings. |

## The naming rule

Every variable a template's `compose.yaml` reads, and every variable in its
`env.default`, is `<TEMPLATE>_<NAME>`: the template's name in capitals, with
`-` as `_` (`WINDOWS_RAM_SIZE`, `WINDOWS_BIND`). A generic variable exported
in the user's shell (`VERSION`, `USERNAME`) then can't stand in for one, and
two templates never share a name. Every variable `template.conf` names
(`BIND_VAR`, `PORTS`, `LOGIN_VARS`, `SECRET_VARS`, `DISK_VAR`) follows the
same rule.

The names on the left of `environment:` are the image's own, and stay as the
image expects them:

```yaml
environment:
  RAM_SIZE: ${WINDOWS_RAM_SIZE:-4G}
```

## template.conf

One `KEY=value` per line; lists are space-separated; `#` starts a comment
line. The last line for a key wins.

| Key | Format | Read by | Meaning |
|---|---|---|---|
| `DESCRIPTION` | text | `stack-new`, `stack-help`, completion | One line saying what the template makes. |
| `ALIASES` | names | `stack-new`, `stack-help templates` | Other names `stack-new` accepts (`stack-new win`). Each is a valid stack name, unique across all templates, and not another template's folder name. A folder's own name wins over an alias. Completion offers folder names only. |
| `REQUIRES` | words | `stack-new`, `stack-up` | What the host must have. `kvm`: `/dev/kvm` exists and can be opened for reading and writing. `avx2`: the CPU reports AVX2 in `/proc/cpuinfo`. An unknown word refuses with "update workbench-containers", so an older module never creates or starts a template it can't check. |
| `DIRS` | folders | `stack-new` | Folders created in the stack (`storage shared`). |
| `NOCOW_DIRS` | folders | `stack-new` | Of `DIRS`, the ones that get `chattr +C` on btrfs while still empty: folders that will hold VM disks. |
| `BIND_VAR` | variable | `stack-new`, `stack-up`, `stack-info` | The variable holding the address the ports are published on. `stack-new` sets it to `127.0.0.1`; `stack-up` warns when it isn't a loopback address. |
| `PORTS` | `VAR:base:label ...` | `stack-new`, `stack-info` | One entry per published port. `stack-new` picks the first free port from `base` (up to `base + 99`) that no other stack has claimed, and writes `VAR=<port>`. `label` names it in the output; `web` is shown as an `http://` URL. |
| `LOGIN_VARS` | variables | `stack-new`, `stack-info` | Set to the user's login name (letters, digits, `.`, `_`, `-`, at most 20 characters). |
| `SECRET_VARS` | variables | `stack-new`, `stack-info` | Set to 20 random letters and digits. Never printed. |
| `STOP_TIMEOUT` | seconds | `stack-new` | How long `stack-down` waits for the containers to stop. Match the compose file's `stop_grace_period`. |
| `DISK_VAR` | variable | `stack-new` | The `env.default` variable holding the VM disk's size (`64G`; `K`, `M`, `G` or `T`). When the stacks folder's filesystem has less free space, `stack-new` warns and goes ahead. |
| `ACCEPT` | text | `stack-new` | A licence the user must accept before the stack is created. See [Licences](#licences). |
| `ACCEPT_VENDOR_CHECK` | text | `stack-new` | A hardware maker, such as `Apple Inc.`, reported beside `ACCEPT`. |
| `NOTE` | text | `stack-new` | Printed at the end of `stack-new`, with `<name>` replaced by the stack's name. |

The Windows template's `template.conf`:

```sh
DESCRIPTION=Windows 11 in a KVM virtual machine (dockur/windows)
ALIASES=win
REQUIRES=kvm
DISK_VAR=WINDOWS_DISK_SIZE
DIRS=storage shared
NOCOW_DIRS=storage
BIND_VAR=WINDOWS_BIND
PORTS=WINDOWS_WEB_PORT:8006:web WINDOWS_RDP_PORT:3389:rdp
LOGIN_VARS=WINDOWS_USERNAME
SECRET_VARS=WINDOWS_PASSWORD
STOP_TIMEOUT=120
NOTE=The first stack-up downloads Windows (several GB) and installs it unattended; follow it with: stack-logs <name> -f. Setup and access: stack-help templates windows
```

## What stack-new writes

In order: it checks `REQUIRES`, asks for `ACCEPT`, creates the stacks folder
if needed, warns about `DISK_VAR`, then creates the stack. If anything fails
after the stack's folder exists, the folder and record are removed again.

**The stack folder** gets a copy of `compose.yaml`, the `DIRS` folders, and
`.env`, created mode 0600: `env.default` as it is, then a generated block:

```sh
# Written by stack-new on 2026-11-25. Edit freely.
WINDOWS_BIND=127.0.0.1
WINDOWS_WEB_PORT=8006
WINDOWS_RDP_PORT=3389
WINDOWS_USERNAME=you
WINDOWS_PASSWORD=<20 random letters and digits>
```

**The record**, `.wb/<name>.conf` in the stacks folder:

| Key | Value |
|---|---|
| `ORIGIN` | `template:<template>`, the folder name even when an alias was used. |
| `TEMPLATE_SHA` | The workbench-containers snapshot the template came from. |
| `PROJECT` | The stack's name, used as the compose project name. |
| `COMPOSE` | The compose tool. |
| `COMPOSE_FILE` | `compose.yaml`. |
| `STOP_TIMEOUT` | From `template.conf`. |
| `REQUIRES` | From `template.conf`; `stack-up` checks it again. |
| `BIND_VAR` | From `template.conf`. |
| `PORT_LABELS` | `VAR:label` per `PORTS` entry, without the base port. |
| `LOGIN_VARS`, `SECRET_VARS` | From `template.conf`. |
| `ACCEPTED` | The UTC time the licence was accepted; empty without `ACCEPT`. |
| `CREATED` | The UTC time the stack was created. |

Finally `stack-new` runs `compose config` for the new stack; if compose
rejects it, nothing is kept.

## Licences

Use `ACCEPT` when the software in the image comes with terms the user has to
agree to, for example an operating system licensed for one kind of
hardware. Keep the text short and factual: what the terms say, and where to
read them.

- On a terminal, `stack-new` prints the text and asks
  `Accept and continue? [y/N]`. Anything but `y` or `yes` stops with
  `not created`.
- Without a terminal, it needs `--accept`. Without it, it stops.
- `--accept` on a terminal still prints the text, without asking.
- Nothing is created before the answer, the stacks folder included.
- The record's `ACCEPTED` holds the time.

The macOS template is the example: its `ACCEPT` says Apple's licence allows
macOS only on Apple-branded hardware, and `ACCEPT_VENDOR_CHECK=Apple Inc.`

With `ACCEPT_VENDOR_CHECK`, `stack-new` prints one line before the question,
reporting a fact and nothing more:

```text
This machine reports its maker as Apple Inc.. That matches Apple Inc..
This machine reports its maker as Framework. That isn't Apple Inc..
This machine doesn't report its maker.
```

The maker is read from `/sys/class/dmi/id/sys_vendor`. It doesn't stop
`stack-new` either way: whether the terms are met is for the user to judge.

## Adding a template

1. **The folder:** `stacks/templates/<template>/`, with a name that's a
   valid stack name (lowercase letters, digits, `-`, `_`). Add `compose.yaml`,
   `env.default`, `template.conf` and, for anything with a first start or a
   way in, `help.txt`.
2. **Naming:** every variable is `<TEMPLATE>_*`, in `compose.yaml`,
   `env.default` and `template.conf`.
3. **`REQUIRES`:** list what the host needs (`kvm`, `avx2`). A new kind of
   requirement needs code in `_containers_requires_check` (`shell/stacks.sh`)
   first.
4. **Loopback ports:** every `ports:` entry starts with
   `${<TEMPLATE>_BIND:-127.0.0.1}:`, and `BIND_VAR` names that variable.
5. **`:Z` mounts:** every bind mount ends in `:Z`, so SELinux hosts relabel
   it; hosts without SELinux ignore it.
6. **Restart policy:** `restart: unless-stopped`, so a stack the user
   stopped stays stopped.
7. **No `container_name`,** so several stacks from one template can run side
   by side. No `/dev/net/tun` and no `cap_add`: use user-mode networking
   (`<TEMPLATE>_NETWORK:-user`).
8. **Stopping:** set `stop_grace_period` in `compose.yaml` and the same time,
   in seconds, as `STOP_TIMEOUT`. podman-compose ignores
   `stop_grace_period`; `stack-down` passes `STOP_TIMEOUT` as `-t`.
9. **Disks:** a folder that holds a VM disk goes in `NOCOW_DIRS`, and the
   disk size variable in `DISK_VAR`.
10. **A spike first:** run the template by hand on Fedora under rootless
    podman, with SELinux enforcing, before adding it.
11. **The checks:** `tests/check-stacks.sh` case 17 reads every template and
    checks the rules above: the files exist, no `container_name`,
    `/dev/net/tun` or `cap_add`, user-mode networking, `unless-stopped`, ports
    on the bind variable, `:Z` mounts, the naming rule, the required
    `template.conf` keys, and that aliases are valid and unique.
