#!/bin/bash
# scripts/build.sh
# Local build helper script for testing

set -e

DISCOURSE_VERSION="${1:-latest}"
PLUGINS_CONFIG="${2:-default}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

echo "Building Discourse image for version: $DISCOURSE_VERSION"
echo "Using plugins config: $PLUGINS_CONFIG"

# Check if plugins config exists
PLUGINS_FILE="config/plugins/${PLUGINS_CONFIG}.yaml"
if [ ! -f "$PLUGINS_FILE" ]; then
  echo "ERROR: Plugin config not found: $PLUGINS_FILE"
  exit 1
fi

# Prepare merged config
cp config/basecontainer.yaml /tmp/container.yaml

# Merge plugins into hooks
yq -i '.hooks.after_code[0].exec.cmd = load("'$PLUGINS_FILE'").plugins' /tmp/container.yaml

# Substitute version
sed -i "s|{{ DISCOURSE_VERSION }}|$DISCOURSE_VERSION|g" /tmp/container.yaml

# Generate config hash
CONFIG_HASH=$(sha256sum /tmp/container.yaml | cut -c1-12)
echo "Config hash: $CONFIG_HASH"

# Generate version manifest
echo "Generating version manifest..."
./scripts/generate-manifest.sh "$DISCOURSE_VERSION" "$CONFIG_HASH" > /tmp/version-manifest.yaml

echo "Building image with k8s-bootstrap script..."

# Copy merged config into discourse_docker/containers/
cp /tmp/container.yaml "$REPO_ROOT/discourse_docker/containers/basecontainer.yaml"

# Build using k8s-bootstrap
export PUPS_SKIP_TAGS="migrate,precompile"
./scripts/k8s-bootstrap basecontainer

# Clean up the copied config
rm -f "$REPO_ROOT/discourse_docker/containers/basecontainer.yaml"

echo "Adding version manifest to image..."
cd "$REPO_ROOT"

# Extract dependency versions for OCI labels
PG_VERSION=$(grep -oP '^ARG PG_MAJOR=\K.+' "$REPO_ROOT/discourse_docker/image/base/Dockerfile")
REDIS_VERSION=$(grep -oP '^REDIS_VERSION=\K.+' "$REPO_ROOT/discourse_docker/image/base/install-redis")
RUBY_VERSION=$(grep -oP '^ARG RUBY_VERSION=\K.+' "$REPO_ROOT/discourse_docker/image/base/Dockerfile")

cat > /tmp/Dockerfile.manifest << 'EOF'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
ARG PG_VERSION REDIS_VERSION RUBY_VERSION
LABEL org.discourse.postgresql-version="${PG_VERSION}" \
      org.discourse.redis-version="${REDIS_VERSION}" \
      org.discourse.ruby-version="${RUBY_VERSION}"
COPY version-manifest.yaml /version-manifest.yaml
EOF

docker build \
  --build-arg BASE_IMAGE=local_discourse/basecontainer \
  --build-arg PG_VERSION="$PG_VERSION" \
  --build-arg REDIS_VERSION="$REDIS_VERSION" \
  --build-arg RUBY_VERSION="$RUBY_VERSION" \
  -f /tmp/Dockerfile.manifest \
  -t discourse-k8s:${DISCOURSE_VERSION}-${CONFIG_HASH} \
  /tmp/

echo ""
echo "Build complete!"
echo "Image: discourse-k8s:${DISCOURSE_VERSION}-${CONFIG_HASH}"
echo ""
echo "To run locally (requires PostgreSQL and Redis):"
echo "  docker run -it --rm discourse-k8s:${DISCOURSE_VERSION}-${CONFIG_HASH} bash"
