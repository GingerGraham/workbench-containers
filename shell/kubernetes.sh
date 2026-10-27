#!/usr/bin/env bash
# shell/kubernetes.sh — workbench-containers
# Kubernetes tool configuration — aliases and kubectl version management.
# Registered at tier: tools (workbench.yml), sourced unconditionally.
# Ported from workbench-precursor's tools/kubernetes.sh.

# ── aliases ───────────────────────────────────────────────────────────────────
_wb_declare_availability kubectl k kube-version
alias k="kubectl"
alias kube-version="kubectl version --client --short 2>/dev/null \
    || kubectl version --client | awk '/Client Version:/{print \$NF}' | sed 's/^v//'"

# ── functions ─────────────────────────────────────────────────────────────────
set-kubectl() {
    local KUBECTL_VERSION="" USE_LATEST="" OPTIND=1 opt

    while getopts ":hlsv:" opt; do
        case ${opt} in
            h) echo "Usage: set-kubectl [-v version|-l]"; return 0 ;;
            l|s) USE_LATEST=true ;;
            v)   KUBECTL_VERSION="${OPTARG}" ;;
            \?)  log_error "Invalid option: -${OPTARG}"; return 1 ;;
        esac
    done

    if [[ "${USE_LATEST}" == "true" ]]; then
        log_info "Fetching latest stable kubectl version..."
        KUBECTL_VERSION="$(curl -fsS https://dl.k8s.io/release/stable.txt)" \
            || { log_error "set-kubectl: could not fetch the latest stable version"; return 1; }
        KUBECTL_VERSION="${KUBECTL_VERSION#v}"
        log_info "Latest kubectl: ${KUBECTL_VERSION}"
    fi

    [[ -z "${KUBECTL_VERSION}" ]] && KUBECTL_VERSION="${1:-}"

    if [[ ! "${KUBECTL_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        if [[ "${KUBECTL_VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]; then
            KUBECTL_VERSION="${KUBECTL_VERSION}.0"
        else
            log_error "Invalid kubectl version: '${KUBECTL_VERSION}'"
            return 1
        fi
    fi

    if command -v kubectl &>/dev/null; then
        local current
        current="$(kubectl version --client --short 2>/dev/null \
            || kubectl version --client | awk '/Client Version:/{print $NF}' | sed 's/^v//')"
        if [[ "${current}" == "${KUBECTL_VERSION}" ]]; then
            log_info "kubectl ${KUBECTL_VERSION} already active"; return 0
        fi
    fi

    # Go-style arch naming (contracts/core-api.md's normalization snippet) —
    # the precursor hardcoded amd64 here, silently producing a non-executable
    # binary on arm64. Fixed using WORKBENCH_ARCH (Core API platform fact).
    local kc_arch
    case "${WORKBENCH_ARCH}" in
        x86_64)        kc_arch="amd64" ;;
        aarch64|arm64) kc_arch="arm64" ;;
        *) log_error "set-kubectl: unsupported architecture ${WORKBENCH_ARCH}"; return 1 ;;
    esac

    local kubectl_dir="${HOME}/.local/bin/k8s/kubectl-${KUBECTL_VERSION}"
    mkdir -p "${kubectl_dir}"

    local kubectl_url
    case "${WORKBENCH_OS}" in
        Mac)   kubectl_url="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/darwin/${kc_arch}/kubectl" ;;
        Linux) kubectl_url="https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/${kc_arch}/kubectl" ;;
        *)     log_error "Unsupported OS"; return 1 ;;
    esac

    if [[ ! -f "${kubectl_dir}/kubectl" ]]; then
        log_info "Downloading kubectl ${KUBECTL_VERSION}..."
        # Verified against dl.k8s.io's published .sha256; nothing is written
        # to kubectl_dir unless it matches (security review M3).
        if ! _wb_fetch_verified "${kubectl_url}" "${kubectl_dir}/kubectl" "hashfile:${kubectl_url}.sha256"; then
            log_error "kubectl download or verification failed"
            return 1
        fi
        chmod +x "${kubectl_dir}/kubectl"
    fi

    if [[ ! -x "${kubectl_dir}/kubectl" ]]; then
        log_error "kubectl download failed"; return 1
    fi

    # A prior failed download may have left an HTML error page in place of
    # the binary — the -x check above won't catch that, so confirm it runs.
    if ! "${kubectl_dir}/kubectl" version --client &>/dev/null; then
        log_error "kubectl ${KUBECTL_VERSION} failed to run after download — removing it, please re-run"
        rm -f "${kubectl_dir}/kubectl"
        return 1
    fi

    # Point ~/.local/bin/kubectl (on PATH via workbench-core's loader) at
    # this version. Only that path is replaced: a kubectl elsewhere on PATH
    # belongs to a package manager (Homebrew's symlink, a distro package)
    # and is left alone, never removed or renamed.
    local kubectl_link="${HOME}/.local/bin/kubectl" current_path
    if [[ -e "${kubectl_link}" && ! -L "${kubectl_link}" ]]; then
        mv "${kubectl_link}" "${kubectl_link}.old" \
            || { log_error "set-kubectl: could not move ${kubectl_link} aside"; return 1; }
    fi
    ln -sfn "${kubectl_dir}/kubectl" "${kubectl_link}" \
        || { log_error "set-kubectl: could not link ${kubectl_link}"; return 1; }
    hash -r 2>/dev/null

    current_path="$(command -v kubectl 2>/dev/null)"
    if [[ "${current_path}" != "${kubectl_link}" ]]; then
        log_warn "set-kubectl: kubectl ${KUBECTL_VERSION} is at ${kubectl_link}, but ${current_path:-nothing} comes first on PATH"
    fi
    log_info "kubectl ${KUBECTL_VERSION} active"
}
