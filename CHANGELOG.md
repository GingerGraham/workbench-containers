# Changelog

All notable changes to `workbench-containers` are documented here.

## [Unreleased]

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
