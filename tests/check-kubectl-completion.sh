#!/usr/bin/env bash
# tests/check-kubectl-completion.sh — workbench-containers
# shell/completions/kubernetes.sh in a real interactive zsh with no
# workbench-shell and no compinit of its own. Plain bash, numbered
# OK:/FAIL: checks, no framework. No network: kubectl is a fake whose
# `completion zsh` prints the same shape of script as the real one
# (`#compdef kubectl`, then `compdef _kubectl kubectl`), checked against
# kubectl 1.37 in zsh 5.9.
#
#   - the file runs compinit itself when nothing else has, so
#     kubectl is registered with no workbench-shell (workbench-containers#28);
#   - a user's own plain `compinit` AFTER this file resets zsh's completion
#     table; the file puts the registration back before the first prompt;
#   - a user's compinit BEFORE this file needs nothing extra;
#   - the one-shot hook removes itself after the first prompt;
#   - bash still registers completion for the `k` alias.
#
# Needs zsh; skipped without it.
# shellcheck disable=SC2016  # probe commands are for the zsh under test, not this shell
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
COMPLETION="${REPO_ROOT}/shell/completions/kubernetes.sh"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

WORK="$(mktemp -d)" || { echo "FAIL: mktemp -d failed"; exit 1; }
trap 'rm -rf "${WORK}"' EXIT

# Host tools the scripts call, linked into a PATH of their own so the real
# host's kubectl and docker stay out of it. compinit needs mv, ls and
# friends to write its dump; without mv it writes none, which changes what
# a second compinit does and hides the failure this suite is here to catch.
BIN="${WORK}/bin"
mkdir -p "${BIN}"
for _t in mkdir rm mv ls cp grep head sed cat dirname basename sort uname tr; do
    _p="$(command -v "${_t}")" || continue
    ln -s "${_p}" "${BIN}/${_t}"
done

cat > "${BIN}/kubectl" <<'EOF'
#!/bin/sh
case "$*" in
    "version --client -o json")
        printf '{\n  "clientVersion": {\n    "gitVersion": "v1.99.0"\n  }\n}\n' ;;
    "completion zsh")
        printf '#compdef kubectl\ncompdef _kubectl kubectl\n\n_kubectl() { :; }\n' ;;
    "completion bash")
        printf '__start_kubectl() { :; }\n' ;;
esac
EOF
chmod +x "${BIN}/kubectl"

if ! ZSH="$(command -v zsh)"; then
    echo "SKIP: zsh not installed — nothing to check"
    exit 0
fi

# run_zsh <name> <.zshrc body> — starts an interactive zsh whose .zshrc is
# the body, feeds it the probe commands on stdin (so precmd runs before
# each), and prints what the probes print.
run_zsh() {
    local rc="$2" home="${WORK}/home-$1"
    mkdir -p "${home}"
    printf 'PROMPT=\n%s\n' "${rc}" > "${home}/.zshrc"
    # shellcheck disable=SC2016  # expanded by the zsh under test
    printf '%s\n' \
        'print "KUBECTL:${_comps[kubectl]:-unset}"' \
        'print "COMPDEF:${+functions[compdef]}"' \
        'print "HOOK:${precmd_functions[(r)_containers_kubectl_completion_rearm]:-gone}"' \
        'exit' \
        | env -i HOME="${home}" ZDOTDIR="${home}" PATH="${BIN}" TERM=dumb \
            WORKBENCH_SHELL=zsh WORKBENCH_OS=Linux \
            "${ZSH}" -d -i 2>&1 | sed -n 's/.*\(\(KUBECTL\|COMPDEF\|HOOK\):.*\)$/\1/p'
}

expect() {
    local description="$1" output="$2" wanted="$3"
    if printf '%s\n' "${output}" | grep -qx -- "${wanted}"; then
        ok "${description}"
    else
        fail "${description} (wanted '${wanted}', got: $(printf '%s' "${output}" | tr '\n' ' '))"
    fi
}

out="$(run_zsh bare "source ${COMPLETION}")"
expect "no compinit anywhere: kubectl is registered" "${out}" "KUBECTL:_kubectl"
expect "no compinit anywhere: the file initialised completion (compdef exists)" "${out}" "COMPDEF:1"
expect "no compinit anywhere: the one-shot hook removed itself" "${out}" "HOOK:gone"

out="$(run_zsh after "source ${COMPLETION}
autoload -Uz compinit
compinit")"
expect "user compinit AFTER the file: kubectl is registered again" "${out}" "KUBECTL:_kubectl"
expect "user compinit AFTER the file: the one-shot hook removed itself" "${out}" "HOOK:gone"

out="$(run_zsh before "autoload -Uz compinit
compinit
source ${COMPLETION}")"
expect "user compinit BEFORE the file: kubectl is registered" "${out}" "KUBECTL:_kubectl"
expect "user compinit BEFORE the file: the one-shot hook removed itself" "${out}" "HOOK:gone"

# A shell started a second time reuses the cached completion script and the
# existing completion dump.
home="${WORK}/home-again"
mkdir -p "${home}"
printf 'PROMPT=\nsource %s\n' "${COMPLETION}" > "${home}/.zshrc"
for _round in first second; do
    out="$(printf '%s\n' 'print "KUBECTL:${_comps[kubectl]:-unset}"' 'exit' \
        | env -i HOME="${home}" ZDOTDIR="${home}" PATH="${BIN}" TERM=dumb \
            WORKBENCH_SHELL=zsh WORKBENCH_OS=Linux "${ZSH}" -d -i 2>&1 \
        | sed -n 's/.*\(KUBECTL:.*\)$/\1/p')"
    expect "${_round} shell in the same HOME: kubectl is registered" "${out}" "KUBECTL:_kubectl"
done

# bash: the `k` alias gets kubectl's completion function.
home="${WORK}/home-bash"
mkdir -p "${home}"
out="$(env -i HOME="${home}" PATH="${BIN}" WORKBENCH_SHELL=bash \
    "${BASH}" -c "source '${COMPLETION}'; complete -p k 2>&1")"
if printf '%s' "${out}" | grep -q -- '-F __start_kubectl k'; then
    ok "bash: the k alias completes with __start_kubectl"
else
    fail "bash: the k alias completes with __start_kubectl (got: ${out})"
fi

echo
echo "==============================="
echo "Total OK/FAIL checks: ${check_no}, failed: ${FAILED}"
echo "==============================="
[[ "${FAILED}" -eq 0 ]]
