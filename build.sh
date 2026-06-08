#!/bin/bash
set -e

# Build context is ~/devel — Dockerfiles COPY from sibling directories.
# Both images use pullPolicy: Never so they must exist in the local Docker cache
# before running install.sh.
#
# Usage:
#   bash build.sh                        # build against current server checkout
#   bash build.sh --server-version v1.31.0  # checkout that tag first, then build

BUILD_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SERVER_DIR="$BUILD_DIR/temporal/temporal"

# Parse --server-version flag
SERVER_VERSION=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-version)
      SERVER_VERSION="$2"
      shift 2
      ;;
    *)
      echo "Unknown argument: $1"
      echo "Usage: bash build.sh [--server-version v1.31.0]"
      exit 1
      ;;
  esac
done

# Optionally check out a specific server release tag
if [[ -n "$SERVER_VERSION" ]]; then
  echo "==> Checking out Temporal server $SERVER_VERSION"
  git -C "$SERVER_DIR" fetch --tags
  git -C "$SERVER_DIR" checkout "$SERVER_VERSION"
fi

# Show which server commit we are building against
CURRENT_REF="$(git -C "$SERVER_DIR" describe --tags --always 2>/dev/null || echo unknown)"
echo "==> Building against server: $CURRENT_REF ($(git -C "$SERVER_DIR" rev-parse --short HEAD 2>/dev/null))"

SERVER_API_VERSION="$(grep 'go.temporal.io/api' "$SERVER_DIR/go.mod" | awk '{print $2}' | head -1)"
# Align go.temporal.io/api across every go.mod in the Docker build graph.
# MVS picks the highest version across all modules, so all must pin the server's version.
# (can't run go get here because replace directives point to /deps/ Docker paths)
DYNCONFIG_DIR="$BUILD_DIR/temporal-configmap-dynconfig"
for GOMOD in "$(dirname "$0")/images/server/go.mod" "$DYNCONFIG_DIR/go.mod"; do
  CURRENT="$(grep 'go.temporal.io/api' "$GOMOD" | awk '{print $2}' | head -1)"
  if [[ "$CURRENT" != "$SERVER_API_VERSION" ]]; then
    echo "==> Aligning go.temporal.io/api in $GOMOD: $CURRENT -> $SERVER_API_VERSION"
    sed -i '' "s|go.temporal.io/api $CURRENT|go.temporal.io/api $SERVER_API_VERSION|" "$GOMOD"
  fi
done

echo "==> Building temporal-custom-server:latest (server: $CURRENT_REF)"
docker build --no-cache \
  -t temporal-custom-server:latest \
  -f "$BUILD_DIR/temporal-helm-superchart/images/server/Dockerfile" \
  "$BUILD_DIR"

echo "==> Building temporal-health-poller:latest"
docker build --no-cache \
  -t temporal-health-poller:latest \
  "$(dirname "$0")/images/poller"

echo "==> Images built:"
docker images --format "  {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}" \
  | grep -E "temporal-custom-server|temporal-health-poller"
