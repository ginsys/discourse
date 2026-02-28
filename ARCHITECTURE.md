# Discourse on Kubernetes: Architecture Document

## Document Information

| Item | Value |
|------|-------|
| Version | 2.0 |
| Date | 2026-01-28 |
| Status | Production Ready |

---

## 1. Executive Summary

This document defines the architecture for deploying Discourse forum platform on Kubernetes (Talos Linux / Hetzner infrastructure). The design philosophy is to stay as close to upstream Discourse Docker as possible while enabling cloud-native deployment patterns.

**⚠️ Support Status:** Kubernetes deployments are not officially supported by Discourse. This architecture is based on community experience and engineering analysis. Official Discourse support only covers the standard Docker-based deployment via `discourse_docker`. While Discourse runs successfully on Kubernetes, deployment and operational issues will need to be resolved without upstream vendor support.

### Key Decisions

- **Image Strategy**: Build custom images using upstream `discourse/base`, tracking upstream releases
- **Database**: CloudNativePG (PostgreSQL 15+)
- **Cache/Queue**: Valkey (Redis-compatible)
- **Storage**: S3-compatible object storage (deploy-time configuration)
- **TLS**: Ingress + cert-manager (container serves HTTP only)
- **Scaling**: Multi-replica capable, Sidekiq architecture configurable at deploy-time

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              KUBERNETES CLUSTER                              │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                         INGRESS CONTROLLER                              │ │
│  │  • TLS termination via cert-manager                                     │ │
│  │  • Routes to Discourse service                                          │ │
│  │  • WebSocket upgrade support                                            │ │
│  │  • Sticky sessions (recommended)                                        │ │
│  └────────────────────────────┬───────────────────────────────────────────┘ │
│                               │ HTTP :80                                     │
│                               ▼                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐ │
│  │                      DISCOURSE DEPLOYMENT                               │ │
│  │  ┌─────────────────────────────────────────────────────────────────┐   │ │
│  │  │  Pod (replicas: configurable)                                    │   │ │
│  │  │  ┌─────────────────────────────────────────────────────────┐    │   │ │
│  │  │  │  Container: discourse                                    │    │   │ │
│  │  │  │  • nginx (reverse proxy, :80)                            │    │   │ │
│  │  │  │  • puma (Rails app, UNICORN_WORKERS)                     │    │   │ │
│  │  │  │  • sidekiq (jobs, UNICORN_SIDEKIQS) - configurable       │    │   │ │
│  │  │  │  • runit (process supervisor)                            │    │   │ │
│  │  │  └─────────────────────────────────────────────────────────┘    │   │ │
│  │  └─────────────────────────────────────────────────────────────────┘   │ │
│  │                                                                         │ │
│  │  [Optional: Separate Sidekiq Deployment - same image, different env]    │ │
│  └─────────────────────────────────────────────────────────────────────────┘ │
│                               │                                              │
│              ┌────────────────┼────────────────┐                             │
│              ▼                ▼                ▼                             │
│  ┌──────────────────┐ ┌─────────────┐ ┌─────────────────────┐               │
│  │  CloudNativePG   │ │   Valkey    │ │  S3-Compatible      │               │
│  │  (PostgreSQL 15) │ │  (Redis 7)  │ │  Object Storage     │               │
│  │                  │ │             │ │                     │               │
│  │  • hstore ext    │ │  • Sidekiq  │ │  • Uploads          │               │
│  │  • pg_trgm ext   │ │  • Cache    │ │  • Backups          │               │
│  │                  │ │  • MessageBus│ │  • Avatars          │               │
│  └──────────────────┘ └─────────────┘ └─────────────────────┘               │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Decision Matrix

### 3.1 Infrastructure Decisions

| # | Topic | Decision | Notes |
|---|-------|----------|-------|
| 1 | Redis Implementation | **Valkey** | Deployment method (simple StatefulSet or operator) configurable at deploy-time |
| 2 | Sidekiq Architecture | **Deploy-time choice** | Same image, env vars toggle unified vs separated mode |
| 3 | Shared Storage | **S3-compatible** | RWX PVC not available; MinIO or external S3 |
| 4 | TLS Termination | **Ingress + cert-manager** | Container serves HTTP only on port 80 |
| 5 | Ingress Controller | Out of scope | Cluster-level decision |
| 6 | WebSocket Handling | **Sticky sessions (default)** | Document AnyCable as advanced option |
| 7 | Mail Receiver | **All options remain** | Document requirements; deploy-time choice |
| 8 | Plugin Strategy | **Deploy-time decision** | Start with generic image capability |
| 9 | Default Replicas | **Multi-replica assumed** | Actual count is deploy-time decision |
| 10 | PostgreSQL | **CloudNativePG** | Managed PostgreSQL 15+ with required extensions |
| 11 | Resource Limits | **Configurable** | Per-deployment decision |

### 3.2 Template Decisions

Templates included in image build:

| Template | Status | Purpose |
|----------|--------|---------|
| `web.template.yml` | **Required** | Core: nginx + puma + sidekiq + runit + anacron |
| `web.ratelimited.template.yml` | **Required** | nginx rate limiting (12 req/s, 100/min per IP) |
| `offline-page.template.yml` | **Required** | Maintenance/offline page support |
| `web.ipv6.template.yml` | **Optional** | IPv6 listener (document for IPv6-enabled clusters) |

Templates explicitly excluded:

| Template | Reason |
|----------|--------|
| `web.socketed.template.yml` | K8s uses TCP networking, not Unix sockets |
| `web.ssl.template.yml` | Ingress handles TLS termination |
| `web.letsencrypt.ssl.template.yml` | cert-manager handles certificates |
| `postgres.template.yml` | Using CloudNativePG instead |
| `redis.template.yml` | Using Valkey instead |
| `sshd.template.yml` | Use `kubectl exec` for container access |
| `cron.template.yml` | Deprecated (cron included in base image) |
| `web.onion.template.yml` | Tor hidden service (edge case) |
| `import/*.template.yml` | One-time migration tools |

**Note on `web.modsecurity.template.yml`:** This is NOT part of the core Discourse project. It is a community-created template that requires a custom nginx build with ModSecurity module. Not included in our architecture.

---

## 4. External Dependencies

### 4.1 PostgreSQL (CloudNativePG)

| Requirement | Value |
|-------------|-------|
| Minimum Version | 13 |
| Recommended Version | 15+ |
| Required Extensions | `hstore`, `pg_trgm`, `unaccent` |
| Extension Scope | Must be installed in both `template1` AND the discourse database |

**CloudNativePG Cluster Configuration Notes:**
- Enable `hstore`, `pg_trgm`, and `unaccent` extensions
- Configure appropriate connection pooling
- Set up automated backups

**Connection Pool Sizing:**

The database connection pool must accommodate all concurrent connections:

```
pool_size >= (UNICORN_WORKERS × threads_per_worker) + (sidekiq_processes × SIDEKIQ_CONCURRENCY)
```

**Example calculation:**
- Web pods: 3 replicas × 4 workers × 5 threads = 60 connections
- Sidekiq pods: 2 replicas × 5 processes × 25 concurrency = 250 connections
- Total pool needed: 310+ connections

**Connection Pooling Considerations:**
- For deployments requiring >100 connections, consider using PgBouncer in transaction or statement mode
- CloudNativePG supports built-in PgBouncer pooling
- Monitor connection usage and adjust `max_connections` accordingly

### 4.2 Valkey (Redis-compatible)

| Requirement | Value |
|-------------|-------|
| Minimum Version | 7 |
| Compatibility | Compatible in practice; not officially certified by Discourse |

**Usage in Discourse:**
- Sidekiq job queue
- Rails cache
- MessageBus (pub/sub for real-time updates)
- Rate limiting
- Session storage

**Deployment Options:**
- Simple StatefulSet (sufficient for most deployments)
- Valkey Operator (for HA requirements)

### 4.3 S3-Compatible Object Storage

**Required for multi-replica deployments.**

| Use Case | Path/Bucket |
|----------|-------------|
| User uploads | `/uploads/` |
| Backups | `/backups/` |
| Optimized images | `/optimized/` |
| Avatars | `/avatars/` |

**Options:**
- External S3 (AWS, Cloudflare R2, etc.)
- Self-hosted MinIO

### 4.4 Dependency Initialization

**Optional: Init Containers for Dependency Checking**

While the migration Job includes a wait-for-postgres init container, the main Discourse deployment can also benefit from explicit dependency checking:

```yaml
initContainers:
  - name: wait-for-postgres
    image: postgres:15
    command:
      - sh
      - -c
      - |
        until pg_isready -h $DISCOURSE_DB_HOST -p $DISCOURSE_DB_PORT; do
          echo "Waiting for PostgreSQL..."
          sleep 2
        done
    env:
      - name: DISCOURSE_DB_HOST
        value: "discourse-pg-rw.discourse.svc"
      - name: DISCOURSE_DB_PORT
        value: "5432"

  - name: wait-for-redis
    image: redis:7
    command:
      - sh
      - -c
      - |
        until redis-cli -h $DISCOURSE_REDIS_HOST -p $DISCOURSE_REDIS_PORT ping; do
          echo "Waiting for Redis/Valkey..."
          sleep 2
        done
    env:
      - name: DISCOURSE_REDIS_HOST
        value: "valkey.discourse.svc"
      - name: DISCOURSE_REDIS_PORT
        value: "6379"
```

**Trade-offs:**
- **Pros:** Explicit dependency checking, cleaner logs, prevents crash loops during initial deployment
- **Cons:** Slightly slower pod startup, additional containers to maintain
- **Recommendation:** Use for initial deployment, optional for steady-state operations

### 4.5 Filesystem Layout

Discourse requires specific filesystem paths for operation. In Kubernetes deployments, these are handled differently than in traditional Docker deployments.

#### /shared Mount

**Purpose:** Shared state directory for logs, uploads (when not using S3), and temporary files.

**Implementation Options:**

**With S3 (Recommended for multi-replica):**
```yaml
volumes:
  - name: shared
    emptyDir: {}
```
- Ephemeral storage, recreated with each pod
- Uploads go to S3, so no persistence needed
- Logs are ephemeral (use stdout/stderr for log aggregation)

**Without S3 (Single replica only):**
```yaml
volumes:
  - name: shared
    persistentVolumeClaim:
      claimName: discourse-shared
```
- Requires RWX PersistentVolumeClaim (not available on all storage classes)
- Stores uploads, backups locally
- Not recommended for production

**Mount Configuration:**
```yaml
volumeMounts:
  - name: shared
    mountPath: /shared
```

#### /var/www/discourse/tmp

**Purpose:** Rails temporary files (cache, sessions, sockets).

**Implementation:**
```yaml
volumes:
  - name: tmp
    emptyDir: {}

volumeMounts:
  - name: tmp
    mountPath: /var/www/discourse/tmp
```

This directory should always be ephemeral (emptyDir) as it contains pod-specific runtime state.

#### Directory Structure

```
/shared/
├── log/              # Application logs (use stdout/stderr instead in K8s)
├── uploads/          # User uploads (use S3 in multi-replica)
├── backups/          # Database backups (use S3 or external backup)
└── tmp/              # Temporary processing files

/var/www/discourse/
├── app/              # Rails application (baked into image)
├── public/           # Static assets (baked into image)
├── tmp/              # Rails temp (emptyDir in K8s)
└── plugins/          # Plugins (baked into image)
```

---

## 5. Sidekiq Architecture Options

The same Docker image supports multiple Sidekiq deployment patterns via environment variables.

### Option A: Unified (Default)

Sidekiq runs inside web pods alongside Puma.

```yaml
env:
  UNICORN_WORKERS: "4"
  UNICORN_SIDEKIQS: "1"
```

**Pros:** Simple, fewer resources
**Cons:** Sidekiq scales with web tier

### Option B: Separated

Sidekiq runs as dedicated deployment.

**Web Pods:**
```yaml
env:
  UNICORN_WORKERS: "4"
  UNICORN_SIDEKIQS: "0"
```

**Sidekiq Pods:**
```yaml
env:
  UNICORN_WORKERS: "0"
  UNICORN_SIDEKIQS: "5"
```

**Pros:** Independent scaling, isolate heavy jobs
**Cons:** More complexity, more resources

### Option C: Hybrid

Light Sidekiq in web pods + dedicated heavy Sidekiq deployment.

**Use Case:** High-traffic sites with heavy background processing (bulk emails, large imports)

---

## 6. WebSocket / Real-time Handling

### Default: MessageBus with Sticky Sessions

Discourse uses MessageBus for real-time updates (notifications, presence, live posts). It supports both long-polling and WebSockets through the same Puma workers.

**Recommended Ingress Configuration:**
```yaml
annotations:
  # Enable sticky sessions
  nginx.ingress.kubernetes.io/affinity: "cookie"
  nginx.ingress.kubernetes.io/session-cookie-name: "DISCOURSE_AFFINITY"
  nginx.ingress.kubernetes.io/session-cookie-expires: "172800"
  nginx.ingress.kubernetes.io/session-cookie-max-age: "172800"

  # WebSocket support
  nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
  nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"

  # Disable buffering for real-time endpoints
  nginx.ingress.kubernetes.io/proxy-buffering: "off"

  # Allow large uploads
  nginx.ingress.kubernetes.io/proxy-body-size: "100m"
```

### Advanced Option: AnyCable

For very high-traffic sites, AnyCable offloads WebSocket connections to a Go-based server.

**When to consider:**
- 10,000+ concurrent users
- Ruby worker saturation from WebSocket handling

**Not covered in this architecture** — document for future reference only.

---

## 7. Mail Receiver (Reply-by-Email)

Incoming email requires port 25, which is problematic in Kubernetes.

### Option A: External VM

Keep mail receiver outside K8s on a VM with port 25 access.
- Run `mail-receiver` container on dedicated VM
- Forward to Discourse via internal API

### Option B: External Service + Webhook

Use email service (Forward Email, Mailgun, Postmark) with webhook forwarding.
- Configure email service to POST to `/admin/email/handle_mail`
- No port 25 needed in cluster

### Option C: Disable Feature

Simply don't offer reply-by-email functionality.

**Decision:** All options documented; deploy-time choice based on requirements.

---

## 8. Build Strategy

### 8.1 Build-time vs Runtime Configuration

In Kubernetes deployments, the separation between build-time and runtime is critical for reliability and security.

**Baked at Build Time** (via `pups --skip-tags migrate,precompile`):
- Discourse version (from git tag/commit)
- Plugin list and versions (from git SHAs)
- Ruby gems (`bundle install`)
- Nginx configuration
- Base system packages
- Ember CLI compilation (`SKIP_EMBER_CLI_COMPILE=1` prevents re-running at boot)

**Handled at Deploy Time** (via Job or on-boot env vars):
- Database migrations (`rake db:migrate`)
- Asset precompilation (`rake assets:precompile`)

**Configured at Runtime:**
- Database connection parameters
- Redis/Valkey connection
- SMTP settings
- S3 credentials and configuration
- Site hostname
- Worker/process counts

**Note:** The build uses `--skip-tags migrate,precompile` because both require a running database. Migrations and asset precompilation are run either via a Kubernetes Job (recommended for multi-replica) or on boot by setting `MIGRATE_ON_BOOT=1` and `PRECOMPILE_ON_BOOT=1` (suitable for single-pod deployments). Both variables default to `0` in the image.

### 8.2 Migration Strategy

**⚠️ Never use `MIGRATE_ON_BOOT=1` in multi-replica deployments.**

`MIGRATE_ON_BOOT` and `PRECOMPILE_ON_BOOT` default to `0` in the image. For single-pod deployments, setting both to `1` is acceptable. For multi-replica deployments, running migrations on pod startup creates race conditions where multiple pods attempt concurrent schema changes, leading to:
- Lock contention
- Failed migrations
- Inconsistent database state
- Pod crash loops

**Required Approach for Multi-Replica: Kubernetes Job**

Migrations must run as a separate Kubernetes Job before deploying new pods. See `kubernetes/base/migration-job.yaml` for the production-ready manifest.

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: discourse-migrate-20260128-v2026-1-0
spec:
  template:
    spec:
      restartPolicy: OnFailure
      initContainers:
        - name: wait-for-postgres
          image: postgres:15
          command:
            - sh
            - -c
            - |
              until pg_isready -h $DISCOURSE_DB_HOST -p $DISCOURSE_DB_PORT; do
                echo "Waiting for PostgreSQL..."
                sleep 2
              done
          env:
            - name: DISCOURSE_DB_HOST
              value: "discourse-pg-rw.discourse.svc"
            - name: DISCOURSE_DB_PORT
              value: "5432"
      containers:
        - name: migrate
          image: ghcr.io/ginsys/discourse:v2026.1.0-abc123def456
          command:
            - bash
            - -c
            - |
              set -e
              cd /var/www/discourse

              # Acquire advisory lock to prevent concurrent migrations
              # Lock ID: 123456 (arbitrary, consistent across deployments)
              su discourse -c "bundle exec rails runner '
                ActiveRecord::Base.connection.execute(\"SELECT pg_advisory_lock(123456)\")
                puts \"Lock acquired, running migrations...\"
              '"

              # Run migrations
              su discourse -c 'bundle exec rake db:migrate'

              # Release lock
              su discourse -c "bundle exec rails runner '
                ActiveRecord::Base.connection.execute(\"SELECT pg_advisory_unlock(123456)\")
                puts \"Lock released.\"
              '"
          env:
            - name: DISCOURSE_DB_HOST
              valueFrom:
                secretKeyRef:
                  name: discourse-secrets
                  key: db-host
            # ... other DB connection vars
```

**Key Points:**
- Job name includes version/date to track migration history
- `initContainer` waits for PostgreSQL availability
- PostgreSQL advisory lock prevents concurrent execution
- Job must complete successfully before rolling out new Deployment
- Failed jobs remain for debugging (set `ttlSecondsAfterFinished` for cleanup)

### 8.3 Image Versioning and Tagging

**Deterministic Builds:**

Every image is tagged with its version and a hash of the full merged configuration:

```
ghcr.io/ginsys/discourse:v2026.1.0-abc123def456
```

**Tag Formats:**

| Format | Example | Purpose |
|--------|---------|---------|
| `v{version}-{config-hash}` | `v2026.1.0-abc123def456` | Immutable tag |
| `{major.minor}-latest` | `2026.1-latest` | Rolling tag for latest build |

**Config Hash Generation:**
```bash
# Hash is SHA256 of the full merged config (base + plugins), first 12 chars
sha256sum /tmp/container.yaml | cut -c1-12
```

The hash covers the entire merged configuration file, not just plugins. This means any change to base config or plugin list produces a different tag.

**Version Manifest (stored in image at `/version-manifest.yaml`):**
```yaml
discourse:
  version: "v2026.1.0"

plugins_hash: "abc123def456"

plugins:
  []

dependencies:
  postgresql: "15"
  redis: "7.4.7"
  ruby: "3.4.7"

build:
  timestamp: "2026-01-28T10:30:00Z"
  builder: "github-actions"
  workflow_run: "1234567890"
  commit: "abc123..."
```

Dependency versions are extracted from the `discourse_docker` submodule at build time. Images also carry OCI labels (`org.discourse.postgresql-version`, `org.discourse.redis-version`, `org.discourse.ruby-version`) queryable via `docker inspect`.

### 8.4 CI/CD Build Guardrails

**Never Connect CI to Production Database:**

Build-time processes must never require database connectivity:

**Network-Level Protection:**
- Block outbound connections from CI/build environment to production database
- Use network policies, security groups, or firewall rules
- Treat CI as untrusted zone

**Build Process Validation:**
```bash
# In CI pipeline, verify no DB connection attempts
if grep -r "DISCOURSE_DB_HOST.*production" build-config/; then
  echo "ERROR: Production DB reference in build config"
  exit 1
fi
```

**Environment Separation:**
```bash
# CI environment should never have production credentials
# Build-time variables:
- DISCOURSE_VERSION=v2026.1.0
- PLUGIN_LIST=solved,voting,sitemap

# Runtime variables (NOT in CI):
- DISCOURSE_DB_HOST
- DISCOURSE_DB_PASSWORD
- DISCOURSE_SMTP_PASSWORD
```

### 8.5 Rollback Strategy

**Image Retention:**
- Always keep the previous image tagged and available
- Use image retention policies in container registry (keep last 5 versions minimum)
- Never delete an image that is currently deployed or was deployed in the last 30 days

**Code Rollback Without DB Rollback:**

Discourse migrations are generally forward-compatible:

**Safe Rollback Scenario:**
```
Deploy v2026.1.0:
  - Adds new table: user_badges_v2
  - New code uses user_badges_v2
  - Old code ignores user_badges_v2

Rollback to v2025.12.0:
  - Old code still works (doesn't query new table)
  - New table remains (harmless)
  - No data loss
```

**Unsafe Rollback Scenario (requires DB rollback):**
```
Deploy v2026.1.0:
  - Removes column: users.legacy_field
  - Migration: ALTER TABLE users DROP COLUMN legacy_field

Rollback to v2025.12.0:
  - Old code expects users.legacy_field
  - ERROR: column does not exist
  - Requires restoring DB from backup
```

**Migration Reversibility Requirements:**

For complex migrations, document rollback procedure:

```ruby
# discourse/db/migrate/20260128_add_user_badges_v2.rb
class AddUserBadgesV2 < ActiveRecord::Migration[7.0]
  def up
    create_table :user_badges_v2 do |t|
      # schema
    end
  end

  def down
    drop_table :user_badges_v2
  end
end
```

**Rollback Runbook:**
```bash
# 1. Scale down new version
kubectl scale deployment discourse-web --replicas=0

# 2. If code rollback is sufficient:
kubectl set image deployment/discourse-web discourse=ghcr.io/ginsys/discourse:v2025.12.0-xyz789abcdef

# 3. If DB rollback required (DESTRUCTIVE):
#    a. Take fresh backup
#    b. Restore from pre-migration backup
#    c. Verify data integrity
#    d. Deploy old version
```

**Best Practice:** Thoroughly test migrations in staging, including rollback procedures, before production deployment.

### 8.6 Boot-Time Environment Variables

These variables control what happens when the container starts. Both default to `0` in the image:

| Variable | Default | Description |
|----------|---------|-------------|
| `MIGRATE_ON_BOOT` | `0` | Run `rake db:migrate` on container start |
| `PRECOMPILE_ON_BOOT` | `0` | Run `rake assets:precompile` on container start |

**Single-pod deployments:** Set both to `1`. Migrations and precompilation run on boot.

**Multi-replica deployments:** Leave at `0`. Use a Kubernetes Job (see `kubernetes/base/migration-job.yaml`) to run migrations and precompilation before rolling out new pods.

See Section 9 for runtime environment variables.

### 8.7 Upstream Dependency Tracking

This project deliberately deviates from the upstream `discourse_docker/launcher` to support CI-based image builds without a running database. However, several values must stay in sync with upstream to avoid build failures.

**Auto-extracted values:**

| Value | Source | Extraction |
|-------|--------|------------|
| Base image tag | `discourse_docker/launcher` line 1 | `grep '^image='` in `extract-upstream-versions.sh` |
| PostgreSQL version | `discourse_docker/image/base/Dockerfile` | `ARG PG_MAJOR=` regex |
| Redis version | `discourse_docker/image/base/install-redis` | `REDIS_VERSION=` regex |
| Ruby version | `discourse_docker/image/base/Dockerfile` | `ARG RUBY_VERSION=` regex |

All extractions are centralized in `scripts/extract-upstream-versions.sh`, which is called by `k8s-bootstrap`, `build.sh`, `generate-manifest.sh`, and the CI workflow. `k8s-bootstrap` calls the shared helper unless `BASE_IMAGE` is already set via env override. No hardcoded fallback — extraction failure is fatal.

**Known risks:**
- Regex patterns are fragile — if upstream changes from `ARG PG_MAJOR=15` to a different format, the validation loop produces an explicit "Failed to extract" error
- Template extraction via `sed` in `k8s-bootstrap` assumes the `templates:` block format is stable
- The `_FILE_SEPERATOR_` delimiter is a pups convention (the typo is intentional upstream)

**Intentionally NOT replicated from upstream launcher:**
- Docker prerequisite checks (memory, disk, kernel) — CI runners are controlled environments
- Env var passing via `docker run -e` — pups processes `env:` sections internally; runtime env comes from K8s pod spec
- Volume/link/port extraction — not needed for image builds, K8s handles runtime concerns
- SSH key copying — not applicable to CI builds

---

## 9. Runtime Environment Variables

### Required Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `DISCOURSE_HOSTNAME` | Primary domain | `forum.example.com` |
| `DISCOURSE_DB_HOST` | PostgreSQL host | `discourse-pg-rw.discourse.svc` |
| `DISCOURSE_DB_PORT` | PostgreSQL port | `5432` |
| `DISCOURSE_DB_NAME` | Database name | `discourse` |
| `DISCOURSE_DB_USERNAME` | Database user | `discourse` |
| `DISCOURSE_DB_PASSWORD` | Database password | (from Secret) |
| `DISCOURSE_REDIS_HOST` | Valkey/Redis host | `valkey.discourse.svc` |
| `DISCOURSE_REDIS_PORT` | Valkey/Redis port | `6379` |
| `DISCOURSE_SMTP_ADDRESS` | SMTP server | `smtp.example.com` |
| `DISCOURSE_SMTP_PORT` | SMTP port | `587` |
| `DISCOURSE_SMTP_USER_NAME` | SMTP username | `postmaster@example.com` |
| `DISCOURSE_SMTP_PASSWORD` | SMTP password | (from Secret) |
| `DISCOURSE_DEVELOPER_EMAILS` | Admin emails | `admin@example.com` |

### S3 Configuration

| Variable | Description |
|----------|-------------|
| `DISCOURSE_USE_S3` | Enable S3 (`true`) |
| `DISCOURSE_S3_BUCKET` | Bucket name |
| `DISCOURSE_S3_REGION` | AWS region or `us-east-1` for MinIO |
| `DISCOURSE_S3_ACCESS_KEY_ID` | Access key |
| `DISCOURSE_S3_SECRET_ACCESS_KEY` | Secret key |
| `DISCOURSE_S3_ENDPOINT` | Custom endpoint for MinIO |
| `DISCOURSE_S3_CDN_URL` | Optional CDN URL |

### Scaling Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `UNICORN_WORKERS` | Puma worker processes | Auto-detected |
| `UNICORN_SIDEKIQS` | Sidekiq processes per pod | `1` |

---

## 10. Resource Guidelines

### Minimum (Development/Small)

```yaml
resources:
  requests:
    memory: "512Mi"
    cpu: "250m"
  limits:
    memory: "1Gi"
    cpu: "1000m"
```

### Moderate (Production)

```yaml
resources:
  requests:
    memory: "1Gi"
    cpu: "500m"
  limits:
    memory: "2Gi"
    cpu: "2000m"
```

### Generous (High Traffic)

```yaml
resources:
  requests:
    memory: "2Gi"
    cpu: "1000m"
  limits:
    memory: "4Gi"
    cpu: "4000m"
```

**Note:** Actual requirements depend on traffic, plugins, and configuration. Monitor and adjust.

---

## 11. Health Checks

Discourse provides `/srv/status` endpoint for health checking. This endpoint returns HTTP 200 when the application is healthy and able to serve requests.

### Startup Probe (Required)

**Purpose:** Allow extended startup time for initial boot without triggering liveness failures.

```yaml
startupProbe:
  httpGet:
    path: /srv/status
    port: 80
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 30  # 30 * 10s = 5 minutes max startup time
```

**Why this matters:**
- Initial boot may take 2-5 minutes depending on:
  - Asset loading
  - Plugin initialization
  - Database connection pool warmup
- After migration Job completes, pods still need time to start
- Prevents premature pod restarts during slow startup

### Liveness Probe

**Purpose:** Detect and restart pods that have become unresponsive.

```yaml
livenessProbe:
  httpGet:
    path: /srv/status
    port: 80
  periodSeconds: 30
  timeoutSeconds: 5
  failureThreshold: 3
```

**Note:** No `initialDelaySeconds` needed when using `startupProbe`. Liveness probe only activates after startup succeeds.

### Readiness Probe

**Purpose:** Control when pod receives traffic from Service.

```yaml
readinessProbe:
  httpGet:
    path: /srv/status
    port: 80
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
  successThreshold: 1
```

**Behavior:**
- Pod removed from Service endpoints when probe fails
- Traffic routed to healthy pods only
- Pod added back when probe succeeds

### Probe Endpoint Details

The `/srv/status` endpoint:
- Returns HTTP 200 when healthy
- Checks:
  - Rails application responsiveness
  - Database connectivity
  - Redis/Valkey connectivity
- Does NOT perform expensive operations (no DB queries beyond connection check)
- Safe to call frequently

---

## 12. Operational Requirements

### 12.1 PodDisruptionBudget

**Critical for production reliability.**

A PodDisruptionBudget (PDB) ensures that cluster maintenance (node drains, upgrades) does not take down all replicas simultaneously, preventing downtime.

**Web Deployment PDB:**
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: discourse-web-pdb
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: discourse
      component: web
```

**Sidekiq Deployment PDB (if separated):**
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: discourse-sidekiq-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: discourse
      component: sidekiq
```

**Configuration Guidelines:**
- **Web:** `maxUnavailable: 1` ensures rolling updates leave N-1 replicas serving traffic
- **Sidekiq:** `minAvailable: 1` ensures job processing continues during disruptions
- For 2-replica deployments, use `maxUnavailable: 1` (allows 1 down, 1 up)
- For 3+ replica deployments, use `maxUnavailable: 1` or `minAvailable: 2`

**What PDB Protects Against:**
- Kubernetes node upgrades
- Cluster autoscaler scale-downs
- Node drains for maintenance
- Involuntary pod evictions

**What PDB Does NOT Protect Against:**
- Manual `kubectl delete pod` (PDB can be overridden)
- Pod crashes due to application errors
- Deployment rollouts (controlled by `maxSurge`/`maxUnavailable` in Deployment spec)

### 12.2 Upgrade Runbook

**Pre-Upgrade Checklist:**
- [ ] Review Discourse release notes and breaking changes
- [ ] Verify all plugins are compatible with new Discourse version
- [ ] Take full database backup (CloudNativePG snapshot or pg_dump)
- [ ] Build and test new image in staging environment
- [ ] Verify migration Job runs successfully in staging
- [ ] Document rollback procedure
- [ ] Schedule maintenance window (if downtime expected)
- [ ] Notify users of potential disruption

**Upgrade Procedure:**

**1. Build New Image**
```bash
# Build with new Discourse version + current plugins
docker build -t ghcr.io/ginsys/discourse:v2026.2.0-abc123def456 .

# Push to registry
docker push ghcr.io/ginsys/discourse:v2026.2.0-abc123def456
```

**2. Database Backup**
```bash
# CloudNativePG on-demand backup
kubectl cnpg backup discourse-pg --backup-name pre-v2026-2-0-upgrade

# Or manual pg_dump
kubectl exec -n discourse discourse-pg-1 -- \
  pg_dump -U discourse discourse > backup-pre-v2026-2-0.sql
```

**3. Scale Down Sidekiq (if separated)**
```bash
# Prevents new jobs from being processed during migration
kubectl scale deployment/discourse-sidekiq --replicas=0

# Wait for current jobs to complete (optional)
# Check Redis queue depth before proceeding
```

**4. Run Migration Job**
```bash
# Apply migration Job manifest
kubectl apply -f discourse-migrate-v2026-2-0-job.yaml

# Watch migration progress
kubectl logs -f job/discourse-migrate-20260128-v2026-2-0

# Wait for completion
kubectl wait --for=condition=complete --timeout=600s \
  job/discourse-migrate-20260128-v2026-2-0
```

**5. Roll Web Deployment**
```bash
# Update image
kubectl set image deployment/discourse-web \
  discourse=ghcr.io/ginsys/discourse:v2026.2.0-abc123def456

# Watch rollout
kubectl rollout status deployment/discourse-web

# Verify pods are healthy
kubectl get pods -l app=discourse,component=web
```

**6. Roll Sidekiq Deployment (if separated)**
```bash
# Update image and scale back up
kubectl set image deployment/discourse-sidekiq \
  discourse=ghcr.io/ginsys/discourse:v2026.2.0-abc123def456

kubectl scale deployment/discourse-sidekiq --replicas=2

# Verify pods are healthy
kubectl get pods -l app=discourse,component=sidekiq
```

**7. Post-Upgrade Validation**
```bash
# Check application logs
kubectl logs -l app=discourse --tail=100

# Verify /srv/status endpoint
kubectl exec -it deployment/discourse-web -- curl http://localhost/srv/status

# Smoke test:
# - Login as admin
# - Create test post
# - Upload image
# - Verify real-time updates work
# - Check background jobs are processing
```

**8. Cleanup**
```bash
# Remove old migration Job (after validation)
kubectl delete job/discourse-migrate-20260128-v2026-2-0

# (Optional) Remove old image from registry
# Keep at least N-1 version for rollback
```

**Rollback Procedure:**

**If application fails after upgrade:**
```bash
# 1. Immediate rollback to previous image
kubectl rollout undo deployment/discourse-web
kubectl rollout undo deployment/discourse-sidekiq  # if separated

# 2. Verify pods are running previous version
kubectl get pods -o jsonpath='{.items[*].spec.containers[0].image}'
```

**If database rollback required (DESTRUCTIVE):**
```bash
# 1. Scale down all Discourse pods
kubectl scale deployment/discourse-web --replicas=0
kubectl scale deployment/discourse-sidekiq --replicas=0

# 2. Restore database from backup
# CloudNativePG recovery:
kubectl cnpg restore discourse-pg --backup-name pre-v2026-2-0-upgrade

# Or manual restore:
kubectl exec -i discourse-pg-1 -- \
  psql -U discourse discourse < backup-pre-v2026-2-0.sql

# 3. Deploy previous version
kubectl set image deployment/discourse-web discourse=ghcr.io/ginsys/discourse:v2025.12.0-xyz789abcdef
kubectl scale deployment/discourse-web --replicas=3

# 4. Verify data integrity
# Check recent posts, user data, etc.
```

**Rollback Decision Matrix:**

| Scenario | Code Rollback | DB Rollback | Data Loss |
|----------|---------------|-------------|-----------|
| New code has bugs, migrations added only new tables/columns | Yes | No | None |
| Migration removed columns/tables that old code needs | Yes | Yes | Any data written after upgrade |
| Migration modified data irreversibly | Yes | Yes | Any data written after upgrade |
| Performance regression only | Yes | No | None |

### 12.3 Monitoring and Alerting

**Critical Metrics to Monitor:**

**Application Metrics:**
- HTTP request rate, latency (p50, p95, p99)
- Error rate (4xx, 5xx responses)
- Active user sessions
- Background job queue depth (Sidekiq)
- Background job processing rate
- Failed job count

**Resource Metrics:**
- Pod CPU usage (per pod and aggregate)
- Pod memory usage (per pod and aggregate)
- Database connection pool utilization
- Redis/Valkey memory usage
- Disk usage (if using PVC for /shared)

**Database Metrics (CloudNativePG):**
- Connection count
- Active queries
- Long-running queries (>30s)
- Replication lag (if using replicas)
- Database size growth rate

**Discourse-Specific Metrics:**
- Queued email count
- Failed email deliveries
- Upload processing queue
- Asset generation queue
- Search indexing lag

**Metrics Collection:**

**Option A: discourse-prometheus Plugin**
```ruby
# Add to plugins list at build time
- name: discourse-prometheus
  repo: https://github.com/discourse/discourse-prometheus
```

Exposes `/metrics` endpoint for Prometheus scraping.

**Option B: Sidecar Exporter**

Deploy a sidecar container to export application metrics:
```yaml
containers:
  - name: discourse
    # main container

  - name: metrics-exporter
    image: discourse-metrics-exporter:latest
    ports:
      - containerPort: 9090
        name: metrics
```

**Basic Alerting Thresholds:**

| Metric | Warning | Critical |
|--------|---------|----------|
| HTTP error rate | >2% | >5% |
| Response time p95 | >2s | >5s |
| Sidekiq queue depth | >1000 | >5000 |
| Failed jobs | >50 | >200 |
| Pod memory usage | >80% | >90% |
| Database connections | >80% pool | >95% pool |
| Database replication lag | >30s | >60s |

**Recommended Alerts:**

```yaml
# Example PrometheusRule (if using Prometheus Operator)
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: discourse-alerts
spec:
  groups:
    - name: discourse
      interval: 30s
      rules:
        - alert: DiscourseHighErrorRate
          expr: |
            rate(http_requests_total{status=~"5.."}[5m])
            / rate(http_requests_total[5m]) > 0.05
          for: 5m
          annotations:
            summary: "High error rate on Discourse"

        - alert: DiscourseSidekiqBacklog
          expr: sidekiq_queue_size > 5000
          for: 10m
          annotations:
            summary: "Large Sidekiq queue backlog"

        - alert: DiscoursePodsDown
          expr: |
            kube_deployment_status_replicas_available{deployment="discourse-web"}
            < kube_deployment_spec_replicas{deployment="discourse-web"}
          for: 5m
          annotations:
            summary: "Discourse pods unavailable"
```

**Log Aggregation:**

Discourse logs to stdout/stderr (when using Kubernetes). Ensure cluster has log aggregation configured:
- Fluentd/Fluent Bit to Elasticsearch
- Promtail to Loki
- CloudWatch Logs (if on AWS)
- Google Cloud Logging (if on GCP)

**Key Log Patterns to Alert On:**
- `FATAL` level messages
- Database connection errors: `PG::ConnectionBad`
- Redis connection errors: `Redis::CannotConnectError`
- Failed job patterns: `ERROR: Job failed`
- Memory errors: `OutOfMemoryError`

### 12.4 Sidekiq Operational Considerations

**Scheduler Queue:**

Discourse uses Sidekiq's scheduler queue for periodic tasks (digest emails, badge checks, etc.).

**Critical:** The scheduler queue must run with `concurrency: 1` and should only run in **one pod** across the entire deployment.

**Configuration for Separated Sidekiq:**

**Scheduler Pod (1 replica):**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: discourse-sidekiq-scheduler
spec:
  replicas: 1  # MUST be 1
  template:
    spec:
      containers:
        - name: sidekiq
          env:
            - name: UNICORN_WORKERS
              value: "0"
            - name: UNICORN_SIDEKIQS
              value: "1"
            - name: SIDEKIQ_CONCURRENCY
              value: "1"  # Must be 1 for scheduler
```

**Worker Pods (N replicas):**
```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: discourse-sidekiq-workers
spec:
  replicas: 3
  template:
    spec:
      containers:
        - name: sidekiq
          env:
            - name: UNICORN_WORKERS
              value: "0"
            - name: UNICORN_SIDEKIQS
              value: "5"
            - name: SIDEKIQ_CONCURRENCY
              value: "25"
```

**Why This Matters:**
- Multiple scheduler instances create duplicate scheduled jobs
- Results in duplicate digest emails, duplicate badge grants, etc.
- Scheduler must be single-threaded to avoid race conditions

**For Unified Architecture:**

If running Sidekiq in web pods, ensure only one pod has scheduler enabled:
- Use StatefulSet for web pods
- Configure pod-0 with scheduler, others without
- Or use a separate 1-replica Deployment for scheduler only

### 12.5 Horizontal Pod Autoscaler (HPA)

**Web Pods:**
```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: discourse-web-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: discourse-web
  minReplicas: 3
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
    - type: Resource
      resource:
        name: memory
        target:
          type: Utilization
          averageUtilization: 80
```

**Sidekiq Worker Pods (KEDA for Queue-Based Scaling):**

For advanced use cases, use KEDA to scale Sidekiq workers based on queue depth:

```yaml
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata:
  name: discourse-sidekiq-scaler
spec:
  scaleTargetRef:
    name: discourse-sidekiq-workers
  minReplicaCount: 2
  maxReplicaCount: 8
  triggers:
    - type: redis
      metadata:
        address: valkey.discourse.svc:6379
        listName: sidekiq:queue:default
        listLength: "100"  # Scale up if >100 jobs queued
```

**Scaling Considerations:**
- HPA should not scale below PDB `minAvailable`
- During peak hours, pre-scale to avoid cold start latency
- Monitor queue depth trends to tune `listLength` trigger

### 12.6 Graceful Shutdown

Ensure pods shut down gracefully to avoid disrupting active requests and jobs.

```yaml
spec:
  template:
    spec:
      terminationGracePeriodSeconds: 60
      containers:
        - name: discourse
          lifecycle:
            preStop:
              exec:
                command:
                  - /bin/sh
                  - -c
                  - |
                    # Stop accepting new requests
                    sv stop unicorn
                    # Wait for Sidekiq to finish current jobs
                    sv stop sidekiq
                    # Give time for cleanup
                    sleep 10
```

**Shutdown Sequence:**
1. Pod receives SIGTERM
2. Pod removed from Service endpoints (no new traffic)
3. `preStop` hook runs
4. Application stops accepting new work
5. In-flight requests complete (up to `terminationGracePeriodSeconds`)
6. Pod terminated

### 12.7 Backup and Restore Strategy

**Database Backups (CloudNativePG):**

CloudNativePG provides automated continuous backup:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: discourse-pg
spec:
  backup:
    barmanObjectStore:
      destinationPath: s3://backups/discourse-pg/
      s3Credentials:
        # credentials config
    retentionPolicy: "30d"
```

**Manual On-Demand Backup:**
```bash
kubectl cnpg backup discourse-pg --backup-name manual-$(date +%Y%m%d-%H%M%S)
```

**Application-Level Backups:**

Discourse includes built-in backup functionality:
- Admin panel: /admin/backups
- Generates SQL dump + uploaded files
- Stores in S3 (if configured) or /shared/backups

**Backup Schedule:**
- Database: Continuous WAL archiving + daily base backups
- Application: Weekly full backups via Discourse admin
- Pre-upgrade: Manual backup before every upgrade

**Restore Testing:**
- Test restore procedure quarterly
- Verify backup integrity monthly
- Document RTO (Recovery Time Objective) and RPO (Recovery Point Objective)

**Disaster Recovery Checklist:**
- [ ] Database backup available and verified
- [ ] S3 bucket accessible and replicated
- [ ] Kubernetes manifests in version control
- [ ] Secrets backed up securely (e.g., Vault, sealed-secrets)
- [ ] DNS records documented
- [ ] TLS certificates backed up (or auto-renewed via cert-manager)
- [ ] Runbook for full cluster rebuild

### 12.9 Security Context and Network Policies

**Security Context Considerations:**

The upstream Discourse Docker image runs as `root` with runit as the process supervisor. This creates challenges for clusters with restrictive PodSecurityPolicies or PodSecurityStandards.

**Current State:**
```yaml
securityContext:
  # Upstream image requires root
  runAsUser: 0
  runAsGroup: 0
```

**Implications:**
- Cannot enforce `runAsNonRoot: true`
- May conflict with `restricted` PodSecurityStandard
- Requires privileged namespace or exceptions

**Future Improvement:**
- Build custom image with non-root user
- Replace runit with simpler process manager (s6-overlay, tini)
- Run nginx as non-root (port >1024)

**Network Policies (Recommended):**

Limit pod communication to required services only:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: discourse-web-netpol
spec:
  podSelector:
    matchLabels:
      app: discourse
      component: web
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # Allow from Ingress Controller
    - from:
        - namespaceSelector:
            matchLabels:
              name: ingress-nginx
      ports:
        - protocol: TCP
          port: 80
  egress:
    # Allow to PostgreSQL
    - to:
        - podSelector:
            matchLabels:
              cnpg.io/cluster: discourse-pg
      ports:
        - protocol: TCP
          port: 5432

    # Allow to Valkey
    - to:
        - podSelector:
            matchLabels:
              app: valkey
      ports:
        - protocol: TCP
          port: 6379

    # Allow to S3 (external)
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: TCP
          port: 443

    # Allow to SMTP (external)
    - to:
        - namespaceSelector: {}
      ports:
        - protocol: TCP
          port: 587

    # Allow DNS
    - to:
        - namespaceSelector:
            matchLabels:
              name: kube-system
      ports:
        - protocol: UDP
          port: 53
```

**Network Policy Guidelines:**
- Start with permissive policies in staging
- Monitor traffic patterns with network policy logging
- Incrementally tighten policies
- Document external dependencies (SMTP, S3, CDN)

### 12.8 Plugin Compatibility Notes

**Critical for Multi-Replica Deployments:**

Not all Discourse plugins are compatible with Kubernetes multi-replica deployments.

**Compatibility Requirements:**
- **No local filesystem writes** (except to /tmp or emptyDir volumes)
- **No server-specific state** stored in memory across requests
- **S3-compatible** for any file storage needs

**Known Problematic Patterns:**
- Plugins writing to `/shared/plugins/plugin-name/data/`
- Plugins caching data in local files instead of Redis
- Plugins assuming single-server deployment

**Vetting Process:**
1. Review plugin source code for filesystem writes
2. Test in multi-replica staging environment
3. Monitor for inconsistent behavior across pods
4. Check plugin documentation for multi-server support

**Recommended Plugins (Known Compatible):**
- discourse-solved
- discourse-voting
- discourse-sitemap
- discourse-calendar
- discourse-prometheus (for metrics)

**Plugins Requiring Special Configuration:**
- discourse-prometheus: Configure to export from all pods
- discourse-backup: Ensure S3 configured for multi-replica

---

## Appendix A: Upstream Discourse Docker Architecture

### Base Image (`discourse/base`)

Contains:
- Ubuntu base
- Ruby 3.4
- PostgreSQL client libraries
- Redis client
- Nginx
- ImageMagick
- runit (process supervisor)
- pups (template processor)

### Bootstrap Process

Standard upstream bootstrap:
```
1. Pull discourse/base
2. Apply pups templates (web.template.yml, etc.)
3. Clone Discourse code (specified version)
4. Clone plugins (from hooks.after_code)
5. bundle install
6. rake assets:precompile
7. Commit as new image
```

**This project's build** uses `pups --skip-tags migrate,precompile`, which skips step 6 (and any migration steps). Precompilation and migrations are instead handled at deploy time via a Kubernetes Job or on-boot environment variables.

### What's Baked vs Runtime

| Baked at Build Time | Configured at Runtime |
|---------------------|----------------------|
| Ruby version | Database connection |
| Discourse version | Redis connection |
| Plugins | SMTP settings |
| Nginx config | S3 settings |
| Bundled gems | Site hostname |
| Ember CLI assets | Worker counts |

**Note:** In this project's K8s build, asset precompilation and DB migrations are deferred to deploy time (handled by a Job or on-boot env vars) since the build runs without a database.

---

## Appendix B: Template Details

### web.template.yml

Core template that configures:
- Nginx reverse proxy (listens on :80)
- Puma application server (listens on :3000 internally)
- Sidekiq background processor
- runit service supervision
- Anacron for scheduled tasks
- Log rotation
- Shared directory structure

### web.ratelimited.template.yml

Adds nginx rate limiting:
- 12 requests/second per IP
- 100 requests/minute per IP
- Configurable via params

### offline-page.template.yml

Provides maintenance page functionality during upgrades/maintenance.

### web.ipv6.template.yml (Optional)

Adds IPv6 listener to nginx. Only needed if cluster has IPv6 networking.

---

## Appendix C: Glossary

| Term | Definition |
|------|------------|
| **pups** | Discourse's YAML-based template processor |
| **launcher** | Shell script that orchestrates Docker operations |
| **MessageBus** | Discourse's real-time messaging system |
| **Sidekiq** | Ruby background job processor |
| **runit** | Process supervisor used inside container |
| **CloudNativePG** | Kubernetes operator for PostgreSQL |
| **Valkey** | Redis-compatible in-memory data store (Linux Foundation) |
| **UNICORN_WORKERS** | Legacy environment variable name; Discourse now uses Puma (not Unicorn) as application server, but variable name retained for backward compatibility |
| **UNICORN_SIDEKIQS** | Number of Sidekiq worker processes to run in container |
| **Puma** | Current Ruby application server used by Discourse (replaced Unicorn) |
| **PDB** | PodDisruptionBudget - Kubernetes resource that limits voluntary disruptions |
| **HPA** | HorizontalPodAutoscaler - Automatically scales pods based on metrics |
| **KEDA** | Kubernetes Event-Driven Autoscaling - Advanced autoscaling based on event sources like queue depth |
