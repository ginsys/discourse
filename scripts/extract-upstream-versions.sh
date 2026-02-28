#!/bin/bash
# scripts/extract-upstream-versions.sh
# Extracts dependency versions and config from discourse_docker submodule
# Output: shell-sourceable KEY=VALUE pairs
#
# Usage:
#   eval "$(./scripts/extract-upstream-versions.sh)"
#   echo "$PG_VERSION"   # e.g. 15
#   echo "$BASE_IMAGE"   # e.g. discourse/base:2.0.20260209-1300

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DD="$REPO_ROOT/discourse_docker"

PG_VERSION=$(grep -oP '^ARG PG_MAJOR=\K.+' "$DD/image/base/Dockerfile")
REDIS_VERSION=$(grep -oP '^REDIS_VERSION=\K.+' "$DD/image/base/install-redis")
RUBY_VERSION=$(grep -oP '^ARG RUBY_VERSION=\K.+' "$DD/image/base/Dockerfile")
BASE_IMAGE=$(grep '^image=' "$DD/launcher" 2>/dev/null | head -1 | tr -d '"' | cut -d= -f2)

# Validate all values were extracted
for var in PG_VERSION REDIS_VERSION RUBY_VERSION BASE_IMAGE; do
  if [ -z "${!var}" ]; then
    echo "ERROR: Failed to extract $var from discourse_docker submodule" >&2
    exit 1
  fi
done

echo "PG_VERSION=$PG_VERSION"
echo "REDIS_VERSION=$REDIS_VERSION"
echo "RUBY_VERSION=$RUBY_VERSION"
echo "BASE_IMAGE=$BASE_IMAGE"
