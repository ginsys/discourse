# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Automated build system for creating Discourse Docker images optimized for Kubernetes deployment. Tracks upstream `discourse/discourse_docker` via git submodule (no fork), builds images that don't require DB/Redis at build time, and automates builds when new upstream versions are released.

## Key Commands

### Testing
```bash
# Quick validation test (runs in CI on every push/PR)
./scripts/test-k8s-bootstrap-validation

# Full integration test (requires Docker, slow - creates actual image)
./scripts/test-k8s-bootstrap
```

### Building Locally
```bash
# Build with default plugins (none)
./scripts/build.sh v2026.1.0

# Build with a specific plugin set
./scripts/build.sh v2026.1.0 acme

# Run k8s-bootstrap directly (config must be in discourse_docker/containers/)
export PUPS_SKIP_TAGS="migrate,precompile"
./scripts/k8s-bootstrap basecontainer
```

### Triggering CI Builds
```bash
# Trigger build workflow via GitHub CLI
gh workflow run build-image.yml -f discourse_version=v2026.1.0 -f plugins=default

# Check workflow run status
gh run list --workflow=build-image.yml
```

### Submodule Management
```bash
# Update discourse_docker submodule
cd discourse_docker && git fetch origin && git checkout <commit> && cd ..
git add discourse_docker
```

## Architecture

### Build-Time vs Runtime Separation

The core design constraint: Discourse's standard bootstrap requires a running PostgreSQL and Redis, which aren't available in CI. This project solves it by:

1. **Build time**: `k8s-bootstrap` runs `pups --skip-tags migrate,precompile` to install everything except DB-dependent operations
2. **Deploy time**: Migrations and asset precompilation are handled by a Kubernetes Job (multi-replica) or by setting `MIGRATE_ON_BOOT=1` and `PRECOMPILE_ON_BOOT=1` (single-pod). Both default to `0` in the image

### Build Pipeline Flow

1. `build.sh` merges `config/basecontainer.yaml` + `config/plugins/<name>.yaml` using `yq`
2. Substitutes `{{ DISCOURSE_VERSION }}` with the target version via `sed`
3. Copies merged config to `discourse_docker/containers/basecontainer.yaml`
4. `k8s-bootstrap` extracts templates, merges them in pups format (`_FILE_SEPERATOR_`), extracts env vars, runs `pups --stdin --skip-tags migrate,precompile` inside `discourse/base` container
5. Commits the container as `local_discourse/basecontainer`
6. Adds `/version-manifest.yaml` to final image and tags as `discourse-k8s:<version>-<config-hash>`

### Plugin System

Plugins are defined in `config/plugins/*.yaml` as arrays of git clone commands. They get injected into `basecontainer.yaml`'s `hooks.after_code[0].exec.cmd` array at build time. Different plugin sets produce different config hashes, ensuring unique image tags.

### CI/CD Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `test.yml` | Push/PR to main | Runs validation tests |
| `build-image.yml` | Manual or called by check-upstream | Builds and pushes image to ghcr.io |
| `check-upstream.yml` | Daily 6 AM UTC cron | Updates submodule, detects new Discourse releases, triggers build |

### Image Tagging

- `v2026.1.0-abc123def456` - Immutable tag (version + config SHA256 hash)
- `2026.1-latest` - Rolling tag for latest build of that major.minor

## Key Files

- `config/basecontainer.yaml` - Base container config with placeholder env vars
- `config/plugins/*.yaml` - Plugin set definitions (git clone commands)
- `scripts/k8s-bootstrap` - Core build script (validates pups, merges templates, runs build)
- `scripts/build.sh` - Local build helper (merges config + plugins, calls k8s-bootstrap)
- `scripts/extract-upstream-versions.sh` - Shared helper that extracts PG, Redis, Ruby versions and base image from submodule (used by build.sh, generate-manifest.sh, and CI)
- `scripts/generate-manifest.sh` - Creates `/version-manifest.yaml` embedded in images
- `scripts/list-versions` - Query available Discourse stable versions
- `scripts/test-k8s-bootstrap` - Full integration test (requires Docker)
- `scripts/test-k8s-bootstrap-validation` - Quick validation test (no Docker)
- `versions.yaml` - Tracks last-built Discourse version (updated by CI)
- `discourse_docker/` - Git submodule of upstream discourse/discourse_docker
- `ARCHITECTURE.md` - Detailed architecture and K8s deployment patterns
- `kubernetes/` - Kustomize-based K8s manifests (base and overlays)

### Version Manifest

Each built image contains `/version-manifest.yaml` with Discourse version, plugin hash, dependency versions (PostgreSQL, Redis, Ruby), and build metadata. Dependency versions are extracted dynamically from the `discourse_docker` submodule via `scripts/extract-upstream-versions.sh`.

Images also carry OCI labels (`org.discourse.postgresql-version`, `org.discourse.redis-version`, `org.discourse.ruby-version`) queryable via `docker inspect` without running a container.

### Upstream Dependency Tracking

All upstream-dependent values are extracted dynamically from the `discourse_docker` submodule rather than hardcoded:

- **Base image**: `k8s-bootstrap` calls `extract-upstream-versions.sh` to get the base image from `discourse_docker/launcher`, with env var override (`BASE_IMAGE`). No hardcoded fallback — fails fast if extraction breaks.
- **Dependency versions**: `extract-upstream-versions.sh` extracts PG, Redis, and Ruby versions using regex patterns against `discourse_docker/image/base/` files
- **Known fragility**: The regex patterns (`ARG PG_MAJOR=\K.+`, etc.) could break if upstream changes their Dockerfile format. Validation errors are raised if extraction fails.

## Build Prerequisites

- Docker with at least 4GB memory and 10GB free disk
- `yq` (YAML processor) for config merging
- `curl` and `jq` for API queries (CI scripts)
