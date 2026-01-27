# Discourse on Kubernetes: Architecture Document

## Document Information

| Item | Value |
|------|-------|
| Version | 1.0 |
| Date | 2026-01-27 |
| Status | Architecture Decided |

---

## 1. Executive Summary

This document defines the architecture for deploying Discourse forum platform on Kubernetes (Talos Linux / Hetzner infrastructure). The design philosophy is to stay as close to upstream Discourse Docker as possible while enabling cloud-native deployment patterns.

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
| Required Extensions | `hstore`, `pg_trgm` |
| Extension Scope | Must be installed in both `template1` AND the discourse database |

**CloudNativePG Cluster Configuration Notes:**
- Enable `hstore` and `pg_trgm` extensions
- Configure appropriate connection pooling
- Set up automated backups

### 4.2 Valkey (Redis-compatible)

| Requirement | Value |
|-------------|-------|
| Minimum Version | 7 |
| Compatibility | Drop-in Redis replacement confirmed |

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

## 8. Environment Variables Reference

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

### Build/Boot Options

| Variable | Description |
|----------|-------------|
| `MIGRATE_ON_BOOT` | Run migrations on startup (`1`/`0`) |
| `PRECOMPILE_ON_BOOT` | Precompile assets on startup (`1`/`0`) |

---

## 9. Resource Guidelines

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

## 10. Health Checks

### Liveness Probe

```yaml
livenessProbe:
  httpGet:
    path: /srv/status
    port: 80
  initialDelaySeconds: 120
  periodSeconds: 30
  timeoutSeconds: 5
  failureThreshold: 3
```

### Readiness Probe

```yaml
readinessProbe:
  httpGet:
    path: /srv/status
    port: 80
  initialDelaySeconds: 30
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
```

---

## 11. Next Steps

### Phase 1: Docker Image Build Strategy (NEXT)

**Objective:** Investigate and document how to build Docker images based on upstream `discourse/discourse_docker` repository.

**Goals:**
1. **Avoid forking** the upstream repository
2. Create a **tracking repository** that:
   - Monitors upstream releases
   - Contains build scripts for our custom images
   - Manages plugin configurations
3. Establish **automated build pipeline** triggered by:
   - Upstream version releases
   - Plugin updates
   - Configuration changes

**Key Questions to Investigate:**
- How does `./launcher bootstrap` work internally?
- Can we replicate the build process in CI/CD (GitHub Actions, etc.)?
- What's the minimum viable build configuration for K8s?
- How to handle plugin inclusion at build time?
- Image tagging and versioning strategy?

**Deliverables:**
- Build repository structure
- CI/CD pipeline configuration
- Documentation for adding/removing plugins
- Version tracking mechanism

### Phase 2: Kubernetes Manifests

- Base Kustomize structure
- CloudNativePG Cluster definition
- Valkey StatefulSet
- Discourse Deployment
- Ingress configuration
- Secret management approach

### Phase 3: Deployment Automation

- Per-customer overlay structure
- GitOps integration
- Backup/restore procedures
- Upgrade runbook

---

## Appendix A: Upstream Discourse Docker Architecture

### Base Image (`discourse/base`)

Contains:
- Ubuntu base
- Ruby 3.3
- PostgreSQL client libraries
- Redis client
- Nginx
- ImageMagick
- runit (process supervisor)
- pups (template processor)

### Bootstrap Process

```
1. Pull discourse/base
2. Apply pups templates (web.template.yml, etc.)
3. Clone Discourse code (specified version)
4. Clone plugins (from hooks.after_code)
5. bundle install
6. rake assets:precompile
7. Commit as new image
```

### What's Baked vs Runtime

| Baked at Build Time | Configured at Runtime |
|---------------------|----------------------|
| Ruby version | Database connection |
| Discourse version | Redis connection |
| Plugins | SMTP settings |
| Precompiled assets | S3 settings |
| Nginx config | Site hostname |
| Bundled gems | Worker counts |

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
