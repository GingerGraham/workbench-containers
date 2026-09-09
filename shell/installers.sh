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
    local helm_version="$1"
    local helm_dir="${HOME}/.local/bin/k8s/helm-${helm_version}"
    mkdir -p "${helm_dir}"
    cd "${helm_dir}" || return 1
    command -v openssl &>/dev/null || { VERIFY_CHECKSUM=false; export VERIFY_CHECKSUM; }
    log_info "Installing helm ${helm_version}..."
    curl -fsSL "https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3" -o get_helm.sh
    [[ -f get_helm.sh ]] || { log_error "Failed to download helm install script"; cd - || true; return 1; }
    chmod 700 get_helm.sh
    ./get_helm.sh
    unset VERIFY_CHECKSUM
    rm -f get_helm.sh
    cd - || true
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
    helm_version="$(curl -s https://api.github.com/repos/helm/helm/releases/latest \
        | grep '"tag_name":' | sed -E 's/.+"v([^"]+)".+/\1/')"
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
