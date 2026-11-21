#!/usr/bin/env bash
# shell/installers.sh — workbench-containers
# install-helm and its per-distro helpers. Ported from
# workbench-precursor's lazy/installers-iac.sh (the Helm slice — grouped
# here rather than workbench-iac since Helm operates specifically on
# Kubernetes clusters, per the module map §3), plus install-kubectl, a
# wrapper over set-kubectl in shell/kubernetes.sh. install-docker and
# install-podman are new to this module (not in the precursor); see the
# "Docker and Podman" section at the end of this file.
#
# WORKBENCH_OS is a workbench-core Core API platform fact
# (contracts/core-api.md), replacing the precursor's DOTFILES_OS.

_helm-install-linux() {
    local helm_version="$1" arch asset url tmp_dir
    case "${WORKBENCH_ARCH}" in
        x86_64|amd64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) log_error "helm: unsupported architecture ${WORKBENCH_ARCH}"; return 1 ;;
    esac

    # Official release tarball, verified against its published .sha256sum —
    # replaces get-helm-3 from helm's main branch, which skipped verification
    # when openssl was missing (security review M3). User-level install; no
    # sudo, no cd in the caller's shell.
    asset="helm-v${helm_version}-linux-${arch}.tar.gz"
    url="https://get.helm.sh/${asset}"
    local helm_dir="${HOME}/.local/bin/k8s/helm-${helm_version}"

    log_info "Installing helm ${helm_version}..."
    tmp_dir="$(mktemp -d)" || return 1
    _wb_fetch_verified "${url}" "${tmp_dir}/${asset}" "hashfile:${url}.sha256sum" \
        || { rm -rf "${tmp_dir}"; return 1; }
    tar -xzf "${tmp_dir}/${asset}" -C "${tmp_dir}" \
        || { log_error "helm: failed to extract ${asset}"; rm -rf "${tmp_dir}"; return 1; }
    [[ -f "${tmp_dir}/linux-${arch}/helm" ]] \
        || { log_error "helm: binary not found in ${asset}"; rm -rf "${tmp_dir}"; return 1; }

    mkdir -p "${helm_dir}"
    install -m 755 "${tmp_dir}/linux-${arch}/helm" "${helm_dir}/helm" \
        || { log_error "helm: failed to install binary into ${helm_dir}"; rm -rf "${tmp_dir}"; return 1; }
    rm -rf "${tmp_dir}"
    ln -sf "${helm_dir}/helm" "${HOME}/.local/bin/helm" \
        || { log_error "helm: failed to symlink helm into ${HOME}/.local/bin"; return 1; }

    if [[ -x /usr/local/bin/helm ]]; then
        log_warn "helm: an older root-installed /usr/local/bin/helm exists (from the previous install method). Remove it with: sudo rm /usr/local/bin/helm"
    fi
    command -v helm &>/dev/null && log_info "Helm ${helm_version} installed"
}

_helm-install-mac() {
    command -v brew &>/dev/null || { log_error "brew is required on macOS"; return 1; }
    if command -v helm &>/dev/null; then
        brew upgrade helm
    else
        brew install helm
    fi
}

install-helm() {
    local helm_version
    local latest_json
    latest_json="$(curl -fsS https://api.github.com/repos/helm/helm/releases/latest)" \
        || { log_error "Could not query the latest helm release"; return 1; }
    helm_version="$(echo "${latest_json}" | grep '"tag_name":' | sed -E 's/.+"v([^"]+)".+/\1/')"
    [[ -z "${helm_version}" ]] && { log_error "Could not determine helm version"; return 1; }

    if command -v helm &>/dev/null; then
        local current
        current="$(helm version --short | sed -r 's/v([0-9]+\.[0-9]+\.[0-9]+).*/\1/')"
        [[ "${current}" == "${helm_version}" ]] && { log_info "Helm ${helm_version} already installed"; return 0; }
    fi

    case "${WORKBENCH_OS}" in
        Linux) _helm-install-linux "${helm_version}" ;;
        Mac)   _helm-install-mac ;;
        *)     log_error "Unsupported OS for helm install"; return 1 ;;
    esac
}

installed-helm() {
    command -v helm &>/dev/null
}

# kubectl through wb tools. set-kubectl (shell/kubernetes.sh) does the
# verified download; this sources it, since wb tools loads only this file.
_containers_inst_dir="$(builtin cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)"
install-kubectl() {
    # shellcheck source=shell/kubernetes.sh
    source "${_containers_inst_dir}/kubernetes.sh" || return 1
    set-kubectl -l
}

installed-kubectl() {
    command -v kubectl &>/dev/null
}

# ── Docker and Podman ─────────────────────────────────────────────────────────
# Both run through `wb tools install`, in bash, with workbench-core's Core API
# (get-elevation-command, _wb_have_tty, _read_prompt, the D79 pinned-key
# helpers) already loaded. Supported: Fedora/RHEL (dnf), Debian/Ubuntu (apt),
# Arch (pacman) and macOS (brew). Anything else is refused with a message.
#
# install-docker on Linux is rootless: Docker CE from Docker's own repository,
# then dockerd-rootless-setuptool.sh, a per-user systemd service and
# linger. There is no system docker.service and no docker group. On macOS it
# installs Docker Desktop. install-podman installs podman, toolbox and
# podman-compose, and offers podman-docker when no docker command exists.
#
# List docker before podman in one `wb tools install` run: they run in the
# order given, so the podman-docker offer sees the docker that just went in.

# Docker signs its deb and rpm repositories with different keys. Fingerprints
# read from the keys served at download.docker.com/linux/{ubuntu,debian}/gpg
# and download.docker.com/linux/{fedora,rhel}/gpg on 2026-11-21 with
# `gpg --show-keys --with-colons` (uids "Docker Release (CE deb)" and "Docker
# Release (CE rpm)"). Not yet checked against Docker's documentation by a
# maintainer. A key rotation makes the install fail until this pin is updated
# (workbench-core D79). Public OpenPGP fingerprints, not secrets.
_DOCKER_DEB_KEY_FPR="9DC858229FC7DD38854AE2D88D81803C0EBFCD88" # gitleaks:allow
_DOCKER_RPM_KEY_FPR="060A61C51B558A7F742B77AAC52FEB6B621E9F35" # gitleaks:allow

# True for the real Docker CLI. The podman-docker shim is also a `docker`
# binary, so it is told apart by what `docker --version` prints.
_containers_real_docker() {
    type -P docker &>/dev/null || return 1
    docker --version 2>/dev/null | grep -q '^Docker version'
}

# True when any `docker` binary exists, real or the podman-docker shim.
_containers_any_docker() {
    type -P docker &>/dev/null
}

_containers_distro_supported() {
    case "${WORKBENCH_DISTRO}" in
        rhel|debian|arch) return 0 ;;
        *) return 1 ;;
    esac
}

# Reads one KEY=value field from os-release (without sourcing it).
# _CONTAINERS_OS_RELEASE overrides the path, for tests.
_containers_os_release_field() {
    local field="$1" file="${_CONTAINERS_OS_RELEASE:-/etc/os-release}" line value
    [[ -r "${file}" ]] || return 1
    line="$(grep -E "^${field}=" "${file}" | head -1)" || return 1
    value="${line#*=}"
    value="${value#\"}"
    value="${value%\"}"
    printf '%s' "${value}"
}

# Yes/no question, default no. No terminal to ask on means no.
_containers_confirm() {
    local answer=""
    _wb_have_tty || return 1
    _read_prompt "$1 [y/N] " answer
    case "${answer}" in
        y|Y|yes|Yes|YES) return 0 ;;
        *) return 1 ;;
    esac
}

_containers_pkg_installed() {
    case "${WORKBENCH_DISTRO}" in
        rhel)   rpm -q "$1" &>/dev/null ;;
        debian) dpkg -s "$1" 2>/dev/null | grep -q '^Status: install ok installed' ;;
        arch)   pacman -Q "$1" &>/dev/null ;;
        *)      return 1 ;;
    esac
}

# Debian needs a fresh index before an install; dnf and pacman do not.
_containers_pkg_refresh() {
    local elevation_cmd
    [[ "${WORKBENCH_DISTRO}" == "debian" ]] || return 0
    elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} apt-get update
}

_containers_pkg_install() {
    local elevation_cmd
    elevation_cmd="$(get-elevation-command)" || return 1
    case "${WORKBENCH_DISTRO}" in
        rhel)
            if command -v dnf &>/dev/null; then
                ${elevation_cmd} dnf install -y "$@"
            else
                ${elevation_cmd} yum install -y "$@"
            fi
            ;;
        debian) ${elevation_cmd} apt-get install -y "$@" ;;
        arch)   ${elevation_cmd} pacman -S --needed --noconfirm "$@" ;;
        *)      return 1 ;;
    esac
}

_containers_pkg_remove() {
    local elevation_cmd
    elevation_cmd="$(get-elevation-command)" || return 1
    case "${WORKBENCH_DISTRO}" in
        rhel)
            if command -v dnf &>/dev/null; then
                ${elevation_cmd} dnf remove -y "$@"
            else
                ${elevation_cmd} yum remove -y "$@"
            fi
            ;;
        debian) ${elevation_cmd} apt-get remove -y "$@" ;;
        arch)   ${elevation_cmd} pacman -Rs --noconfirm "$@" ;;
        *)      return 1 ;;
    esac
}

# Installs packages that make the tool nicer but are not what was asked for.
# A distro that lacks one of them gets a warning, not a failed install.
# Usage: _containers_pkg_install_optional <what it is> <pkg>...
_containers_pkg_install_optional() {
    local what="$1"
    shift
    _containers_pkg_install "$@" \
        || log_warn "${what}: could not install $* — continuing without it"
}

# ── Podman ────────────────────────────────────────────────────────────────────
# podman-docker puts a `docker` command in front of podman. Only offered when
# no docker binary exists, and only with a terminal to ask on.
_podman-offer-docker-shim() {
    if _containers_any_docker; then
        return 0
    fi
    if _containers_pkg_installed podman-docker; then
        return 0
    fi
    if ! _containers_confirm "podman: no docker command found. Install podman-docker (a 'docker' command that runs podman)?"; then
        log_info "podman: podman-docker not installed. To add it later, install the package 'podman-docker' with your package manager."
        return 0
    fi
    _containers_pkg_install podman-docker \
        || log_warn "podman: could not install podman-docker — continuing without it"
}

_podman-install-linux() {
    local toolbox_pkg
    if ! _containers_distro_supported; then
        log_error "podman: unsupported distro '${WORKBENCH_DISTRO}' (supported: Fedora/RHEL, Debian/Ubuntu, Arch)"
        return 1
    fi
    case "${WORKBENCH_DISTRO}" in
        debian) toolbox_pkg="podman-toolbox" ;;
        *)      toolbox_pkg="toolbox" ;;
    esac

    log_info "Installing podman..."
    _containers_pkg_refresh || return 1
    _containers_pkg_install podman \
        || { log_error "podman: package install failed"; return 1; }
    _containers_pkg_install_optional "podman toolbox" "${toolbox_pkg}"
    _containers_pkg_install_optional "podman compose provider" podman-compose
    _podman-offer-docker-shim
    command -v podman &>/dev/null \
        || { log_error "podman: not found on PATH after the install"; return 1; }
    log_info "Podman installed"
}

_podman-install-mac() {
    command -v brew &>/dev/null || { log_error "brew is required on macOS"; return 1; }
    if command -v podman &>/dev/null; then
        brew upgrade podman
    else
        brew install podman || return 1
    fi
    brew list podman-compose &>/dev/null || brew install podman-compose \
        || log_warn "podman: could not install podman-compose — continuing without it"
    log_info "podman: macOS runs containers in a VM. Create and start it once with: podman machine init && podman machine start"
}

install-podman() {
    case "${WORKBENCH_OS}" in
        Linux) _podman-install-linux ;;
        Mac)   _podman-install-mac ;;
        *)     log_error "Unsupported OS for podman install"; return 1 ;;
    esac
}

installed-podman() {
    command -v podman &>/dev/null
}

# ── Docker ────────────────────────────────────────────────────────────────────
# podman-docker and docker-ce both own /usr/bin/docker, so the shim has to go
# before Docker goes in.
_docker-clear-podman-shim() {
    _containers_pkg_installed podman-docker || return 0
    if ! _containers_confirm "docker: podman-docker is installed and conflicts with Docker (both provide /usr/bin/docker). Remove it?"; then
        log_error "docker: not installing while podman-docker is present. Remove it first, or run this again in a terminal and answer y."
        return 1
    fi
    _containers_pkg_remove podman-docker
}

# Docker CE for Fedora/RHEL: its own repo, key pinned (D79), only the Docker
# packages allowed from it.
_docker-repo-rpm() {
    local family
    case "$(_containers_os_release_field ID)" in
        fedora) family="fedora" ;;
        rhel)   family="rhel" ;;
        *)      family="centos" ;;   # Rocky, Alma, CentOS Stream: Docker's docs use the centos repo
    esac
    # shellcheck disable=SC2016  # $releasever and $basearch are for dnf, not the shell
    _wb_dnf_vendor_repo \
        --id docker-ce-stable \
        --name "Docker CE Stable" \
        --baseurl "https://download.docker.com/linux/${family}/"'$releasever/$basearch/stable' \
        --key-url "https://download.docker.com/linux/${family}/gpg" \
        --fingerprint "${_DOCKER_RPM_KEY_FPR}" \
        --include docker-ce \
        --include docker-ce-cli \
        --include docker-ce-rootless-extras \
        --include containerd.io \
        --include docker-buildx-plugin \
        --include docker-compose-plugin
}

# Docker CE for Debian/Ubuntu (and Ubuntu derivatives, which take the Ubuntu
# repo and codename): pinned keyring (D79) and a signed-by source.
_docker-repo-deb() {
    local elevation_cmd family codename id id_like
    elevation_cmd="$(get-elevation-command)" || return 1
    id="$(_containers_os_release_field ID)"
    id_like="$(_containers_os_release_field ID_LIKE)"
    case "${id} ${id_like}" in
        *ubuntu*) family="ubuntu"; codename="$(_containers_os_release_field UBUNTU_CODENAME)" ;;
        *)        family="debian"; codename="" ;;
    esac
    [[ -n "${codename}" ]] || codename="$(_containers_os_release_field VERSION_CODENAME)"
    [[ -n "${codename}" ]] || { log_error "docker: could not read the release codename from os-release"; return 1; }

    _wb_apt_keyring_pinned "https://download.docker.com/linux/${family}/gpg" \
        /etc/apt/keyrings/docker.gpg "${_DOCKER_DEB_KEY_FPR}" || return 1
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${family} ${codename} stable" \
        | ${elevation_cmd} tee /etc/apt/sources.list.d/docker.list >/dev/null
}

# First unused id range for /etc/subuid or /etc/subgid, as first-last.
_docker-next-subid-range() {
    local file="$1" start
    start="$(awk -F: 'BEGIN { next_free = 100000 } { end = $2 + $3; if (end > next_free) next_free = end } END { print next_free }' \
        "${file}" 2>/dev/null)"
    [[ -n "${start}" ]] || start=100000
    printf '%s-%s' "${start}" "$((start + 65535))"
}

# Rootless Docker maps container users onto a range in /etc/subuid and
# /etc/subgid. Most distros create it with the account; add it when missing.
_docker-ensure-subids() {
    local user="$1" elevation_cmd
    # _CONTAINERS_SUBUID_FILE and _CONTAINERS_SUBGID_FILE override the paths, for tests.
    local subuid_file="${_CONTAINERS_SUBUID_FILE:-/etc/subuid}"
    local subgid_file="${_CONTAINERS_SUBGID_FILE:-/etc/subgid}"
    if grep -q "^${user}:" "${subuid_file}" 2>/dev/null && grep -q "^${user}:" "${subgid_file}" 2>/dev/null; then
        return 0
    fi
    elevation_cmd="$(get-elevation-command)" || return 1
    log_info "docker: adding subordinate uid/gid ranges for ${user}"
    ${elevation_cmd} usermod \
        --add-subuids "$(_docker-next-subid-range "${subuid_file}")" \
        --add-subgids "$(_docker-next-subid-range "${subgid_file}")" \
        "${user}"
}

# The Docker CE packages start a system-wide daemon. Rootless only wants the
# per-user one, so the system units are disabled. Called only after a first
# install, never to an existing Docker.
_docker-disable-system-daemon() {
    local elevation_cmd
    elevation_cmd="$(get-elevation-command)" || return 1
    ${elevation_cmd} systemctl disable --now docker.service docker.socket 2>/dev/null
    ${elevation_cmd} rm -f /var/run/docker.sock
    return 0
}

_docker-rootless-setup() {
    local user elevation_cmd
    user="$(id -un)"
    elevation_cmd="$(get-elevation-command)" || return 1

    if [[ "$(id -u)" == "0" ]]; then
        log_error "docker: rootless Docker is set up for a normal user, not root. Run wb as your own user."
        return 1
    fi
    if ! command -v dockerd-rootless-setuptool.sh &>/dev/null; then
        log_error "docker: dockerd-rootless-setuptool.sh not found after install (docker-ce-rootless-extras on Fedora/Debian, rootlesskit on Arch)"
        return 1
    fi
    if ! systemctl --user show-environment &>/dev/null; then
        log_warn "docker: no systemd user session here (a container, WSL2 without systemd, or an ssh session without one). Docker is installed; finish later, from a login session, with: dockerd-rootless-setuptool.sh install"
        return 0
    fi

    _docker-ensure-subids "${user}" || return 1
    dockerd-rootless-setuptool.sh install \
        || { log_error "docker: dockerd-rootless-setuptool.sh install failed"; return 1; }
    systemctl --user enable --now docker.service \
        || { log_error "docker: could not enable the per-user docker.service"; return 1; }
    # Keeps the user's daemon running after logout and starts it at boot.
    ${elevation_cmd} loginctl enable-linger "${user}" \
        || log_warn "docker: could not enable linger for ${user} — the daemon will stop when you log out"
    if docker context inspect rootless &>/dev/null; then
        docker context use rootless >/dev/null
    fi
    log_info "docker: rootless daemon running as ${user}; docker CLI context 'rootless' selected"
}

_docker-install-linux() {
    local first_install=true
    if ! _containers_distro_supported; then
        log_error "docker: unsupported distro '${WORKBENCH_DISTRO}' (supported: Fedora/RHEL, Debian/Ubuntu, Arch)"
        return 1
    fi
    _containers_real_docker && first_install=false

    log_info "Installing Docker (rootless)..."
    _docker-clear-podman-shim || return 1

    case "${WORKBENCH_DISTRO}" in
        rhel)
            _docker-repo-rpm || return 1
            _containers_pkg_install docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras \
                shadow-utils || { log_error "docker: package install failed"; return 1; }
            _containers_pkg_install_optional "docker rootless storage" fuse-overlayfs
            ;;
        debian)
            _docker-repo-deb || return 1
            _containers_pkg_refresh || return 1
            _containers_pkg_install docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras \
                uidmap dbus-user-session || { log_error "docker: package install failed"; return 1; }
            ;;
        arch)
            _containers_pkg_install docker docker-compose docker-buildx \
                || { log_error "docker: package install failed"; return 1; }
            _containers_pkg_install rootlesskit slirp4netns fuse-overlayfs \
                || { log_error "docker: could not install the rootless prerequisites (rootlesskit slirp4netns fuse-overlayfs)"; return 1; }
            ;;
    esac

    if [[ "${first_install}" == "true" ]]; then
        _docker-disable-system-daemon
        _docker-rootless-setup
    else
        log_info "docker: already installed — packages updated, existing daemon setup left alone"
    fi
}

_docker-install-mac() {
    command -v brew &>/dev/null || { log_error "brew is required on macOS"; return 1; }
    if brew list --cask docker &>/dev/null; then
        brew upgrade --cask docker
    else
        brew install --cask docker || return 1
    fi
    log_info "docker: open Docker Desktop once to finish setup and start the engine"
}

install-docker() {
    case "${WORKBENCH_OS}" in
        Linux) _docker-install-linux ;;
        Mac)   _docker-install-mac ;;
        *)     log_error "Unsupported OS for docker install"; return 1 ;;
    esac
}

installed-docker() {
    _containers_real_docker
}
