# Changelog

All notable changes to `workbench-containers` are documented here.

## [Unreleased]

### Added

- **`wb tools install kubectl`.** A new `install-kubectl` installer runs
  `set-kubectl -l`: the latest stable kubectl, SHA-256 verified, linked at
  `~/.local/bin/kubectl`. `k` and `kube-version` are now listed only when
  `kubectl` exists, and the listing names that installer.

### Changed

- **`dc` is chosen when the shell starts**: `DOCKER_COMPOSE_CMD` if set,
  otherwise `docker-compose`, otherwise `podman-compose`. Previously it
  always ran `docker-compose` unless `DOCKER_COMPOSE_CMD` was set, even on a
  host with only `podman-compose`. Change `DOCKER_COMPOSE_CMD` in a new shell
  (or reload) for it to take effect.

### Fixed

- **The Docker aliases need a real `docker` binary.** On a podman-only host,
  this module's own `docker=podman` alias made `command -v docker` true in
  zsh (and interactive bash), so `d`, `dps`, `dpsa`, `di`, `drm`, `drmi`,
  `dex` and `dlog` were listed and, on reload, defined. They now check for
  the binary, ignoring aliases, and so does the `docker=podman` alias itself.
  Each declaration says what it needs, so `wb functions` gives a reason for
  every hidden name.
- **`set-kubectl` called twice in one shell used the first version.** It now
  keeps its own `OPTIND`, so a second `set-kubectl -v <version>` parses its
  options.
- **`set-kubectl` no longer removes or renames a kubectl outside
  `~/.local/bin`.** It used to `rm` (if a symlink) or `mv` aside whichever
  kubectl came first on `PATH`, including Homebrew's or a distro package's.
  It now replaces only `~/.local/bin/kubectl`, checks that the link was
  made, and warns if another kubectl still comes first on `PATH`.

- **`get-containers-functions` lists names in zsh.** The hand-written getter
  read `${BASH_SOURCE[0]}` inside the function, which zsh doesn't set, so in
  zsh it printed `(none)`. It is deleted; workbench-core now generates the
  getter from `register.getters[]` (core D89), reading the module's
  registered files in bash and zsh alike. The listing's headers now read
  `Docker/Podman/Kubernetes helpers — functions:` / `— aliases:` (the
  manifest label), and the getter no longer lists itself. `workbench.yml`'s
  `core_api` floor rises to `>=1.8 <2.0`.
- README: `install-helm` is run with `wb tools install helm` (or
  `wb tools upgrade helm`), not the removed `wb tools update`.

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
