#!/usr/bin/env bash
# shell/stacks.sh — workbench-containers
# Compose stacks: one folder per compose project under
# ${XDG_DATA_HOME:-~/.local/share}/stacks/<name>/, with functions to create
# them (stack-new from a template, stack-import from a project you already
# have), list them, look at one (stack-info), run, stop and log them, edit
# their files (stack-edit), and remove them; stack-help explains them.
# workbench-core D129, D132. Tab completion for every stack command is
# registered through the Core API's workbench_complete (D132).
#
# Registered at tier: tools (workbench.yml), after containers.sh, whose
# _containers_docker_bin and _containers_docker_compose_plugin it calls.
# Bash 3.2 and zsh: this file is sourced into both. No associative arrays,
# no ${var,,}/${var^^}, no mapfile, no arrays at all, and no word-splitting
# of unquoted parameters (zsh doesn't do it).
#
# Three rules for anything added here:
#   - No globs over folders that may be empty. zsh's default NOMATCH aborts
#     the command with "no matches found", and 2>/dev/null doesn't stop it.
#     Enumerate with find (-mindepth/-maxdepth work in GNU and BSD find).
#   - Call engine and compose programs with `command` (command podman,
#     command podman-compose), so a user's alias — or this module's
#     docker→podman one — is never used by mistake.
#   - Every compose run goes through _containers_compose_in, so the stack's
#     .env beats the shell (D129). No other function calls a compose tool
#     directly.
#
# Settings (README "Stacks"):
#   WORKBENCH_STACKS_DIR        the stacks root (default ${XDG_DATA_HOME:-~/.local/share}/stacks)
#   WORKBENCH_STACKS_COMPOSE    podman-compose | docker-compose | "docker compose"
#   WORKBENCH_STACKS_SUBVOLUME  yes|no — answers the btrfs question in advance
#   WORKBENCH_STACKS_NOCOW      0 skips chattr +C (default 1)
# Test-only internals, overridable the way workbench-cloud's
# _AWSEMU_OSTREE_MARKER is:
#   _CONTAINERS_KVM_DEV         default /dev/kvm
#   _CONTAINERS_SNAPPER_DIR     default /etc/snapper/configs
#   _CONTAINERS_CPUINFO         default /proc/cpuinfo
#   _CONTAINERS_DMI_VENDOR_FILE default /sys/class/dmi/id/sys_vendor

_containers_stacks_lib_dir="$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"

_containers_stacks_root() {
    printf '%s\n' "${WORKBENCH_STACKS_DIR:-${XDG_DATA_HOME:-${HOME}/.local/share}/stacks}"
}

_containers_stacks_templates_dir() {
    printf '%s\n' "${_containers_stacks_lib_dir}/../stacks/templates"
}

_containers_stack_meta_path() {
    printf '%s/.wb/%s.conf\n' "$(_containers_stacks_root)" "$1"
}

# _containers_kv_get <file> <KEY> — the last KEY=value in <file>, read as
# data (grep/cut), never sourced: the same rule as sync.conf. Empty when the
# file or the key is missing.
_containers_kv_get() {
    case "$2" in
        ''|*[!ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_]*) return 1 ;;
    esac
    [ -f "$1" ] || return 0
    grep -E "^$2=" "$1" | tail -n 1 | cut -d= -f2-
}

# _containers_stack_name_ok <name> — a compose project name: lowercase
# letters, digits, - and _, starting with a letter or a digit, at most 63
# characters. Letters are listed out because a-z ranges follow the locale.
_containers_stack_name_ok() {
    case "$1" in
        ''|[!abcdefghijklmnopqrstuvwxyz0123456789]*) return 1 ;;
        *[!abcdefghijklmnopqrstuvwxyz0123456789_-]*) return 1 ;;
    esac
    [ "${#1}" -le 63 ]
}

# _containers_real_docker — Docker's own CLI. podman-docker's /usr/bin/docker
# script passes _containers_docker_bin but isn't Docker (as D128 decided).
# Runs the CLI, so don't call this at shell start.
_containers_real_docker() {
    _containers_docker_bin && command docker --version 2>/dev/null | grep -q '^Docker version'
}

# _containers_stack_compose_available — for the availability declaration.
# Runs nothing, so it's safe at every shell start.
_containers_stack_compose_available() {
    [ -n "${WORKBENCH_STACKS_COMPOSE:-}" ] && return 0
    command -v podman >/dev/null 2>&1 && command -v podman-compose >/dev/null 2>&1 && return 0
    _containers_docker_compose_plugin && return 0
    _containers_docker_bin && command -v docker-compose >/dev/null 2>&1
}

# _containers_stack_compose_cmd — the compose command a new stack records.
# Rootless-first, like the docker→podman alias, so a stack's files belong to
# the user. Deliberately not _containers_compose_cmd (the dc alias), which
# prefers docker-compose: on a podman host that talks to whatever
# /var/run/docker.sock is, possibly rootful podman through podman-docker.
_containers_stack_compose_cmd() {
    case "${WORKBENCH_STACKS_COMPOSE:-}" in
        "") ;;
        podman-compose|docker-compose|"docker compose")
            printf '%s\n' "${WORKBENCH_STACKS_COMPOSE}"
            return 0
            ;;
        *)
            log_error "stacks: WORKBENCH_STACKS_COMPOSE must be podman-compose, docker-compose or \"docker compose\" (got '${WORKBENCH_STACKS_COMPOSE}')"
            return 1
            ;;
    esac
    if command -v podman >/dev/null 2>&1 && command -v podman-compose >/dev/null 2>&1; then
        echo podman-compose
        return 0
    fi
    if _containers_real_docker; then
        if _containers_docker_compose_plugin; then
            echo "docker compose"
            return 0
        fi
        if command -v docker-compose >/dev/null 2>&1; then
            echo docker-compose
            return 0
        fi
    fi
    if command -v podman >/dev/null 2>&1; then
        log_error "stacks: podman is installed but podman-compose isn't — install it with your package manager, or set WORKBENCH_STACKS_COMPOSE"
    else
        log_error "stacks: no compose tool found — run: wb tools install podman (it adds podman-compose), or wb tools install docker"
    fi
    return 1
}

# _containers_stack_engine_cli <compose> — the engine CLI that owns a
# compose tool's containers. docker-compose without a real Docker CLI is
# docker-compose on the podman socket (DOCKER_HOST).
_containers_stack_engine_cli() {
    case "$1" in
        podman-compose) echo podman ;;
        *) if _containers_real_docker; then echo docker; else echo podman; fi ;;
    esac
}

# _containers_stack_label_key <compose> — the label its compose tool puts on
# a project's containers and volumes.
_containers_stack_label_key() {
    case "$1" in
        podman-compose) echo io.podman.compose.project ;;
        *)              echo com.docker.compose.project ;;
    esac
}

# _containers_compose_file_in <dir> — the compose file compose would pick,
# in the Compose specification's order.
_containers_compose_file_in() {
    local f
    for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml; do
        if [ -f "$1/${f}" ]; then
            printf '%s\n' "${f}"
            return 0
        fi
    done
    return 1
}

# _containers_env_file_wins <file> — compose takes ${VAR} from the shell
# ahead of .env, so an exported VERSION or USERNAME would silently replace
# the stack's own value (D129). Unsets every variable <file> defines that
# the shell exports, and names them in one warning. The variables the tools
# themselves need keep the shell's value. Call it only inside the runner's
# subshell, so the caller's shell keeps everything.
_containers_env_file_wins() {
    local key shadowed=""
    [ -f "$1" ] || return 0
    while IFS= read -r key; do
        case "${key}" in
            PATH|HOME|USER|LOGNAME|SHELL|PWD|TMPDIR|LANG|LC_*|XDG_*|DOCKER_HOST|DOCKER_CONTEXT|CONTAINER_HOST) continue ;;
        esac
        if printenv "${key}" >/dev/null 2>&1 && unset "${key}" 2>/dev/null; then
            shadowed="${shadowed} ${key}"
        fi
    done < <(awk -F= '/^[A-Za-z_][A-Za-z0-9_]*=/ { print $1 }' "$1")
    if [ -n "${shadowed}" ]; then
        log_warn "stacks: using the stack's .env, not your shell, for:${shadowed}"
    fi
    return 0
}

# _containers_cd_quiet <cd args...> — builtin cd without the shell's
# directory-change hooks. zsh runs chpwd and every chpwd_functions entry on
# each cd, subshells included. In a stack folder that meant direnv's hook
# reported the stack's .env as blocked on every stack-* call (and with the
# .env allowed, would have loaded it and tripped _containers_env_file_wins
# for every key), and hooks such as zoxide's recorded the folder. zsh's -q
# skips the hooks; bash has none on cd. Keyed on ZSH_VERSION, the
# interpreter running this line, not WORKBENCH_SHELL (workbench-core D130).
_containers_cd_quiet() {
    if [ -n "${ZSH_VERSION:-}" ]; then
        builtin cd -q "$@" || return
    else
        builtin cd "$@" || return
    fi
}

# _containers_override_file_in <dir> <compose-file> — the override file
# compose reads beside <compose-file> when no -f is given: compose.override.*
# next to compose.*, docker-compose.override.* next to docker-compose.*.
# The runner passes -f, which turns that automatic read off, so it names the
# override itself (D132).
_containers_override_file_in() {
    local base f
    case "$2" in
        compose.yaml|compose.yml) base=compose ;;
        docker-compose.yaml|docker-compose.yml) base=docker-compose ;;
        *) return 1 ;;
    esac
    for f in "${base}.override.yaml" "${base}.override.yml"; do
        if [ -f "$1/${f}" ]; then
            printf '%s\n' "${f}"
            return 0
        fi
    done
    return 1
}

# _containers_compose_in <dir> <compose> <project> <file> <args...> — runs
# compose from <dir> in a subshell, so the caller's directory and
# environment never change. Builds the argument list with set --, as
# _containers_pick_port does: no arrays, and zsh doesn't split unquoted
# parameters.
_containers_compose_in() {
    local dir="$1" compose="$2" project="$3" file="$4" override
    shift 4
    (
        _containers_cd_quiet -- "${dir}" || exit 1
        _containers_env_file_wins .env
        if override="$(_containers_override_file_in . "${file}")"; then
            set -- -f "${override}" "$@"
        fi
        set -- -p "${project}" -f "${file}" "$@"
        case "${compose}" in
            podman-compose)   command podman-compose "$@" ;;
            docker-compose)   command docker-compose "$@" ;;
            "docker compose") command docker compose "$@" ;;
            *) log_error "stacks: unknown compose command '${compose}'"; exit 1 ;;
        esac
    )
}

# _containers_fs_type <path> — the filesystem type, on Linux only (GNU
# stat). Empty elsewhere: BSD stat's -f means something else.
_containers_fs_type() {
    [ "${WORKBENCH_OS:-}" = "Linux" ] || return 0
    stat -f -c %T "$1" 2>/dev/null
}

# _containers_nocow <dir> — chattr +C on an empty folder on btrfs, so the VM
# disk created in it later inherits No_COW. WORKBENCH_STACKS_NOCOW=0 skips.
_containers_nocow() {
    [ "${WORKBENCH_STACKS_NOCOW:-1}" = "0" ] && return 0
    [ "$(_containers_fs_type "$1")" = "btrfs" ] || return 0
    if ! command -v chattr >/dev/null 2>&1 || ! chattr +C "$1" 2>/dev/null; then
        log_warn "stacks: couldn't set No_COW on $1 — a VM disk there will fragment on btrfs"
    fi
}

# _containers_stacks_claimed_ports — every *_PORT value in every stack's
# .env, one per line: ports promised to stacks that may be stopped. -L
# follows linked stacks.
_containers_stacks_claimed_ports() {
    local root f
    root="$(_containers_stacks_root)"
    [ -d "${root}" ] || return 0
    command find -L "${root}" -mindepth 2 -maxdepth 2 -name .env -type f 2>/dev/null | while IFS= read -r f; do
        awk -F= '$1 ~ /^[A-Z_]*PORT$/ && $2 ~ /^[0-9]+$/ { print $2 }' "${f}"
    done
}

# _containers_random_secret — 20 letters and digits from /dev/urandom. It
# reads a fixed 512 bytes (about 125 letters and digits) rather than piping
# the endless /dev/urandom into tr and waiting for head to close the pipe:
# that only ends if tr is killed by SIGPIPE. CI runners can start a job with
# SIGPIPE ignored, and BSD tr, unlike GNU tr, then keeps reading forever
# instead of stopping at the write error (the macOS job hung on it).
_containers_random_secret() {
    local s
    s="$(head -c 512 /dev/urandom 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | head -c 20)"
    [ "${#s}" -eq 20 ] || return 1
    printf '%s\n' "${s}"
}

# _containers_login_name — the user's login name, cut to what a Windows
# account name allows (20 characters), or "user".
_containers_login_name() {
    local u
    u="$(id -un 2>/dev/null | LC_ALL=C tr -cd 'A-Za-z0-9._-' | cut -c1-20)"
    printf '%s\n' "${u:-user}"
}

# _containers_kvm_ok — /dev/kvm exists and this user can open it.
_containers_kvm_ok() {
    local dev="${_CONTAINERS_KVM_DEV:-/dev/kvm}"
    [ -c "${dev}" ] && [ -r "${dev}" ] && [ -w "${dev}" ]
}

# _containers_kvm_hint — one line on how to get KVM on this host.
_containers_kvm_hint() {
    if [ "${WORKBENCH_OS:-}" = "Mac" ]; then
        echo "KVM is Linux-only; this template needs a Linux host"
    elif [ "${WORKBENCH_WSL:-}" = "true" ]; then
        echo 'enable nested virtualisation: nestedVirtualization=true under [wsl2] in %UserProfile%\.wslconfig, then wsl --shutdown'
    else
        echo "check virtualisation is on in the firmware, and that you can open /dev/kvm (sudo usermod -aG kvm \$USER, then log in again)"
    fi
}

# _containers_stack_meta_write <name> <KEY=value>... — replaces the stack's
# record: a header comment, then one line per argument.
_containers_stack_meta_write() {
    local name="$1" file kv
    shift
    file="$(_containers_stack_meta_path "${name}")"
    mkdir -p "$(dirname -- "${file}")" || return 1
    {
        printf '# workbench record of stack %s — read as data, never sourced\n' "${name}"
        for kv in "$@"; do
            printf '%s\n' "${kv}"
        done
    } > "${file}"
}

# _containers_stack_dir <name> — prints <root>/<name> when it is a folder, or
# a symlink to one. Fails with a message otherwise.
_containers_stack_dir() {
    local name="$1" dir target
    if ! _containers_stack_name_ok "${name}"; then
        log_error "stacks: '${name}' isn't a valid stack name (lowercase letters, digits, - and _, starting with a letter or digit, at most 63 characters)"
        return 1
    fi
    dir="$(_containers_stacks_root)/${name}"
    if [ -d "${dir}" ]; then
        printf '%s\n' "${dir}"
        return 0
    fi
    if [ -L "${dir}" ]; then
        target="$(readlink "${dir}")"
        log_error "stacks: ${name}: its folder ${target} is gone (${dir} links to it)"
        return 1
    fi
    log_error "stacks: ${name}: no such stack (stack-list shows them)"
    return 1
}

# The record readers. Each prints the recorded value, else the default.
_containers_stack_compose_of() {
    local value
    value="$(_containers_kv_get "$(_containers_stack_meta_path "$1")" COMPOSE)"
    if [ -n "${value}" ]; then
        printf '%s\n' "${value}"
    else
        _containers_stack_compose_cmd
    fi
}

_containers_stack_project_of() {
    local value
    value="$(_containers_kv_get "$(_containers_stack_meta_path "$1")" PROJECT)"
    printf '%s\n' "${value:-$1}"
}

_containers_stack_file_of() {
    local value dir
    value="$(_containers_kv_get "$(_containers_stack_meta_path "$1")" COMPOSE_FILE)"
    if [ -n "${value}" ]; then
        printf '%s\n' "${value}"
        return 0
    fi
    dir="$(_containers_stack_dir "$1")" || return 1
    if ! _containers_compose_file_in "${dir}"; then
        log_error "stacks: $1: no compose file in ${dir}"
        return 1
    fi
}

# _containers_stack_run <name> <args...> — compose, for this stack, from its
# folder, with its recorded tool, project and file.
_containers_stack_run() {
    local name="$1" dir compose project file
    shift
    dir="$(_containers_stack_dir "${name}")" || return 1
    compose="$(_containers_stack_compose_of "${name}")" || return 1
    project="$(_containers_stack_project_of "${name}")"
    file="$(_containers_stack_file_of "${name}")" || return 1
    _containers_compose_in "${dir}" "${compose}" "${project}" "${file}" "$@"
}

# _containers_stack_down <name> [compose down args...] — down, with the
# template's stop timeout when the record has one. podman-compose drops
# stop_grace_period, so the container's own timeout stays 10 seconds and
# the VM would be killed mid-shutdown (D129).
_containers_stack_down() {
    local name="$1" timeout_seconds
    shift
    timeout_seconds="$(_containers_kv_get "$(_containers_stack_meta_path "${name}")" STOP_TIMEOUT)"
    if [ -n "${timeout_seconds}" ]; then
        _containers_stack_run "${name}" down -t "${timeout_seconds}" "$@"
    else
        _containers_stack_run "${name}" down "$@"
    fi
}

# _containers_project_running <compose> <project> — 0 when the engine has a
# container labelled with the project, 1 when it has none, 2 when the engine
# can't be asked.
_containers_project_running() {
    local cli key found
    cli="$(_containers_stack_engine_cli "$1")"
    key="$(_containers_stack_label_key "$1")"
    found="$(command "${cli}" ps -q --filter "label=${key}=$2" 2>/dev/null)" || return 2
    [ -n "${found}" ]
}

# _containers_project_volumes <compose> <project> — the project's named
# volumes, one per line. Nothing when the engine can't be asked.
_containers_project_volumes() {
    local cli key
    cli="$(_containers_stack_engine_cli "$1")"
    key="$(_containers_stack_label_key "$1")"
    command "${cli}" volume ls -q --filter "label=${key}=$2" 2>/dev/null || true
}

# _containers_stack_running <name> — as _containers_project_running, for a
# recorded stack. 2 also when no compose tool can be resolved.
_containers_stack_running() {
    local compose project
    compose="$(_containers_stack_compose_of "$1" 2>/dev/null)" || return 2
    project="$(_containers_stack_project_of "$1")"
    _containers_project_running "${compose}" "${project}"
}

# _containers_stack_volumes <name> — the stack's named volumes.
_containers_stack_volumes() {
    local compose project
    compose="$(_containers_stack_compose_of "$1" 2>/dev/null)" || return 0
    project="$(_containers_stack_project_of "$1")"
    _containers_project_volumes "${compose}" "${project}"
}

# _containers_project_from <dir> <file> — the project name compose would
# use: a top-level name: in the file, otherwise the folder's name. Lowercase,
# and only a-z 0-9 _ - kept.
_containers_project_from() {
    local project abs
    project="$(awk '/^name:[[:space:]]*/ { sub(/^name:[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); gsub(/["\047]/, ""); print; exit }' "$1/$2" 2>/dev/null)"
    if [ -z "${project}" ]; then
        abs="$(_containers_abs_dir "$1")" || return 1
        project="$(basename -- "${abs}")"
    fi
    _str_lower "${project}" | LC_ALL=C tr -cd 'a-z0-9_-'
    printf '\n'
}

# _containers_abs_dir <dir> — the folder's absolute, symlink-free path.
_containers_abs_dir() {
    ( _containers_cd_quiet -P -- "$1" >/dev/null 2>&1 && pwd -P )
}

# _containers_words <string> — the space-separated words, one per line, so
# loops don't depend on word-splitting (zsh doesn't).
_containers_words() {
    printf '%s\n' "$1" | tr -s ' ' '\n'
}

# _containers_pick_port <base> <label> <taken-lines> — workbench_port_pick,
# with the taken ports given as one string, a port per line. Builds the
# argument list with set -- instead of an array.
_containers_pick_port() {
    local base="$1" label="$2" taken="$3" line
    set -- "${base}" "${label}"
    while IFS= read -r line; do
        if [ -n "${line}" ]; then
            set -- "$@" "${line}"
        fi
    done <<EOF
${taken}
EOF
    workbench_port_pick "$@"
}

# _containers_tty_print — stdin to the terminal. A function of its own so
# tests can stand in for it.
_containers_tty_print() {
    command cat >/dev/tty
}

# _containers_snapper_watches_home — a Snapper config on this machine takes
# snapshots of /home.
_containers_snapper_watches_home() {
    local dir="${_CONTAINERS_SNAPPER_DIR:-/etc/snapper/configs}" file
    [ -d "${dir}" ] || return 1
    command find "${dir}" -maxdepth 1 -type f 2>/dev/null | while IFS= read -r file; do
        if [ -r "${file}" ] && grep -qF 'SUBVOLUME="/home"' "${file}" 2>/dev/null; then
            echo found
        fi
    done | grep -q found
}

# _containers_subvolume_explanation <root> — the text of the btrfs question.
_containers_subvolume_explanation() {
    command cat <<EOF
Your stacks folder will be created on btrfs: $1

  Plain folder (default)
    + behaves like any other folder
    - if /home is snapshotted, the snapshots include your VM disks:
      each snapshot makes a disk copy-on-write again, so it fragments,
      and the snapshot grows with every block the VM changes
  btrfs subvolume
    + /home snapshots skip it, so VM disks stay NOCOW
    - snapshots, and backups taken from snapshots, no longer cover your stacks
EOF
    if _containers_snapper_watches_home; then
        echo "  Snapper is taking snapshots of /home on this machine."
    fi
    if command -v timeshift >/dev/null 2>&1; then
        echo "  Timeshift is installed on this machine."
    fi
}

# _containers_stacks_root_ensure — creates the stacks root the first time.
# On btrfs the root can become a subvolume, and this is the only moment it
# can: a folder can't be converted later. Plain folder unless asked
# (WORKBENCH_STACKS_SUBVOLUME, or the question when a terminal is there).
_containers_stacks_root_ensure() {
    local root parent want="" answer=""
    root="$(_containers_stacks_root)"
    [ -d "${root}" ] && return 0
    parent="$(dirname -- "${root}")"
    if ! mkdir -p "${parent}"; then
        log_error "stacks: can't create ${parent}"
        return 1
    fi
    if [ "$(_containers_fs_type "${parent}")" = "btrfs" ]; then
        case "${WORKBENCH_STACKS_SUBVOLUME:-}" in
            yes) want=yes ;;
            no) ;;
            "")
                if _wb_have_tty; then
                    _containers_subvolume_explanation "${root}" | _containers_tty_print
                    _read_prompt "Create it as a subvolume? [y/N] " answer
                    case "${answer}" in
                        y|Y|yes|YES|Yes) want=yes ;;
                    esac
                    log_info "stacks: set WORKBENCH_STACKS_SUBVOLUME=yes or no in ~/.config/workbench/local/settings.sh to skip this question"
                fi
                ;;
            *)
                log_warn "stacks: WORKBENCH_STACKS_SUBVOLUME must be yes or no (got '${WORKBENCH_STACKS_SUBVOLUME}') — making a plain folder"
                ;;
        esac
    fi
    if [ "${want}" = "yes" ]; then
        if command -v btrfs >/dev/null 2>&1 && command btrfs subvolume create "${root}" >/dev/null; then
            return 0
        fi
        log_warn "stacks: couldn't create ${root} as a btrfs subvolume (is btrfs-progs installed?) — making a plain folder"
    fi
    mkdir -p "${root}"
}

# _containers_stack_discard <name> — removes the folder and record that
# stack-new created in this call. Only ever called after stack-new itself
# made them.
_containers_stack_discard() {
    local root
    root="$(_containers_stacks_root)"
    rm -rf -- "${root:?}/${1:?}"
    rm -f -- "$(_containers_stack_meta_path "$1")"
}

# _containers_stack_abort <name> <message> — logs, discards what this call
# made, and returns 1.
_containers_stack_abort() {
    log_error "stacks: $1: $2"
    _containers_stack_discard "$1"
    return 1
}

# _containers_templates_list — "<name>  <DESCRIPTION>" per template.
_containers_templates_list() {
    local conf
    command find "$(_containers_stacks_templates_dir)" -mindepth 2 -maxdepth 2 -name template.conf -type f 2>/dev/null | sort | while IFS= read -r conf; do
        printf '  %-12s %s\n' "$(basename -- "$(dirname -- "${conf}")")" "$(_containers_kv_get "${conf}" DESCRIPTION)"
    done
}

# _containers_usage <line>... — prints the lines.
_containers_usage() {
    printf '%s\n' "$@"
}

# _containers_stack_names — the stacks' names, one per line, sorted: every
# entry in the root that isn't hidden and is a valid stack name. Runs only
# find, so completion can call it on every TAB.
_containers_stack_names() {
    local root entry name
    root="$(_containers_stacks_root)"
    [ -d "${root}" ] || return 0
    command find "${root}" -mindepth 1 -maxdepth 1 ! -name '.*' \( -type d -o -type l \) 2>/dev/null | sort | while IFS= read -r entry; do
        name="${entry##*/}"
        if _containers_stack_name_ok "${name}"; then
            printf '%s\n' "${name}"
        fi
    done
}

# _containers_template_names — the templates' folder names, one per line.
_containers_template_names() {
    local conf dir
    command find "$(_containers_stacks_templates_dir)" -mindepth 2 -maxdepth 2 -name template.conf -type f 2>/dev/null | sort | while IFS= read -r conf; do
        dir="${conf%/template.conf}"
        printf '%s\n' "${dir##*/}"
    done
}

# _containers_template_resolve <name-or-alias> — the template folder name for
# a template's own name or one of its ALIASES. Fails when nothing matches.
_containers_template_resolve() {
    local want="$1" t alias
    case "${want}" in
        ''|*/*|.*) return 1 ;;
    esac
    if [ -f "$(_containers_stacks_templates_dir)/${want}/template.conf" ]; then
        printf '%s\n' "${want}"
        return 0
    fi
    while IFS= read -r t; do
        [ -n "${t}" ] || continue
        while IFS= read -r alias; do
            if [ -n "${alias}" ] && [ "${alias}" = "${want}" ]; then
                printf '%s\n' "${t}"
                return 0
            fi
        done <<EOF
$(_containers_words "$(_containers_kv_get "$(_containers_stacks_templates_dir)/${t}/template.conf" ALIASES)")
EOF
    done <<EOF
$(_containers_template_names)
EOF
    return 1
}

# _containers_nth_line <n> — line <n> of stdin.
_containers_nth_line() {
    awk -v n="$1" 'NR == n { print; exit }'
}

# _containers_choose <title> <lines> — a numbered menu on the terminal; prints
# the chosen line. Up to three tries; Enter alone takes the first line.
# Status 2 without a terminal or after three bad answers.
_containers_choose() {
    local title="$1" lines="$2" count answer tries=0
    count="$(printf '%s\n' "${lines}" | grep -c .)"
    _wb_have_tty || return 2
    {
        printf '%s\n' "${title}"
        printf '%s\n' "${lines}" | awk 'NF { printf "  %d) %s\n", ++n, $0 }'
    } | _containers_tty_print
    while [ "${tries}" -lt 3 ]; do
        answer=""
        _read_prompt "Choice [1-${count}, Enter for 1]: " answer
        case "${answer}" in
            "") answer=1 ;;
        esac
        case "${answer}" in
            *[!0123456789]*) ;;
            *)
                if [ "${answer}" -ge 1 ] && [ "${answer}" -le "${count}" ]; then
                    printf '%s\n' "${lines}" | grep . | _containers_nth_line "${answer}"
                    return 0
                fi
                ;;
        esac
        tries=$((tries + 1))
    done
    log_error "stacks: no choice made"
    return 2
}

# _containers_stack_resolve <command> [<name>] — the stack a command acts on.
# A name given must be a stack. With none: the only stack, if there is one;
# otherwise a numbered menu on a terminal (status 2 without one).
_containers_stack_resolve() {
    local cmd="$1" name="${2:-}" names count menu entry state picked
    if [ -n "${name}" ]; then
        _containers_stack_dir "${name}" >/dev/null || return 1
        printf '%s\n' "${name}"
        return 0
    fi
    names="$(_containers_stack_names)"
    count="$(printf '%s\n' "${names}" | grep -c .)"
    if [ "${count}" -eq 0 ]; then
        log_error "stacks: no stacks yet (stack-new or stack-import)"
        return 1
    fi
    if [ "${count}" -eq 1 ]; then
        log_info "stacks: ${cmd}: using ${names}, the only stack"
        printf '%s\n' "${names}"
        return 0
    fi
    if ! _wb_have_tty; then
        log_error "stacks: ${cmd}: which stack? $(printf '%s\n' "${names}" | tr '\n' ' ')"
        return 2
    fi
    menu=""
    while IFS= read -r entry; do
        _containers_stack_running "${entry}" </dev/null
        case "$?" in
            0) state=running ;;
            1) state=stopped ;;
            *) state=unknown ;;
        esac
        menu="${menu}$(printf '%-20s %s' "${entry}" "${state}")
"
    done <<EOF
${names}
EOF
    picked="$(_containers_choose "Which stack?" "${menu}")" || return 2
    printf '%s\n' "${picked%% *}"
}

# _containers_seconds <duration> — compose duration ("2m", "90s", "1m30s",
# "1h", or a plain number of seconds) in whole seconds. Fails on anything
# else, and on durations below a second (us, ms).
_containers_seconds() {
    printf '%s\n' "$1" | awk '
        {
            s = $0; total = 0; ok = 1
            gsub(/["\047[:space:]]/, "", s)
            if (s ~ /^[0-9]+$/) { print s; exit }
            if (s !~ /^([0-9]+(\.[0-9]+)?(h|m|s))+$/) { exit 1 }
            while (match(s, /^[0-9]+(\.[0-9]+)?(h|m|s)/)) {
                part = substr(s, 1, RLENGTH); unit = substr(part, RLENGTH, 1)
                value = substr(part, 1, RLENGTH - 1) + 0
                total += (unit == "h") ? value * 3600 : (unit == "m") ? value * 60 : value
                s = substr(s, RLENGTH + 1)
            }
            printf "%d\n", total
        }'
}

# _containers_grace_seconds <compose-file> — the longest stop_grace_period in
# the file, in seconds. Nothing when there isn't one.
_containers_grace_seconds() {
    local value best=0 secs
    while IFS= read -r value; do
        [ -n "${value}" ] || continue
        secs="$(_containers_seconds "${value}")" || continue
        [ -n "${secs}" ] || continue
        if [ "${secs}" -gt "${best}" ]; then
            best="${secs}"
        fi
    done <<EOF
$(awk '/^[[:space:]]+stop_grace_period:/ { sub(/^[[:space:]]+stop_grace_period:[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); print }' "$1" 2>/dev/null)
EOF
    if [ "${best}" -gt 0 ]; then
        printf '%s\n' "${best}"
    fi
}

# _containers_kib <size> — a dockur-style size ("64G", "512M", "1T") in KiB.
# Fails on anything else, a bare number included.
_containers_kib() {
    printf '%s\n' "$1" | awk '
        {
            s = toupper($0); gsub(/["\047[:space:]]/, "", s); sub(/B$/, "", s)
            if (s !~ /^[0-9]+(\.[0-9]+)?[KMGT]$/) { exit 1 }
            unit = substr(s, length(s), 1); n = substr(s, 1, length(s) - 1)
            m = (unit == "K") ? 1 : (unit == "M") ? 1024 : (unit == "G") ? 1048576 : 1073741824
            printf "%d\n", n * m
        }'
}

# _containers_free_kib <path> — free KiB on <path>'s filesystem (POSIX df).
_containers_free_kib() {
    df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# _containers_editor — the editor stack-edit runs: VISUAL, then EDITOR, then
# the first of nano, vim and vi on PATH. Fails when there is none.
_containers_editor() {
    local e
    if [ -n "${VISUAL:-}" ]; then
        printf '%s\n' "${VISUAL}"
        return 0
    fi
    if [ -n "${EDITOR:-}" ]; then
        printf '%s\n' "${EDITOR}"
        return 0
    fi
    for e in nano vim vi; do
        if command -v "${e}" >/dev/null 2>&1; then
            printf '%s\n' "${e}"
            return 0
        fi
    done
    return 1
}

# _containers_run_editor <editor> <file> — runs the editor on the file. The
# editor setting is split into words by sh, so EDITOR="code --wait" works,
# and the file name is passed as "$1", never re-parsed.
_containers_run_editor() {
    # shellcheck disable=SC2016  # $1 is for the inner sh
    command sh -c "$1"' "$1"' sh "$2"
}

# _containers_complete <index> <command> <words...> — the completion
# provider for every stack-* command (workbench_complete, workbench-core
# D132). Runs only find and grep, so it never waits on the engine.
_containers_complete() {
    local idx="$1" cmd="$2" cur="" prev="" npos=0 i=1 w
    shift 2
    for w in "$@"; do
        if [ "${i}" -eq "${idx}" ]; then
            cur="${w}"
            break
        fi
        case "${w}" in
            -*) ;;
            *)
                case "${prev}" in
                    --name|--stop-timeout) ;;
                    *) npos=$((npos + 1)) ;;
                esac
                ;;
        esac
        prev="${w}"
        i=$((i + 1))
    done
    case "${prev}" in
        --name|--stop-timeout) return 0 ;;
    esac
    case "${cur}" in
        -*)
            case "${cmd}" in
                stack-new) printf '%s\n' --name --list --accept --help ;;
                stack-import) printf '%s\n' --name --link --move --copy --stop-timeout --dry-run --yes --help ;;
                stack-rm) printf '%s\n' --purge --help ;;
                stack-logs) printf '%s\n' --follow --tail --timestamps --help ;;
                stack-help) printf '%s\n' --full ;;
                stack-compose) [ "${npos}" -eq 0 ] && printf '%s\n' --help ;;
                *) printf '%s\n' --help ;;
            esac
            return 0
            ;;
    esac
    case "${cmd}" in
        stack-new)
            if [ "${npos}" -eq 0 ]; then
                _containers_template_names | while IFS= read -r w; do
                    printf '%s\t%s\n' "${w}" "$(_containers_kv_get "$(_containers_stacks_templates_dir)/${w}/template.conf" DESCRIPTION)"
                done
            fi
            ;;
        stack-import)
            [ "${npos}" -eq 0 ] && echo @files
            ;;
        stack-up|stack-down|stack-logs|stack-path|stack-info|stack-rm)
            [ "${npos}" -eq 0 ] && _containers_stack_candidates
            ;;
        stack-edit)
            case "${npos}" in
                0) _containers_stack_candidates ;;
                1) printf '%s\t%s\n' compose "the compose file" env "the stack's .env settings" override "compose's override file" ;;
            esac
            ;;
        stack-compose)
            case "${npos}" in
                0) _containers_stack_candidates ;;
                1) printf '%s\n' build config create down events exec images kill logs pause port ps pull restart rm run start stop top unpause up ;;
            esac
            ;;
        stack-help)
            if [ "${npos}" -eq 0 ]; then
                printf '%s\t%s\n' import "bring your own compose project in" templates "what each template needs and gives you" commands "every stack command"
            fi
            ;;
    esac
}

# _containers_stack_candidates — "<name><TAB><origin>" per stack.
_containers_stack_candidates() {
    local name origin
    _containers_stack_names | while IFS= read -r name; do
        origin="$(_containers_kv_get "$(_containers_stack_meta_path "${name}")" ORIGIN)"
        printf '%s\t%s\n' "${name}" "${origin:-manual}"
    done
}

# _containers_requires_check <name> <requires> — every requirement in the
# space-separated list is met. kvm: /dev/kvm can be opened. avx2: the CPU
# reports AVX2. Logs what's missing, with a hint, and fails.
_containers_requires_check() {
    local name="$1" req rc=0
    while IFS= read -r req; do
        case "${req}" in
            "") ;;
            kvm)
                if ! _containers_kvm_ok; then
                    log_error "stacks: ${name}: needs KVM, and ${_CONTAINERS_KVM_DEV:-/dev/kvm} isn't there or isn't readable and writable"
                    log_error "stacks: $(_containers_kvm_hint)"
                    rc=1
                fi
                ;;
            avx2)
                if ! grep -qw avx2 "${_CONTAINERS_CPUINFO:-/proc/cpuinfo}" 2>/dev/null; then
                    log_error "stacks: ${name}: needs a CPU with AVX2 (Intel Haswell or AMD Zen, or newer), and this one doesn't report it"
                    rc=1
                fi
                ;;
            *)
                log_error "stacks: ${name}: needs '${req}', which this version of workbench-containers can't check — update it (wb update containers)"
                rc=1
                ;;
        esac
    done <<EOF
$(_containers_words "$2")
EOF
    return "${rc}"
}

_wb_alias_availability --needs "podman with podman-compose, or Docker with compose" --install podman \
    _containers_stack_compose_available \
    stack-new stack-import stack-list stack-info stack-up stack-down stack-logs stack-edit stack-compose stack-path stack-rm stack-help

# Tab completion for every stack command (workbench-core D132). Registered
# whether or not compose is installed: completion on a host without compose
# still offers templates and help topics. Only when the Core API has
# workbench_complete (1.13): an older core keeps an earlier register list
# that still sources this file, and the commands work there without
# completion rather than every shell start printing "command not found".
if command -v workbench_complete >/dev/null 2>&1; then
    workbench_complete _containers_complete \
        stack-new stack-import stack-list stack-info stack-up stack-down stack-logs stack-edit stack-compose stack-path stack-rm stack-help
fi

# _containers_stack_taken <name> — the root has an entry, or a record, for
# <name>.
_containers_stack_taken() {
    local dir
    dir="$(_containers_stacks_root)/$1"
    [ -e "${dir}" ] || [ -L "${dir}" ] || [ -e "$(_containers_stack_meta_path "$1")" ]
}

# _containers_name_suggest <base> — <base> when it is free, else the first
# free <base>-2, <base>-3, and so on.
_containers_name_suggest() {
    local n=2
    if ! _containers_stack_taken "$1"; then
        printf '%s\n' "$1"
        return 0
    fi
    while _containers_stack_taken "$1-${n}"; do
        n=$((n + 1))
    done
    printf '%s\n' "$1-${n}"
}

# _containers_vendor_line <check> — one factual line on the hardware maker
# this machine reports, compared with <check>.
_containers_vendor_line() {
    local vendor
    vendor="$(head -n 1 "${_CONTAINERS_DMI_VENDOR_FILE:-/sys/class/dmi/id/sys_vendor}" 2>/dev/null | sed 's/[[:space:]]*$//')"
    if [ -z "${vendor}" ]; then
        printf "This machine doesn't report its maker.\n"
    elif [ "${vendor}" = "$1" ]; then
        printf 'This machine reports its maker as %s. That matches %s.\n' "${vendor}" "$1"
    else
        printf "This machine reports its maker as %s. That isn't %s.\n" "${vendor}" "$1"
    fi
}

# _containers_yes_default <prompt> — asks; 0 unless the answer is n or no.
_containers_yes_default() {
    local answer=""
    _read_prompt "$1" answer
    case "${answer}" in
        n|N|no|NO|No) return 1 ;;
    esac
    return 0
}

# ── public functions ──────────────────────────────────────────────────────────

stack-new() {
    local template="" name="" list_only="" accept_flag="" root dir tdir tconf menu picked_line answer tries
    local requires bind_var ports dirs nocow_dirs login_vars secret_vars stop_timeout note accept_text vendor_check disk_var
    local disk_value disk_kib free_kib free_h accepted port_labels
    local compose claimed picked port_records env_extra entry var rest base label port d login secret sha created
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                _containers_usage "Usage: stack-new [<template>] [--name <name>] [--accept]" \
                    "       stack-new --list" \
                    "Creates a stack from a template in the stacks folder; doesn't start it." \
                    "With no template, asks which on a terminal (lists them otherwise). Without --name, suggests one." \
                    "--accept accepts a template's licence without asking (needed without a terminal)."
                return 0
                ;;
            --list) list_only=1; shift ;;
            --accept) accept_flag=1; shift ;;
            --name)
                if [ "$#" -lt 2 ]; then
                    log_error "stacks: --name needs a value"
                    return 2
                fi
                name="$2"
                shift 2
                ;;
            -*)
                log_error "stacks: stack-new: unknown option '$1'"
                return 2
                ;;
            *)
                if [ -n "${template}" ]; then
                    log_error "stacks: stack-new takes one template (got '${template}' and '$1')"
                    return 2
                fi
                template="$1"
                shift
                ;;
        esac
    done

    if [ -n "${list_only}" ] || { [ -z "${template}" ] && ! _wb_have_tty; }; then
        printf 'Templates (stack-new <template> [--name <name>]):\n'
        _containers_templates_list
        return 0
    fi
    if [ -z "${template}" ]; then
        menu="$(_containers_template_names | while IFS= read -r entry; do
            printf '%-10s %s\n' "${entry}" "$(_containers_kv_get "$(_containers_stacks_templates_dir)/${entry}/template.conf" DESCRIPTION)"
        done)"
        if [ -z "${menu}" ]; then
            log_error "stacks: no templates found in $(_containers_stacks_templates_dir)"
            return 1
        fi
        picked_line="$(_containers_choose "Which template?" "${menu}")" || return 2
        template="${picked_line%% *}"
    fi
    if ! template="$(_containers_template_resolve "${template}")"; then
        log_error "stacks: no template '${template}'. Templates:"
        _containers_templates_list >&2
        return 1
    fi
    tdir="$(_containers_stacks_templates_dir)/${template}"
    tconf="${tdir}/template.conf"

    if [ -z "${name}" ]; then
        name="$(_containers_name_suggest "${template}")"
        if _wb_have_tty; then
            tries=0
            while :; do
                answer=""
                _read_prompt "Name for the stack [${name}]: " answer
                if [ -z "${answer}" ]; then
                    break
                fi
                if ! _containers_stack_name_ok "${answer}"; then
                    log_error "stacks: '${answer}' isn't a valid stack name (lowercase letters, digits, - and _, starting with a letter or digit, at most 63 characters)"
                elif _containers_stack_taken "${answer}"; then
                    log_error "stacks: ${answer}: already exists"
                else
                    name="${answer}"
                    break
                fi
                tries=$((tries + 1))
                if [ "${tries}" -ge 3 ]; then
                    log_error "stacks: no name chosen; nothing was created"
                    return 1
                fi
            done
        else
            log_info "stacks: naming it ${name} (--name to choose)"
        fi
    fi
    if ! _containers_stack_name_ok "${name}"; then
        log_error "stacks: '${name}' isn't a valid stack name (lowercase letters, digits, - and _, starting with a letter or digit, at most 63 characters)"
        return 1
    fi
    root="$(_containers_stacks_root)"
    dir="${root}/${name}"
    if _containers_stack_taken "${name}"; then
        log_error "stacks: ${name}: already exists (${dir}); choose another with --name"
        return 1
    fi

    requires="$(_containers_kv_get "${tconf}" REQUIRES)"
    bind_var="$(_containers_kv_get "${tconf}" BIND_VAR)"
    ports="$(_containers_kv_get "${tconf}" PORTS)"
    dirs="$(_containers_kv_get "${tconf}" DIRS)"
    nocow_dirs="$(_containers_kv_get "${tconf}" NOCOW_DIRS)"
    login_vars="$(_containers_kv_get "${tconf}" LOGIN_VARS)"
    secret_vars="$(_containers_kv_get "${tconf}" SECRET_VARS)"
    stop_timeout="$(_containers_kv_get "${tconf}" STOP_TIMEOUT)"
    note="$(_containers_kv_get "${tconf}" NOTE)"
    accept_text="$(_containers_kv_get "${tconf}" ACCEPT)"
    vendor_check="$(_containers_kv_get "${tconf}" ACCEPT_VENDOR_CHECK)"
    disk_var="$(_containers_kv_get "${tconf}" DISK_VAR)"

    _containers_requires_check "${name}" "${requires}" || return 1

    # A licence to accept. Nothing has been created yet, the root included.
    accepted=""
    if [ -n "${accept_text}" ]; then
        printf '%s\n' "${accept_text}"
        if [ -n "${vendor_check}" ]; then
            _containers_vendor_line "${vendor_check}"
        fi
        if [ -z "${accept_flag}" ]; then
            if ! _wb_have_tty; then
                log_error "stacks: ${name}: this template needs its licence accepted; run on a terminal, or add --accept"
                return 1
            fi
            answer=""
            _read_prompt "Accept and continue? [y/N] " answer
            case "${answer}" in
                y|Y|yes|YES|Yes) ;;
                *)
                    log_error "stacks: ${name}: not created"
                    return 1
                    ;;
            esac
        fi
        accepted="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    fi

    compose="$(_containers_stack_compose_cmd)" || return 1
    _containers_stacks_root_ensure || return 1

    # The VM disk is sparse and grows as it fills: warn, don't stop.
    if [ -n "${disk_var}" ]; then
        disk_value="$(_containers_kv_get "${tdir}/env.default" "${disk_var}")"
        if disk_kib="$(_containers_kib "${disk_value}" 2>/dev/null)" && [ -n "${disk_kib}" ]; then
            free_kib="$(_containers_free_kib "${root}")"
            case "${free_kib}" in
                ''|*[!0123456789]*) ;;
                *)
                    if [ "${free_kib}" -lt "${disk_kib}" ]; then
                        free_h="$(df -Ph "${root}" 2>/dev/null | awk 'NR == 2 { print $4 }')"
                        log_warn "stacks: ${name}: the disk can grow to ${disk_value}, and ${root} has ${free_h:-${free_kib}K} free"
                    fi
                    ;;
            esac
        fi
    fi

    # From here on, everything this call makes is removed again on failure.
    if ! mkdir "${dir}"; then
        log_error "stacks: ${name}: can't create ${dir}"
        return 1
    fi
    if ! command cp "${tdir}/compose.yaml" "${dir}/compose.yaml"; then
        _containers_stack_abort "${name}" "can't copy the template's compose.yaml"
        return 1
    fi
    while IFS= read -r d; do
        [ -n "${d}" ] || continue
        if ! mkdir -p "${dir}/${d}"; then
            _containers_stack_abort "${name}" "can't create ${dir}/${d}"
            return 1
        fi
    done <<EOT
$(_containers_words "${dirs}")
EOT
    # Still empty here, which is what +C needs for the disk created in it.
    while IFS= read -r d; do
        [ -n "${d}" ] || continue
        _containers_nocow "${dir}/${d}"
    done <<EOT
$(_containers_words "${nocow_dirs}")
EOT

    # Ports: one free port per template entry, never one another stack has
    # claimed (even a stopped one), nor one picked earlier in this call.
    claimed="$(_containers_stacks_claimed_ports)"
    picked=""
    port_records=""
    port_labels=""
    while IFS= read -r entry; do
        [ -n "${entry}" ] || continue
        var="${entry%%:*}"
        rest="${entry#*:}"
        base="${rest%%:*}"
        label="${rest#*:}"
        if ! port="$(_containers_pick_port "${base}" "stacks: ${name}" "${claimed}
${picked}")"; then
            _containers_stack_abort "${name}" "no free port for ${var}"
            return 1
        fi
        picked="${picked}${port}
"
        port_records="${port_records}${var}=${port}|${label}
"
        port_labels="${port_labels}${port_labels:+ }${var}:${label}"
    done <<EOT
$(_containers_words "${ports}")
EOT

    # What stack-new adds to the template's env.default.
    login="$(_containers_login_name)"
    env_extra="
# Written by stack-new on $(date +%Y-%m-%d). Edit freely.
"
    if [ -n "${bind_var}" ]; then
        env_extra="${env_extra}${bind_var}=127.0.0.1
"
    fi
    while IFS= read -r entry; do
        [ -n "${entry}" ] || continue
        env_extra="${env_extra}${entry%%|*}
"
    done <<EOT
${port_records}
EOT
    while IFS= read -r var; do
        [ -n "${var}" ] || continue
        env_extra="${env_extra}${var}=${login}
"
    done <<EOT
$(_containers_words "${login_vars}")
EOT
    while IFS= read -r var; do
        [ -n "${var}" ] || continue
        if ! secret="$(_containers_random_secret)"; then
            _containers_stack_abort "${name}" "can't read random bytes for ${var}"
            return 1
        fi
        env_extra="${env_extra}${var}=${secret}
"
    done <<EOT
$(_containers_words "${secret_vars}")
EOT

    # umask 077 in a subshell: .env is created 0600, and the caller's umask
    # is untouched.
    if ! ( umask 077 && { command cat "${tdir}/env.default" && printf '%s' "${env_extra}"; } > "${dir}/.env" ); then
        _containers_stack_abort "${name}" "can't write ${dir}/.env"
        return 1
    fi

    sha=""
    if command -v workbench_module_conf_get >/dev/null 2>&1; then
        sha="$(workbench_module_conf_get containers RESOLVED_SHA "" 2>/dev/null)" || sha=""
    fi
    created="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    if ! _containers_stack_meta_write "${name}" \
        "ORIGIN=template:${template}" \
        "TEMPLATE_SHA=${sha}" \
        "PROJECT=${name}" \
        "COMPOSE=${compose}" \
        "COMPOSE_FILE=compose.yaml" \
        "STOP_TIMEOUT=${stop_timeout}" \
        "REQUIRES=${requires}" \
        "BIND_VAR=${bind_var}" \
        "PORT_LABELS=${port_labels}" \
        "LOGIN_VARS=${login_vars}" \
        "SECRET_VARS=${secret_vars}" \
        "ACCEPTED=${accepted}" \
        "CREATED=${created}"; then
        _containers_stack_abort "${name}" "can't write the stack's record"
        return 1
    fi

    if ! _containers_stack_run "${name}" config >/dev/null; then
        _containers_stack_abort "${name}" "compose rejected the new stack (see above); nothing was kept"
        return 1
    fi

    printf 'stacks: %s: created in %s\n' "${name}" "${dir}"
    while IFS= read -r entry; do
        [ -n "${entry}" ] || continue
        rest="${entry#*=}"
        port="${rest%%|*}"
        label="${rest#*|}"
        if [ "${label}" = "web" ]; then
            printf '  web: http://127.0.0.1:%s/\n' "${port}"
        else
            printf '  %s: 127.0.0.1:%s\n' "${label}" "${port}"
        fi
    done <<EOT
${port_records}
EOT
    if [ -n "${login_vars}" ]; then
        printf '  User: %s\n' "${login}"
    fi
    if [ -n "${secret_vars}" ]; then
        printf '  Password: in %s/.env\n' "${dir}"
    fi
    if [ -n "${note}" ]; then
        printf '%s\n' "${note}" | sed "s/<name>/${name}/g"
    fi
    printf '  Details: stack-info %s\n' "${name}"
    printf 'Start it with: stack-up %s\n' "${name}"
}

stack-import() {
    local source_arg="" name="" mode="" dry_run="" assume_yes="" stop_flag="" stop_timeout=""
    local kind srcdir srcabs file compose project root dest override picked_line
    local size volumes verb rc added how timeout_text from_text
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                _containers_usage "Usage: stack-import <folder|compose-file> [--name <name>] [--link|--move|--copy]" \
                    "                    [--stop-timeout <seconds>] [--dry-run] [--yes]" \
                    "Brings a compose project you already have in as a stack. stack-help import walks through it."
                return 0
                ;;
            --name)
                if [ "$#" -lt 2 ]; then
                    log_error "stacks: --name needs a value"
                    return 2
                fi
                name="$2"
                shift 2
                ;;
            --stop-timeout)
                if [ "$#" -lt 2 ]; then
                    log_error "stacks: --stop-timeout needs a number of seconds"
                    return 2
                fi
                case "$2" in
                    ''|*[!0123456789]*|0|00*)
                        log_error "stacks: --stop-timeout takes a whole number of seconds, at least 1 (got '$2')"
                        return 2
                        ;;
                esac
                stop_flag="$2"
                shift 2
                ;;
            --link|--move|--copy) mode="${1#--}"; shift ;;
            --dry-run) dry_run=1; shift ;;
            --yes|-y) assume_yes=1; shift ;;
            -*)
                log_error "stacks: stack-import: unknown option '$1'"
                return 2
                ;;
            *)
                if [ -n "${source_arg}" ]; then
                    log_error "stacks: stack-import takes one folder or file (got '${source_arg}' and '$1')"
                    return 2
                fi
                source_arg="$1"
                shift
                ;;
        esac
    done
    if [ -z "${source_arg}" ]; then
        _containers_usage "Usage: stack-import <folder|compose-file> [--name <name>] [--link|--move|--copy]" \
            "                    [--stop-timeout <seconds>] [--dry-run] [--yes]" >&2
        printf 'stack-help import walks through it.\n' >&2
        return 2
    fi

    if [ -d "${source_arg}" ]; then
        kind=folder
        srcdir="${source_arg}"
        if ! file="$(_containers_compose_file_in "${srcdir}")"; then
            log_error "stacks: no compose file in ${srcdir} (looked for compose.yaml, compose.yml, docker-compose.yaml, docker-compose.yml)"
            return 1
        fi
    elif [ -f "${source_arg}" ]; then
        kind="file"
        srcdir="$(dirname -- "${source_arg}")"
        file="$(basename -- "${source_arg}")"
        case "${mode}" in
            ""|copy) mode=copy ;;
            *)
                log_error "stacks: --${mode} needs a folder: point stack-import at the file's folder to move or link it"
                return 1
                ;;
        esac
    else
        log_error "stacks: ${source_arg}: no such folder or file"
        return 1
    fi
    srcabs="$(_containers_abs_dir "${srcdir}")" || {
        log_error "stacks: can't open ${srcdir}"
        return 1
    }

    compose="$(_containers_stack_compose_cmd)" || return 1
    project="$(_containers_project_from "${srcabs}" "${file}")"
    if [ -z "${name}" ]; then
        if ! _containers_stack_name_ok "${project}"; then
            log_error "stacks: can't make a stack name from '${project}'; choose one with --name"
            return 1
        fi
        name="${project}"
    else
        if ! _containers_stack_name_ok "${name}"; then
            log_error "stacks: '${name}' isn't a valid stack name (lowercase letters, digits, - and _, starting with a letter or digit, at most 63 characters)"
            return 1
        fi
        project="${name}"
    fi
    root="$(_containers_stacks_root)"
    dest="${root}/${name}"
    if _containers_stack_taken "${name}"; then
        log_error "stacks: ${name}: already exists (${dest}); choose another with --name"
        return 1
    fi

    # Compose has to accept the files where they are before anything moves.
    if ! _containers_compose_in "${srcabs}" "${compose}" "${project}" "${file}" config >/dev/null; then
        log_error "stacks: ${name}: compose rejected ${srcabs}/${file} (see above); nothing was imported"
        return 1
    fi

    if [ "${kind}" = "folder" ] && [ -z "${mode}" ]; then
        if _wb_have_tty && [ -z "${dry_run}" ]; then
            picked_line="$(_containers_choose "How should ${name} be imported?" "link   leave the files where they are; the stack points at them
move   move the folder into ${dest}
copy   copy it there and leave the original")" || return 2
            mode="${picked_line%% *}"
        else
            mode="link"
            if ! _wb_have_tty; then
                log_info "stacks: linking in place (--move or --copy to change)"
            fi
        fi
    fi

    size=""
    if [ "${kind}" = "folder" ] && [ "${mode}" != "link" ]; then
        _containers_project_running "${compose}" "${project}"
        rc=$?
        case "${rc}" in
            0)
                log_error "stacks: ${name}: ${project} is running; stop it first, or use --link"
                return 1
                ;;
            1) ;;
            *)
                log_error "stacks: ${name}: can't tell whether ${project} is running — start the engine, or use --link"
                return 1
                ;;
        esac
    fi
    if [ "${mode}" != "link" ]; then
        if [ "${kind}" = "folder" ]; then
            size="$(du -sh "${srcabs}" 2>/dev/null | cut -f1)"
        else
            size="$(du -sh "${srcabs}/${file}" 2>/dev/null | cut -f1)"
        fi
    fi

    # Best effort: not every compose tool has `config --volumes`.
    volumes="$(_containers_compose_in "${srcabs}" "${compose}" "${project}" "${file}" config --volumes 2>/dev/null | awk 'NF { printf "%s%s", sep, $1; sep = ", " }')"
    if [ -n "${stop_flag}" ]; then
        stop_timeout="${stop_flag}"
        timeout_text="${stop_timeout}s (--stop-timeout)"
    else
        stop_timeout="$(_containers_grace_seconds "${srcabs}/${file}")"
        if [ -n "${stop_timeout}" ]; then
            timeout_text="${stop_timeout}s, from stop_grace_period"
        else
            timeout_text="compose's default (10s)"
        fi
    fi
    from_text="${file}"
    if override="$(_containers_override_file_in "${srcabs}" "${file}")"; then
        from_text="${file}, + ${override}"
    fi
    case "${mode}" in
        link) how="link — the files stay where they are" ;;
        move) how="move — into ${dest}" ;;
        *)    how="copy — into ${dest}; the original stays" ;;
    esac
    printf 'Import %s\n' "${name}"
    printf '  %-13s %s\n' from "${srcabs} (${from_text})"
    printf '  %-13s %s\n' how "${how}"
    if [ -n "${size}" ]; then
        printf '  %-13s %s\n' size "${size}"
    fi
    printf '  %-13s %s\n' project "${project} (named volumes are keyed by it)"
    printf '  %-13s %s\n' "compose tool" "${compose}"
    printf '  %-13s %s\n' "stop timeout" "${timeout_text}"
    if [ -n "${volumes}" ]; then
        printf '  %-13s %s\n' volumes "${volumes} — kept by the engine, not in the folder"
    else
        printf '  %-13s %s\n' volumes "none found"
    fi

    if [ -n "${dry_run}" ]; then
        printf 'stacks: %s: dry run, nothing changed\n' "${name}"
        return 0
    fi
    if [ -z "${assume_yes}" ] && _wb_have_tty; then
        if ! _containers_yes_default "Import it? [Y/n] "; then
            printf 'stacks: %s: not imported\n' "${name}"
            return 1
        fi
    fi

    if [ "${mode}" != "link" ]; then
        case "${mode}" in
            move) verb="Moving" ;;
            *) verb="Copying" ;;
        esac
        printf 'stacks: %s: %s %s from %s\n' "${name}" "${verb}" "${size:-?}" "${srcabs}"
    fi

    _containers_stacks_root_ensure || return 1
    case "${mode}" in
        link)
            ln -s "${srcabs}" "${dest}" || return 1
            ;;
        move)
            command mv "${srcabs}" "${dest}" || return 1
            ;;
        copy)
            if ! mkdir "${dest}"; then
                log_error "stacks: ${name}: can't create ${dest}"
                return 1
            fi
            if [ "${kind}" = "folder" ]; then
                command cp -a "${srcabs}/." "${dest}/" || { rm -rf -- "${dest}"; return 1; }
            else
                command cp -p "${srcabs}/${file}" "${dest}/${file}" || { rm -rf -- "${dest}"; return 1; }
                if [ -f "${srcabs}/.env" ]; then
                    command cp -p "${srcabs}/.env" "${dest}/.env" || { rm -rf -- "${dest}"; return 1; }
                fi
            fi
            ;;
    esac

    added="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    from_text=""
    if [ "${mode}" != "link" ]; then
        from_text="FROM=${srcabs}"
    fi
    if ! _containers_stack_meta_write "${name}" \
        "ORIGIN=${mode}" \
        "PROJECT=${project}" \
        "COMPOSE=${compose}" \
        "COMPOSE_FILE=${file}" \
        "STOP_TIMEOUT=${stop_timeout}" \
        ${from_text:+"${from_text}"} \
        "ADDED=${added}"; then
        log_error "stacks: ${name}: can't write the stack's record"
        return 1
    fi

    if [ "${kind}" = "file" ]; then
        if ! _containers_stack_run "${name}" config >/dev/null; then
            rm -rf -- "${dest}"
            rm -f -- "$(_containers_stack_meta_path "${name}")"
            log_error "stacks: ${name}: ${file} probably refers to files beside the original; try: stack-import ${srcabs} --copy"
            return 1
        fi
    fi

    printf 'stacks: %s: imported as %s (%s)\n' "${name}" "${dest}" "${mode}"
    printf 'Start it with: stack-up %s\n' "${name}"
}

stack-list() {
    local root entries entry name origin state target rc
    case "${1:-}" in
        "") ;;
        -h|--help)
            _containers_usage "Usage: stack-list" "Lists the stacks in the stacks folder, with where they came from and whether they run."
            return 0
            ;;
        *)
            log_error "stacks: stack-list takes no arguments (got '$1')"
            return 2
            ;;
    esac
    root="$(_containers_stacks_root)"
    entries=""
    if [ -d "${root}" ]; then
        entries="$(command find "${root}" -mindepth 1 -maxdepth 1 ! -name '.*' \( -type d -o -type l \) 2>/dev/null | sort)"
    fi
    if [ -z "${entries}" ]; then
        printf 'stacks: no stacks yet (stack-new or stack-import)\n'
        return 0
    fi
    printf '%-20s %-20s %-8s %s\n' NAME ORIGIN STATE PATH
    while IFS= read -r entry; do
        [ -n "${entry}" ] || continue
        name="$(basename -- "${entry}")"
        origin="$(_containers_kv_get "$(_containers_stack_meta_path "${name}")" ORIGIN)"
        target="${entry}"
        if [ -L "${entry}" ]; then
            target="$(readlink "${entry}")"
        fi
        if [ -L "${entry}" ] && [ ! -d "${entry}" ]; then
            state=missing
        else
            # </dev/null: nothing in this loop may read the loop's own input.
            _containers_stack_running "${name}" </dev/null
            rc=$?
            case "${rc}" in
                0) state=running ;;
                1) state=stopped ;;
                *) state=unknown ;;
            esac
        fi
        printf '%-20s %-20s %-8s %s\n' "${name}" "${origin:-manual}" "${state}" "${target}"
    done <<EOF
${entries}
EOF
}

stack-up() {
    local name="" dir requires bind_var bind_value
    case "${1:-}" in
        -h|--help)
            _containers_usage "Usage: stack-up [<name>] [compose up args...]" \
                "Starts the stack in the background (compose up -d). With one stack, the name can be left out."
            return 0
            ;;
        ""|-*) ;;
        *) name="$1"; shift ;;
    esac
    name="$(_containers_stack_resolve stack-up "${name}")" || return $?
    dir="$(_containers_stack_dir "${name}")" || return 1
    bind_var="$(_containers_kv_get "$(_containers_stack_meta_path "${name}")" BIND_VAR)"
    if [ -n "${bind_var}" ]; then
        bind_value="$(_containers_kv_get "${dir}/.env" "${bind_var}")"
        case "${bind_value}" in
            ""|127.*) ;;
            *) log_warn "stacks: ${name}: ${bind_var}=${bind_value} publishes this stack beyond this machine" ;;
        esac
    fi
    requires="$(_containers_kv_get "$(_containers_stack_meta_path "${name}")" REQUIRES)"
    _containers_requires_check "${name}" "${requires}" || return 1
    _containers_stack_run "${name}" up -d "$@"
}

stack-down() {
    local name=""
    case "${1:-}" in
        -h|--help)
            _containers_usage "Usage: stack-down [<name>] [compose down args...]" \
                "Stops the stack and removes its containers and network; its folder and volumes stay." \
                "Waits for the stack's stop timeout. With one stack, the name can be left out."
            return 0
            ;;
        ""|-*) ;;
        *) name="$1"; shift ;;
    esac
    name="$(_containers_stack_resolve stack-down "${name}")" || return $?
    _containers_stack_down "${name}" "$@"
}

stack-logs() {
    local name=""
    case "${1:-}" in
        -h|--help)
            _containers_usage "Usage: stack-logs [<name>] [compose logs args...]   e.g. stack-logs win11 -f" \
                "Shows the stack's logs. With one stack, the name can be left out: stack-logs -f"
            return 0
            ;;
        ""|-*) ;;
        *) name="$1"; shift ;;
    esac
    name="$(_containers_stack_resolve stack-logs "${name}")" || return $?
    _containers_stack_run "${name}" logs "$@"
}

stack-compose() {
    local name=""
    case "${1:-}" in
        -h|--help)
            _containers_usage "Usage: stack-compose [<name>] <compose args...>   e.g. stack-compose win11 ps -a" \
                "Runs compose for the stack, from its folder, with its recorded tool, project and file." \
                "The first word is taken as the stack only when a stack has that name; otherwise every" \
                "word goes to compose, and the stack is the only one (or chosen from a list)."
            return 0
            ;;
        "")
            _containers_usage "Usage: stack-compose [<name>] <compose args...>   e.g. stack-compose win11 ps -a" >&2
            return 2
            ;;
    esac
    if _containers_stack_name_ok "$1" && [ -d "$(_containers_stacks_root)/$1" ]; then
        name="$1"
        shift
        if [ "$#" -eq 0 ]; then
            _containers_usage "Usage: stack-compose [<name>] <compose args...>   e.g. stack-compose win11 ps -a" >&2
            return 2
        fi
    else
        name="$(_containers_stack_resolve stack-compose "")" || return $?
    fi
    _containers_stack_run "${name}" "$@"
}

stack-path() {
    local name="" dir
    case "${1:-}" in
        -h|--help)
            _containers_usage "Usage: stack-path [<name>]   e.g. cd \"\$(stack-path win11)\"" \
                "Prints the stack's folder. With one stack, the name can be left out."
            return 0
            ;;
        ""|-*) ;;
        *) name="$1"; shift ;;
    esac
    name="$(_containers_stack_resolve stack-path "${name}")" || return $?
    dir="$(_containers_stack_dir "${name}")" || return 1
    _containers_abs_dir "${dir}"
}

# _containers_info_line <label> <value> — one stack-info line, skipped when
# the value is empty.
_containers_info_line() {
    [ -n "$2" ] || return 0
    printf '  %-13s %s\n' "$1" "$2"
}

stack-info() {
    local name="" dir rec env target origin when from state rc compose file override project tool_text
    local labels entry var label port host bind_var timeout_text requires size volumes login_vars secret_vars login_text value
    case "${1:-}" in
        -h|--help)
            _containers_usage "Usage: stack-info [<name>]" \
                "Shows a stack's folder, origin, state, compose files, ports, login, stop timeout, needs, size and volumes." \
                "Never prints a secret's value. With one stack, the name can be left out."
            return 0
            ;;
        ""|-*) ;;
        *) name="$1"; shift ;;
    esac
    name="$(_containers_stack_resolve stack-info "${name}")" || return $?
    dir="$(_containers_stack_dir "${name}")" || return 1
    rec="$(_containers_stack_meta_path "${name}")"
    env="${dir}/.env"

    target=""
    if [ -L "${dir}" ]; then
        target="$(readlink "${dir}")"
    fi
    origin="$(_containers_kv_get "${rec}" ORIGIN)"
    when="$(_containers_kv_get "${rec}" CREATED)"
    [ -n "${when}" ] || when="$(_containers_kv_get "${rec}" ADDED)"
    if [ -n "${when}" ]; then
        origin="${origin:-manual}, created ${when}"
    fi
    from="$(_containers_kv_get "${rec}" FROM)"
    _containers_stack_running "${name}"
    rc=$?
    case "${rc}" in
        0) state=running ;;
        1) state=stopped ;;
        *) state=unknown ;;
    esac
    compose="$(_containers_stack_compose_of "${name}" 2>/dev/null)" || compose=""
    file="$(_containers_stack_file_of "${name}" 2>/dev/null)" || file=""
    project="$(_containers_stack_project_of "${name}")"
    tool_text="${file}"
    if [ -n "${file}" ] && override="$(_containers_override_file_in "${dir}" "${file}")"; then
        tool_text="${tool_text} (+ ${override})"
    fi
    tool_text="${compose}${compose:+, }${tool_text}${tool_text:+, }project ${project}"

    printf '%s\n' "${name}"
    _containers_info_line folder "$(_containers_stacks_root)/${name}"
    _containers_info_line "linked to" "${target}"
    _containers_info_line origin "${origin:-manual}"
    _containers_info_line from "${from}"
    _containers_info_line state "${state}"
    _containers_info_line compose "${tool_text}"

    labels="$(_containers_kv_get "${rec}" PORT_LABELS)"
    if [ -n "${labels}" ]; then
        bind_var="$(_containers_kv_get "${rec}" BIND_VAR)"
        host=""
        if [ -n "${bind_var}" ]; then
            host="$(_containers_kv_get "${env}" "${bind_var}")"
        fi
        case "${host}" in
            ""|0.0.0.0) host=127.0.0.1 ;;
        esac
        while IFS= read -r entry; do
            [ -n "${entry}" ] || continue
            var="${entry%%:*}"
            label="${entry#*:}"
            port="$(_containers_kv_get "${env}" "${var}")"
            [ -n "${port}" ] || continue
            if [ "${label}" = "web" ]; then
                _containers_info_line "${label}" "http://${host}:${port}/"
            else
                _containers_info_line "${label}" "${host}:${port}"
            fi
        done <<EOT
$(_containers_words "${labels}")
EOT
    elif [ -f "${env}" ]; then
        while IFS= read -r entry; do
            _containers_info_line ports "${entry}"
        done <<EOT
$(grep -E '^[A-Za-z_][A-Za-z0-9_]*_PORT=' "${env}" 2>/dev/null)
EOT
    fi

    login_vars="$(_containers_kv_get "${rec}" LOGIN_VARS)"
    secret_vars="$(_containers_kv_get "${rec}" SECRET_VARS)"
    login_text=""
    while IFS= read -r var; do
        [ -n "${var}" ] || continue
        value="$(_containers_kv_get "${env}" "${var}")"
        [ -n "${value}" ] || continue
        login_text="${login_text}${login_text:+, }${value}"
    done <<EOT
$(_containers_words "${login_vars}")
EOT
    while IFS= read -r var; do
        [ -n "${var}" ] || continue
        login_text="${login_text}${login_text:+; }password: ${var} in ${env}"
    done <<EOT
$(_containers_words "${secret_vars}")
EOT
    _containers_info_line login "${login_text}"

    timeout_text="$(_containers_kv_get "${rec}" STOP_TIMEOUT)"
    if [ -n "${timeout_text}" ]; then
        timeout_text="${timeout_text}s"
    else
        timeout_text="compose's default (10s)"
    fi
    _containers_info_line "stop timeout" "${timeout_text}"
    requires="$(_containers_kv_get "${rec}" REQUIRES)"
    _containers_info_line needs "${requires}"
    size="$(du -sh "$(_containers_abs_dir "${dir}")" 2>/dev/null | cut -f1)"
    _containers_info_line size "${size}"
    volumes="$(_containers_stack_volumes "${name}" | awk 'NF { printf "%s%s", sep, $1; sep = ", " }')"
    _containers_info_line volumes "${volumes:-none}"
}

stack-edit() {
    local name="" which="" dir compose_file override files file abs editor was600 before after picked_line
    case "${1:-}" in
        -h|--help)
            _containers_usage "Usage: stack-edit [<name>] [compose|env|override]" \
                "Opens one of the stack's files in your editor (VISUAL, then EDITOR, then nano, vim or vi)," \
                "then checks the stack with compose config and offers another edit when compose can't read it." \
                "With more than the compose file, asks which file. Changes apply at the next stack-up." \
                "An editor that returns at once (code without --wait) makes the check run before you save." \
                "With one stack, the name can be left out."
            return 0
            ;;
        compose|env|override)
            # A file word, unless a stack has that name.
            if [ -d "$(_containers_stacks_root)/$1" ]; then
                name="$1"
                shift
            fi
            ;;
        ""|-*) ;;
        *) name="$1"; shift ;;
    esac
    case "${1:-}" in
        "") ;;
        compose|env|override) which="$1"; shift ;;
        *)
            log_error "stacks: stack-edit: '$1' isn't a file to edit (compose, env or override)"
            return 2
            ;;
    esac
    if [ "$#" -gt 0 ]; then
        log_error "stacks: stack-edit: too many arguments ('$1')"
        return 2
    fi
    name="$(_containers_stack_resolve stack-edit "${name}")" || return $?
    dir="$(_containers_stack_dir "${name}")" || return 1
    compose_file="$(_containers_stack_file_of "${name}")" || return 1
    override="$(_containers_override_file_in "${dir}" "${compose_file}")" || override=""

    case "${which}" in
        compose) file="${compose_file}" ;;
        env) file=.env ;;
        override)
            file="${override}"
            if [ -z "${file}" ]; then
                log_error "stacks: ${name}: no override file in ${dir} (compose.override.yaml beside the compose file)"
                return 1
            fi
            ;;
        *) file="" ;;
    esac
    if [ -n "${file}" ] && [ ! -f "${dir}/${file}" ]; then
        log_error "stacks: ${name}: no ${file} in ${dir}"
        return 1
    fi
    if ! _wb_have_tty; then
        log_error "stacks: stack-edit needs a terminal"
        return 1
    fi
    if ! editor="$(_containers_editor)"; then
        log_error "stacks: no editor found; set EDITOR (for example, EDITOR=nano)"
        return 1
    fi
    if [ -z "${file}" ]; then
        files="${compose_file}"
        if [ -f "${dir}/.env" ]; then
            files="${files}
.env"
        fi
        if [ -n "${override}" ]; then
            files="${files}
${override}"
        fi
        if [ "${files}" = "${compose_file}" ]; then
            file="${compose_file}"
        else
            picked_line="$(_containers_choose "Edit which file of ${name}?" "${files}")" || return 2
            file="${picked_line}"
        fi
    fi

    abs="${dir}/${file}"
    was600=""
    if [ -n "$(command find "${abs}" -perm 600 2>/dev/null)" ]; then
        was600=1
    fi
    before="$(cksum < "${abs}")"
    while :; do
        _containers_run_editor "${editor}" "${abs}"
        after="$(cksum < "${abs}")"
        if [ "${after}" = "${before}" ]; then
            printf 'stacks: %s: no changes\n' "${name}"
            return 0
        fi
        if [ -n "${was600}" ] && [ -z "$(command find "${abs}" -perm 600 2>/dev/null)" ]; then
            chmod 600 "${abs}" && printf 'stacks: %s: %s is mode 600 again\n' "${name}" "${file}"
        fi
        if _containers_stack_run "${name}" config >/dev/null; then
            break
        fi
        if ! _containers_yes_default "Edit again? [Y/n] "; then
            log_warn "stacks: ${name}: compose can't read the stack as it is; stack-up will fail until it's fixed"
            return 1
        fi
    done
    if _containers_stack_running "${name}"; then
        printf 'stacks: %s: running; the change applies at the next start: stack-down %s && stack-up %s\n' "${name}" "${name}" "${name}"
    fi
    return 0
}

stack-rm() {
    local name="" purge="" root dir target compose project cli answer size volumes rc volume
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                _containers_usage "Usage: stack-rm <name> [--purge]" \
                    "Forgets a stack. A linked stack loses its link and record; your folder stays." \
                    "--purge deletes a stack's own folder (needs a terminal, and the stack's name typed back)."
                return 0
                ;;
            --purge) purge=1; shift ;;
            -*)
                log_error "stacks: stack-rm: unknown option '$1'"
                return 2
                ;;
            *)
                if [ -n "${name}" ]; then
                    log_error "stacks: stack-rm takes one stack (got '${name}' and '$1')"
                    return 2
                fi
                name="$1"
                shift
                ;;
        esac
    done
    # Always the name, even with one stack: stack-rm never picks one.
    if [ -z "${name}" ]; then
        _containers_usage "Usage: stack-rm <name> [--purge]" >&2
        printf 'Stacks: %s\n' "$(_containers_stack_names | tr '\n' ' ' | sed 's/ $//')" >&2
        return 2
    fi
    if ! _containers_stack_name_ok "${name}"; then
        log_error "stacks: '${name}' isn't a valid stack name"
        return 1
    fi
    root="$(_containers_stacks_root)"
    dir="${root}/${name}"
    target=""
    if [ -L "${dir}" ]; then
        target="$(readlink "${dir}")"
    elif [ ! -d "${dir}" ]; then
        log_error "stacks: ${name}: no such stack (stack-list shows them)"
        return 1
    fi

    _containers_stack_running "${name}"
    rc=$?
    case "${rc}" in
        0)
            log_error "stacks: ${name}: is running; stop it first: stack-down ${name}"
            return 1
            ;;
        1) ;;
        *)
            if [ -z "${target}" ]; then
                log_error "stacks: ${name}: can't tell whether it is running (is the engine started?); nothing was removed"
                return 1
            fi
            ;;
    esac

    if [ -n "${target}" ]; then
        if [ -n "${purge}" ]; then
            log_error "stacks: ${name} is your folder ${target}; stack-rm only removes the link. Delete the folder yourself if you want it gone."
            return 1
        fi
        rm -f -- "${dir}"
        rm -f -- "$(_containers_stack_meta_path "${name}")"
        printf 'stacks: %s: removed the link; %s was left as it is\n' "${name}" "${target}"
        return 0
    fi

    if [ -z "${purge}" ]; then
        log_error "stacks: ${name}'s folder is its data. Use --purge to delete it, or move the folder out of ${root}."
        return 1
    fi
    if ! _wb_have_tty; then
        log_error "stacks: ${name}: --purge asks for the stack's name and needs a terminal"
        return 1
    fi

    compose="$(_containers_stack_compose_of "${name}" 2>/dev/null)" || compose=""
    project="$(_containers_stack_project_of "${name}")"
    size="$(du -sh "${dir}" 2>/dev/null | cut -f1)"
    volumes=""
    if [ -n "${compose}" ]; then
        volumes="$(_containers_project_volumes "${compose}" "${project}")"
    fi
    printf 'This deletes the stack and everything in it:\n'
    printf '  folder:  %s (%s)\n' "${dir}" "${size:-?}"
    if [ -n "${volumes}" ]; then
        printf '  named volumes, which stay behind: %s\n' "$(printf '%s\n' "${volumes}" | tr '\n' ' ')"
    fi
    _read_prompt "Type the stack's name to delete it: " answer
    if [ "${answer}" != "${name}" ]; then
        printf 'stacks: %s: not deleted\n' "${name}"
        return 1
    fi

    if ! _containers_stack_down "${name}"; then
        log_warn "stacks: ${name}: compose down failed; deleting the folder anyway"
    fi
    cli=""
    if [ -n "${compose}" ]; then
        cli="$(_containers_stack_engine_cli "${compose}")"
    fi
    # Rootless podman maps the container's users into subuids; a file
    # written by a non-root user inside is only removable from that
    # namespace.
    if [ "${cli}" = "podman" ] && [ "$(command podman info --format '{{.Host.Security.Rootless}}' 2>/dev/null)" = "true" ]; then
        command podman unshare rm -rf -- "${dir}"
    else
        rm -rf -- "${dir}"
    fi
    if [ -e "${dir}" ]; then
        log_error "stacks: ${name}: some files belong to another user (rootful Docker writes them as root): sudo rm -rf -- ${dir}"
        return 1
    fi
    rm -f -- "$(_containers_stack_meta_path "${name}")"
    printf 'stacks: %s: deleted %s\n' "${name}" "${dir}"

    if [ -n "${compose}" ]; then
        volumes="$(_containers_project_volumes "${compose}" "${project}")"
        if [ -n "${volumes}" ]; then
            printf 'stacks: %s: named volumes left behind; remove each with:\n' "${name}"
            while IFS= read -r volume; do
                [ -n "${volume}" ] || continue
                printf '  %s volume rm %s\n' "${cli}" "${volume}"
            done <<EOF
${volumes}
EOF
        fi
    fi
}

# _containers_help_overview — stack-help with no topic.
_containers_help_overview() {
    printf 'Stacks: compose projects kept one per folder, under %s.\n\n' "$(_containers_stacks_root)"
    _containers_help_commands
    command cat <<'EOT'

With one stack, the name can be left out; with several, you're asked which.
stack-rm always needs the name. Tab completes stack names, templates and
options.

More:  stack-help import      bring your own compose project in
       stack-help templates   what each template needs and gives you
       stack-help <command>   one command's options
       stack-help --full      the full guide
EOT
}

# _containers_help_commands — the overview's command table.
_containers_help_commands() {
    command cat <<'EOT'
  stack-new [<template>]           create a stack from a template
  stack-import <folder|file>       bring a compose project you already have in
  stack-list                       every stack: where it came from, whether it runs
  stack-info [<name>]              its folder, ports, login, size and volumes
  stack-up [<name>]                start it (compose up -d)
  stack-down [<name>]              stop it, giving it its stop timeout
  stack-logs [<name>] [-f]         its logs
  stack-edit [<name>] [compose|env|override]
                                   edit its files, then check them
  stack-compose [<name>] <args>    any other compose command, for the stack
  stack-path [<name>]              print its folder: cd "$(stack-path win11)"
  stack-rm <name> [--purge]        forget it; --purge deletes its folder
  stack-help [<topic>]             this help
EOT
}

# _containers_help_import — stack-help import.
_containers_help_import() {
    command cat <<'EOT'
Importing your own compose project

1. Look first:   stack-import ~/src/myapp --dry-run
   Shows the stack's name, the compose file, how it would be imported, the
   stop timeout and any named volumes. Nothing changes.

2. Import it:    stack-import ~/src/myapp
   On a terminal it asks how:
     link   leave the files where they are; the stack points at them
     move   move the folder into the stacks folder
     copy   copy it there and leave the original
   then shows the summary and asks before doing anything.
   --link, --move or --copy answers the first question; --yes the second.

3. Use it:       stack-up myapp
                 stack-logs myapp -f
                 stack-info myapp
                 stack-edit myapp

Good to know
  - The name comes from the compose file's name:, else the folder's name.
    --name chooses another. The compose project name is kept either way,
    because named volumes are keyed by it.
  - --move and --copy refuse while the project is running: stop it first.
  - A lone compose file is copied with any .env beside it. If it uses other
    files beside it, import the folder instead.
  - Named volumes stay in the engine's storage, not in the stack folder.
    stack-rm --purge leaves them, and says how to remove them.
  - stack-down waits as long as the compose file's stop_grace_period, so a
    VM can shut down cleanly. --stop-timeout <seconds> sets another time.
    With neither, compose waits 10 seconds.
  - compose.override.yaml beside the compose file is used too.
  - The stack's .env wins over variables exported in your shell.
EOT
}

# _containers_help_template <template> — one template's block.
_containers_help_template() {
    local conf aliases requires ports entry labels
    conf="$(_containers_stacks_templates_dir)/$1/template.conf"
    aliases="$(_containers_kv_get "${conf}" ALIASES)"
    requires="$(_containers_kv_get "${conf}" REQUIRES)"
    ports="$(_containers_kv_get "${conf}" PORTS)"
    labels=""
    while IFS= read -r entry; do
        [ -n "${entry}" ] || continue
        labels="${labels}${labels:+, }${entry##*:}"
    done <<EOT
$(_containers_words "${ports}")
EOT
    if [ -n "${aliases}" ]; then
        printf '%s (also: %s)\n' "$1" "$(printf '%s' "${aliases}" | sed 's/  */, /g')"
    else
        printf '%s\n' "$1"
    fi
    printf '  %s\n' "$(_containers_kv_get "${conf}" DESCRIPTION)"
    printf '  %-9s %s\n' needs "${requires:-nothing beyond compose}"
    if [ -n "${labels}" ]; then
        printf '  %-9s %s\n' ports "${labels}"
    fi
    if [ -n "$(_containers_kv_get "${conf}" LOGIN_VARS)$(_containers_kv_get "${conf}" SECRET_VARS)" ]; then
        printf '  %-9s %s\n' login "stack-new sets a user and a random password in the stack's .env"
    fi
    if [ -n "$(_containers_kv_get "${conf}" ACCEPT)" ]; then
        printf '  %-9s %s\n' licence "must be accepted when the stack is created (--accept without a terminal)"
    fi
    printf '  stack-help templates %s for setup and access\n' "$1"
}

stack-help() {
    local topic="" full="" extra="" t first=1 tname
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                _containers_usage "Usage: stack-help [<topic>|<command>] [--full]" \
                    "Topics: import, templates [<template>], commands. <command> is any stack command." \
                    "--full shows the full guide (wb module docs containers stacks)."
                return 0
                ;;
            --full) full=1; shift ;;
            *)
                if [ -z "${topic}" ]; then
                    topic="$1"
                elif [ -z "${extra}" ]; then
                    extra="$1"
                else
                    log_error "stacks: stack-help: too many arguments ('$1')"
                    return 2
                fi
                shift
                ;;
        esac
    done
    if [ -n "${full}" ]; then
        if command -v wb >/dev/null 2>&1; then
            wb module docs containers stacks
            return
        fi
        printf 'The full guide: %s\n' "$(builtin cd -- "${_containers_stacks_lib_dir}/.." >/dev/null 2>&1 && pwd)/docs/stacks.md"
        return 0
    fi
    case "${topic}" in
        "") _containers_help_overview ;;
        import) _containers_help_import ;;
        commands) _containers_help_commands ;;
        templates)
            if [ -n "${extra}" ]; then
                if ! tname="$(_containers_template_resolve "${extra}")"; then
                    log_error "stacks: no template '${extra}'. Templates:"
                    _containers_templates_list >&2
                    return 2
                fi
                _containers_help_template "${tname}"
                if [ -f "$(_containers_stacks_templates_dir)/${tname}/help.txt" ]; then
                    printf '\n'
                    command cat "$(_containers_stacks_templates_dir)/${tname}/help.txt"
                fi
                return 0
            fi
            while IFS= read -r t; do
                [ -n "${t}" ] || continue
                [ -n "${first}" ] || printf '\n'
                first=""
                _containers_help_template "${t}"
            done <<EOT
$(_containers_template_names)
EOT
            ;;
        new|list|info|up|down|logs|edit|compose|path|rm|help|stack-new|stack-import|stack-list|stack-info|stack-up|stack-down|stack-logs|stack-edit|stack-compose|stack-path|stack-rm|stack-help)
            t="stack-${topic#stack-}"
            "${t}" --help
            ;;
        *)
            log_error "stacks: no help on '${topic}'"
            log_error "stacks: topics: import, templates [<template>], commands, or a command (up, stack-up, ...)"
            return 2
            ;;
    esac
}
