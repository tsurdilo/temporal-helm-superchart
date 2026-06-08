#!/bin/bash
# teardown.sh — Completely removes the temporal-stack release and all associated resources.
#
# Removes:
#   - Helm release (all chart-managed resources)
#   - temporal-dynconfig ConfigMap (kept by helm.sh/resource-policy: keep)
#   - temporal namespace
#   - temporal-custom-server and temporal-health-poller Docker images
#
# Usage:
#   bash teardown.sh           # removes everything including Docker images
#   bash teardown.sh --keep-images   # skip Docker image removal

set -e

NAMESPACE=${NAMESPACE:-temporal}
RELEASE=${RELEASE:-temporal-stack}
KEEP_IMAGES=false

for arg in "$@"; do
  case $arg in
    --keep-images) KEEP_IMAGES=true ;;
  esac
done

echo "==> Uninstalling Helm release '$RELEASE' from namespace '$NAMESPACE'..."
helm uninstall "$RELEASE" --namespace "$NAMESPACE" 2>/dev/null \
  && echo "    Release removed." \
  || echo "    Release not found (already gone)."

echo "==> Deleting temporal-dynconfig ConfigMap (resource-policy: keep)..."
kubectl delete configmap temporal-dynconfig -n "$NAMESPACE" 2>/dev/null \
  && echo "    ConfigMap deleted." \
  || echo "    ConfigMap not found (already gone)."

echo "==> Deleting namespace '$NAMESPACE'..."
kubectl delete namespace "$NAMESPACE" 2>/dev/null \
  && echo "    Waiting for namespace to be fully gone..." \
  || echo "    Namespace not found (already gone)."
until ! kubectl get namespace "$NAMESPACE" &>/dev/null; do sleep 2; done
echo "    Namespace gone."

if [[ "$KEEP_IMAGES" == "false" ]]; then
  echo "==> Removing Docker images..."
  docker rmi temporal-custom-server:latest 2>/dev/null \
    && echo "    temporal-custom-server removed." \
    || echo "    temporal-custom-server not found (already gone)."
  docker rmi temporal-health-poller:latest 2>/dev/null \
    && echo "    temporal-health-poller removed." \
    || echo "    temporal-health-poller not found (already gone)."
else
  echo "==> Skipping Docker image removal (--keep-images)."
fi

echo ""
echo "==> Teardown complete."
echo ""
echo "To do a fresh install from scratch:"
echo "  bash build.sh --server-version v1.31.0"
echo "  bash install.sh"
