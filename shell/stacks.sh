#!/usr/bin/env bash
# shell/stacks.sh — workbench-containers
# Compose stacks: one folder per compose project under
# ${XDG_DATA_HOME:-~/.local/share}/stacks/<name>/, with functions to create
# (stack-new from a template, stack-add from a project you already have),
# list, run, stop, log and remove them. workbench-core D129.
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

# _containers_compose_in <dir> <compose> <project> <file> <args...> — runs
# compose from <dir> in a subshell, so the caller's directory and
# environment never change. A case per tool instead of word-splitting
# "docker compose": no arrays, and zsh doesn't split unquoted parameters.
_containers_compose_in() {
    local dir="$1" compose="$2" project="$3" file="$4"
    shift 4
    (
        builtin cd -- "${dir}" || exit 1
        _containers_env_file_wins .env
        case "${compose}" in
            podman-compose)   command podman-compose -p "${project}" -f "${file}" "$@" ;;
            docker-compose)   command docker-compose -p "${project}" -f "${file}" "$@" ;;
            "docker compose") command docker compose -p "${project}" -f "${file}" "$@" ;;
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
    ( builtin cd -P -- "$1" >/dev/null 2>&1 && pwd -P )
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

_wb_alias_availability --needs "podman with podman-compose, or Docker with compose" --install podman \
    _containers_stack_compose_available \
    stack-new stack-add stack-list stack-up stack-down stack-logs stack-compose stack-path stack-rm

# ── public functions ──────────────────────────────────────────────────────────

stack-new() {
    local template="" name="" list_only="" root dir tdir tconf
    local requires bind_var ports dirs nocow_dirs login_vars secret_vars stop_timeout note
    local compose claimed picked port_records env_extra entry var rest base label port d login secret sha created
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                _containers_usage "Usage: stack-new [<template>] [--name <name>]" \
                    "       stack-new --list" \
                    "Creates a stack from a template in the stacks folder; doesn't start it."
                return 0
                ;;
            --list) list_only=1; shift ;;
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

    if [ -z "${template}" ] || [ -n "${list_only}" ]; then
        printf 'Templates (stack-new <template> [--name <name>]):\n'
        _containers_templates_list
        return 0
    fi
    case "${template}" in
        */*|.*) tconf="" ;;
        *) tconf="$(_containers_stacks_templates_dir)/${template}/template.conf" ;;
    esac
    if [ -z "${tconf}" ] || [ ! -f "${tconf}" ]; then
        log_error "stacks: no template '${template}'. Templates:"
        _containers_templates_list >&2
        return 1
    fi
    tdir="$(dirname -- "${tconf}")"

    name="${name:-${template}}"
    if ! _containers_stack_name_ok "${name}"; then
        log_error "stacks: '${name}' isn't a valid stack name (lowercase letters, digits, - and _, starting with a letter or digit, at most 63 characters)"
        return 1
    fi
    root="$(_containers_stacks_root)"
    dir="${root}/${name}"
    if [ -e "${dir}" ] || [ -L "${dir}" ] || [ -e "$(_containers_stack_meta_path "${name}")" ]; then
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

    if [ "${requires}" = "kvm" ] && ! _containers_kvm_ok; then
        log_error "stacks: ${name}: needs KVM, and ${_CONTAINERS_KVM_DEV:-/dev/kvm} isn't there or isn't readable and writable"
        log_error "stacks: $(_containers_kvm_hint)"
        return 1
    fi
    compose="$(_containers_stack_compose_cmd)" || return 1
    _containers_stacks_root_ensure || return 1

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
    done <<EOF
$(_containers_words "${dirs}")
EOF
    # Still empty here, which is what +C needs for the disk created in it.
    while IFS= read -r d; do
        [ -n "${d}" ] || continue
        _containers_nocow "${dir}/${d}"
    done <<EOF
$(_containers_words "${nocow_dirs}")
EOF

    # Ports: one free port per template entry, never one another stack has
    # claimed (even a stopped one), nor one picked earlier in this call.
    claimed="$(_containers_stacks_claimed_ports)"
    picked=""
    port_records=""
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
    done <<EOF
$(_containers_words "${ports}")
EOF

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
    done <<EOF
${port_records}
EOF
    while IFS= read -r var; do
        [ -n "${var}" ] || continue
        env_extra="${env_extra}${var}=${login}
"
    done <<EOF
$(_containers_words "${login_vars}")
EOF
    while IFS= read -r var; do
        [ -n "${var}" ] || continue
        if ! secret="$(_containers_random_secret)"; then
            _containers_stack_abort "${name}" "can't read random bytes for ${var}"
            return 1
        fi
        env_extra="${env_extra}${var}=${secret}
"
    done <<EOF
$(_containers_words "${secret_vars}")
EOF

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
    done <<EOF
${port_records}
EOF
    if [ -n "${login_vars}" ]; then
        printf '  User: %s\n' "${login}"
    fi
    if [ -n "${secret_vars}" ]; then
        printf '  Password: in %s/.env\n' "${dir}"
    fi
    if [ -n "${note}" ]; then
        printf '%s\n' "${note}" | sed "s/<name>/${name}/g"
    fi
    printf 'Start it with: stack-up %s\n' "${name}"
}

stack-add() {
    local source_arg="" name="" mode="" kind srcdir srcabs file compose project root dest
    local size volumes verb rc added
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -h|--help)
                _containers_usage "Usage: stack-add <folder|compose-file> [--name <name>] [--link|--move|--copy]" \
                    "A folder is linked in place by default; a lone compose file is copied (with any .env beside it)." \
                    "--move and --copy refuse while the project is running."
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
            --link|--move|--copy) mode="${1#--}"; shift ;;
            -*)
                log_error "stacks: stack-add: unknown option '$1'"
                return 2
                ;;
            *)
                if [ -n "${source_arg}" ]; then
                    log_error "stacks: stack-add takes one folder or file (got '${source_arg}' and '$1')"
                    return 2
                fi
                source_arg="$1"
                shift
                ;;
        esac
    done
    if [ -z "${source_arg}" ]; then
        log_error "stacks: stack-add needs a folder or a compose file"
        return 2
    fi

    if [ -d "${source_arg}" ]; then
        kind=folder
        srcdir="${source_arg}"
        if ! file="$(_containers_compose_file_in "${srcdir}")"; then
            log_error "stacks: no compose file in ${srcdir} (looked for compose.yaml, compose.yml, docker-compose.yaml, docker-compose.yml)"
            return 1
        fi
        mode="${mode:-link}"
    elif [ -f "${source_arg}" ]; then
        kind="file"
        srcdir="$(dirname -- "${source_arg}")"
        file="$(basename -- "${source_arg}")"
        case "${mode}" in
            ""|copy) mode=copy ;;
            *)
                log_error "stacks: --${mode} needs a folder: point stack-add at the file's folder to move or link it"
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
    if [ -e "${dest}" ] || [ -L "${dest}" ] || [ -e "$(_containers_stack_meta_path "${name}")" ]; then
        log_error "stacks: ${name}: already exists (${dest}); choose another with --name"
        return 1
    fi

    # Compose has to accept the files where they are before anything moves.
    if ! _containers_compose_in "${srcabs}" "${compose}" "${project}" "${file}" config >/dev/null; then
        log_error "stacks: ${name}: compose rejected ${srcabs}/${file} (see above); nothing was added"
        return 1
    fi

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
        size="$(du -sh "${srcabs}" 2>/dev/null | cut -f1)"
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
    if ! _containers_stack_meta_write "${name}" \
        "ORIGIN=${mode}" \
        "PROJECT=${project}" \
        "COMPOSE=${compose}" \
        "COMPOSE_FILE=${file}" \
        "ADDED=${added}"; then
        log_error "stacks: ${name}: can't write the stack's record"
        return 1
    fi

    if [ "${kind}" = "file" ]; then
        if ! _containers_stack_run "${name}" config >/dev/null; then
            rm -rf -- "${dest}"
            rm -f -- "$(_containers_stack_meta_path "${name}")"
            log_error "stacks: ${name}: ${file} probably refers to files beside the original; try: stack-add ${srcabs} --copy"
            return 1
        fi
    fi

    # Best effort: not every compose tool has `config --volumes`.
    volumes="$(_containers_stack_run "${name}" config --volumes 2>/dev/null | awk 'NF { printf "%s%s", sep, $1; sep = ", " }')"
    if [ -n "${volumes}" ]; then
        log_warn "stacks: ${name}: keeps data in named volumes (${volumes}), stored by the engine, not in the stack folder; stack-rm --purge leaves them"
    fi

    printf 'stacks: %s: added as %s (%s)\n' "${name}" "${dest}" "${mode}"
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
        printf 'stacks: no stacks yet (stack-new or stack-add)\n'
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
    local name="${1:-}" dir requires bind_var bind_value
    case "${name}" in
        ""|-h|--help)
            _containers_usage "Usage: stack-up <name> [compose up args...]" "Starts the stack in the background (compose up -d)."
            [ -n "${name}" ] && return 0
            return 2
            ;;
    esac
    shift
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
    if [ "${requires}" = "kvm" ] && ! _containers_kvm_ok; then
        log_error "stacks: ${name}: needs KVM, and ${_CONTAINERS_KVM_DEV:-/dev/kvm} isn't there or isn't readable and writable"
        log_error "stacks: $(_containers_kvm_hint)"
        return 1
    fi
    _containers_stack_run "${name}" up -d "$@"
}

stack-down() {
    local name="${1:-}"
    case "${name}" in
        ""|-h|--help)
            _containers_usage "Usage: stack-down <name> [compose down args...]" "Stops the stack and removes its containers and network; its folder and volumes stay."
            [ -n "${name}" ] && return 0
            return 2
            ;;
    esac
    shift
    _containers_stack_down "${name}" "$@"
}

stack-logs() {
    local name="${1:-}"
    case "${name}" in
        ""|-h|--help)
            _containers_usage "Usage: stack-logs <name> [compose logs args...]   e.g. stack-logs win11 -f"
            [ -n "${name}" ] && return 0
            return 2
            ;;
    esac
    shift
    _containers_stack_run "${name}" logs "$@"
}

stack-compose() {
    local name="${1:-}"
    case "${name}" in
        -h|--help)
            _containers_usage "Usage: stack-compose <name> <compose args...>   e.g. stack-compose win11 ps -a" "Runs compose for the stack, from its folder, with its recorded tool, project and file."
            return 0
            ;;
    esac
    if [ -z "${name}" ] || [ "$#" -lt 2 ]; then
        _containers_usage "Usage: stack-compose <name> <compose args...>   e.g. stack-compose win11 ps -a"
        return 2
    fi
    shift
    _containers_stack_run "${name}" "$@"
}

stack-path() {
    local name="${1:-}" dir
    case "${name}" in
        ""|-h|--help)
            _containers_usage "Usage: stack-path <name>   e.g. cd \"\$(stack-path win11)\""
            [ -n "${name}" ] && return 0
            return 2
            ;;
    esac
    dir="$(_containers_stack_dir "${name}")" || return 1
    _containers_abs_dir "${dir}"
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
    if [ -z "${name}" ]; then
        _containers_usage "Usage: stack-rm <name> [--purge]"
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
