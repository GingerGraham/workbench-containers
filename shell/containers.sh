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

if command -v podman &>/dev/null; then
    alias pd="podman"
    alias pdps="podman ps"
    alias pdpsa="podman ps -a"
    alias pdi="podman images"
fi

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
