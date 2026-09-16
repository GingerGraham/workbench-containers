#!/usr/bin/env bash
# shell/containers.sh — workbench-containers
# Container tool configuration — Docker and Podman aliases. Registered at
# tier: tools (.dotfiles-sync.yml), sourced unconditionally; each block
# guards on `command -v`.
# Ported from workbench-precursor's tools/containers.sh, unchanged — no
# installers exist for either in the precursor repo (assumed pre-installed
# or package-managed).

# ── aliases ───────────────────────────────────────────────────────────────────
if command -v docker &>/dev/null; then
    alias d="docker"
    alias dps="docker ps"
    alias dpsa="docker ps -a"
    alias di="docker images"
    alias drm="docker rm"
    alias drmi="docker rmi"
    alias dex="docker exec -it"
    alias dlog="docker logs"
fi

# The docker-prefixed aliases above are only ever defined once the
# `command -v docker` guard has passed, but get-containers-functions'
# static-grep listing can't see that runtime guard, so without this it
# would list them even on hosts without docker. Declare their
# availability predicates so the listing matches reality. This is
# unrelated to the docker-vs-podman backend selection below, which
# already works on either tool and stays ungated.
_wb_declare_availability docker d dps dpsa di drm drmi dex dlog

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
if command -v podman &>/dev/null && ! command -v docker &>/dev/null; then
    alias docker="podman"
fi

if command -v docker-compose &>/dev/null || command -v podman-compose &>/dev/null; then
    alias dc='${DOCKER_COMPOSE_CMD:-docker-compose}'
fi

get-containers-functions() {
    local _dir; _dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    _get_functions_in "Container/Kubernetes functions" "" "${_dir}/containers.sh" "${_dir}/kubernetes.sh"
    _get_aliases_in "Container/Kubernetes aliases" "" "${_dir}/containers.sh" "${_dir}/kubernetes.sh"
}
