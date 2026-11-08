#!/bin/bash
# scripts/extract-upstream-versions.sh
# Extracts dependency versions and config from discourse_docker submodule
# Sources: image/base/Dockerfile (PG, Ruby, Debian release), templates/web.template.yml (base image)
# Output: shell-sourceable KEY=VALUE pairs, each value checked to be a plain literal
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
# Since discourse/discourse_docker#1152 the launcher reads its image from this template line,
# so the template is the source. The launcher's own `image=` line is now a shell command.
BASE_IMAGE=$(sed -n 's/^base_image:[[:space:]]*//p' "$DD/templates/web.template.yml" 2>/dev/null \
  | head -1 | tr -d "\"'" | sed 's/[[:space:]]*$//' || true)

# Validate all values were extracted
for var in PG_VERSION RUBY_VERSION BASE_IMAGE DEBIAN_RELEASE; do
  if [ -z "${!var}" ]; then
    echo "ERROR: Failed to extract $var from discourse_docker submodule" >&2
    exit 1
  fi
done

# Callers eval this script's output, so every value must be a plain literal. Anything else
# (a backtick, a $, a space) means the upstream format changed: fail here, never let it run.
VERSION_RE='^[A-Za-z0-9._-]+$'
IMAGE_RE='^[A-Za-z0-9._/-]+:[A-Za-z0-9._-]+$'
for var in PG_VERSION RUBY_VERSION DEBIAN_RELEASE BASE_IMAGE; do
  re="$VERSION_RE"
  [ "$var" = BASE_IMAGE ] && re="$IMAGE_RE"
  if ! [[ "${!var}" =~ $re ]]; then
    echo "ERROR: Failed to extract $var from discourse_docker submodule (unexpected value: ${!var})" >&2
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
