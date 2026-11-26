#!/usr/bin/env bash
# tests/check-stacks-docs.sh — workbench-containers
# Case 34 of the stack checks (docs/decisions-log.md D132 in workbench-core):
# the stack docs keep up with the code. docs/stacks.md mentions every public
# stack-* function, every WORKBENCH_STACKS_* setting and both stack-help
# topics; docs/stack-templates.md every template.conf key a shipped template
# uses, and help.txt; README.md links to both. Plain bash, numbered OK:/FAIL:
# checks, no framework.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
STACKS_SH="${REPO_ROOT}/shell/stacks.sh"
GUIDE="${REPO_ROOT}/docs/stacks.md"
CONTRACT="${REPO_ROOT}/docs/stack-templates.md"
README="${REPO_ROOT}/README.md"

FAILED=0
check_no=0
ok()   { check_no=$((check_no + 1)); echo "OK:   [$check_no] $*"; }
fail() { check_no=$((check_no + 1)); echo "FAIL: [$check_no] $*"; FAILED=$((FAILED + 1)); }

for f in "${GUIDE}" "${CONTRACT}"; do
    if [[ -s "${f}" ]]; then
        ok "34 ${f#"${REPO_ROOT}"/} exists"
    else
        fail "34 ${f#"${REPO_ROOT}"/} is missing"
    fi
done

# Every public function: a line starting "stack-<name>() {".
missing=""
n=0
while IFS= read -r fn; do
    [[ -n "${fn}" ]] || continue
    n=$((n + 1))
    grep -qF -- "${fn}" "${GUIDE}" 2>/dev/null || missing="${missing} ${fn}"
done < <(grep -oE '^stack-[a-z]+\(\)' "${STACKS_SH}" | sed 's/()$//' | sort -u)
if [[ "${n}" -eq 12 && -z "${missing}" ]]; then
    ok "34 docs/stacks.md mentions all ${n} stack-* functions"
else
    fail "34 docs/stacks.md: ${n} functions found (12 expected), not mentioned:${missing}"
fi

missing=""
n=0
while IFS= read -r var; do
    [[ -n "${var}" ]] || continue
    n=$((n + 1))
    grep -qF -- "${var}" "${GUIDE}" 2>/dev/null || missing="${missing} ${var}"
done < <(grep -oE 'WORKBENCH_STACKS_[A-Z_]+' "${STACKS_SH}" | sort -u)
if [[ "${n}" -gt 0 && -z "${missing}" ]]; then
    ok "34 docs/stacks.md mentions every WORKBENCH_STACKS_* setting (${n})"
else
    fail "34 docs/stacks.md doesn't mention:${missing}"
fi

if grep -qF 'stack-help import' "${GUIDE}" && grep -qF 'stack-help templates' "${GUIDE}"; then
    ok "34 docs/stacks.md mentions stack-help import and stack-help templates"
else
    fail "34 docs/stacks.md is missing a stack-help topic"
fi

missing=""
n=0
while IFS= read -r key; do
    [[ -n "${key}" ]] || continue
    n=$((n + 1))
    grep -qF -- "\`${key}\`" "${CONTRACT}" 2>/dev/null || missing="${missing} ${key}"
done < <(find "${REPO_ROOT}/stacks/templates" -mindepth 2 -maxdepth 2 -name template.conf -type f -exec grep -hoE '^[A-Z_]+=' {} + | sed 's/=$//' | sort -u)
if [[ "${n}" -gt 0 && -z "${missing}" ]]; then
    ok "34 docs/stack-templates.md documents every template.conf key the templates use (${n})"
else
    fail "34 docs/stack-templates.md doesn't document:${missing}"
fi
if grep -qF 'help.txt' "${CONTRACT}"; then
    ok "34 docs/stack-templates.md documents help.txt"
else
    fail "34 docs/stack-templates.md doesn't mention help.txt"
fi

if grep -qF '](docs/stacks.md)' "${README}" && grep -qF '](docs/stack-templates.md)' "${README}"; then
    ok "34 README.md links to docs/stacks.md and docs/stack-templates.md"
else
    fail "34 README.md doesn't link to both stack docs"
fi

echo
echo "==============================="
echo "Total OK/FAIL checks: ${check_no}, failed: ${FAILED}"
echo "==============================="
[[ "${FAILED}" -eq 0 ]]
