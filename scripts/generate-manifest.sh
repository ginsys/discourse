#!/bin/bash
# scripts/generate-manifest.sh
# Generates a version manifest for the built Docker image

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DISCOURSE_VERSION="$1"
PLUGINS_HASH="$2"

if [ -z "$DISCOURSE_VERSION" ] || [ -z "$PLUGINS_HASH" ]; then
  echo "Usage: $0 <discourse_version> <plugins_hash>" >&2
  exit 1
fi

# Extract dependency versions from discourse_docker submodule
eval "$("$SCRIPT_DIR/extract-upstream-versions.sh")"

cat << EOF
discourse:
  version: "${DISCOURSE_VERSION}"

plugins_hash: "${PLUGINS_HASH}"

plugins:
$(if [ -f plugins.yml ] && [ "$(yq e '.plugins | length' plugins.yml)" -gt 0 ]; then
    yq e '.plugins[] | "  - name: " + .name + "\n    repo: " + .repo + "\n    ref: " + (.ref // "latest")' plugins.yml
  else
    echo "  []"
  fi)

dependencies:
  postgresql: "${PG_VERSION}"
  redis: "${REDIS_VERSION}"
  ruby: "${RUBY_VERSION}"

build:
  timestamp: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  builder: "github-actions"
  workflow_run: "${GITHUB_RUN_ID:-local}"
  commit: "${GITHUB_SHA:-$(git rev-parse HEAD 2>/dev/null || echo 'unknown')}"
EOF
