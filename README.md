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

The Go-based launcher in `discourse_docker` separates operations:
- `./launcher build` - Creates image (NO database required) - runs at CI time
- `./launcher migrate` - Runs migrations - handled by Kubernetes Jobs at deploy time
- `./launcher configure` - Precompiles assets - part of build process

### Why No `docker_manager`?

The `docker_manager` plugin is **not included** and **not needed** for Kubernetes deployments. It's only used for in-place upgrades via `./launcher rebuild` in traditional Docker setups. In K8s, upgrades happen by deploying new image versions through CI/CD.

## Repository Structure

```
discourse-k8s-image/
├── .github/
│   └── workflows/
│       ├── check-upstream.yml      # Cron: detect new Discourse releases
│       └── build-image.yml         # Build and push Docker image
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
│   ├── k8s-bootstrap                # Custom bootstrap script
│   └── generate-manifest.sh        # Create version manifest
│
├── versions.yaml                   # Tracks last-built versions
└── README.md
```

## Image Tagging Strategy

| Tag Format | Example | Purpose |
|------------|---------|---------|
| `v3.2.1-abc123def456` | Full version + config hash | Immutable, specific build |
| `3.2-latest` | Major.minor + latest | Rolling tag for minor version |

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
gh workflow run build-image.yml -f discourse_version=v3.2.1 -f plugins=acme
```

**Note**: Different plugin sets generate different config hashes, ensuring unique image tags for each combination.

### Manual Build Trigger

1. Go to Actions tab in GitHub
2. Select "Build Discourse Image" workflow
3. Click "Run workflow"
4. Enter the Discourse version (e.g., `v3.2.1`) or leave empty for latest
5. Enter the plugin config name (e.g., `acme`) or leave as `default` for no plugins
6. Click "Run workflow"

### Local Testing

Build an image locally:

```bash
./scripts/build.sh v3.2.1
```

This creates an image tagged as `discourse-k8s:v3.2.1-<plugin-hash>`.

### Automated Builds

The `check-upstream.yml` workflow runs daily at 6 AM UTC:
1. Queries GitHub API for latest Discourse release
2. Compares against last-built version in `versions.yaml`
3. If new version detected, updates `versions.yaml` and triggers build workflow
4. Build workflow creates image with default plugin set (no plugins)

**Note**: Automated builds use the `default` plugin configuration (empty). Custom plugin builds must be triggered manually.

## GitHub Container Registry

Images are published to GitHub Container Registry (GHCR):

```
ghcr.io/<owner>/discourse:v3.2.1-abc123def456
ghcr.io/<owner>/discourse:3.2-latest
```

### Pulling Images

```bash
# Authenticate with GHCR
echo $GITHUB_TOKEN | docker login ghcr.io -u <username> --password-stdin

# Pull specific version
docker pull ghcr.io/<owner>/discourse:v3.2.1-abc123def456

# Pull latest for major.minor
docker pull ghcr.io/<owner>/discourse:3.2-latest
```

## Version Manifest

Each image includes `/version-manifest.yaml` with build details:

```yaml
discourse:
  version: "v3.2.1"

plugins_hash: "abc123def456"

plugins:
  - name: discourse-solved
    repo: https://github.com/discourse/discourse-solved
    ref: main

dependencies:
  postgresql: "15"
  redis: "7.4.7"
  ruby: "3.3.8"

build:
  timestamp: "2024-01-15T10:30:00Z"
  builder: "github-actions"
  workflow_run: "1234567890"
  commit: "abc123..."
```

Retrieve from a running container:

```bash
docker run --rm ghcr.io/<owner>/discourse:v3.2.1-abc123def456 cat /version-manifest.yaml
```

Query dependency versions via OCI labels (no container needed):

```bash
docker inspect --format '{{index .Config.Labels "org.discourse.postgresql-version"}}' <image>
docker inspect --format '{{index .Config.Labels "org.discourse.redis-version"}}' <image>
docker inspect --format '{{index .Config.Labels "org.discourse.ruby-version"}}' <image>
```

## Kubernetes Deployment

### Environment Variables

The image expects these to be overridden at runtime:

- `DISCOURSE_DB_HOST` - PostgreSQL hostname
- `DISCOURSE_REDIS_HOST` - Redis hostname
- `DISCOURSE_HOSTNAME` - Public hostname for Discourse

Example Kubernetes deployment:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: discourse-web
spec:
  replicas: 2
  template:
    spec:
      containers:
      - name: discourse
        image: ghcr.io/<owner>/discourse:v3.2.1-abc123def456
        env:
        - name: DISCOURSE_DB_HOST
          value: "postgres.default.svc.cluster.local"
        - name: DISCOURSE_REDIS_HOST
          value: "redis.default.svc.cluster.local"
        - name: DISCOURSE_HOSTNAME
          value: "discourse.example.com"
        # Add other required env vars...
```

### Database Migrations

Run migrations as a Kubernetes Job before deploying new versions:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: discourse-migrate-v3.2.1
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: migrate
        image: ghcr.io/<owner>/discourse:v3.2.1-abc123def456
        command: ["/sbin/boot"]
        args: ["migrate"]
        env:
        - name: DISCOURSE_DB_HOST
          value: "postgres.default.svc.cluster.local"
        # Add other required env vars...
```

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
curl -s https://api.github.com/repos/discourse/discourse/tags | jq -r '.[].name'
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
2. Test locally using `./scripts/k8s-bootstrap basecontainer`
3. Commit and push changes
4. Trigger manual workflow to test in CI

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

This build infrastructure is provided as-is. Discourse itself is licensed under GPL v2.
