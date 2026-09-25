# Changelog

All notable changes to `workbench-containers` are documented here.

## [Unreleased]

## [0.3.1] - 2026-09-25

### Fixed

- **Helm installed from a verified release tarball, not `get-helm-3` from
  helm's `main` branch** (security review M3). `_helm-install-linux` now
  downloads `get.helm.sh`'s official `helm-v<version>-linux-<arch>.tar.gz`
  and verifies it against the published `.sha256sum` via workbench-core's
  `_wb_fetch_verified` (`CORE_API_VERSION` 1.4) before installing — refusing
  to proceed on a hash mismatch, rather than silently skipping verification
  when `openssl` was missing. Installs the requested version into
  `~/.local/bin/k8s/helm-<version>` (previously `/usr/local/bin` via `sudo`,
  and the wrong version — the old script ignored the version it was given).
  No longer `cd`s the caller's interactive shell. `install-helm`'s latest-version
  lookup now fails loudly (`curl -fsS`) instead of silently on an HTTP error.
  Requires `workbench.yml`'s `core_api` floor raised to `>=1.4 <2.0`.
  `install-helm`'s latest-version lookup now checks `curl`'s own exit
  status directly (rather than a `curl | grep | sed` pipeline's last-command
  status, which stayed 0 even when `curl` failed), and `_helm-install-linux`
  now checks the `install`/`ln` steps instead of reporting success
  regardless of whether the binary actually landed.
- **`set-kubectl` fails on HTTP errors and verifies its download** (security
  review M3). Previously downloaded with `curl -sSL` and no `--fail`, so a
  404/5xx error body was saved as `kubectl` and made executable — and once
  saved, the `[[ ! -f ]]` guard meant it was never replaced on a later
  attempt. Now downloads via workbench-core's `_wb_fetch_verified`
  (`CORE_API_VERSION` 1.4), verified against `dl.k8s.io`'s published
  `.sha256`, and refuses to leave a non-executable file in place. Also adds
  a sanity check (`kubectl version --client`) after download, removing the
  file and asking the user to re-run if it fails — this catches a bad file
  left behind by the pre-fix version on an existing host, which the
  existing executable-bit check alone can't detect. The "latest" lookup
  moves off the legacy `storage.googleapis.com/kubernetes-release` bucket
  to `dl.k8s.io` and now fails loudly on an HTTP error instead of silently.

## [0.3.0] - 2026-09-23

### Added

- **Manual `workflow_dispatch` release override.** `release.yml` now
  accepts a `bump_type` (patch/minor/major) input to force a release
  through `workbench-core`'s reusable `module-release.yml`, regardless of
  what Conventional Commits since the last tag would compute — a floor,
  never a downgrade of a higher severity already pending. Manual dispatch
  only runs from `main`. See `workbench-core`'s `docs/decisions-log.md` D67.

## [0.2.1] - 2026-09-16

### Fixed

- **Docker/Podman alias listings gated on tool availability** —
  `get-containers-functions` (and `wb functions`) no longer list the
  `d`/`dps`/`dpsa`/`di`/`drm`/`drmi`/`dex`/`dlog` docker aliases or the
  `pd`/`pdps`/`pdpsa`/`pdi` podman aliases on a host missing the
  corresponding tool — each set is only ever defined inside its own
  `command -v` guard in `shell/containers.sh`, but the listing's
  static-grep view couldn't see that runtime guard until now. Declared
  via `_wb_declare_availability` (`workbench-core`'s
  `docs/module-authoring.md` "Declaring function availability" once
  that PR lands). The docker-vs-podman backend-selection aliases
  (`docker` shim, `dc` compose) are unaffected — they already work
  with either tool.

### Added

- **Agent-instruction files** (`AGENTS.md`, `CLAUDE.md`,
  `.github/copilot-instructions.md`,
  `.claude/skills/conventional-commits/SKILL.md`) — ports
  `workbench-core`'s D32 agent-instruction topology to this repo. See
  `workbench-core`'s `docs/decisions-log.md` D58.
- **Repo governance files** (`.github/PULL_REQUEST_TEMPLATE.md`,
  `.github/ISSUE_TEMPLATE/{bug_report,feature_request,config}.yml`,
  `.github/CODEOWNERS`, `CONTRIBUTING.md`, `SECURITY.md`) — ports
  `workbench-core`'s D31 governance-file topology to this repo,
  piloted on `workbench-git` first. See `workbench-core`'s
  `docs/decisions-log.md` D60.

## [0.2.0] - 2026-09-09

### Added

- Added `installed-helm` — reports install status to `wb tools upgrade`/
  `wb tools list --status` (workbench-core §12 D43).

## [0.1.0] - 2026-09-09

### Added

- Initial decomposition from `workbench-precursor` (Wave C): Docker/Podman
  aliases, `k`/`kube-version`/`set-kubectl`, kubectl shell completions, and
  `install-helm`, split out of the precursor's grab-bag `installers-iac.sh`
  (Helm is grouped here rather than `workbench-iac` since it operates
  specifically on Kubernetes clusters).

### Fixed

- `set-kubectl` hardcoded `amd64` in its download URL, silently producing
  a non-executable binary on arm64. Now resolves the correct architecture
  from `WORKBENCH_ARCH` (Core API platform fact).

### Changed

- `WORKBENCH_OS`/`WORKBENCH_ARCH`/`WORKBENCH_SHELL` replace
  `DOTFILES_OS`/`DOTFILES_SHELL`.
