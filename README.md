# fedora-coreos-config-konflux-testing

This repository is a fork of [coreos/fedora-coreos-config](https://github.com/coreos/fedora-coreos-config)
used for testing Fedora CoreOS builds with [Konflux](https://konflux-ci.dev/).

## Why a separate repository?

A separate repository (with a different name than upstream) is required because the `.tekton/`
directory contains Konflux-specific configurations that are tied to the upstream repository.
By maintaining a separate fork, we can:

- Use our own Konflux pipelines in `.tekton/`
- Test builds independently from upstream
- Keep our CI/CD configuration separate

## Syncing from upstream

This repository is synced from upstream using `sync-upstream.sh` (available on the `testing-devel` branch).

**Synced branches:** `testing-devel`, `rawhide`

**Excluded from sync (preserved locally):**
- `.tekton/` - Custom Konflux pipelines
- `.github/` - Custom GitHub workflows
- `README.md` - This file
- `sync-upstream.sh` - The sync script (only on `testing-devel`)

### Usage

```bash
# Sync all branches
./sync-upstream.sh

# Sync a specific branch
./sync-upstream.sh testing-devel

# Dry run
./sync-upstream.sh -n
```

The script rebases local commits on top of upstream changes, preserving your commit history.

## Upstream documentation

For documentation about the Fedora CoreOS configuration itself, see the
[upstream repository](https://github.com/coreos/fedora-coreos-config).
