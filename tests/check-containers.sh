#!/usr/bin/env bash
# tests/check-containers.sh — workbench-containers
# Behaviour of shell/containers.sh, shell/kubernetes.sh and
# shell/installers.sh, in bash and (when installed) zsh, since every
# register.shell file is also sourced into zsh. Plain bash, numbered
# OK:/FAIL: checks, no framework. No network and no workbench-core: the
# Core API helpers these files call are stubbed, and every external tool
# is a fake on a PATH this script builds (the real host may have docker).
#
#   - the docker aliases need a real docker binary, not the docker→podman
#     alias, so they aren't listed on a podman-only PATH;
#   - the docker→podman alias only when there is no docker binary;
#   - dc resolves to DOCKER_COMPOSE_CMD, else docker-compose, else
#     podman-compose, and is undeclared without any of them;
#   - set-kubectl called twice with -v uses the second version (OPTIND);
#   - set-kubectl leaves a kubectl elsewhere on PATH alone;
#   - install-kubectl (set-kubectl -l) leaves kubectl on PATH.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)" || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'rm -rf "${WORK}"' EXIT

# Host tools the scenarios need, linked into one directory so PATH can
# leave out everything else (/usr/bin included).
HOSTBIN="${WORK}/hostbin"
mkdir -p "${HOSTBIN}"
for _t in mkdir ln rm mv chmod cat awk sed grep head dirname basename readlink; do
    _p="$(command -v "${_t}")" || { echo "FAIL: host tool ${_t} not found"; exit 1; }
    ln -s "${_p}" "${HOSTBIN}/${_t}"
done

# _fake <dir> <name> [<body>] — an executable /bin/sh script.
_fake() {
    mkdir -p "$1"
    printf '#!/bin/sh\n%s\n' "${3:-exit 0}" > "$1/$2"
    chmod +x "$1/$2"
}

# The scenario body, run once per shell. Prints PASS:<text> / BAD:<text>.
cat > "${WORK}/scenario.sh" <<'EOF'
R="${REPO_ROOT}"
log_info()  { :; }
log_warn()  { echo "WARN: $*" >> "${HOME}/warn.log"; }
log_error() { echo "ERROR: $*" >> "${HOME}/err.log"; }
# Minimal stand-ins for workbench-core's Core API (lib/core/functions.sh):
# same predicate names, no needs-text bookkeeping.
_wb_declare_availability() {
    local _cmd="$1" _fn; shift
    for _fn in "$@"; do eval "_${_fn}-available() { command -v \"${_cmd}\" >/dev/null 2>&1; }"; done
}
_wb_alias_availability() {
    while [ "$#" -gt 0 ]; do
        case "$1" in --needs|--install) shift 2 ;; *) break ;; esac
    done
    local _check="$1" _fn; shift
    for _fn in "$@"; do eval "_${_fn}-available() { ${_check}; }"; done
}
listed() { "_$1-available" >/dev/null 2>&1; }
alias_value() {
    local _v
    _v="$(alias "$1" 2>/dev/null)" || return 1
    _v="${_v#alias }"; _v="${_v#"$1"=}"; _v="${_v#\'}"; _v="${_v%\'}"
    printf '%s' "${_v}"
}
check() { if eval "$2"; then echo "PASS:$1"; else echo "BAD:$1"; fi; }

case "${SCENARIO}" in
    podman-only)
        . "${R}/shell/containers.sh"
        check "podman-only: d/dps/dpsa/di/drm/drmi/dex/dlog not listed" \
            '! listed d && ! listed dps && ! listed dpsa && ! listed di && ! listed drm && ! listed drmi && ! listed dex && ! listed dlog'
        check "podman-only: docker aliases to podman" '[ "$(alias_value docker)" = "podman" ]'
        check "podman-only: the docker shim is listed" 'listed docker'
        check "podman-only: alias d not defined" '! alias d >/dev/null 2>&1'
        check "podman-only: docker alias doesn't count as a docker binary" '! _containers_docker_bin'
        . "${R}/shell/containers.sh"
        check "podman-only, reloaded: alias d still not defined" '! alias d >/dev/null 2>&1'
        check "podman-only, reloaded: docker aliases still not listed" '! listed d && ! listed dlog'
        ;;
    docker-and-podman)
        . "${R}/shell/containers.sh"
        check "docker+podman: docker aliases listed and defined" 'listed d && listed dlog && [ "$(alias_value d)" = "docker" ]'
        check "docker+podman: no docker→podman alias" '! alias docker >/dev/null 2>&1 && ! listed docker'
        check "docker+podman: podman aliases listed" 'listed pd && listed pdi'
        ;;
    podman-compose-only)
        . "${R}/shell/containers.sh"
        check "podman-compose only: dc is podman-compose" '[ "$(alias_value dc)" = "podman-compose" ]'
        check "podman-compose only: dc listed" 'listed dc'
        ;;
    both-compose)
        . "${R}/shell/containers.sh"
        check "both composes: dc is docker-compose" '[ "$(alias_value dc)" = "docker-compose" ]'
        ;;
    compose-env)
        . "${R}/shell/containers.sh"
        check "DOCKER_COMPOSE_CMD wins: dc is 'docker compose'" '[ "$(alias_value dc)" = "docker compose" ]'
        ;;
    no-compose)
        . "${R}/shell/containers.sh"
        check "no compose: dc not defined and not listed" '! alias dc >/dev/null 2>&1 && ! listed dc'
        ;;
    kubectl-versions)
        . "${R}/shell/kubernetes.sh"
        check "no kubectl: k and kube-version not listed" '! listed k && ! listed kube-version'
        set-kubectl -v 1.30.1 >/dev/null 2>&1
        check "set-kubectl -v 1.30.1 links that version" \
            '[ "$(readlink "${HOME}/.local/bin/kubectl")" = "${HOME}/.local/bin/k8s/kubectl-1.30.1/kubectl" ]'
        set-kubectl -v 1.31.2 >/dev/null 2>&1
        check "set-kubectl -v twice: the second call uses its version (OPTIND)" \
            '[ "$(readlink "${HOME}/.local/bin/kubectl")" = "${HOME}/.local/bin/k8s/kubectl-1.31.2/kubectl" ]'
        check "set-kubectl: kubectl on PATH is ~/.local/bin/kubectl" '[ "$(command -v kubectl)" = "${HOME}/.local/bin/kubectl" ]'
        check "set-kubectl: k listed once kubectl exists" 'listed k'
        ;;
    kubectl-elsewhere)
        . "${R}/shell/kubernetes.sh"
        set-kubectl -v 1.31.2 >/dev/null 2>&1
        check "set-kubectl leaves a package manager's kubectl in place" '[ -x "${PKGBIN}/kubectl" ] && [ ! -e "${PKGBIN}/kubectl.old" ]'
        check "set-kubectl links ~/.local/bin/kubectl anyway" \
            '[ "$(readlink "${HOME}/.local/bin/kubectl")" = "${HOME}/.local/bin/k8s/kubectl-1.31.2/kubectl" ]'
        ;;
    install-kubectl)
        . "${R}/shell/installers.sh"
        check "installed-kubectl false before install" '! installed-kubectl'
        install-kubectl >/dev/null 2>&1
        check "install-kubectl (set-kubectl -l) puts kubectl on PATH at ~/.local/bin/kubectl" \
            '[ "$(command -v kubectl)" = "${HOME}/.local/bin/kubectl" ] && [ "$(readlink "${HOME}/.local/bin/kubectl")" = "${HOME}/.local/bin/k8s/kubectl-1.32.0/kubectl" ]'
        check "installed-kubectl true after install" 'installed-kubectl'
        ;;
esac
EOF

# Fake _wb_fetch_verified: writes a kubectl that reports the version in
# its URL (and, like kubectl 1.28+, rejects --short).
cat > "${WORK}/fetch.sh" <<'EOF'
_wb_fetch_verified() {
    local _v="${1#*/release/v}"; _v="${_v%%/*}"
    printf '#!/bin/sh\ncase "$*" in *--short*) exit 1 ;; esac\necho "Client Version: v%s"\n' "${_v}" > "$2"
}
EOF

# run_scenario <shell> <name> <PATH-dirs> [VAR=value ...]
run_scenario() {
    local _sh="$1" _name="$2" _path="$3"; shift 3
    local _home="${WORK}/home-${_sh##*/}-${_name}" _out _line
    # shellcheck disable=SC2016  # expanded by the child shell
    local _body='. "$1"; . "$2"'
    mkdir -p "${_home}/.local/bin"
    _out="$(env -i HOME="${_home}" PATH="${_home}/.local/bin:${_path}:${HOSTBIN}" \
        REPO_ROOT="${REPO_ROOT}" SCENARIO="${_name}" PKGBIN="${WORK}/pkg" \
        WORKBENCH_OS=Linux WORKBENCH_ARCH=x86_64 WORKBENCH_SHELL="${_sh##*/}" "$@" \
        "${_sh}" -c "${_body}" _ "${WORK}/fetch.sh" "${WORK}/scenario.sh" 2>&1)"
    [[ -n "${_out}" ]] || { fail "[${_sh##*/}] ${_name}: scenario printed nothing"; return; }
    while IFS= read -r _line; do
        case "${_line}" in
            PASS:*) ok "[${_sh##*/}] ${_line#PASS:}" ;;
            BAD:*)  fail "[${_sh##*/}] ${_line#BAD:}" ;;
            *)      fail "[${_sh##*/}] ${_name}: unexpected output: ${_line}" ;;
        esac
    done <<< "${_out}"
}

_fake "${WORK}/podman" podman
_fake "${WORK}/docker" docker
_fake "${WORK}/docker" docker-compose
_fake "${WORK}/podman" podman-compose
_fake "${WORK}/pkg" kubectl 'echo "Client Version: v1.29.0"'
_fake "${WORK}/curl" curl 'echo v1.32.0'
mkdir -p "${WORK}/empty"

shells="$(command -v bash)"
if command -v zsh &>/dev/null; then
    shells="${shells} $(command -v zsh)"
else
    echo "SKIP: zsh not installed — zsh runs of these checks skipped"
fi

for sh in ${shells}; do
    # Separate fake dirs per tool, so each PATH holds only what it names.
    mkdir -p "${WORK}/p-only" "${WORK}/pc-only"
    ln -sf "${WORK}/podman/podman" "${WORK}/p-only/podman"
    ln -sf "${WORK}/podman/podman-compose" "${WORK}/pc-only/podman-compose"
    run_scenario "${sh}" podman-only         "${WORK}/p-only"
    run_scenario "${sh}" docker-and-podman   "${WORK}/docker:${WORK}/p-only"
    run_scenario "${sh}" podman-compose-only "${WORK}/podman"
    run_scenario "${sh}" both-compose        "${WORK}/docker:${WORK}/podman"
    run_scenario "${sh}" compose-env         "${WORK}/empty" DOCKER_COMPOSE_CMD="docker compose"
    run_scenario "${sh}" no-compose          "${WORK}/p-only"
    run_scenario "${sh}" kubectl-versions    "${WORK}/empty"
    run_scenario "${sh}" kubectl-elsewhere   "${WORK}/pkg"
    run_scenario "${sh}" install-kubectl     "${WORK}/curl"
done

echo
echo "==============================="
echo "Total OK/FAIL checks: ${check_no}, failed: ${FAILED}"
echo "==============================="
[[ "${FAILED}" -eq 0 ]]
