#!/bin/bash
# scripts/extract-upstream-versions.sh
# Extracts dependency versions and config from discourse_docker submodule
# Output: shell-sourceable KEY=VALUE pairs
#
# Usage (assign first so `set -e` catches a non-zero exit; `eval "$(...)"` does not):
#   VARS=$(./scripts/extract-upstream-versions.sh)
#   eval "$VARS"
#   echo "$PG_VERSION"   # e.g. 18
#   echo "$BASE_IMAGE"   # e.g. discourse/base:2.0.20260812-0036
#   echo "$REDIS_VERSION"  # e.g. debian-trixie -- provenance, not a pinned semver

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DD="${DD_DIR:-$REPO_ROOT/discourse_docker}"

PG_VERSION=$(grep -oP '^ARG PG_MAJOR=\K.+' "$DD/image/base/Dockerfile" 2>/dev/null || true)
RUBY_VERSION=$(grep -oP '^ARG RUBY_VERSION=\K.+' "$DD/image/base/Dockerfile" 2>/dev/null || true)
DEBIAN_RELEASE=$(grep -oP '^ARG DEBIAN_RELEASE=\K.+' "$DD/image/base/Dockerfile" 2>/dev/null || true)
BASE_IMAGE=$(grep '^image=' "$DD/launcher" 2>/dev/null | head -1 | tr -d '"' | cut -d= -f2 || true)

# Validate all values were extracted
for var in PG_VERSION RUBY_VERSION BASE_IMAGE DEBIAN_RELEASE; do
  if [ -z "${!var}" ]; then
    echo "ERROR: Failed to extract $var from discourse_docker submodule" >&2
    exit 1
  fi
done

# Redis is no longer built/pinned upstream (discourse/discourse_docker#1108, 2026-08-11): it's installed
# from Debian's own package, so there is no upstream version to extract. Record the Debian
# release as provenance instead of a fabricated version string.
REDIS_VERSION="debian-${DEBIAN_RELEASE}"

echo "PG_VERSION=$PG_VERSION"
echo "REDIS_VERSION=$REDIS_VERSION"
echo "RUBY_VERSION=$RUBY_VERSION"
echo "BASE_IMAGE=$BASE_IMAGE"
echo "DEBIAN_RELEASE=$DEBIAN_RELEASE"
