#!/bin/bash
# scripts/build.sh
# Local build helper script for testing

set -e

DISCOURSE_VERSION="${1:-latest}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_ROOT"

echo "Building Discourse image for version: $DISCOURSE_VERSION"

# Generate plugin hash
PLUGINS_HASH=$(sha256sum plugins.yml | cut -c1-12)
echo "Plugin hash: $PLUGINS_HASH"

# Generate version manifest
echo "Generating version manifest..."
./scripts/generate-manifest.sh "$DISCOURSE_VERSION" "$PLUGINS_HASH" > /tmp/version-manifest.yaml

echo "Building image with discourse_docker launcher..."

# Copy our container config into discourse_docker/containers/
cp "$REPO_ROOT/containers/k8s-web.yml" "$REPO_ROOT/discourse_docker/containers/k8s-web.yml"

cd discourse_docker

export DISCOURSE_VERSION="$DISCOURSE_VERSION"
./launcher bootstrap k8s-web

# Clean up the copied config
rm -f containers/k8s-web.yml

echo "Adding version manifest to image..."
cd "$REPO_ROOT"

cat > /tmp/Dockerfile.manifest << 'EOF'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
COPY version-manifest.yaml /version-manifest.yaml
EOF

docker build \
  --build-arg BASE_IMAGE=local_discourse/k8s-web \
  -f /tmp/Dockerfile.manifest \
  -t discourse-k8s:${DISCOURSE_VERSION}-${PLUGINS_HASH} \
  /tmp/

echo ""
echo "Build complete!"
echo "Image: discourse-k8s:${DISCOURSE_VERSION}-${PLUGINS_HASH}"
echo ""
echo "To run locally (requires PostgreSQL and Redis):"
echo "  docker run -it --rm discourse-k8s:${DISCOURSE_VERSION}-${PLUGINS_HASH} bash"
