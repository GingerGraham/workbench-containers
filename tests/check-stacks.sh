#!/usr/bin/env bash
# tests/check-stacks.sh — workbench-containers
# Behaviour of shell/stacks.sh (docs/decisions-log.md D129 in workbench-core),
# in bash and, when installed, zsh, since every register.shell file is also
# sourced into zsh. Plain bash, numbered OK:/FAIL: checks, no framework. No
# network and no workbench-core: the Core API helpers stacks.sh calls are
# stubbed, and every external tool is a fake on a PATH this script builds
# (the real host may have podman, docker, btrfs or KVM).
#
# The numbered cases are the ones in the brief, 1–18:
#   1 names              7 an existing name         13 stack-import --move
#   2 compose tool       8 failing config           14 stack-import <file>
#   3 root creation      9 stack-up                 15 stack-list
#   4 stack-new windows  10 stack-down              16 stack-rm
#   5 ports              11 stack-compose           17 template structure
#   6 KVM                12 stack-import <folder>   18 .env beats the shell
#
# and, for docs/decisions-log.md D132 in workbench-core, 20–33:
#   20 completion provider   25 stack-new menus/names  30 override files
#   21 registration          26 REQUIRES lists         31 stack-info
#   22 the one-stack rule    27 ACCEPT                 32 stack-edit
#   23 stack-rm, no name     28 DISK_VAR               33 stack-help
#   24 stack-compose         29 stack-import
# (34, the docs, is tests/check-stacks-docs.sh.)
#
# Each fake records "<name>|<$PWD>|<argv>" to a calls file. Control files in
# $CTL steer them: ps-out/ps-rc (what `podman ps` prints and returns),
# volumes, rootless, fstype (what `stat` reports), listening (ports `ss`
# reports), docker-version, config-rcs (one exit status per compose `config`
# call, first line first), config-volumes, user (what `id -un` prints).
#
# SC2015: '[[ cond ]] && ok || fail' is this suite's assertion idiom.
# SC2016: the fake tools' bodies are single-quoted on purpose; they expand
# when the fake runs, not when it is written.
# shellcheck disable=SC2015,SC2016
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)" || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'rm -rf "${WORK}"' EXIT

# Host tools the scenarios need, linked into one directory so PATH can leave
# out everything else (/usr/bin included).
HOSTBIN="${WORK}/hostbin"
mkdir -p "${HOSTBIN}"
for _t in mkdir ln rm mv chmod cat awk sed grep head tail dirname basename readlink \
    find sort cut tr du cp date printenv cksum touch wc sh; do
    # The real binary, not a wrapper some environments put first on PATH.
    _p=""
    for _d in /usr/bin /bin; do
        [[ -x "${_d}/${_t}" ]] && { _p="${_d}/${_t}"; break; }
    done
    [[ -n "${_p}" ]] || _p="$(command -v "${_t}")" || { echo "FAIL: host tool ${_t} not found"; exit 1; }
    ln -s "${_p}" "${HOSTBIN}/${_t}"
done

# _fake <dir> <name> <body> — an executable /bin/sh script.
_fake() {
    mkdir -p "$1"
    printf '#!/bin/sh\n%s\n' "$3" > "$1/$2"
    chmod +x "$1/$2"
}

RECORD='printf "%s|%s|%s\n" "$(basename "$0")" "$PWD" "$*" >> "${CALLS}"'

BIN_DEFAULT="${WORK}/bin-default"    # podman, podman-compose and the system fakes
BIN_BTRFS="${WORK}/bin-btrfs"
BIN_DC="${WORK}/bin-dc"              # docker-compose
BIN_DOCKER_REAL="${WORK}/bin-docker-real"
BIN_DOCKER_SHIM="${WORK}/bin-docker-shim"
BIN_PODMAN_ONLY="${WORK}/bin-podman-only"
BIN_EMPTY="${WORK}/bin-empty"
mkdir -p "${BIN_EMPTY}"
BIN_SLOWTR="${WORK}/bin-slowtr"
_fake "${BIN_SLOWTR}" tr 'cat >/dev/null; printf "abcdefghijklmnopqrstuvwxyz0123456789"'

# podman: ps and volume ls read control files; unshare really runs its
# command (the stack-rm --purge case checks the folder is gone).
PODMAN_BODY="${RECORD}
case \"\$1\" in
    ps)     [ -f \"\${CTL}/ps-out\" ] && cat \"\${CTL}/ps-out\"; exit \"\$(cat \"\${CTL}/ps-rc\" 2>/dev/null || echo 0)\" ;;
    volume) cat \"\${CTL}/volumes\" 2>/dev/null; exit 0 ;;
    info)   cat \"\${CTL}/rootless\" 2>/dev/null; exit 0 ;;
    unshare) shift; exec \"\$@\" ;;
esac
exit 0"
_fake "${BIN_DEFAULT}" podman "${PODMAN_BODY}"
_fake "${BIN_PODMAN_ONLY}" podman "${PODMAN_BODY}"

# podman-compose and docker-compose: record argv and $PWD and the three
# variables case 18 looks at; `config` takes its exit status from config-rcs.
COMPOSE_BODY="${RECORD}
for a in \"\$@\"; do printf '%s\\n' \"\$a\"; done > \"\${CTL}/argv\"
{ printf 'WINDOWS_VERSION=%s\n' \"\$(printenv WINDOWS_VERSION)\"
  printf 'HOME=%s\n' \"\$(printenv HOME)\"
  printf 'OTHER_VAR=%s\n' \"\$(printenv OTHER_VAR)\"; } > \"\${CTL}/envseen\"
case \" \$* \" in
    *\" config \"*)
        if [ -s \"\${CTL}/config-rcs\" ]; then
            rc=\"\$(head -n 1 \"\${CTL}/config-rcs\")\"
            sed 1d \"\${CTL}/config-rcs\" > \"\${CTL}/config-rcs.new\"
            mv \"\${CTL}/config-rcs.new\" \"\${CTL}/config-rcs\"
            [ \"\${rc}\" = 0 ] || exit \"\${rc}\"
        fi
        case \" \$* \" in *\" --volumes \"*|*\" --volumes\") cat \"\${CTL}/config-volumes\" 2>/dev/null ;; esac
        ;;
esac
exit 0"
_fake "${BIN_DEFAULT}" podman-compose "${COMPOSE_BODY}"
_fake "${BIN_DC}" docker-compose "${COMPOSE_BODY}"

# The system fakes.
_fake "${BIN_DEFAULT}" ss 'while IFS= read -r p; do printf "LISTEN 0 4096 0.0.0.0:%s 0.0.0.0:*\n" "$p"; done < "${CTL}/listening" 2>/dev/null; exit 0'
_fake "${BIN_DEFAULT}" stat 'cat "${CTL}/fstype"'
_fake "${BIN_DEFAULT}" chattr "${RECORD}"
_fake "${BIN_DEFAULT}" id 'cat "${CTL}/user"'
_fake "${BIN_BTRFS}" btrfs "${RECORD}"'
case "$1 $2" in "subvolume create") mkdir -p "$3" ;; esac
exit 0'
_fake "${BIN_DOCKER_REAL}" docker "${RECORD}"'
case "$1" in --version) echo "Docker version 27.0.0, build abc" ;; esac
exit 0'
_fake "${BIN_DOCKER_SHIM}" docker "${RECORD}"'
case "$1" in --version) echo "podman version 5.0.0" ;; esac
exit 0'

# The D132 fakes, on their own PATH entry: df (free space from df-kib and
# df-h), an editor (editor-action: append, the default, chmod644 or none;
# every call's arguments, one per line, then "--", in editor-args) and wb.
BIN_TOOLS="${WORK}/bin-tools"
_fake "${BIN_TOOLS}" df '[ -f "${CTL}/df-kib" ] || exit 1
printf "Filesystem 1024-blocks Used Available Capacity Mounted on\n"
case "$1" in
    -Ph) printf "fake 1 1 %s 1%% /\n" "$(cat "${CTL}/df-h")" ;;
    *)   printf "fake 1 1 %s 1%% /\n" "$(cat "${CTL}/df-kib")" ;;
esac'
_fake "${BIN_TOOLS}" fake-editor 'for a in "$@"; do printf "%s\n" "$a"; f="$a"; done >> "${CTL}/editor-args"
echo -- >> "${CTL}/editor-args"
echo x >> "${CTL}/editor-count"
case "$(cat "${CTL}/editor-action" 2>/dev/null)" in
    none) ;;
    chmod644) echo "# edited" >> "$f"; chmod 644 "$f" ;;
    *) echo "# edited" >> "$f" ;;
esac'
_fake "${BIN_TOOLS}" wb "${RECORD}"

# A docker compose plugin under DOCKER_CONFIG, the first place the plugin
# lookup in containers.sh checks.
_fake "${WORK}/dockercfg/cli-plugins" docker-compose 'exit 0'

# ── The scenario body, run once per shell and scenario. Prints PASS:<text> /
# BAD:<text>; anything else is a failure. ────────────────────────────────────
cat > "${WORK}/prelude.sh" <<'EOF'
R="${REPO_ROOT}"
log_info()  { printf '[INFO] %s\n' "$*" >&2; }
log_warn()  { printf '[WARN] %s\n' "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }

# Stand-ins for workbench-core's Core API.
_wb_declare_availability() { :; }
_wb_alias_availability() { :; }
workbench_alias_define() { :; }
# Records each call's arguments, a call per line, in COMPLETE_CALLS.
# NO_COMPLETE_STUB=1 leaves it undefined, as on a core older than 1.13.
COMPLETE_CALLS=""
if [ -z "${NO_COMPLETE_STUB:-}" ]; then
    workbench_complete() { COMPLETE_CALLS="${COMPLETE_CALLS}$*
"; }
fi
_str_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
_wb_have_tty() { [ -f "${CTL}/tty" ]; }
# The answer is the first line of $CTL/answers; the prompt is kept.
_read_prompt() {
    local _v
    printf 'PROMPT: %s\n' "$1" >> "${CTL}/tty.out"
    _v="$(head -n 1 "${CTL}/answers" 2>/dev/null)"
    sed 1d "${CTL}/answers" > "${CTL}/answers.new" 2>/dev/null; mv "${CTL}/answers.new" "${CTL}/answers" 2>/dev/null
    eval "$2=\${_v}"
}

# Mirrors workbench-core lib/core/functions.sh, CORE_API_VERSION 1.12
# (workbench-core D129). The module's CI has no workbench-core checkout, and
# which port stack-new picks is part of what this suite tests; core's own
# tests/check-port-helpers.sh covers the search itself.
workbench_port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -Hltn 2>/dev/null | awk -v p="${port}" '$4 ~ (":" p "$") { found = 1 } END { exit found ? 0 : 1 }'
    elif command -v lsof >/dev/null 2>&1; then
        [ -n "$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN -t 2>/dev/null)" ]
    else
        return 2
    fi
}
workbench_port_pick() {
    local base="$1" label="$2" candidate last rc t skip
    case "${base}" in
        ''|*[!0123456789]*)
            log_error "${label}: port base must be a number (got '${base}')"
            return 2
            ;;
    esac
    shift 2
    candidate="${base}"
    last=$((base + 99))
    while [ "${candidate}" -le "${last}" ]; do
        skip=""
        for t in "$@"; do
            if [ "${t}" = "${candidate}" ]; then
                skip=1
                break
            fi
        done
        if [ -z "${skip}" ]; then
            workbench_port_in_use "${candidate}"
            rc=$?
            case "${rc}" in
                1)
                    printf '%s\n' "${candidate}"
                    return 0
                    ;;
                0) ;;
                *)
                    log_warn "${label}: can't check ports (no ss or lsof) — trying ${candidate}"
                    printf '%s\n' "${candidate}"
                    return 0
                    ;;
            esac
        fi
        candidate=$((candidate + 1))
    done
    log_error "${label}: no free port from ${base} to ${last}"
    return 1
}

. "${R}/shell/containers.sh"
# stacks.sh's own stderr while it's sourced, for case 21's older-core check.
. "${R}/shell/stacks.sh" 2>"${HOME}/stacks-source.err"
# The terminal, for the btrfs question, goes to a file.
_containers_tty_print() { cat >> "${CTL}/tty.out"; }

check() { if eval "$2"; then echo "PASS:$1"; else echo "BAD:$1"; fi; }
# run <cmd...> — out is stdout and stderr, rc the status.
run() { out="$("$@" 2>&1)"; rc=$?; }
setctl() { printf '%s\n' "$2" > "${CTL}/$1"; }
calls() { cat "${CALLS}"; }
has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
mode600() { [ -n "$(find "$1" -perm 600 2>/dev/null)" ]; }
# fresh — an empty stacks root, no calls, ext4, no terminal, a user name.
fresh() {
    rm -rf "${WORKBENCH_STACKS_DIR}" "${CTL}" "${CALLS}"
    mkdir -p "${CTL}"
    : > "${CALLS}"
    setctl fstype ext2/ext3
    setctl user "fake user!"
    setctl rootless true
    : > "${CTL}/listening"
}
root_dir() { printf '%s\n' "${WORKBENCH_STACKS_DIR}"; }
EOF

cat > "${WORK}/scenario-main.sh" <<'EOF'
R="${REPO_ROOT}"
ROOT="${WORKBENCH_STACKS_DIR}"
export _CONTAINERS_KVM_DEV=/dev/null

# ── 1. names ─────────────────────────────────────────────────────────────────
for n in win11 my_stack-2 9lives; do
    check "1 name '${n}' is valid" '_containers_stack_name_ok "${n}"'
done
for n in Win11 -x _x .x a/b "a b" "" "$(printf '%064d' 0 | tr 0 a)"; do
    check "1 name '${n}' is rejected" '! _containers_stack_name_ok "${n}"'
done

# ── the random secret reads a bounded amount of input ────────────────────────
# A fake tr that reads its whole input before printing, as BSD tr does when
# SIGPIPE is ignored. With an endless /dev/urandom feeding it, it would never
# finish; the scenario watchdog then fails the run.
check "secret: 20 letters and digits" '[ "$(_containers_random_secret | tr -d "A-Za-z0-9\n" | wc -c | tr -d " ")" = 0 ] && [ "$(_containers_random_secret | tr -d "\n" | wc -c | tr -d " ")" = 20 ]'
check "secret: two calls differ" '[ "$(_containers_random_secret)" != "$(_containers_random_secret)" ]'

# ── 3. root creation (ext4, btrfs variants) ──────────────────────────────────
fresh
run _containers_stacks_root_ensure
check "3 ext4: the root is a plain folder, no question, no output" '[ "${rc}" = 0 ] && [ -d "${ROOT}" ] && [ -z "${out}" ] && [ ! -e "${CTL}/tty.out" ] && ! has "$(calls)" "btrfs"'
fresh; setctl fstype btrfs
run _containers_stacks_root_ensure
check "3 btrfs, no terminal: a plain folder and no output" '[ "${rc}" = 0 ] && [ -d "${ROOT}" ] && [ -z "${out}" ] && ! has "$(calls)" "btrfs|"'
fresh; setctl fstype btrfs
WORKBENCH_STACKS_SUBVOLUME=yes run _containers_stacks_root_ensure
check "3 btrfs, SUBVOLUME=yes: btrfs subvolume create <root> is called" '[ "${rc}" = 0 ] && has "$(calls)" "btrfs|" && has "$(calls)" "subvolume create ${ROOT}" && [ -d "${ROOT}" ]'
fresh; setctl fstype btrfs
WORKBENCH_STACKS_SUBVOLUME=no run _containers_stacks_root_ensure
check "3 btrfs, SUBVOLUME=no: a plain folder, no question" '[ -d "${ROOT}" ] && ! has "$(calls)" "subvolume" && [ ! -e "${CTL}/tty.out" ]'
fresh; setctl fstype btrfs
WORKBENCH_STACKS_SUBVOLUME=maybe run _containers_stacks_root_ensure
check "3 btrfs, SUBVOLUME=maybe: warns and makes a plain folder" 'has "${out}" "must be yes or no" && [ -d "${ROOT}" ] && ! has "$(calls)" "subvolume"'
fresh; setctl fstype btrfs; : > "${CTL}/tty"; setctl answers y
run _containers_stacks_root_ensure
check "3 btrfs, terminal, answer y: a subvolume, the explanation shown, and the skip line printed" 'has "$(calls)" "subvolume create ${ROOT}" && has "$(cat "${CTL}/tty.out")" "Create it as a subvolume? [y/N]" && has "$(cat "${CTL}/tty.out")" "Plain folder (default)" && has "${out}" "stacks: set WORKBENCH_STACKS_SUBVOLUME=yes or no in ~/.config/workbench/local/settings.sh to skip this question"'
fresh; setctl fstype btrfs; : > "${CTL}/tty"; : > "${CTL}/answers"
run _containers_stacks_root_ensure
check "3 btrfs, terminal, empty answer: a plain folder" '[ -d "${ROOT}" ] && ! has "$(calls)" "subvolume"'
fresh; setctl fstype btrfs; : > "${CTL}/tty"; : > "${CTL}/answers"
run _containers_stacks_root_ensure
check "3 no Snapper config: no Snapper line, and no Timeshift line without timeshift" '! has "$(cat "${CTL}/tty.out")" "Snapper" && ! has "$(cat "${CTL}/tty.out")" "Timeshift"'
fresh; setctl fstype btrfs; : > "${CTL}/tty"; : > "${CTL}/answers"
mkdir -p "${HOME}/snapper"; printf 'SUBVOLUME="/home"\nFSTYPE="btrfs"\n' > "${HOME}/snapper/home.conf"
_CONTAINERS_SNAPPER_DIR="${HOME}/snapper" run _containers_stacks_root_ensure
check "3 a Snapper config for /home: the Snapper line appears" 'has "$(cat "${CTL}/tty.out")" "  Snapper is taking snapshots of /home on this machine."'
fresh; setctl fstype btrfs; : > "${CTL}/tty"; : > "${CTL}/answers"
printf 'SUBVOLUME="/data"\n' > "${HOME}/snapper/home.conf"
_CONTAINERS_SNAPPER_DIR="${HOME}/snapper" run _containers_stacks_root_ensure
check "3 a Snapper config for another subvolume: no Snapper line" '! has "$(cat "${CTL}/tty.out")" "Snapper"'

# ── 4. stack-new windows ─────────────────────────────────────────────────────
fresh
run stack-new windows --name win11
D="${ROOT}/win11"
REC="${ROOT}/.wb/win11.conf"
check "4 stack-new windows succeeds" '[ "${rc}" = 0 ]'
check "4 creates compose.yaml, storage/ and shared/" '[ -f "${D}/compose.yaml" ] && [ -d "${D}/storage" ] && [ -d "${D}/shared" ]'
check "4 ext4: no chattr call" '! has "$(calls)" "chattr|"'
check "4 .env is mode 600" 'mode600 "${D}/.env"'
check "4 .env: WINDOWS_BIND=127.0.0.1" 'grep -qx "WINDOWS_BIND=127.0.0.1" "${D}/.env"'
check "4 .env: WINDOWS_WEB_PORT=8006 and WINDOWS_RDP_PORT=3389" 'grep -qx "WINDOWS_WEB_PORT=8006" "${D}/.env" && grep -qx "WINDOWS_RDP_PORT=3389" "${D}/.env"'
check "4 .env: WINDOWS_USERNAME is the sanitised login name" 'grep -qx "WINDOWS_USERNAME=fakeuser" "${D}/.env"'
check "4 .env: WINDOWS_PASSWORD is 20 letters and digits" 'grep -Eq "^WINDOWS_PASSWORD=[A-Za-z0-9]{20}\$" "${D}/.env"'
check "4 .env keeps the template's settings" 'grep -qx "WINDOWS_VERSION=11" "${D}/.env" && grep -qx "WINDOWS_NETWORK=user" "${D}/.env"'
PW="$(grep '^WINDOWS_PASSWORD=' "${D}/.env" | cut -d= -f2-)"
check "4 the output has neither the password nor PASSWORD=" '! has "${out}" "${PW}" && ! has "${out}" "PASSWORD="'
check "4 the output has the web URL and the rdp address" 'has "${out}" "web: http://127.0.0.1:8006/" && has "${out}" "rdp: 127.0.0.1:3389"'
check "4 the output names the user, points at .env for the password and says how to start" 'has "${out}" "User: fakeuser" && has "${out}" "Password: in ${D}/.env" && has "${out}" "Start it with: stack-up win11"'
check "4 the template's note is printed with the name filled in" 'has "${out}" "follow it with: stack-logs win11 -f"'
check "4 stack-new does not start the stack" '! has "$(calls)" " up"'
check "4 the record: ORIGIN, STOP_TIMEOUT, REQUIRES, BIND_VAR, COMPOSE" 'grep -qx "ORIGIN=template:windows" "${REC}" && grep -qx "STOP_TIMEOUT=120" "${REC}" && grep -qx "REQUIRES=kvm" "${REC}" && grep -qx "BIND_VAR=WINDOWS_BIND" "${REC}" && grep -qx "COMPOSE=podman-compose" "${REC}"'
check "4 the record: PROJECT, COMPOSE_FILE and a CREATED time" 'grep -qx "PROJECT=win11" "${REC}" && grep -qx "COMPOSE_FILE=compose.yaml" "${REC}" && grep -Eq "^CREATED=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\$" "${REC}"'
check "4 the config check ran from the stack folder" 'has "$(calls)" "podman-compose|${D}|-p win11 -f compose.yaml config"'

fresh; setctl fstype btrfs
run stack-new windows --name w
check "4 btrfs: chattr +C on storage only" 'has "$(calls)" "chattr|" && has "$(calls)" "+C ${ROOT}/w/storage" && ! has "$(calls)" "+C ${ROOT}/w/shared"'
fresh; setctl fstype btrfs
WORKBENCH_STACKS_NOCOW=0 run stack-new windows --name w
check "4 btrfs with WORKBENCH_STACKS_NOCOW=0: no chattr" '! has "$(calls)" "chattr|"'

# ── 5. ports ─────────────────────────────────────────────────────────────────
fresh; setctl listening 8006
run stack-new windows --name p1
check "5 with 8006 listening, WINDOWS_WEB_PORT=8007" 'grep -qx "WINDOWS_WEB_PORT=8007" "${ROOT}/p1/.env" && grep -qx "WINDOWS_RDP_PORT=3389" "${ROOT}/p1/.env" && has "${out}" "web: http://127.0.0.1:8007/"'
fresh
run stack-new windows --name win11
run stack-new windows --name win2
check "5 a second stack skips the first, stopped, stack's ports → 8007 and 3390" 'grep -qx "WINDOWS_WEB_PORT=8007" "${ROOT}/win2/.env" && grep -qx "WINDOWS_RDP_PORT=3390" "${ROOT}/win2/.env"'
run stack-new windows --name win3
check "5 a third stack → 8008 and 3391" 'grep -qx "WINDOWS_WEB_PORT=8008" "${ROOT}/win3/.env" && grep -qx "WINDOWS_RDP_PORT=3391" "${ROOT}/win3/.env"'

# ── 6. KVM ───────────────────────────────────────────────────────────────────
fresh
_CONTAINERS_KVM_DEV="${HOME}/no-such-kvm" run stack-new windows
check "6 no KVM: an error and the Linux hint, status 1" '[ "${rc}" = 1 ] && has "${out}" "needs KVM" && has "${out}" "check virtualisation is on in the firmware"'
check "6 no KVM: no folder and no record" '[ ! -e "${ROOT}/windows" ] && [ ! -e "${ROOT}/.wb/windows.conf" ]'
_CONTAINERS_KVM_DEV="${HOME}/no-such-kvm" WORKBENCH_WSL=true run stack-new windows
check "6 no KVM on WSL: the hint mentions nestedVirtualization" 'has "${out}" "nestedVirtualization"'
_CONTAINERS_KVM_DEV="${HOME}/no-such-kvm" WORKBENCH_OS=Mac run stack-new windows
check "6 no KVM on macOS: the hint says KVM is Linux-only" 'has "${out}" "KVM is Linux-only"'

# ── 7. an existing name ──────────────────────────────────────────────────────
fresh
run stack-new windows --name win11
BEFORE="$(find "${ROOT}" | sort | cksum; find "${ROOT}" -type f -exec cat {} + | cksum)"
run stack-new windows --name win11
AFTER="$(find "${ROOT}" | sort | cksum; find "${ROOT}" -type f -exec cat {} + | cksum)"
check "7 an existing name is refused" '[ "${rc}" = 1 ] && has "${out}" "win11: already exists"'
check "7 ... and nothing under the root changed" '[ "${BEFORE}" = "${AFTER}" ]'
run stack-new nosuch
check "7 an unknown template is refused and the templates are listed" '[ "${rc}" = 1 ] && has "${out}" "no template" && has "${out}" "windows"'
run stack-new
check "7 stack-new with no template lists them and returns 0" '[ "${rc}" = 0 ] && has "${out}" "windows" && has "${out}" "dockur/windows"'

# ── 8. a failing config during stack-new ─────────────────────────────────────
fresh; setctl config-rcs 1
run stack-new windows --name bad
check "8 a failing config: status 1" '[ "${rc}" = 1 ]'
check "8 ... and no folder and no record afterwards" '[ ! -e "${ROOT}/bad" ] && [ ! -e "${ROOT}/.wb/bad.conf" ]'
fresh; run stack-new windows --name win11; : > "${CTL}/config-rcs"; : > "${CALLS}"; setctl config-rcs 1
run stack-new windows --name other
check "8 a failure leaves an earlier stack alone" '[ -d "${ROOT}/win11" ] && [ -f "${ROOT}/.wb/win11.conf" ] && [ ! -e "${ROOT}/other" ]'

# ── 9. stack-up ──────────────────────────────────────────────────────────────
fresh; run stack-new windows --name win11
D="${ROOT}/win11"
: > "${CALLS}"
HERE="$PWD"
run stack-up win11
check "9 stack-up runs podman-compose in the stack folder with -p -f up -d" '[ "${rc}" = 0 ] && has "$(calls)" "podman-compose|${D}|-p win11 -f compose.yaml up -d"'
check "9 the caller's directory is unchanged" '[ "${PWD}" = "${HERE}" ]'
check "9 loopback: no warning" '! has "${out}" "beyond this machine"'
printf 'WINDOWS_BIND=0.0.0.0\n' >> "${D}/.env"
run stack-up win11
check "9 WINDOWS_BIND=0.0.0.0: the warning" 'has "${out}" "win11: WINDOWS_BIND=0.0.0.0 publishes this stack beyond this machine"'
mkdir -p "${HOME}/src/imp"; printf 'services:\n  web:\n    image: x\n' > "${HOME}/src/imp/compose.yaml"; printf 'BIND=0.0.0.0\nTAG=1\n' > "${HOME}/src/imp/.env"
run stack-import "${HOME}/src/imp"
run stack-up imp
check "9 an imported stack (no BIND_VAR) with BIND=0.0.0.0: no warning" '[ "${rc}" = 0 ] && ! has "${out}" "beyond this machine"'
run stack-up nosuch
check "9 an unknown stack: an error" '[ "${rc}" = 1 ] && has "${out}" "nosuch: no such stack"'
run stack-up
check "9 stack-up with no name, two stacks, no terminal: status 2 and both names" '[ "${rc}" = 2 ] && has "${out}" "which stack?" && has "${out}" "win11" && has "${out}" "imp"'
_CONTAINERS_KVM_DEV="${HOME}/no-such-kvm" run stack-up win11
check "9 REQUIRES=kvm and no KVM: an error and the hint, compose not run" '[ "${rc}" = 1 ] && has "${out}" "needs KVM" && has "${out}" "check virtualisation"'

# ── 10. stack-down ───────────────────────────────────────────────────────────
: > "${CALLS}"
run stack-down win11
check "10 stack-down passes -t from STOP_TIMEOUT" 'has "$(calls)" "-p win11 -f compose.yaml down -t 120"'
: > "${CALLS}"
run stack-down imp
check "10 an imported stack has no STOP_TIMEOUT: down with no -t" 'has "$(calls)" "-p imp -f compose.yaml down" && ! has "$(calls)" "down -t"'
: > "${CALLS}"
run stack-down win11 -v
check "10 extra arguments follow -t" 'has "$(calls)" "down -t 120 -v"'

# ── 11. stack-compose, stack-logs, stack-path ────────────────────────────────
: > "${CALLS}"
run stack-compose win11 ps -a
check "11 stack-compose passes its arguments through" 'has "$(calls)" "-p win11 -f compose.yaml ps -a"'
run stack-compose win11
check "11 stack-compose with no arguments: usage, status 2" '[ "${rc}" = 2 ] && has "${out}" "Usage: stack-compose"'
: > "${CALLS}"
run stack-logs win11 -f
check "11 stack-logs passes -f" 'has "$(calls)" "-p win11 -f compose.yaml logs -f"'
check "11 stack-path prints the folder" '[ "$(stack-path win11)" = "$(_containers_abs_dir "${ROOT}/win11")" ]'

# ── 12. stack-import of a folder ────────────────────────────────────────────────
fresh
mkdir -p "${HOME}/src/Gitea-Stack"; printf 'services:\n  web:\n    image: x\n' > "${HOME}/src/Gitea-Stack/compose.yaml"
run stack-import "${HOME}/src/Gitea-Stack"
ABS="$(_containers_abs_dir "${HOME}/src/Gitea-Stack")"
check "12 stack-import of a folder links it, named from the folder (lowercased)" '[ "${rc}" = 0 ] && [ -L "${ROOT}/gitea-stack" ] && [ "$(readlink "${ROOT}/gitea-stack")" = "${ABS}" ]'
check "12 ... with ORIGIN=link and the project name kept" 'grep -qx "ORIGIN=link" "${ROOT}/.wb/gitea-stack.conf" && grep -qx "PROJECT=gitea-stack" "${ROOT}/.wb/gitea-stack.conf" && grep -qx "COMPOSE_FILE=compose.yaml" "${ROOT}/.wb/gitea-stack.conf"'
check "12 ... and says how to start it" 'has "${out}" "Start it with: stack-up gitea-stack"'
check "12 the source was validated with config from its own folder" 'has "$(calls)" "podman-compose|${ABS}|-p gitea-stack -f compose.yaml config"'
mkdir -p "${HOME}/src/other"; printf 'name: myproj\nservices:\n  web:\n    image: x\n' > "${HOME}/src/other/compose.yaml"
run stack-import "${HOME}/src/other"
check "12 a top-level name: gives the project and the stack name" '[ -L "${ROOT}/myproj" ] && grep -qx "PROJECT=myproj" "${ROOT}/.wb/myproj.conf"'
run stack-import "${HOME}/src/other"
check "12 adding it again is refused: the name is taken" '[ "${rc}" = 1 ] && has "${out}" "myproj: already exists"'
mkdir -p "${HOME}/src/_x"; printf 'services:\n  web:\n    image: x\n' > "${HOME}/src/_x/compose.yaml"
run stack-import "${HOME}/src/_x"
check "12 an invalid folder name and no --name: refused, asking for --name" '[ "${rc}" = 1 ] && has "${out}" "--name"'
run stack-import "${HOME}/src/_x" --name fine
check "12 --name makes the project the name" '[ -L "${ROOT}/fine" ] && grep -qx "PROJECT=fine" "${ROOT}/.wb/fine.conf"'
mkdir -p "${HOME}/src/empty"
run stack-import "${HOME}/src/empty"
check "12 a folder with no compose file is refused" '[ "${rc}" = 1 ] && has "${out}" "no compose file"'
printf '1\n' > "${CTL}/config-rcs"
mkdir -p "${HOME}/src/broken"; printf 'x: [\n' > "${HOME}/src/broken/compose.yaml"
run stack-import "${HOME}/src/broken"
check "12 a compose file compose rejects: nothing is added" '[ "${rc}" = 1 ] && [ ! -e "${ROOT}/broken" ] && [ ! -e "${ROOT}/.wb/broken.conf" ]'
fresh; mkdir -p "${HOME}/src/volp"; printf 'services:\n  web:\n    image: x\n' > "${HOME}/src/volp/compose.yaml"
printf 'pgdata\ncache\n' > "${CTL}/config-volumes"
run stack-import "${HOME}/src/volp"
check "12 named volumes are reported in the summary, not moved" 'has "${out}" "volumes       pgdata, cache — kept by the engine, not in the folder"'

# ── 13. stack-import --move ─────────────────────────────────────────────────────
fresh
mkdir -p "${HOME}/src/mv-me"; printf 'services:\n  web:\n    image: x\n' > "${HOME}/src/mv-me/compose.yaml"; printf 'hello\n' > "${HOME}/src/mv-me/data.txt"
printf 'abc123\n' > "${CTL}/ps-out"
run stack-import "${HOME}/src/mv-me" --move
check "13 --move while the project runs: refused, source untouched" '[ "${rc}" = 1 ] && has "${out}" "is running" && [ -f "${HOME}/src/mv-me/data.txt" ] && [ ! -e "${ROOT}/mv-me" ]'
check "13 ... and the running check filtered by the compose project label" 'has "$(calls)" "ps -q --filter label=io.podman.compose.project=mv-me"'
printf '1\n' > "${CTL}/ps-rc"; : > "${CTL}/ps-out"
run stack-import "${HOME}/src/mv-me" --move
check "13 --move when the engine can't be asked: refused" '[ "${rc}" = 1 ] && has "${out}" "can'"'"'t tell whether mv-me is running" && [ -f "${HOME}/src/mv-me/data.txt" ]'
printf '0\n' > "${CTL}/ps-rc"; : > "${CTL}/ps-out"
run stack-import "${HOME}/src/mv-me" --move
check "13 --move when nothing runs: the folder moves, as a real folder" '[ "${rc}" = 0 ] && [ -d "${ROOT}/mv-me" ] && [ ! -L "${ROOT}/mv-me" ] && [ -f "${ROOT}/mv-me/data.txt" ] && [ ! -e "${HOME}/src/mv-me" ] && grep -qx "ORIGIN=move" "${ROOT}/.wb/mv-me.conf"'
mkdir -p "${HOME}/src/cp-me"; printf 'services:\n  web:\n    image: x\n' > "${HOME}/src/cp-me/compose.yaml"; printf 'hello\n' > "${HOME}/src/cp-me/data.txt"
printf 'abc123\n' > "${CTL}/ps-out"
run stack-import "${HOME}/src/cp-me" --copy
check "13 --copy while the project runs: refused" '[ "${rc}" = 1 ] && has "${out}" "is running" && [ ! -e "${ROOT}/cp-me" ]'
: > "${CTL}/ps-out"
run stack-import "${HOME}/src/cp-me" --copy
check "13 --copy: both copies exist, ORIGIN=copy, and the size was printed" '[ "${rc}" = 0 ] && [ -f "${ROOT}/cp-me/data.txt" ] && [ -f "${HOME}/src/cp-me/data.txt" ] && grep -qx "ORIGIN=copy" "${ROOT}/.wb/cp-me.conf" && has "${out}" "Copying"'
mkdir -p "${HOME}/src/ln-me"; printf 'services:\n  web:\n    image: x\n' > "${HOME}/src/ln-me/compose.yaml"
printf 'abc123\n' > "${CTL}/ps-out"
run stack-import "${HOME}/src/ln-me"
check "13 --link works while the project runs" '[ "${rc}" = 0 ] && [ -L "${ROOT}/ln-me" ]'

# ── 14. stack-import of a lone compose file ─────────────────────────────────────
fresh
mkdir -p "${HOME}/lone"; printf 'services:\n  web:\n    image: x\n' > "${HOME}/lone/compose.yaml"; printf 'TAG=1\n' > "${HOME}/lone/.env"; chmod 600 "${HOME}/lone/.env"
run stack-import "${HOME}/lone/compose.yaml"
check "14 a lone file is copied, with its .env, as ORIGIN=copy" '[ "${rc}" = 0 ] && [ -f "${ROOT}/lone/compose.yaml" ] && [ -f "${ROOT}/lone/.env" ] && [ ! -L "${ROOT}/lone" ] && grep -qx "ORIGIN=copy" "${ROOT}/.wb/lone.conf"'
check "14 ... keeping the .env's mode" 'mode600 "${ROOT}/lone/.env"'
fresh
mkdir -p "${HOME}/lone"; printf 'services:\n  web:\n    image: x\n' > "${HOME}/lone/compose.yaml"
# The source check, the summary's config --volumes, then the copy's check.
printf '0\n0\n1\n' > "${CTL}/config-rcs"
run stack-import "${HOME}/lone/compose.yaml"
check "14 config failing after the copy: the copy and record are removed" '[ "${rc}" = 1 ] && [ ! -e "${ROOT}/lone" ] && [ ! -e "${ROOT}/.wb/lone.conf" ] && [ -f "${HOME}/lone/compose.yaml" ]'
check "14 ... and the error suggests adding the folder" 'has "${out}" "refers to files beside the original" && has "${out}" "stack-import $(_containers_abs_dir "${HOME}/lone") --copy"'
run stack-import "${HOME}/lone/compose.yaml" --move
check "14 --move with a file: refused" '[ "${rc}" = 1 ] && has "${out}" "point stack-import at the file'"'"'s folder to move or link it"'
run stack-import "${HOME}/lone/compose.yaml" --link
check "14 --link with a file: refused" '[ "${rc}" = 1 ] && has "${out}" "point stack-import at the file'"'"'s folder"'
run stack-import "${HOME}/nothing-here"
check "14 a path that doesn't exist: refused" '[ "${rc}" = 1 ] && has "${out}" "no such folder or file"'

# ── 15. stack-list ───────────────────────────────────────────────────────────
fresh
run stack-list
check "15 a missing root: the no-stacks line, status 0" '[ "${rc}" = 0 ] && has "${out}" "stacks: no stacks yet (stack-new or stack-import)"'
mkdir -p "${ROOT}/.wb"
run stack-list
check "15 a root with only .wb/: the no-stacks line, and no 'no matches found'" '[ "${rc}" = 0 ] && has "${out}" "no stacks yet" && ! has "${out}" "no matches found"'
fresh
run stack-new windows --name win11
mkdir -p "${HOME}/src/gitea"; printf 'services:\n  web:\n    image: x\n' > "${HOME}/src/gitea/compose.yaml"
run stack-import "${HOME}/src/gitea"
ln -s "${HOME}/gone-away" "${ROOT}/gone"
mkdir -p "${ROOT}/handmade"
run stack-list
check "15 stack-list has a header and one line per stack" 'has "${out}" "NAME" && has "${out}" "ORIGIN" && has "${out}" "STATE" && has "${out}" "PATH"'
check "15 a template stack: origin template:windows, stopped, its folder" 'has "${out}" "win11" && has "${out}" "template:windows" && has "${out}" "stopped" && has "${out}" "${ROOT}/win11"'
check "15 a linked stack: origin link, its target as the path" 'has "${out}" "gitea" && has "${out}" "link" && has "${out}" "$(_containers_abs_dir "${HOME}/src/gitea")"'
check "15 a link whose target is gone: missing" 'printf "%s\n" "${out}" | grep -E "^gone +manual +missing" >/dev/null'
check "15 a folder with no record: origin manual" 'printf "%s\n" "${out}" | grep -E "^handmade +manual" >/dev/null'
check "15 the .wb folder is not listed" '! printf "%s\n" "${out}" | grep -E "^\.wb" >/dev/null'
printf 'abc123\n' > "${CTL}/ps-out"
run stack-list
check "15 a running project: running" 'printf "%s\n" "${out}" | grep -E "^win11 +template:windows +running" >/dev/null'
printf '1\n' > "${CTL}/ps-rc"; : > "${CTL}/ps-out"
run stack-list
check "15 the engine can't be asked: unknown" 'printf "%s\n" "${out}" | grep -E "^win11 +template:windows +unknown" >/dev/null'

# ── 16. stack-rm ─────────────────────────────────────────────────────────────
fresh
run stack-new windows --name win11
mkdir -p "${HOME}/src/gitea"; printf 'services:\n  web:\n    image: x\n' > "${HOME}/src/gitea/compose.yaml"; printf 'keep\n' > "${HOME}/src/gitea/data.txt"
run stack-import "${HOME}/src/gitea"
printf 'abc123\n' > "${CTL}/ps-out"
run stack-rm win11
check "16 refused while running" '[ "${rc}" = 1 ] && has "${out}" "is running" && [ -d "${ROOT}/win11" ]'
: > "${CTL}/ps-out"
run stack-rm win11
check "16 a root folder without --purge: refused, intact" '[ "${rc}" = 1 ] && has "${out}" "folder is its data" && has "${out}" "--purge" && [ -d "${ROOT}/win11" ] && [ -f "${ROOT}/.wb/win11.conf" ]'
run stack-rm gitea
check "16 a linked stack: the link and record go, the target stays" '[ "${rc}" = 0 ] && [ ! -e "${ROOT}/gitea" ] && [ ! -L "${ROOT}/gitea" ] && [ ! -e "${ROOT}/.wb/gitea.conf" ] && [ -f "${HOME}/src/gitea/data.txt" ] && has "${out}" "was left as it is"'
run stack-import "${HOME}/src/gitea"
run stack-rm gitea --purge
check "16 a linked stack with --purge: refused, intact" '[ "${rc}" = 1 ] && has "${out}" "is your folder" && has "${out}" "stack-rm only removes the link" && [ -L "${ROOT}/gitea" ] && [ -f "${HOME}/src/gitea/data.txt" ]'
printf '1\n' > "${CTL}/ps-rc"
run stack-rm win11 --purge
check "16 the engine can't be asked: refused" '[ "${rc}" = 1 ] && has "${out}" "can'"'"'t tell whether it is running" && [ -d "${ROOT}/win11" ]'
printf '0\n' > "${CTL}/ps-rc"
run stack-rm win11 --purge
check "16 --purge with no terminal: refused, intact" '[ "${rc}" = 1 ] && has "${out}" "needs a terminal" && [ -d "${ROOT}/win11" ]'
: > "${CTL}/tty"; setctl answers wrongname
run stack-rm win11 --purge
check "16 --purge with the wrong name typed: nothing deleted" '[ "${rc}" = 1 ] && [ -d "${ROOT}/win11" ] && [ -f "${ROOT}/.wb/win11.conf" ] && has "$(cat "${CTL}/tty.out")" "Type the stack'"'"'s name to delete it: "'
printf 'win11_data\n' > "${CTL}/volumes"; setctl answers win11; : > "${CALLS}"
run stack-rm win11 --purge
check "16 --purge with the name typed: down, then podman unshare rm -rf -- <dir>" 'has "$(calls)" "-p win11 -f compose.yaml down -t 120" && has "$(calls)" "podman|" && has "$(calls)" "unshare rm -rf -- ${ROOT}/win11"'
check "16 ... the folder and record are gone" '[ "${rc}" = 0 ] && [ ! -e "${ROOT}/win11" ] && [ ! -e "${ROOT}/.wb/win11.conf" ]'
check "16 ... the folder, size and named volumes were shown first" 'has "${out}" "folder:" && has "${out}" "win11_data"'
check "16 ... leftover volumes are listed with the command to remove each" 'has "${out}" "named volumes left behind" && has "${out}" "podman volume rm win11_data"'
fresh
run stack-new windows --name plain
: > "${CTL}/tty"; setctl answers plain; setctl rootless false; : > "${CALLS}"
run stack-rm plain --purge
check "16 not rootless podman: a plain rm -rf, no unshare" '[ ! -e "${ROOT}/plain" ] && ! has "$(calls)" "unshare"'

# ── 18. .env beats the shell ─────────────────────────────────────────────────
fresh
run stack-new windows --name win11
mkdir -p "${HOME}/src/home-env"; printf 'services:\n  web:\n    image: x\n' > "${HOME}/src/home-env/compose.yaml"; printf 'HOME=/elsewhere\nTAG=1\n' > "${HOME}/src/home-env/.env"
run stack-import "${HOME}/src/home-env"

export WINDOWS_VERSION=10 OTHER_VAR=keepme
run stack-up win11
check "18 an exported WINDOWS_VERSION is not seen by compose" 'grep -qx "WINDOWS_VERSION=" "${CTL}/envseen"'
check "18 ... one warning names WINDOWS_VERSION" 'has "${out}" "using the stack'"'"'s .env, not your shell, for: WINDOWS_VERSION" && [ "$(printf "%s\n" "${out}" | grep -c "not your shell")" = 1 ]'
check "18 ... the caller's shell still has WINDOWS_VERSION=10" '[ "${WINDOWS_VERSION}" = 10 ] && [ "$(printenv WINDOWS_VERSION)" = 10 ]'
check "18 a variable exported but not in .env passes through" 'grep -qx "OTHER_VAR=keepme" "${CTL}/envseen" && ! has "${out}" "OTHER_VAR"'
run stack-up home-env
check "18 an imported stack whose .env sets HOME: compose sees the shell's HOME" 'grep -qx "HOME=${HOME}" "${CTL}/envseen"'
check "18 ... and no warning names HOME" '! has "${out}" "HOME"'
run stack-down win11
check "18 stack-down applies the same rule" 'grep -qx "WINDOWS_VERSION=" "${CTL}/envseen" && has "${out}" "WINDOWS_VERSION"'
unset WINDOWS_VERSION
run stack-up win11
check "18 no exported names overlap .env: no warning" '! has "${out}" "not your shell"'
check "18 ... and compose sees OTHER_VAR still" 'grep -qx "OTHER_VAR=keepme" "${CTL}/envseen"'
unset OTHER_VAR

# ── 19. the shell's cd hooks don't run in stack folders ──────────────────────
# zsh runs chpwd_functions on every cd, subshells included; direnv's hook is
# one, and reported a stack's .env as blocked on every stack-* call. bash has
# no cd hooks, so this case only applies in zsh.
if [ -n "${ZSH_VERSION:-}" ]; then
    _check_chpwd_hook() { printf '%s\n' "${PWD}" >> "${CTL}/chpwd"; }
    chpwd_functions=(_check_chpwd_hook)
    ( builtin cd -- "${ROOT}/win11" )
    check "19 zsh: the recording hook runs on a plain subshell cd (the check can see it)" '[ -s "${CTL}/chpwd" ]'
    rm -f "${CTL}/chpwd"
    mkdir -p "${HOME}/src/hooked"; printf 'services:\n  web:\n    image: x\n' > "${HOME}/src/hooked/compose.yaml"
    run stack-up win11
    run stack-down win11
    run stack-path win11
    run stack-import "${HOME}/src/hooked"
    run stack-up hooked
    check "19 zsh: stack-up, stack-down, stack-path and stack-import run no chpwd hook" '[ ! -e "${CTL}/chpwd" ]'
    chpwd_functions=()
    unset -f _check_chpwd_hook
fi
EOF

cat > "${WORK}/scenario-resolve.sh" <<'EOF'
# ── 2. compose tool resolution ──────────────────────────────────────────────
case "${SCENARIO}" in
    resolve-podman-first)
        # podman plus podman-compose, with docker-compose present too.
        run _containers_stack_compose_cmd
        check "2 podman and podman-compose → podman-compose, even with docker-compose present" '[ "${rc}" = 0 ] && [ "${out}" = "podman-compose" ]'
        check "2 the engine for podman-compose is podman" '[ "$(_containers_stack_engine_cli podman-compose)" = "podman" ]'
        check "2 the label key for podman-compose is io.podman.compose.project" '[ "$(_containers_stack_label_key podman-compose)" = "io.podman.compose.project" ]'
        check "2 the label key for the others is com.docker.compose.project" '[ "$(_containers_stack_label_key docker-compose)" = "com.docker.compose.project" ]'
        check "2 the availability check passes" '_containers_stack_compose_available'
        ;;
    resolve-docker-plugin)
        run _containers_stack_compose_cmd
        check "2 a Docker CLI that prints 'Docker version' plus the plugin → docker compose" '[ "${rc}" = 0 ] && [ "${out}" = "docker compose" ]'
        check "2 the engine for docker compose is docker" '[ "$(_containers_stack_engine_cli "docker compose")" = "docker" ]'
        ;;
    resolve-shim)
        run _containers_stack_compose_cmd
        check "2 a podman-docker-style docker plus docker-compose, without podman-compose → an error naming podman-compose" '[ "${rc}" = 1 ] && has "${out}" "podman-compose"'
        check "2 ... and the engine for docker-compose behind the shim is podman" '[ "$(_containers_stack_engine_cli docker-compose)" = "podman" ]'
        ;;
    resolve-bogus)
        run _containers_stack_compose_cmd
        check "2 WORKBENCH_STACKS_COMPOSE=bogus → an error naming the allowed values" '[ "${rc}" = 1 ] && has "${out}" "podman-compose, docker-compose or \"docker compose\"" && has "${out}" "bogus"'
        ;;
    resolve-override)
        run _containers_stack_compose_cmd
        check "2 WORKBENCH_STACKS_COMPOSE=docker-compose wins over podman-compose" '[ "${rc}" = 0 ] && [ "${out}" = "docker-compose" ]'
        ;;
    resolve-none)
        run _containers_stack_compose_cmd
        check "2 no compose tool at all → a message pointing at wb tools install" '[ "${rc}" = 1 ] && has "${out}" "wb tools install podman"'
        check "2 ... and the availability check fails" '! _containers_stack_compose_available'
        ;;
    resolve-podman-nocompose)
        run _containers_stack_compose_cmd
        check "2 podman without podman-compose → an error naming podman-compose" '[ "${rc}" = 1 ] && has "${out}" "podman is installed but podman-compose isn'"'"'t"'
        ;;
esac
EOF

# ── D132 cases 20–25 and 29–33, against the module's own templates ─────────
cat > "${WORK}/scenario-d132.sh" <<'EOF'
R="${REPO_ROOT}"
ROOT="${WORKBENCH_STACKS_DIR}"
export _CONTAINERS_KVM_DEV=/dev/null
# comp <words...> — the provider's output for the last word, out and rc set.
comp() { local _i=$(($# - 1)); out="$(_containers_complete "${_i}" "$@" 2>"${CTL}/comp.err")"; rc=$?; }
TAB="$(printf '\t')"
lines() { printf '%s\n' "$1" | cut -f1 | tr '\n' ' ' | sed 's/ $//'; }
src() { mkdir -p "$1"; printf 'services:\n  web:\n    image: x\n' > "$1/${2:-compose.yaml}"; }

# ── 20. completion provider ──────────────────────────────────────────────────
fresh
comp stack-up ""
check "20 an empty root: nothing, status 0, nothing on stderr" '[ "${rc}" = 0 ] && [ -z "${out}" ] && [ ! -s "${CTL}/comp.err" ]'
run stack-new windows --name win11
src "${HOME}/src/gitea"; run stack-import "${HOME}/src/gitea"
comp stack-new ""
check "20 stack-new \"\": every template folder with its DESCRIPTION, no aliases" '[ "${out}" = "windows${TAB}Windows 11 in a KVM virtual machine (dockur/windows)" ]'
comp stack-new --
check "20 stack-new --: its options" '[ "$(lines "${out}")" = "--name --list --accept --help" ]'
comp stack-new --name ""
check "20 stack-new --name \"\": nothing" '[ -z "${out}" ]'
comp stack-up ""
check "20 stack-up \"\": every stack, each with its origin" '[ "${out}" = "gitea${TAB}link
win11${TAB}template:windows" ]'
comp stack-edit win11 ""
check "20 stack-edit win11 \"\": compose, env, override" '[ "$(lines "${out}")" = "compose env override" ]'
comp stack-compose win11 ""
check "20 stack-compose win11 \"\": the compose commands" 'has " $(lines "${out}") " " ps " && has " $(lines "${out}") " " up " && has " $(lines "${out}") " " exec "'
comp stack-compose ""
check "20 stack-compose \"\": stacks" '[ "$(lines "${out}")" = "gitea win11" ]'
comp stack-import ""
check "20 stack-import \"\": @files" '[ "${out}" = "@files" ]'
comp stack-import --name foo ""
check "20 stack-import --name foo \"\": @files" '[ "${out}" = "@files" ]'
comp stack-rm win11 --p
check "20 stack-rm win11 --p: --purge --help" '[ "$(lines "${out}")" = "--purge --help" ]'
comp stack-help ""
check "20 stack-help \"\": import, templates, commands" '[ "$(lines "${out}")" = "import templates commands" ]'

# ── 21. registration ─────────────────────────────────────────────────────────
check "21 workbench_complete called once, with the provider and the twelve commands" '[ "${COMPLETE_CALLS}" = "_containers_complete stack-new stack-import stack-list stack-info stack-up stack-down stack-logs stack-edit stack-compose stack-path stack-rm stack-help
" ]'
check "21 stack-add is neither registered nor defined" '! has "${COMPLETE_CALLS}" "stack-add" && ! command -v stack-add >/dev/null 2>&1'

# ── 22. the one-stack rule ───────────────────────────────────────────────────
fresh
run stack-up
check "22 no stacks: the no-stacks error, status 1" '[ "${rc}" = 1 ] && has "${out}" "no stacks yet (stack-new or stack-import)"'
run stack-new windows --name win11; : > "${CALLS}"
run stack-up
check "22 one stack: stack-up runs up -d for it and says so" '[ "${rc}" = 0 ] && has "$(calls)" "-p win11 -f compose.yaml up -d" && has "${out}" "using win11, the only stack"'
: > "${CALLS}"
run stack-logs -f
check "22 stack-logs -f with one stack: logs -f for it" 'has "$(calls)" "-p win11 -f compose.yaml logs -f"'
run stack-new windows --name win2; : > "${CALLS}"
run stack-up
check "22 two stacks, no terminal: status 2, both names" '[ "${rc}" = 2 ] && has "${out}" "win11" && has "${out}" "win2" && ! has "$(calls)" "up -d"'
: > "${CTL}/tty"; printf '9\nx\n2\n' > "${CTL}/answers"; : > "${CALLS}"
run stack-up
check "22 a terminal, answers 9, x, 2: the second stack" 'has "$(calls)" "-p win2 -f compose.yaml up -d" && has "$(cat "${CTL}/tty.out")" "Which stack?"'
printf '\n' > "${CTL}/answers"; : > "${CALLS}"
run stack-up
check "22 Enter: the first stack" 'has "$(calls)" "-p win11 -f compose.yaml up -d"'
printf '9\nx\n0\n' > "${CTL}/answers"; : > "${CALLS}"
run stack-up
check "22 three bad answers: status 2, compose not run" '[ "${rc}" = 2 ] && ! has "$(calls)" "up -d"'

# ── 23. stack-rm with no name ────────────────────────────────────────────────
fresh; run stack-new windows --name win11
run stack-rm
check "23 stack-rm with no name and one stack: usage, the stacks, status 2, nothing removed" '[ "${rc}" = 2 ] && has "${out}" "Usage: stack-rm" && has "${out}" "Stacks: win11" && [ -d "${ROOT}/win11" ]'

# ── 24. stack-compose ────────────────────────────────────────────────────────
: > "${CALLS}"
run stack-compose win11 ps -a
check "24 stack-compose win11 ps -a: ps -a" 'has "$(calls)" "-p win11 -f compose.yaml ps -a"'
: > "${CALLS}"
run stack-compose ps -a
check "24 one stack, stack-compose ps -a: ps -a for it" 'has "$(calls)" "-p win11 -f compose.yaml ps -a"'
run stack-new windows --name win2
run stack-compose ps
check "24 two stacks, no terminal, stack-compose ps: status 2" '[ "${rc}" = 2 ]'

# ── 25. stack-new ────────────────────────────────────────────────────────────
fresh; : > "${CTL}/tty"; printf '1\n\n' > "${CTL}/answers"
run stack-new
check "25 no template on a terminal, answer 1: the first template" '[ "${rc}" = 0 ] && [ -f "${ROOT}/windows/compose.yaml" ] && has "$(cat "${CTL}/tty.out")" "Which template?"'
rm -f "${CTL}/tty"
run stack-new win
check "25 stack-new win: windows taken, no terminal → windows-2, with the naming line" '[ "${rc}" = 0 ] && grep -qx "ORIGIN=template:windows" "${ROOT}/.wb/windows-2.conf" && has "${out}" "naming it windows-2 (--name to choose)"'
: > "${CTL}/tty"; printf '\n' > "${CTL}/answers"
run stack-new windows
check "25 a terminal, empty answer: the suggestion" '[ -d "${ROOT}/windows-3" ] && has "$(cat "${CTL}/tty.out")" "Name for the stack [windows-3]: "'
printf 'Bad!\nmywin\n' > "${CTL}/answers"
run stack-new windows
check "25 an invalid answer, then mywin: mywin" '[ -d "${ROOT}/mywin" ] && has "${out}" "isn'"'"'t a valid stack name"'
run stack-new windows --name mywin
check "25 an explicit taken --name: status 1" '[ "${rc}" = 1 ] && has "${out}" "mywin: already exists"'
check "25 the closing lines point at stack-info" 'has "$(rm -rf "${ROOT}/x9" "${ROOT}/.wb/x9.conf"; stack-new windows --name x9 2>&1)" "  Details: stack-info x9"'
check "25 the record has PORT_LABELS, LOGIN_VARS, SECRET_VARS and an empty ACCEPTED" 'grep -qx "PORT_LABELS=WINDOWS_WEB_PORT:web WINDOWS_RDP_PORT:rdp" "${ROOT}/.wb/mywin.conf" && grep -qx "LOGIN_VARS=WINDOWS_USERNAME" "${ROOT}/.wb/mywin.conf" && grep -qx "SECRET_VARS=WINDOWS_PASSWORD" "${ROOT}/.wb/mywin.conf" && grep -qx "ACCEPTED=" "${ROOT}/.wb/mywin.conf"'

# ── 29. stack-import ─────────────────────────────────────────────────────────
fresh; src "${HOME}/src/dry"
run stack-import "${HOME}/src/dry" --dry-run
check "29 --dry-run: the summary and the dry-run line" '[ "${rc}" = 0 ] && has "${out}" "Import dry" && has "${out}" "how           link — the files stay where they are" && has "${out}" "stacks: dry: dry run, nothing changed"'
check "29 --dry-run: no root, no record, no link" '[ ! -e "${ROOT}" ]'
fresh; src "${HOME}/src/mvme"; : > "${CTL}/tty"; printf '2\ny\n' > "${CTL}/answers"
run stack-import "${HOME}/src/mvme"
check "29 a terminal, no mode, answers 2 and y: moved" '[ "${rc}" = 0 ] && [ -d "${ROOT}/mvme" ] && [ ! -L "${ROOT}/mvme" ] && [ ! -e "${HOME}/src/mvme" ] && grep -qx "ORIGIN=move" "${ROOT}/.wb/mvme.conf" && grep -qx "FROM=$(_containers_abs_dir "${HOME}/src")/mvme" "${ROOT}/.wb/mvme.conf" && has "$(cat "${CTL}/tty.out")" "How should mvme be imported?"'
src "${HOME}/src/keep"; printf '1\nn\n' > "${CTL}/answers"
run stack-import "${HOME}/src/keep"
check "29 n at Import it?: nothing changed" '[ "${rc}" = 1 ] && has "${out}" "keep: not imported" && [ ! -e "${ROOT}/keep" ] && [ ! -e "${ROOT}/.wb/keep.conf" ]'
: > "${CTL}/tty.out"
run stack-import "${HOME}/src/keep" --link --yes
check "29 --yes skips the question" '[ "${rc}" = 0 ] && [ -L "${ROOT}/keep" ] && ! has "$(cat "${CTL}/tty.out")" "Import it?"'
rm -f "${CTL}/tty"
mkdir -p "${HOME}/src/vm"; printf 'services:\n  vm:\n    image: x\n    stop_grace_period: 90s\n  side:\n    image: y\n    stop_grace_period: "1m" # short\n' > "${HOME}/src/vm/compose.yaml"
run stack-import "${HOME}/src/vm"
check "29 stop_grace_period 90s: STOP_TIMEOUT=90 and the summary says so" 'grep -qx "STOP_TIMEOUT=90" "${ROOT}/.wb/vm.conf" && has "${out}" "stop timeout  90s, from stop_grace_period"'
: > "${CALLS}"; run stack-down vm
check "29 ... and stack-down passes -t 90" 'has "$(calls)" "-p vm -f compose.yaml down -t 90"'
run stack-import "${HOME}/src/vm" --name vm2 --stop-timeout 30
check "29 --stop-timeout 30 overrides it" 'grep -qx "STOP_TIMEOUT=30" "${ROOT}/.wb/vm2.conf" && has "${out}" "30s (--stop-timeout)"'
run stack-import "${HOME}/src/vm" --name vm3 --stop-timeout 0
check "29 --stop-timeout 0: status 2" '[ "${rc}" = 2 ] && [ ! -e "${ROOT}/vm3" ]'
run stack-import "${HOME}/src/vm" --name vm3 --stop-timeout abc
check "29 --stop-timeout abc: status 2" '[ "${rc}" = 2 ]'
run stack-import
check "29 no path: the usage and the stack-help import line, status 2" '[ "${rc}" = 2 ] && has "${out}" "Usage: stack-import" && has "${out}" "stack-help import walks through it."'
src "${HOME}/src/plain"; run stack-import "${HOME}/src/plain"
check "29 no stop_grace_period: an empty STOP_TIMEOUT and compose's default" 'grep -qx "STOP_TIMEOUT=" "${ROOT}/.wb/plain.conf" && has "${out}" "compose'"'"'s default (10s)"'
check "29 the seconds parser" '[ "$(_containers_seconds 1m30s)" = 90 ] && [ "$(_containers_seconds 1h)" = 3600 ] && [ "$(_containers_seconds 45)" = 45 ] && ! _containers_seconds 500ms >/dev/null'

# ── 30. override files ───────────────────────────────────────────────────────
fresh; src "${HOME}/src/ov"; src "${HOME}/src/ov" compose.override.yaml
run stack-import "${HOME}/src/ov"; : > "${CALLS}"
run stack-up ov
check "30 compose.yaml + compose.override.yaml: both -f" 'has "$(calls)" "-p ov -f compose.yaml -f compose.override.yaml up -d"'
check "30 ... and the import summary named the override" 'has "$(stack-import "${HOME}/src/ov" --name ov9 --dry-run 2>&1)" "(compose.yaml, + compose.override.yaml)"'
src "${HOME}/src/dov" docker-compose.yml; src "${HOME}/src/dov" docker-compose.override.yml
run stack-import "${HOME}/src/dov"; : > "${CALLS}"
run stack-up dov
check "30 docker-compose.yml + docker-compose.override.yml: both -f" 'has "$(calls)" "-p dov -f docker-compose.yml -f docker-compose.override.yml up -d"'
src "${HOME}/src/one"; run stack-import "${HOME}/src/one"; : > "${CALLS}"
run stack-up one
check "30 no override: a single -f" 'has "$(calls)" "-p one -f compose.yaml up -d" && ! has "$(calls)" "compose.yaml -f"'
run stack-compose ov exec web "echo a b"
check "30 an argument with a space reaches compose as one word" 'grep -qx "echo a b" "${CTL}/argv" && grep -qx "compose.override.yaml" "${CTL}/argv"'

# ── 31. stack-info ───────────────────────────────────────────────────────────
fresh; run stack-new windows --name win11
run stack-info win11
PW="$(grep '^WINDOWS_PASSWORD=' "${ROOT}/win11/.env" | cut -d= -f2-)"
check "31 a template stack: web URL, rdp, login and the password's place" 'has "${out}" "  web           http://127.0.0.1:8006/" && has "${out}" "  rdp           127.0.0.1:3389" && has "${out}" "  login         fakeuser; password: WINDOWS_PASSWORD in ${ROOT}/win11/.env"'
check "31 ... no password value, stop timeout 120s, origin template:windows, needs kvm" '! has "${out}" "${PW}" && has "${out}" "  stop timeout  120s" && has "${out}" "  origin        template:windows, created " && has "${out}" "  needs         kvm" && has "${out}" "  state         stopped" && has "${out}" "  volumes       none"'
check "31 ... compose line" 'has "${out}" "  compose       podman-compose, compose.yaml, project win11"'
printf 'WINDOWS_BIND=0.0.0.0\n' >> "${ROOT}/win11/.env"
run stack-info win11
check "31 WINDOWS_BIND=0.0.0.0: the URL shows 127.0.0.1" 'has "${out}" "http://127.0.0.1:8006/"'
mkdir -p "${HOME}/src/app"; printf 'services:\n  web:\n    image: x\n' > "${HOME}/src/app/compose.yaml"; printf 'WEB_PORT=8080\nDB_PORT=5432\n' > "${HOME}/src/app/.env"
run stack-import "${HOME}/src/app" --copy
run stack-info app
check "31 an imported, copied stack: ports lines from .env and from" 'has "${out}" "  ports         WEB_PORT=8080" && has "${out}" "  ports         DB_PORT=5432" && has "${out}" "  from          $(_containers_abs_dir "${HOME}/src/app")" && ! has "${out}" "linked to"'
run stack-import "${HOME}/src/app" --name applink
run stack-info applink
check "31 a linked stack: linked to" 'has "${out}" "  linked to     $(_containers_abs_dir "${HOME}/src/app")"'

# ── 32. stack-edit ───────────────────────────────────────────────────────────
fresh; run stack-new windows --name win11
D="${ROOT}/win11"
export EDITOR=fake-editor
: > "${CTL}/tty"; setctl answers 2
run stack-edit win11
check "32 both files, a terminal, answer 2: .env edited" '[ "${rc}" = 0 ] && grep -qx "# edited" "${D}/.env" && ! grep -qx "# edited" "${D}/compose.yaml" && has "$(cat "${CTL}/tty.out")" "Edit which file of win11?"'
check "32 ... and checked with config afterwards" 'has "$(calls)" "-p win11 -f compose.yaml config"'
src "${HOME}/src/solo"; run stack-import "${HOME}/src/solo" --link --yes; : > "${CTL}/tty.out"
run stack-edit solo
check "32 only the compose file: opened without a question" '[ "${rc}" = 0 ] && grep -qx "# edited" "${HOME}/src/solo/compose.yaml" && ! has "$(cat "${CTL}/tty.out")" "Edit which file"'
: > "${CTL}/tty.out"; : > "${CTL}/editor-args"
run stack-edit win11 env
check "32 stack-edit win11 env: .env without a question" 'grep -qx "${D}/.env" "${CTL}/editor-args" && ! has "$(cat "${CTL}/tty.out")" "Edit which file"'
run stack-edit win11 override
check "32 override when there's none: status 1" '[ "${rc}" = 1 ] && has "${out}" "no override file"'
run stack-edit win11 bogus
check "32 an unknown file word: status 2" '[ "${rc}" = 2 ]'
setctl editor-action chmod644
run stack-edit win11 env
check "32 the editor resets .env to 644: it is 600 again, and says so" 'mode600 "${D}/.env" && has "${out}" ".env is mode 600 again"'
setctl editor-action none; : > "${CALLS}"
run stack-edit win11 env
check "32 an unchanged file: no changes, config not run" '[ "${rc}" = 0 ] && has "${out}" "win11: no changes" && ! has "$(calls)" "config"'
setctl editor-action append; setctl config-rcs 1; setctl answers n
run stack-edit win11 compose
check "32 config failing, answer n: status 1 and the warning" '[ "${rc}" = 1 ] && has "${out}" "compose can'"'"'t read the stack as it is; stack-up will fail until it'"'"'s fixed"'
printf '1\n0\n' > "${CTL}/config-rcs"; setctl answers y; : > "${CTL}/editor-count"
run stack-edit win11 compose
check "32 config failing, answer y: the editor runs again" '[ "${rc}" = 0 ] && [ "$(grep -c x "${CTL}/editor-count")" = 2 ] && has "$(cat "${CTL}/tty.out")" "Edit again? [Y/n]"'
: > "${CTL}/editor-args"
EDITOR="fake-editor --flag" run stack-edit win11 compose
check "32 EDITOR with an argument: the flag and the file arrive as separate words" '[ "$(cat "${CTL}/editor-args")" = "--flag
${D}/compose.yaml
--" ]'
(
    WORKBENCH_STACKS_DIR="${HOME}/my stacks"
    run stack-new windows --name sp
    : > "${CTL}/editor-args"
    run stack-edit sp compose
    check "32 a path with a space is opened as one file" '[ "${rc}" = 0 ] && grep -qx "${HOME}/my stacks/sp/compose.yaml" "${CTL}/editor-args" && grep -qx "# edited" "${HOME}/my stacks/sp/compose.yaml"'
)
rm -f "${CTL}/tty"
run stack-edit win11 env
check "32 no terminal: status 1" '[ "${rc}" = 1 ] && has "${out}" "stack-edit needs a terminal"'
: > "${CTL}/tty"
EDITOR= VISUAL= run stack-edit win11 env
check "32 no VISUAL, EDITOR, nano, vim or vi: the editor error" '[ "${rc}" = 1 ] && has "${out}" "no editor found; set EDITOR (for example, EDITOR=nano)"'
VISUAL=fake-editor EDITOR=nosuch-editor run stack-edit win11 env
check "32 VISUAL wins over EDITOR" '[ "${rc}" = 0 ]'
printf 'abc123\n' > "${CTL}/ps-out"
run stack-edit win11 env
check "32 a running stack: the restart line" 'has "${out}" "win11: running; the change applies at the next start: stack-down win11 && stack-up win11"'
: > "${CTL}/ps-out"
unset EDITOR

# ── 33. stack-help ───────────────────────────────────────────────────────────
run stack-help
_all=1
for c in new import list info up down logs edit compose path rm help; do
    has "${out}" "stack-${c}" || _all=0
done
check "33 the overview lists all twelve commands, with the root" '[ "${_all}" = 1 ] && has "${out}" "under ${ROOT}." && [ "${rc}" = 0 ]'
run stack-help import
check "33 import has the --dry-run step" 'has "${out}" "1. Look first:   stack-import ~/src/myapp --dry-run"'
run stack-help templates
check "33 templates lists windows with its alias win" 'has "${out}" "windows (also: win)" && has "${out}" "stack-help templates windows for setup and access"'
run stack-help templates win
check "33 templates win prints windows' help.txt" 'has "${out}" "Windows (dockur/windows)" && has "${out}" "as drive Z:"'
run stack-help commands
check "33 commands: the table only" 'has "${out}" "stack-rm <name> [--purge]" && ! has "${out}" "More:"'
check "33 stack-help up prints the same as stack-up --help" '[ "$(stack-help up 2>&1)" = "$(stack-up --help 2>&1)" ] && [ "$(stack-help stack-import 2>&1)" = "$(stack-import --help 2>&1)" ]'
: > "${CALLS}"
run stack-help --full
check "33 --full runs wb module docs containers stacks" 'has "$(calls)" "wb|" && has "$(calls)" "|module docs containers stacks"'
run stack-help bogus
check "33 stack-help bogus: status 2" '[ "${rc}" = 2 ] && has "${out}" "no help on '"'"'bogus'"'"'"'
EOF

# ── D132 cases 26–28: test-only templates in a copy of the module ───────────
TPL_REPO="${WORK}/tpl-repo"
mkdir -p "${TPL_REPO}"
cp -R "${REPO_ROOT}/shell" "${REPO_ROOT}/stacks" "${TPL_REPO}/"
_tpl() {
    mkdir -p "${TPL_REPO}/stacks/templates/$1"
    printf 'services:\n  app:\n    image: x\n' > "${TPL_REPO}/stacks/templates/$1/compose.yaml"
    printf '%s\n' "$2" > "${TPL_REPO}/stacks/templates/$1/env.default"
    printf '%s\n' "$3" > "${TPL_REPO}/stacks/templates/$1/template.conf"
}
_tpl licenced 'LICENCED_X=1' 'DESCRIPTION=Test template with a licence
ALIASES=lic
REQUIRES=kvm avx2
ACCEPT=This software is licensed for use on hardware made by Apple only.
ACCEPT_VENDOR_CHECK=Apple Inc.'
_tpl nodisk 'NODISK_DISK_SIZE=64G' 'DESCRIPTION=Test template with a disk
DISK_VAR=NODISK_DISK_SIZE'
_tpl baddisk 'BADDISK_DISK_SIZE=lots' 'DESCRIPTION=Test template with an unparseable disk size
DISK_VAR=BADDISK_DISK_SIZE'
_tpl future 'FUTURE_X=1' 'DESCRIPTION=Test template needing something unknown
REQUIRES=kvm teleport'

cat > "${WORK}/scenario-tpl.sh" <<'EOF'
ROOT="${WORKBENCH_STACKS_DIR}"
export _CONTAINERS_KVM_DEV=/dev/null
export _CONTAINERS_CPUINFO="${HOME}/cpuinfo" _CONTAINERS_DMI_VENDOR_FILE="${HOME}/vendor"

# ── 26. REQUIRES lists ───────────────────────────────────────────────────────
fresh; printf 'flags\t\t: fpu sse2\n' > "${_CONTAINERS_CPUINFO}"
run stack-new licenced --accept
check "26 a CPU without avx2: refused, nothing created" '[ "${rc}" = 1 ] && has "${out}" "needs a CPU with AVX2" && [ ! -e "${ROOT}" ]'
printf 'flags\t\t: fpu sse2 avx2\n' > "${_CONTAINERS_CPUINFO}"
run stack-new lic --accept
check "26 with avx2 (and the alias lic): passes" '[ "${rc}" = 0 ] && grep -qx "ORIGIN=template:licenced" "${ROOT}/.wb/licenced.conf" && grep -qx "REQUIRES=kvm avx2" "${ROOT}/.wb/licenced.conf"'
run stack-new future
check "26 an unknown requirement: refused, with the update hint" '[ "${rc}" = 1 ] && has "${out}" "needs '"'"'teleport'"'"'" && has "${out}" "wb update containers" && [ ! -e "${ROOT}/future" ]'

# ── 27. ACCEPT ───────────────────────────────────────────────────────────────
fresh
run stack-new licenced
check "27 no terminal, no --accept: status 1, nothing created, not even the root" '[ "${rc}" = 1 ] && has "${out}" "needs its licence accepted; run on a terminal, or add --accept" && [ ! -e "${ROOT}" ]'
run stack-new licenced --accept
check "27 --accept: created, ACCEPTED is a timestamp, and the text was printed" '[ "${rc}" = 0 ] && grep -Eq "^ACCEPTED=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z\$" "${ROOT}/.wb/licenced.conf" && has "${out}" "licensed for use on hardware made by Apple only"'
fresh; : > "${CTL}/tty"; printf '\nn\n' > "${CTL}/answers"
run stack-new licenced
check "27 a terminal, answer n: not created" '[ "${rc}" = 1 ] && has "${out}" "licenced: not created" && [ ! -e "${ROOT}/licenced" ] && has "$(cat "${CTL}/tty.out")" "Accept and continue? [y/N] "'
printf '\ny\n' > "${CTL}/answers"
printf 'Apple Inc.\n' > "${_CONTAINERS_DMI_VENDOR_FILE}"
run stack-new licenced
check "27 answer y: created" '[ "${rc}" = 0 ] && [ -d "${ROOT}/licenced" ]'
check "27 a vendor file saying Apple Inc.: That matches" 'has "${out}" "This machine reports its maker as Apple Inc.. That matches Apple Inc.."'
rm -f "${CTL}/tty"; printf 'Framework\n' > "${_CONTAINERS_DMI_VENDOR_FILE}"
run stack-new licenced --accept --name l2
check "27 Framework: That isn't Apple Inc." 'has "${out}" "reports its maker as Framework. That isn'"'"'t Apple Inc."'
rm -f "${_CONTAINERS_DMI_VENDOR_FILE}"
run stack-new licenced --accept --name l3
check "27 no vendor file: doesn't report its maker" 'has "${out}" "This machine doesn'"'"'t report its maker."'

# ── 28. DISK_VAR ─────────────────────────────────────────────────────────────
fresh; setctl df-kib 10485760; setctl df-h 10G
run stack-new nodisk
check "28 10G free: the warning names 64G" '[ "${rc}" = 0 ] && has "${out}" "nodisk: the disk can grow to 64G, and ${ROOT} has 10G free"'
setctl df-kib 104857600; setctl df-h 100G
run stack-new nodisk --name nd2
check "28 100G free: no warning" '[ "${rc}" = 0 ] && ! has "${out}" "can grow to"'
setctl df-kib 10; setctl df-h 10K
run stack-new baddisk
check "28 an unparseable size: no warning, no error" '[ "${rc}" = 0 ] && ! has "${out}" "can grow to" && ! has "${out}" "ERROR"'
check "28 the size parser" '[ "$(_containers_kib 64G)" = 67108864 ] && [ "$(_containers_kib 512M)" = 524288 ] && ! _containers_kib 64 >/dev/null'
EOF

# run_scenario <shell> <scenario-name> <script> <PATH-dirs> [VAR=value ...]
# Everything runs in a fresh HOME, with $CTL and $CALLS inside it. The
# scenario runs in the background with stdin closed and its output in a file,
# under a watchdog (SCENARIO_TIMEOUT seconds, default 300): a hang fails the
# scenario, and shows the last check that finished, instead of stalling the
# whole job. Output is read back once the scenario ends or is killed.
SCENARIO_TIMEOUT="${SCENARIO_TIMEOUT:-300}"
run_scenario() {
    local _sh="$1" _name="$2" _script="$3" _path="$4"; shift 4
    local _home="${WORK}/home-${_sh##*/}-${_name}" _log _line _pid _waited=0 _timed_out="" _last=""
    # shellcheck disable=SC2016  # expanded by the child shell
    local _body='. "$1"; . "$2"'
    mkdir -p "${_home}"
    _log="${_home}.out"
    echo "RUN:  [${_sh##*/}] ${_name}"
    env -i HOME="${_home}" PATH="${_path}:${HOSTBIN}" \
        REPO_ROOT="${REPO_ROOT}" SCENARIO="${_name}" \
        XDG_DATA_HOME="${_home}/xdg" WORKBENCH_STACKS_DIR="${_home}/stacks" \
        CTL="${_home}/ctl" CALLS="${_home}/calls" \
        WORKBENCH_OS=Linux WORKBENCH_ARCH=x86_64 \
        _CONTAINERS_KVM_DEV=/dev/null "$@" \
        "${_sh}" -c "${_body}" _ "${WORK}/prelude.sh" "${_script}" >"${_log}" 2>&1 </dev/null &
    _pid=$!
    while kill -0 "${_pid}" 2>/dev/null; do
        if [[ "${_waited}" -ge "${SCENARIO_TIMEOUT}" ]]; then
            _timed_out=1
            kill "${_pid}" 2>/dev/null
            sleep 1
            kill -9 "${_pid}" 2>/dev/null
            break
        fi
        sleep 1
        _waited=$((_waited + 1))
    done
    wait "${_pid}" 2>/dev/null
    if [[ ! -s "${_log}" && -z "${_timed_out}" ]]; then
        fail "[${_sh##*/}] ${_name}: scenario printed nothing"
        return
    fi
    while IFS= read -r _line; do
        case "${_line}" in
            PASS:*) ok "[${_sh##*/}] ${_line#PASS:}"; _last="${_line#PASS:}" ;;
            BAD:*)  fail "[${_sh##*/}] ${_line#BAD:}"; _last="${_line#BAD:}" ;;
            *)      fail "[${_sh##*/}] ${_name}: unexpected output: ${_line}" ;;
        esac
    done < "${_log}"
    if [[ -n "${_timed_out}" ]]; then
        fail "[${_sh##*/}] ${_name}: no result after ${SCENARIO_TIMEOUT}s, killed; the last check to finish was: ${_last:-<none>}"
    fi
}

# A scenario that needs its control directory set up before the script runs.
# (The resolve scenarios don't call `fresh`, so give them an empty one.)
cat > "${WORK}/scenario-prep.sh" <<'EOF'
mkdir -p "${CTL}"; : > "${CALLS}"
EOF
cat "${WORK}/scenario-prep.sh" "${WORK}/scenario-resolve.sh" > "${WORK}/scenario-resolve-run.sh"

# 21, older core (D132): without workbench_complete, stacks.sh loads
# silently, registers no completion, and the commands still work.
cat > "${WORK}/scenario-nocomplete.sh" <<'EOF'
check "21 older core: no workbench_complete, and sourcing stacks.sh printed nothing" '! command -v workbench_complete >/dev/null 2>&1 && [ ! -s "${HOME}/stacks-source.err" ]'
check "21 older core: no completion registered" '[ -z "${COMPLETE_CALLS}" ]'
run stack-help
check "21 older core: the commands still work (stack-help)" '[ "${rc}" = 0 ] && has "${out}" "stack-import"'
EOF

shells="$(command -v bash)"
if command -v zsh &>/dev/null; then
    shells="${shells} $(command -v zsh)"
else
    echo "SKIP: zsh not installed — zsh runs of these checks skipped"
fi

for sh in ${shells}; do
    run_scenario "${sh}" main "${WORK}/scenario-main.sh" "${BIN_DEFAULT}:${BIN_BTRFS}"
    # 3, last case: SUBVOLUME=yes with no btrfs binary.
    cat > "${WORK}/scenario-nobtrfs.sh" <<'EOF'
fresh; setctl fstype btrfs
WORKBENCH_STACKS_SUBVOLUME=yes run _containers_stacks_root_ensure
check "3 btrfs, SUBVOLUME=yes, no btrfs binary: a warning and a plain folder" '[ "${rc}" = 0 ] && has "${out}" "is btrfs-progs installed?" && [ -d "${WORKBENCH_STACKS_DIR}" ]'
EOF
    run_scenario "${sh}" nobtrfs "${WORK}/scenario-nobtrfs.sh" "${BIN_DEFAULT}"
    # The secret with a tr that only answers once its input ends.
    cat > "${WORK}/scenario-secret.sh" <<'EOF'
check "secret: a tr that reads its whole input still gets a finite one (20 characters)" '[ "$(_containers_random_secret)" = "abcdefghijklmnopqrst" ]'
EOF
    run_scenario "${sh}" secret "${WORK}/scenario-secret.sh" "${BIN_SLOWTR}"

    # 2: compose tool resolution, one scenario per PATH.
    run_scenario "${sh}" resolve-podman-first "${WORK}/scenario-resolve-run.sh" "${BIN_DEFAULT}:${BIN_DC}"
    run_scenario "${sh}" resolve-docker-plugin "${WORK}/scenario-resolve-run.sh" "${BIN_DOCKER_REAL}" DOCKER_CONFIG="${WORK}/dockercfg"
    run_scenario "${sh}" resolve-shim "${WORK}/scenario-resolve-run.sh" "${BIN_PODMAN_ONLY}:${BIN_DOCKER_SHIM}:${BIN_DC}"
    run_scenario "${sh}" resolve-bogus "${WORK}/scenario-resolve-run.sh" "${BIN_DEFAULT}" WORKBENCH_STACKS_COMPOSE=bogus
    run_scenario "${sh}" resolve-override "${WORK}/scenario-resolve-run.sh" "${BIN_DEFAULT}:${BIN_DC}" WORKBENCH_STACKS_COMPOSE=docker-compose
    run_scenario "${sh}" resolve-none "${WORK}/scenario-resolve-run.sh" "${BIN_EMPTY}"
    run_scenario "${sh}" resolve-podman-nocompose "${WORK}/scenario-resolve-run.sh" "${BIN_PODMAN_ONLY}"

    # 20–25 and 29–33 (D132), and 26–28 against the test-only templates.
    run_scenario "${sh}" d132 "${WORK}/scenario-d132.sh" "${BIN_DEFAULT}:${BIN_TOOLS}"
    run_scenario "${sh}" templates "${WORK}/scenario-tpl.sh" "${BIN_DEFAULT}:${BIN_TOOLS}" REPO_ROOT="${TPL_REPO}"
    # 21, older core: no workbench_complete.
    run_scenario "${sh}" no-complete "${WORK}/scenario-nocomplete.sh" "${BIN_DEFAULT}:${BIN_TOOLS}" NO_COMPLETE_STUB=1
done

# ── 17. template structure ───────────────────────────────────────────────────
# Static: reads the real templates. Every template, so a new one (macOS) is
# held to the same rules.
TEMPLATES="${REPO_ROOT}/stacks/templates"
code_of() { grep -v '^[[:space:]]*#' "$1"; }
# items_under <file> <key> — the "- ..." items directly under a key at the
# service level (four spaces).
items_under() {
    awk -v key="$2" '
        $0 ~ "^    " key ":[[:space:]]*$" { inside = 1; next }
        inside && /^      - / { sub(/^      - /, ""); print; next }
        inside { inside = 0 }
    ' "$1"
}
template_dirs="$(find "${TEMPLATES}" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)"
[[ -n "${template_dirs}" ]] && ok "17 the module ships at least one template" || fail "17 no template under stacks/templates"
while IFS= read -r tdir; do
    [[ -n "${tdir}" ]] || continue
    tname="$(basename "${tdir}")"
    prefix="$(printf '%s' "${tname}" | tr 'a-z-' 'A-Z_')_"
    compose="${tdir}/compose.yaml"
    env_default="${tdir}/env.default"
    conf="${tdir}/template.conf"
    for f in "${compose}" "${env_default}" "${conf}"; do
        [[ -f "${f}" ]] && ok "17 ${tname}: $(basename "${f}") exists" || fail "17 ${tname}: $(basename "${f}") is missing"
    done
    [[ -f "${compose}" && -f "${env_default}" && -f "${conf}" ]] || continue

    code_of "${compose}" | grep -q 'container_name' && fail "17 ${tname}: compose.yaml sets container_name" || ok "17 ${tname}: no container_name"
    code_of "${compose}" | grep -q '/dev/net/tun' && fail "17 ${tname}: compose.yaml uses /dev/net/tun" || ok "17 ${tname}: no /dev/net/tun"
    code_of "${compose}" | grep -q 'cap_add' && fail "17 ${tname}: compose.yaml has cap_add" || ok "17 ${tname}: no cap_add"
    code_of "${compose}" | grep -qE "NETWORK:[[:space:]]*\\$\\{${prefix}NETWORK:-user\\}" && ok "17 ${tname}: NETWORK: \${${prefix}NETWORK:-user}" || fail "17 ${tname}: NETWORK is not \${${prefix}NETWORK:-user}"
    code_of "${compose}" | grep -qE '^[[:space:]]+restart:[[:space:]]*unless-stopped[[:space:]]*$' && ok "17 ${tname}: restart: unless-stopped" || fail "17 ${tname}: not restart: unless-stopped"

    bad_ports=""
    n_ports=0
    while IFS= read -r item; do
        [[ -n "${item}" ]] || continue
        n_ports=$((n_ports + 1))
        case "${item}" in "\${${prefix}BIND:-127.0.0.1}:"*) ;; *) bad_ports="${bad_ports} ${item}" ;; esac
    done < <(items_under "${compose}" ports)
    [[ "${n_ports}" -gt 0 && -z "${bad_ports}" ]] && ok "17 ${tname}: every ports: entry starts with \${${prefix}BIND:-127.0.0.1}: (${n_ports})" || fail "17 ${tname}: ports: entries not on \${${prefix}BIND:-127.0.0.1}:${bad_ports}"

    bad_mounts=""
    n_mounts=0
    while IFS= read -r item; do
        [[ -n "${item}" ]] || continue
        n_mounts=$((n_mounts + 1))
        case "${item}" in *:Z) ;; *) bad_mounts="${bad_mounts} ${item}" ;; esac
    done < <(items_under "${compose}" volumes)
    [[ "${n_mounts}" -gt 0 && -z "${bad_mounts}" ]] && ok "17 ${tname}: every mount ends in :Z (${n_mounts})" || fail "17 ${tname}: mounts without :Z:${bad_mounts}"

    bad_vars=""
    while IFS= read -r v; do
        [[ -n "${v}" ]] || continue
        case "${v}" in "${prefix}"*) ;; *) bad_vars="${bad_vars} ${v}" ;; esac
    done < <(code_of "${compose}" | grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*' | sed 's/^\${//' | sort -u)
    [[ -z "${bad_vars}" ]] && ok "17 ${tname}: every \${...} in compose.yaml is a ${prefix}* variable" || fail "17 ${tname}: variables without the ${prefix} prefix:${bad_vars}"

    bad_vars=""
    while IFS= read -r v; do
        [[ -n "${v}" ]] || continue
        case "${v}" in "${prefix}"*) ;; *) bad_vars="${bad_vars} ${v}" ;; esac
    done < <(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "${env_default}" | sed 's/=$//')
    [[ -z "${bad_vars}" ]] && ok "17 ${tname}: every variable in env.default is a ${prefix}* variable" || fail "17 ${tname}: env.default variables without the ${prefix} prefix:${bad_vars}"

    keys_ok=1
    for key in DESCRIPTION REQUIRES DIRS NOCOW_DIRS BIND_VAR PORTS LOGIN_VARS SECRET_VARS STOP_TIMEOUT NOTE; do
        grep -qE "^${key}=" "${conf}" || { keys_ok=0; fail "17 ${tname}: template.conf has no ${key}="; }
    done
    [[ "${keys_ok}" = 1 ]] && ok "17 ${tname}: template.conf has every key"

    bad_vars=""
    for key in BIND_VAR PORTS LOGIN_VARS SECRET_VARS; do
        value="$(grep -E "^${key}=" "${conf}" | tail -n 1 | cut -d= -f2-)"
        for word in ${value}; do
            word="${word%%:*}"
            case "${word}" in "${prefix}"*) ;; *) bad_vars="${bad_vars} ${key}:${word}" ;; esac
        done
    done
    [[ -z "${bad_vars}" ]] && ok "17 ${tname}: BIND_VAR, PORTS, LOGIN_VARS and SECRET_VARS all name ${prefix}* variables" || fail "17 ${tname}: template.conf variables without the ${prefix} prefix:${bad_vars}"
done <<< "${template_dirs}"

# 17 (D132): the Windows template's new keys and help.txt, and every alias a
# valid stack name used once, never another template's folder name.
WIN_CONF="${TEMPLATES}/windows/template.conf"
grep -qx 'ALIASES=win' "${WIN_CONF}" && grep -qx 'DISK_VAR=WINDOWS_DISK_SIZE' "${WIN_CONF}" \
    && ok "17 windows: ALIASES=win and DISK_VAR=WINDOWS_DISK_SIZE" || fail "17 windows: ALIASES or DISK_VAR missing"
[[ -s "${TEMPLATES}/windows/help.txt" ]] && ok "17 windows: help.txt exists" || fail "17 windows: help.txt is missing"
grep -q '^WINDOWS_DISK_SIZE=' "${TEMPLATES}/windows/env.default" \
    && ok "17 windows: DISK_VAR names a variable env.default sets" || fail "17 windows: env.default has no WINDOWS_DISK_SIZE"
all_aliases="$(cat "${TEMPLATES}"/*/template.conf | grep -E '^ALIASES=' | cut -d= -f2- | tr -s ' ' '\n' | grep -v '^$')"
bad_aliases=""
while IFS= read -r a; do
    [[ -n "${a}" ]] || continue
    [[ "${a}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || bad_aliases="${bad_aliases} ${a}(name)"
    [[ -d "${TEMPLATES}/${a}" ]] && bad_aliases="${bad_aliases} ${a}(folder)"
done <<< "${all_aliases}"
dupes="$(printf '%s\n' "${all_aliases}" | sort | uniq -d)"
[[ -z "${bad_aliases}" && -z "${dupes}" ]] && ok "17 every alias is a valid stack name, used once, and no template's folder name" || fail "17 bad aliases:${bad_aliases} ${dupes}"

echo
echo "==============================="
echo "Total OK/FAIL checks: ${check_no}, failed: ${FAILED}"
echo "==============================="
[[ "${FAILED}" -eq 0 ]]
