#!/usr/bin/env bash
# shell/installers.sh — workbench-containers
# install-helm and its per-distro helpers. Ported from
# workbench-precursor's lazy/installers-iac.sh (the Helm slice — grouped
# here rather than workbench-iac since Helm operates specifically on
# Kubernetes clusters, per the module map §3). No installers exist for
# Docker/Podman/kubectl in the precursor repo (assumed pre-installed or
# package-managed) — set-kubectl in shell/kubernetes.sh handles kubectl's
# own version management instead.
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
