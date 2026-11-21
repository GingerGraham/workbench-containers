#!/usr/bin/env bash
# tests/check-installers.sh — workbench-containers
# install-docker, install-podman, installed-docker and installed-podman in
# shell/installers.sh. Plain bash, numbered OK:/FAIL: checks, no framework.
# No network, no root and no real package manager: every external tool is a
# fake on a PATH this script builds, each one appending what it was called
# with to a log the checks read. workbench-core's Core API (elevation,
# prompts, the D79 pinned-key helpers, logging) is stubbed the same way.
#
#   - podman: package set per distro (podman, toolbox, podman-compose),
#     toolbox/compose failures only warn, brew on macOS;
#   - podman-docker is offered only with a terminal, only when no docker
#     binary exists, and not at all when one does;
#   - docker on Fedora/RHEL, Debian/Ubuntu and Arch: the vendor repo with
#     the pinned key, the package set, the system daemon turned off, the
#     rootless setup, linger and the rootless CLI context;
#   - docker refuses an existing podman-docker unless it is removed first;
#   - docker already installed: packages updated, daemon setup left alone;
#   - no systemd user session, running as root, unsupported distro/OS;
#   - installed-docker tells the real Docker CLI from the podman-docker shim.
# shellcheck disable=SC2016  # the fakes are written from single-quoted scripts on purpose
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)" || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'rm -rf "${WORK}"' EXIT

# Host tools the installers call, linked into one directory so PATH can
# leave out everything else (the real host may have docker or dnf). Nothing
# that writes or deletes outside a scenario's own directory is linked: rm
# and tee, which the installers run through elevation on system paths, are
# fakes below.
HOSTBIN="${WORK}/hostbin"
mkdir -p "${HOSTBIN}"
for _t in cp cat cut grep head sed awk tr basename dirname; do
    _p="$(command -v "${_t}")" || { echo "FAIL: host tool ${_t} not found"; exit 1; }
    ln -s "${_p}" "${HOSTBIN}/${_t}"
done

# Fakes. Every one appends "<name> <args>" to $LOG. A fake exits 1 when its
# arguments match the extended regex in $FAIL_ON.
FAKES="${WORK}/fakes"
mkdir -p "${FAKES}"
_fake() {
    # _fake <name> [<sh to run after logging and before the default exit 0>]
    {
        printf '#!/bin/sh\n'
        printf 'echo "%s $*" >> "$LOG"\n' "$1"
        printf '[ -n "$FAIL_ON" ] && echo "$*" | grep -Eq -e "$FAIL_ON" && exit 1\n'
        printf '%s\n' "${2:-}"
        printf 'exit 0\n'
    } > "${FAKES}/$1"
    chmod +x "${FAKES}/$1"
}
printf '#!/bin/sh\nexec "$@"\n' > "${FAKES}/elev"; chmod +x "${FAKES}/elev"
# A package install of Docker puts a docker binary on the scenario's PATH,
# so the "no docker before, docker after" order is real.
_pm_install_hook='case " $* " in *" docker-ce "*|*" docker "*) cp "$DOCKER_TEMPLATE" "$SCN_BIN/docker" ;; esac
case " $* " in *" podman "*) cp "$FAKE_PODMAN" "$SCN_BIN/podman" ;; esac'
_fake dnf "${_pm_install_hook}"
_fake yum "${_pm_install_hook}"
_fake apt-get "${_pm_install_hook}"
_fake pacman '[ "$1" = "-Q" ] && { grep -qx "$2" "$INSTALLED"; exit $?; }
'"${_pm_install_hook}"
_fake rpm '[ "$1" = "-q" ] && { grep -qx "$2" "$INSTALLED"; exit $?; }'
_fake dpkg '[ "$1" = "--print-architecture" ] && { echo amd64; exit 0; }
[ "$1" = "-s" ] && { grep -qx "$2" "$INSTALLED" && echo "Status: install ok installed"; grep -qx "$2" "$INSTALLED"; exit $?; }'
_fake brew '[ "$1" = "list" ] && { for a in "$@"; do last="$a"; done; grep -qx "$last" "$INSTALLED"; exit $?; }'
_fake systemctl '[ "$1" = "--user" ] && [ "$2" = "show-environment" ] && exit "${SYSTEMD_USER_RC:-0}"'
_fake loginctl
_fake usermod
_fake rm
_fake podman
_fake dockerd-rootless-setuptool.sh
_fake id '[ "$1" = "-un" ] && { echo tester; exit 0; }
[ "$1" = "-u" ] && { echo "${FAKE_UID:-1000}"; exit 0; }'
# tee: log the target, then what was piped in (the apt source line).
printf '#!/bin/sh\necho "tee $*" >> "$LOG"\ncat >> "$LOG"\n' > "${FAKES}/tee"; chmod +x "${FAKES}/tee"
# docker: a template, copied into a scenario's bin directory when the
# scenario starts with docker or when a fake package manager installs it.
DOCKER_TEMPLATE="${WORK}/docker-template"
{
    printf '#!/bin/sh\necho "docker $*" >> "$LOG"\n'
    printf '[ "$1" = "--version" ] && { echo "$DOCKER_VERSION_OUT"; exit 0; }\nexit 0\n'
} > "${DOCKER_TEMPLATE}"
chmod +x "${DOCKER_TEMPLATE}"

# os-release fixtures
OSREL="${WORK}/osrel"
mkdir -p "${OSREL}"
printf 'ID=fedora\nVERSION_ID=41\n' > "${OSREL}/fedora"
printf 'ID="rhel"\nID_LIKE="fedora"\nVERSION_ID="9.4"\n' > "${OSREL}/rhel"
printf 'ID="rocky"\nID_LIKE="rhel centos fedora"\nVERSION_ID="9.4"\n' > "${OSREL}/rocky"
printf 'ID=ubuntu\nID_LIKE=debian\nVERSION_CODENAME=noble\nUBUNTU_CODENAME=noble\n' > "${OSREL}/ubuntu"
printf 'ID=linuxmint\nID_LIKE="ubuntu debian"\nVERSION_CODENAME=wilma\nUBUNTU_CODENAME=noble\n' > "${OSREL}/mint"
printf 'ID=debian\nVERSION_CODENAME=bookworm\n' > "${OSREL}/debian"
printf 'ID=arch\n' > "${OSREL}/arch"

# The scenario body, run once per scenario. Prints PASS:<text> / BAD:<text>.
cat > "${WORK}/scenario.sh" <<'EOF'
R="${REPO_ROOT}"
OUT="${HOME}/out.log"
: > "${LOG}"; : > "${OUT}"
log_info()  { echo "INFO: $*"  >> "${OUT}"; }
log_warn()  { echo "WARN: $*"  >> "${OUT}"; }
log_error() { echo "ERROR: $*" >> "${OUT}"; }
get-elevation-command() { echo elev; }
_wb_have_tty() { [ "${TTY:-0}" = "1" ]; }
_read_prompt() { echo "PROMPT: $1" >> "${OUT}"; eval "$2=\${ANSWER:-}"; }
_wb_dnf_vendor_repo() { echo "_wb_dnf_vendor_repo $*" >> "${LOG}"; }
_wb_apt_keyring_pinned() { echo "_wb_apt_keyring_pinned $*" >> "${LOG}"; }
. "${R}/shell/installers.sh"

logged()    { grep -q -- "$1" "${LOG}"; }
logged_f()  { grep -qF -- "$1" "${LOG}"; }
# shim_installed: podman-docker was installed (not merely looked up with rpm -q)
shim_installed() { grep -Eq "^(dnf|apt-get|pacman -S|brew) .*install.* podman-docker$|^pacman -S .* podman-docker$" "${LOG}"; }
# changed: the scenario made a system change (an install, a removal, a
# daemon or account change), as opposed to only asking questions.
changed()   { grep -Eq "^(dnf|yum|apt-get|pacman -[SR]|brew (install|upgrade)|usermod|systemctl (disable|--user enable)|loginctl|dockerd-rootless|_wb_)" "${LOG}"; }
out_has()   { grep -q -- "$1" "${OUT}"; }
# line_before <earlier> <later>: both logged, earlier first
line_before() {
    local a b
    a="$(grep -n -- "$1" "${LOG}" | head -1 | cut -d: -f1)"
    b="$(grep -n -- "$2" "${LOG}" | head -1 | cut -d: -f1)"
    [ -n "${a}" ] && [ -n "${b}" ] && [ "${a}" -lt "${b}" ]
}
check() { if eval "$2"; then echo "PASS:$1"; else echo "BAD:$1"; fi; }

case "${SCENARIO}" in
    podman-fedora)
        install-podman; rc=$?
        check "podman/fedora: succeeds" '[ ${rc} -eq 0 ]'
        check "podman/fedora: dnf installs podman" 'logged "^dnf install -y podman$"'
        check "podman/fedora: toolbox is installed" 'logged "^dnf install -y toolbox$"'
        check "podman/fedora: podman-compose is installed" 'logged "^dnf install -y podman-compose$"'
        check "podman/fedora: no apt-get refresh" '! logged "^apt-get"'
        check "podman/fedora: no terminal, so no podman-docker and no prompt" '! shim_installed && ! out_has PROMPT'
        ;;
    podman-debian)
        install-podman; rc=$?
        check "podman/debian: succeeds" '[ ${rc} -eq 0 ]'
        check "podman/debian: index refreshed before the install" 'line_before "^apt-get update" "^apt-get install -y podman$"'
        check "podman/debian: the toolbox package is podman-toolbox" 'logged "^apt-get install -y podman-toolbox$"'
        check "podman/debian: podman-compose is installed" 'logged "^apt-get install -y podman-compose$"'
        ;;
    podman-arch)
        install-podman; rc=$?
        check "podman/arch: succeeds" '[ ${rc} -eq 0 ]'
        check "podman/arch: pacman installs podman" 'logged "^pacman -S --needed --noconfirm podman$"'
        check "podman/arch: toolbox is installed" 'logged "^pacman -S --needed --noconfirm toolbox$"'
        check "podman/arch: podman-compose is installed" 'logged "^pacman -S --needed --noconfirm podman-compose$"'
        ;;
    podman-optional-fails)
        install-podman; rc=$?
        check "podman, toolbox and compose unavailable: still succeeds" '[ ${rc} -eq 0 ]'
        check "podman, toolbox and compose unavailable: toolbox warned about" 'out_has "WARN: podman toolbox: could not install toolbox"'
        check "podman, toolbox and compose unavailable: compose warned about" 'out_has "WARN: podman compose provider: could not install podman-compose"'
        ;;
    podman-required-fails)
        install-podman; rc=$?
        check "podman package install fails: install-podman fails" '[ ${rc} -ne 0 ]'
        check "podman package install fails: nothing else is tried" '! logged "toolbox"'
        ;;
    podman-shim-yes)
        install-podman; rc=$?
        check "podman-docker offered with a terminal and no docker: asked once" '[ "$(grep -c "^PROMPT:" "${OUT}")" = "1" ]'
        check "podman-docker, answer y: installed" 'shim_installed'
        ;;
    podman-shim-no)
        install-podman; rc=$?
        check "podman-docker, answer n: asked" 'out_has "PROMPT: podman: no docker command found"'
        check "podman-docker, answer n: not installed" '! shim_installed'
        check "podman-docker, answer n: succeeds and says how to add it later" '[ ${rc} -eq 0 ] && out_has "podman-docker not installed"'
        ;;
    podman-shim-docker-present)
        install-podman; rc=$?
        check "docker binary already there: no podman-docker prompt" '! out_has PROMPT'
        check "docker binary already there: podman-docker not installed" '! shim_installed'
        ;;
    podman-shim-already)
        install-podman; rc=$?
        check "podman-docker already installed: no prompt" '! out_has PROMPT'
        ;;
    podman-mac)
        install-podman; rc=$?
        check "podman/mac: succeeds" '[ ${rc} -eq 0 ]'
        check "podman/mac: brew installs podman and podman-compose" 'logged "^brew install podman$" && logged "^brew install podman-compose$"'
        check "podman/mac: no toolbox" '! logged "toolbox"'
        check "podman/mac: tells you to create the machine" 'out_has "podman machine init"'
        ;;
    podman-suse)
        install-podman; rc=$?
        check "podman on an unsupported distro: fails with a message" '[ ${rc} -ne 0 ] && out_has "unsupported distro"'
        check "podman on an unsupported distro: touches no package manager" '! changed'
        ;;
    docker-fedora)
        install-docker; rc=$?
        check "docker/fedora: succeeds" '[ ${rc} -eq 0 ]'
        check "docker/fedora: repo uses the fedora URL" 'logged_f "_wb_dnf_vendor_repo --id docker-ce-stable --name Docker CE Stable --baseurl https://download.docker.com/linux/fedora/\$releasever/\$basearch/stable --key-url https://download.docker.com/linux/fedora/gpg"'
        check "docker/fedora: repo pins the rpm signing key" 'logged -- "--fingerprint 060A61C51B558A7F742B77AAC52FEB6B621E9F35"'
        check "docker/fedora: repo allows only Docker packages" 'logged -- "--include docker-ce --include docker-ce-cli --include docker-ce-rootless-extras --include containerd.io --include docker-buildx-plugin --include docker-compose-plugin"'
        check "docker/fedora: packages include rootless extras and the compose plugin" 'logged "^dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras shadow-utils$"'
        check "docker/fedora: repo is written before the install" 'line_before "^_wb_dnf_vendor_repo" "^dnf install -y docker-ce"'
        check "docker/fedora: system daemon and socket turned off" 'logged "^systemctl disable --now docker.service docker.socket$"'
        check "docker/fedora: system daemon is turned off before the rootless setup" 'line_before "^systemctl disable --now" "^dockerd-rootless-setuptool.sh install$"'
        check "docker/fedora: rootless setup runs" 'logged "^dockerd-rootless-setuptool.sh install$"'
        check "docker/fedora: per-user service enabled and started" 'logged "^systemctl --user enable --now docker.service$"'
        check "docker/fedora: linger enabled for the user" 'logged "^loginctl enable-linger tester$"'
        check "docker/fedora: rootless CLI context selected" 'logged "^docker context use rootless$"'
        check "docker/fedora: no docker group" '! logged "usermod -aG" && ! logged "docker group"'
        check "docker/fedora: subuid ranges exist already, so usermod is not run" '! logged "^usermod"'
        ;;
    docker-rocky)
        install-docker
        check "docker/rocky: uses Docker's centos repo" 'logged -- "--baseurl https://download.docker.com/linux/centos/"'
        ;;
    docker-rhel)
        install-docker
        check "docker/rhel: uses Docker's rhel repo" 'logged -- "--baseurl https://download.docker.com/linux/rhel/"'
        ;;
    docker-ubuntu)
        install-docker; rc=$?
        check "docker/ubuntu: succeeds" '[ ${rc} -eq 0 ]'
        check "docker/ubuntu: pinned keyring from the ubuntu URL" 'logged "^_wb_apt_keyring_pinned https://download.docker.com/linux/ubuntu/gpg /etc/apt/keyrings/docker.gpg 9DC858229FC7DD38854AE2D88D81803C0EBFCD88$"'
        check "docker/ubuntu: apt source written with signed-by and the release codename" 'logged_f "tee /etc/apt/sources.list.d/docker.list" && logged_f "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu noble stable"'
        check "docker/ubuntu: index refreshed after the repo is added, before the install" 'line_before "^apt-get update" "^apt-get install -y docker-ce"'
        check "docker/ubuntu: packages include rootless extras, uidmap and the user session bus" 'logged "^apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras uidmap dbus-user-session$"'
        check "docker/ubuntu: rootless setup runs" 'logged "^dockerd-rootless-setuptool.sh install$"'
        ;;
    docker-mint)
        install-docker
        check "docker/linuxmint: takes the Ubuntu repo and the Ubuntu codename" 'logged "^_wb_apt_keyring_pinned https://download.docker.com/linux/ubuntu/gpg" && logged_f "linux/ubuntu noble stable"'
        ;;
    docker-debian)
        install-docker
        check "docker/debian: source uses the debian repo and codename" 'logged_f "linux/debian bookworm stable"'
        check "docker/debian: pinned keyring from the debian URL" 'logged "^_wb_apt_keyring_pinned https://download.docker.com/linux/debian/gpg /etc/apt/keyrings/docker.gpg 9DC858229FC7DD38854AE2D88D81803C0EBFCD88$"'
        ;;
    docker-arch)
        install-docker; rc=$?
        check "docker/arch: succeeds" '[ ${rc} -eq 0 ]'
        check "docker/arch: no vendor repo" '! logged "_wb_dnf_vendor_repo" && ! logged "_wb_apt_keyring_pinned"'
        check "docker/arch: docker, compose and buildx from the official repos" 'logged "^pacman -S --needed --noconfirm docker docker-compose docker-buildx$"'
        check "docker/arch: rootless prerequisites installed" 'logged "^pacman -S --needed --noconfirm rootlesskit slirp4netns fuse-overlayfs$"'
        check "docker/arch: rootless setup runs" 'logged "^dockerd-rootless-setuptool.sh install$"'
        ;;
    docker-subids)
        install-docker; rc=$?
        check "docker, no subuid entry: succeeds" '[ ${rc} -eq 0 ]'
        check "docker, no subuid entry: ranges start after the last one in use" 'logged "^usermod --add-subuids 265536-331071 --add-subgids 165536-231071 tester$"'
        check "docker, no subuid entry: usermod runs before the rootless setup" 'line_before "^usermod" "^dockerd-rootless-setuptool.sh install$"'
        ;;
    docker-shim-removed)
        install-docker; rc=$?
        check "docker with podman-docker, answer y: asked" 'out_has "PROMPT: docker: podman-docker is installed and conflicts"'
        check "docker with podman-docker, answer y: shim removed before the Docker install" 'line_before "^dnf remove -y podman-docker$" "^dnf install -y docker-ce"'
        check "docker with podman-docker, answer y: succeeds" '[ ${rc} -eq 0 ]'
        ;;
    docker-shim-refused)
        install-docker; rc=$?
        check "docker with podman-docker, answer n: fails" '[ ${rc} -ne 0 ]'
        check "docker with podman-docker, answer n: nothing installed or removed" '! changed'
        check "docker with podman-docker, answer n: says why" 'out_has "not installing while podman-docker is present"'
        ;;
    docker-shim-no-tty)
        install-docker; rc=$?
        check "docker with podman-docker and no terminal: fails without asking" '[ ${rc} -ne 0 ] && ! out_has PROMPT && ! changed'
        ;;
    docker-existing)
        install-docker; rc=$?
        check "docker already installed: succeeds" '[ ${rc} -eq 0 ]'
        check "docker already installed: packages are updated" 'logged "^dnf install -y docker-ce"'
        check "docker already installed: system daemon not touched" '! logged "^systemctl"'
        check "docker already installed: no rootless setup, no context switch" '! logged "dockerd-rootless-setuptool" && ! logged "context use" && ! logged "^loginctl"'
        ;;
    docker-no-systemd)
        install-docker; rc=$?
        check "docker without a systemd user session: succeeds" '[ ${rc} -eq 0 ]'
        check "docker without a systemd user session: warns with the command to finish" 'out_has "WARN: docker: no systemd user session" && out_has "dockerd-rootless-setuptool.sh install"'
        check "docker without a systemd user session: setup tool not run" '! logged "^dockerd-rootless-setuptool.sh"'
        ;;
    docker-root)
        install-docker; rc=$?
        check "docker as root: fails with a message" '[ ${rc} -ne 0 ] && out_has "not root"'
        check "docker as root: setup tool not run" '! logged "^dockerd-rootless-setuptool.sh"'
        ;;
    docker-setup-fails)
        install-docker; rc=$?
        check "docker rootless setup failing: install-docker fails" '[ ${rc} -ne 0 ] && out_has "setuptool.sh install failed"'
        ;;
    docker-pkg-fails)
        install-docker; rc=$?
        check "docker package install failing: fails before any daemon change" '[ ${rc} -ne 0 ] && ! logged "^systemctl" && ! logged "dockerd-rootless-setuptool"'
        ;;
    docker-mac)
        install-docker; rc=$?
        check "docker/mac: succeeds" '[ ${rc} -eq 0 ]'
        check "docker/mac: Docker Desktop through the brew cask" 'logged "^brew install --cask docker$"'
        check "docker/mac: no rootless setup" '! logged "dockerd-rootless-setuptool"'
        ;;
    docker-mac-upgrade)
        install-docker
        check "docker/mac, cask present: upgraded" 'logged "^brew upgrade --cask docker$"'
        ;;
    docker-suse)
        install-docker; rc=$?
        check "docker on an unsupported distro: fails with a message" '[ ${rc} -ne 0 ] && out_has "unsupported distro"'
        check "docker on an unsupported distro: touches no package manager" '! changed'
        ;;
    docker-os)
        install-docker; rc=$?
        check "docker on an unsupported OS: fails" '[ ${rc} -ne 0 ] && out_has "Unsupported OS"'
        install-podman; rc=$?
        check "podman on an unsupported OS: fails" '[ ${rc} -ne 0 ] && out_has "Unsupported OS"'
        ;;
    installed-real)
        check "installed-docker: true for the real Docker CLI" 'installed-docker'
        ;;
    installed-shim)
        check "installed-docker: false for the podman-docker shim" '! installed-docker'
        ;;
    installed-none)
        check "installed-docker: false with no docker binary" '! installed-docker'
        check "installed-podman: false with no podman binary" '! installed-podman'
        ;;
    installed-podman)
        check "installed-podman: true with a podman binary" 'installed-podman'
        ;;
esac
EOF

# run_scenario <name> [VAR=value ...]
# Defaults: Linux, Fedora, no terminal, no docker or podman binary, a systemd
# user session, nothing installed, a subuid/subgid range for "tester".
# HAVE_DOCKER=1 starts the scenario with a docker binary; HAVE_PODMAN=1 with
# podman. INSTALLED_PKGS is a space-separated package list for rpm/dpkg/
# pacman/brew queries. SUBUID_CONTENT/SUBGID_CONTENT replace the id ranges.
run_scenario() {
    local _name="$1"; shift
    local _home="${WORK}/home-${_name}" _bin="${WORK}/home-${_name}/bin" _out _line _f _env
    mkdir -p "${_bin}"
    for _f in "${FAKES}"/*; do ln -s "${_f}" "${_bin}/${_f##*/}"; done
    rm -f "${_bin}/podman"
    _env=" $* "
    case "${_env}" in *" HAVE_DOCKER=1 "*) cp "${DOCKER_TEMPLATE}" "${_bin}/docker" ;; esac
    case "${_env}" in *" HAVE_PODMAN=1 "*) ln -s "${FAKES}/podman" "${_bin}/podman" ;; esac
    : > "${_home}/installed"
    for _f in $(printf '%s\n' "$@" | sed -n 's/^INSTALLED_PKGS=//p'); do echo "${_f}" >> "${_home}/installed"; done
    printf '%s\n' "tester:100000:65536" > "${_home}/subuid"
    printf '%s\n' "tester:100000:65536" > "${_home}/subgid"
    printf '%s\n' "$@" | sed -n 's/^SUBUID_CONTENT=//p' | grep . > /dev/null \
        && printf '%b\n' "$(printf '%s\n' "$@" | sed -n 's/^SUBUID_CONTENT=//p')" > "${_home}/subuid"
    printf '%s\n' "$@" | sed -n 's/^SUBGID_CONTENT=//p' | grep . > /dev/null \
        && printf '%b\n' "$(printf '%s\n' "$@" | sed -n 's/^SUBGID_CONTENT=//p')" > "${_home}/subgid"
    _out="$(env -i HOME="${_home}" PATH="${_bin}:${HOSTBIN}" REPO_ROOT="${REPO_ROOT}" \
        SCENARIO="${_name}" LOG="${_home}/calls.log" INSTALLED="${_home}/installed" \
        SCN_BIN="${_bin}" DOCKER_TEMPLATE="${DOCKER_TEMPLATE}" FAKE_PODMAN="${FAKES}/podman" FAIL_ON="" \
        WORKBENCH_OS=Linux WORKBENCH_DISTRO=rhel WORKBENCH_ARCH=x86_64 \
        _CONTAINERS_OS_RELEASE="${OSREL}/fedora" \
        _CONTAINERS_SUBUID_FILE="${_home}/subuid" _CONTAINERS_SUBGID_FILE="${_home}/subgid" \
        DOCKER_VERSION_OUT="Docker version 28.0.0, build abc" \
        "$@" "${BASH}" "${WORK}/scenario.sh" 2>&1)"
    [[ -n "${_out}" ]] || { fail "${_name}: scenario printed nothing"; return; }
    while IFS= read -r _line; do
        case "${_line}" in
            PASS:*) ok "${_line#PASS:}" ;;
            BAD:*)  fail "${_line#BAD:}" ;;
            *)      fail "${_name}: unexpected output: ${_line}" ;;
        esac
    done <<< "${_out}"
}

DEBIAN=(WORKBENCH_DISTRO=debian)
ARCH=(WORKBENCH_DISTRO=arch)
MAC=(WORKBENCH_OS=Mac WORKBENCH_DISTRO=unknown)
SHIM=(DOCKER_VERSION_OUT=podman_version_5.0.0 HAVE_DOCKER=1)

# podman
run_scenario podman-fedora
run_scenario podman-debian        "${DEBIAN[@]}"
run_scenario podman-arch          "${ARCH[@]}"
run_scenario podman-optional-fails "FAIL_ON=toolbox|podman-compose"
run_scenario podman-required-fails "FAIL_ON=-y podman$"
run_scenario podman-shim-yes      TTY=1 ANSWER=y
run_scenario podman-shim-no       TTY=1 ANSWER=n
run_scenario podman-shim-docker-present TTY=1 ANSWER=y HAVE_DOCKER=1
run_scenario podman-shim-already  TTY=1 ANSWER=y INSTALLED_PKGS=podman-docker
run_scenario podman-mac           "${MAC[@]}"
run_scenario podman-suse          WORKBENCH_DISTRO=suse

# docker
run_scenario docker-fedora
run_scenario docker-rocky         _CONTAINERS_OS_RELEASE="${OSREL}/rocky"
run_scenario docker-rhel          _CONTAINERS_OS_RELEASE="${OSREL}/rhel"
run_scenario docker-ubuntu        "${DEBIAN[@]}" _CONTAINERS_OS_RELEASE="${OSREL}/ubuntu"
run_scenario docker-mint          "${DEBIAN[@]}" _CONTAINERS_OS_RELEASE="${OSREL}/mint"
run_scenario docker-debian        "${DEBIAN[@]}" _CONTAINERS_OS_RELEASE="${OSREL}/debian"
run_scenario docker-arch          "${ARCH[@]}" _CONTAINERS_OS_RELEASE="${OSREL}/arch"
run_scenario docker-subids        SUBUID_CONTENT='other:100000:65536\nthird:165536:100000' SUBGID_CONTENT='other:100000:65536'
run_scenario docker-shim-removed  TTY=1 ANSWER=y INSTALLED_PKGS=podman-docker "${SHIM[@]}"
run_scenario docker-shim-refused  TTY=1 ANSWER=n INSTALLED_PKGS=podman-docker "${SHIM[@]}"
run_scenario docker-shim-no-tty   INSTALLED_PKGS=podman-docker "${SHIM[@]}"
run_scenario docker-existing      HAVE_DOCKER=1
run_scenario docker-no-systemd    SYSTEMD_USER_RC=1
run_scenario docker-root          FAKE_UID=0
run_scenario docker-setup-fails   'FAIL_ON=^install$'
run_scenario docker-pkg-fails     FAIL_ON=docker-ce
run_scenario docker-mac           "${MAC[@]}"
run_scenario docker-mac-upgrade   "${MAC[@]}" INSTALLED_PKGS=docker
run_scenario docker-suse          WORKBENCH_DISTRO=suse
run_scenario docker-os            WORKBENCH_OS=Plan9

# installed-*
run_scenario installed-real       HAVE_DOCKER=1
run_scenario installed-shim       "${SHIM[@]}"
run_scenario installed-none
run_scenario installed-podman     HAVE_PODMAN=1

echo
echo "==============================="
echo "Total OK/FAIL checks: ${check_no}, failed: ${FAILED}"
echo "==============================="
[[ "${FAILED}" -eq 0 ]]
