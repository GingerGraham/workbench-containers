#!/usr/bin/env bash
# shell/containers.sh — workbench-containers
# Container tool configuration — Docker and Podman aliases. Registered at
# tier: tools (workbench.yml), sourced unconditionally; each block guards
# on the tool it needs.
# Ported from workbench-precursor's tools/containers.sh — no installers
# exist for either in the precursor repo (assumed pre-installed or
# package-managed).

# ── aliases ───────────────────────────────────────────────────────────────────
# A real docker binary on PATH, ignoring aliases (this file's own
# docker→podman one, or the user's). `command -v` won't do: zsh reports an
# alias ahead of a binary. Tested in planning in bash and zsh, with and
# without the alias.
_containers_docker_bin() {
    if [[ -n "${ZSH_VERSION:-}" ]]; then
        whence -p docker &>/dev/null
    else
        type -P docker &>/dev/null
    fi
}

# The docker-prefixed aliases below are only ever defined once the
# docker-binary guard has passed, but the getter's static-grep listing
# (core-generated, workbench-core D89) can't see that runtime guard, so
# without this it would list them even on hosts without docker. Declare
# their availability predicates so the listing matches reality.
_wb_alias_availability --needs "docker (the binary, not the podman alias)" \
    _containers_docker_bin d dps dpsa di drm drmi dex dlog

if _containers_docker_bin; then
    alias d="docker"
    alias dps="docker ps"
    alias dpsa="docker ps -a"
    alias di="docker images"
    alias drm="docker rm"
    alias drmi="docker rmi"
    alias dex="docker exec -it"
    alias dlog="docker logs"
fi

if command -v podman &>/dev/null; then
    alias pd="podman"
    alias pdps="podman ps"
    alias pdpsa="podman ps -a"
    alias pdi="podman images"
fi

# Same reasoning as the docker block above, for the podman-prefixed
# aliases.
_wb_declare_availability podman pd pdps pdpsa pdi

# Prefer podman over docker when both are available (rootless-first)
_containers_docker_shim_ok() { command -v podman &>/dev/null && ! _containers_docker_bin; }
_wb_alias_availability --needs "podman, and no docker binary" _containers_docker_shim_ok docker
if _containers_docker_shim_ok; then
    alias docker="podman"
fi

# DOCKER_COMPOSE_CMD wins; otherwise whichever compose is installed.
_containers_compose_cmd() {
    if [[ -n "${DOCKER_COMPOSE_CMD:-}" ]]; then printf '%s' "${DOCKER_COMPOSE_CMD}"
    elif command -v docker-compose &>/dev/null; then printf 'docker-compose'
    elif command -v podman-compose &>/dev/null; then printf 'podman-compose'
    else return 1
    fi
}
_wb_alias_availability --needs "docker-compose or podman-compose (or DOCKER_COMPOSE_CMD)" \
    _containers_compose_cmd dc
if _containers_compose_cmd >/dev/null; then
    # shellcheck disable=SC2139  # chosen once, when the shell starts
    alias dc="$(_containers_compose_cmd)"
fi
