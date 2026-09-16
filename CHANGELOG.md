# Changelog

All notable changes to `workbench-containers` are documented here.

## [Unreleased]

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
