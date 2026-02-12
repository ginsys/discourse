# Discourse Kubernetes Image Builder

Automated build system for creating Discourse Docker images optimized for Kubernetes deployment.

## Overview

This repository:
- Tracks upstream `discourse/discourse_docker` releases without forking
- Builds custom Docker images for Kubernetes deployment
- Automates builds when upstream releases new versions
- Produces deterministically-tagged images with version manifests

## Architecture

### Key Components

- **Git Submodule**: Uses `discourse_docker` as a submodule (no fork required)
- **Base Configuration**: `config/basecontainer.yaml` defines the base image configuration
- **Plugin Sets**: `config/plugins/*.yaml` define optional plugin configurations
- **Version Tracking**: `versions.yaml` tracks the last built version
- **Automated Builds**: GitHub Actions workflows detect and build new releases

### Build vs Runtime Separation

Discourse's standard bootstrap requires a running PostgreSQL and Redis, which aren't available in CI. This project solves that by splitting the process:

- **Build time**: `k8s-bootstrap` runs `pups --stdin --skip-tags migrate,precompile` inside a `discourse/base` container, installing everything except DB-dependent operations (migrations) and asset precompilation
- **Runtime**: Database migrations and asset precompilation are handled either by a Kubernetes Job (recommended for multi-replica) or by setting `MIGRATE_ON_BOOT=1` and `PRECOMPILE_ON_BOOT=1` environment variables (suitable for single-pod deployments)

Both variables default to `0` in the image, so nothing runs on boot unless explicitly enabled.

### Why No `docker_manager`?

The `docker_manager` plugin is **not included** and **not needed** for Kubernetes deployments. It's only used for in-place upgrades via `./launcher rebuild` in traditional Docker setups. In K8s, upgrades happen by deploying new image versions through CI/CD.

## Repository Structure

```
discourse-k8s-image/
├── .github/
│   └── workflows/
│       ├── check-upstream.yml      # Cron: detect new Discourse releases
│       ├── build-image.yml         # Build and push Docker image
│       └── test.yml                # Run validation tests on push/PR
│
├── discourse_docker/               # Git submodule (upstream)
│
├── config/
│   ├── basecontainer.yaml          # Base container config (no plugins)
│   └── plugins/
│       ├── default.yaml            # Default: no plugins
│       └── example.yaml            # Example plugin configuration
│
├── scripts/
│   ├── k8s-bootstrap               # Core build script
│   ├── build.sh                    # Local build helper
│   ├── generate-manifest.sh        # Create version manifest
│   ├── list-versions               # Query available Discourse versions
│   ├── test-k8s-bootstrap          # Full integration test (requires Docker)
│   └── test-k8s-bootstrap-validation  # Quick validation test (no Docker)
│
├── kubernetes/
│   ├── base/                       # Kustomize base manifests
│   └── overlays/
│       ├── single-pod/             # Single replica, migrations on boot
│       └── production/             # Multi-replica, HPA, PDB, Ingress
│
├── ARCHITECTURE.md                 # Detailed architecture and K8s patterns
├── LICENSE
├── versions.yaml                   # Tracks last-built versions
└── README.md
```

## Image Tagging Strategy

| Tag Format | Example | Purpose |
|------------|---------|---------|
| `v2026.1.0-abc123def456` | Full version + config hash | Immutable, specific build |
| `2026.1-latest` | Major.minor + latest | Rolling tag for minor version |

The config hash is a 12-character SHA256 of the full merged configuration (base + plugins), ensuring different plugin sets produce different image tags.

## Usage

### Adding Plugins

Plugins are configured separately from the base container definition. This allows you to:
- Build images with different plugin sets without modifying the base config
- Keep the base configuration clean and versioned
- Create custom plugin combinations for different deployments

#### Create a Plugin Configuration

Create a new file in `config/plugins/` (e.g., `config/plugins/acme.yaml`):

```yaml
# Custom plugin configuration for ACME deployment
plugins:
  - git clone https://github.com/discourse/discourse-solved.git
  - git clone --branch v1.2.3 https://github.com/discourse/discourse-voting.git
```

**Important**: Pin plugins to specific branches or tags for reproducible builds.

#### Build with Plugins

Trigger a build with your plugin configuration:

```bash
# Using GitHub Actions UI
gh workflow run build-image.yml -f plugins=acme

# Or specify version and plugins
gh workflow run build-image.yml -f discourse_version=v2026.1.0 -f plugins=acme
```

**Note**: Different plugin sets generate different config hashes, ensuring unique image tags for each combination.

### Manual Build Trigger

1. Go to Actions tab in GitHub
2. Select "Build Discourse Image" workflow
3. Click "Run workflow"
4. Enter the Discourse version (e.g., `v2026.1.0`) or leave empty for latest
5. Enter the plugin config name (e.g., `acme`) or leave as `default` for no plugins
6. Click "Run workflow"

### Local Build

Build an image locally using `build.sh`:

```bash
# Build with default plugins (none)
./scripts/build.sh v2026.1.0

# Build with a specific plugin set
./scripts/build.sh v2026.1.0 acme
```

This creates an image tagged as `discourse-k8s:v2026.1.0-<config-hash>`.

### Automated Builds

The `check-upstream.yml` workflow runs daily at 6 AM UTC:
1. Updates the `discourse_docker` submodule to latest upstream `main` (pushes directly to main if changed)
2. Queries GitHub API for latest Discourse release
3. Compares against last-built version in `versions.yaml`
4. If new version detected, triggers build workflow against the freshly updated main branch
5. Build workflow creates image with default plugin set (no plugins)

**Note**: Automated builds use the `default` plugin configuration (empty). Custom plugin builds must be triggered manually.

### CI/CD Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `test.yml` | Push/PR to main | Runs `test-k8s-bootstrap-validation` |
| `build-image.yml` | Manual or called by check-upstream | Builds and pushes image to ghcr.io |
| `check-upstream.yml` | Daily 6 AM UTC cron or manual | Updates submodule, detects new releases, triggers build |

## GitHub Container Registry

Images are published to GitHub Container Registry (GHCR):

```
ghcr.io/ginsys/discourse:v2026.1.0-abc123def456
ghcr.io/ginsys/discourse:2026.1-latest
```

### Pulling Images

```bash
# Authenticate with GHCR
echo $GITHUB_TOKEN | docker login ghcr.io -u <username> --password-stdin

# Pull specific version
docker pull ghcr.io/ginsys/discourse:v2026.1.0-abc123def456

# Pull latest for major.minor
docker pull ghcr.io/ginsys/discourse:2026.1-latest
```

## Version Manifest

Each image includes `/version-manifest.yaml` with build details:

```yaml
discourse:
  version: "v2026.1.0"

plugins_hash: "abc123def456"

plugins:
  []

dependencies:
  postgresql: "15"
  redis: "7.4.7"
  ruby: "3.3.8"

build:
  timestamp: "2026-01-15T10:30:00Z"
  builder: "github-actions"
  workflow_run: "1234567890"
  commit: "abc123..."
```

Retrieve from a running container:

```bash
docker run --rm ghcr.io/ginsys/discourse:v2026.1.0-abc123def456 cat /version-manifest.yaml
```

Query dependency versions via OCI labels (no container needed):

```bash
docker inspect --format '{{index .Config.Labels "org.discourse.postgresql-version"}}' <image>
docker inspect --format '{{index .Config.Labels "org.discourse.redis-version"}}' <image>
docker inspect --format '{{index .Config.Labels "org.discourse.ruby-version"}}' <image>
```

## Kubernetes Deployment

### Environment Variables

The image uses the following environment variables at runtime. Both boot-time variables default to `0` in the image:

| Variable | Description | Default |
|----------|-------------|---------|
| `DISCOURSE_DB_HOST` | PostgreSQL hostname | `placeholder` |
| `DISCOURSE_REDIS_HOST` | Redis/Valkey hostname | `placeholder` |
| `DISCOURSE_HOSTNAME` | Public hostname for Discourse | `placeholder` |
| `MIGRATE_ON_BOOT` | Run `db:migrate` on container start | `0` |
| `PRECOMPILE_ON_BOOT` | Run `assets:precompile` on container start | `0` |

For single-pod deployments, set `MIGRATE_ON_BOOT=1` and `PRECOMPILE_ON_BOOT=1`. For multi-replica deployments, leave at `0` and use a Kubernetes Job (see below).

### Deployment Approaches

**Single-pod** (simplest):
```bash
kubectl kustomize kubernetes/overlays/single-pod/ | kubectl apply -f -
```
Migrations and precompilation run on boot. No separate Job needed.

**Multi-replica** (production):
```bash
# 1. Delete previous migration Job (Jobs are immutable — can't update image)
kubectl delete job discourse-migrate -n discourse --ignore-not-found

# 2. Run migrations as a Job (update image tag in migration-job.yaml first)
kubectl apply -f kubernetes/base/migration-job.yaml
kubectl wait --for=condition=complete job/discourse-migrate -n discourse --timeout=600s

# 3. Then deploy/update the application
kubectl kustomize kubernetes/overlays/production/ | kubectl apply -f -
```

If using a GitOps tool, the Job annotations handle this automatically: Flux (`kustomize.toolkit.fluxcd.io/force`), ArgoCD (`BeforeHookCreation`), Helm (`before-hook-creation`).

See `kubernetes/` for full Kustomize manifests and `ARCHITECTURE.md` for detailed deployment patterns, probe tuning, HPA, PDB, and operational runbooks.

## Testing

### Quick Validation (No Docker Required)

```bash
./scripts/test-k8s-bootstrap-validation
```

Validates error detection and config path correctness. Runs in CI on every push/PR.

### Full Integration Test (Requires Docker)

```bash
./scripts/test-k8s-bootstrap
```

Builds an actual image and verifies the installed Discourse version matches.

### Query Available Versions

```bash
./scripts/list-versions
```

Lists recent stable Discourse releases from the GitHub API.

## CI/CD Security

### Build Guardrails

1. **Network Isolation**: Build workflow never has production DB credentials
2. **No Runtime Secrets**: Only GITHUB_TOKEN for registry push
3. **Reproducible**: Same inputs = same image (pinned submodule, plugin refs)
4. **Rollback Ready**: Previous images retained by registry policy

### Required Secrets

Only one secret is required:
- `GITHUB_TOKEN` - Automatically provided by GitHub Actions

## Troubleshooting

### Build Fails with "Version not found"

Ensure the Discourse version exists as a git tag in the upstream repository:
```bash
./scripts/list-versions 20
```

### Plugin Installation Fails

1. Verify the plugin repository URL is correct
2. Ensure the `ref` (branch/tag/commit) exists
3. Check plugin compatibility with the Discourse version

### Local Build Fails

Ensure Docker has sufficient resources:
- Memory: At least 4GB
- Disk space: At least 10GB free

## Contributing

### Updating discourse_docker Submodule

The submodule is updated automatically each day by the `check-upstream.yml` workflow. To update manually:

```bash
cd discourse_docker
git fetch origin
git checkout <commit-sha>
cd ..
git add discourse_docker
git commit -m "Update discourse_docker submodule to <commit-sha>"
```

### Testing Changes

#### Base Configuration Changes
1. Make changes to `config/basecontainer.yaml`
2. Run `./scripts/test-k8s-bootstrap-validation` to validate
3. For full verification: `./scripts/build.sh v2026.1.0`
4. Commit and push changes

#### Plugin Configuration Changes
1. Create or modify plugin config in `config/plugins/`
2. Trigger workflow with plugin name: `gh workflow run build-image.yml -f plugins=<name>`
3. Test the resulting image
4. Commit and push the plugin configuration

## References

- [Discourse Official Repository](https://github.com/discourse/discourse)
- [discourse_docker Repository](https://github.com/discourse/discourse_docker)
- [Discourse Meta Forum](https://meta.discourse.org/)
- [GitHub Container Registry Documentation](https://docs.github.com/packages/working-with-a-github-packages-registry/working-with-the-container-registry)

## License

This build infrastructure is licensed under the MIT License. See [LICENSE](LICENSE) for details.

Discourse itself is licensed under GPL v2.
