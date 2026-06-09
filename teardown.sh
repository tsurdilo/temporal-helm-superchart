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
#   bash teardown.sh                 # removes everything including Docker images
#   bash teardown.sh --keep-images   # skip Docker image removal

set -e

NAMESPACE=${NAMESPACE:-temporal}
RELEASE=${RELEASE:-temporal-stack}
KEEP_IMAGES=false
TOTAL_STEPS=4

for arg in "$@"; do
  case $arg in
    --keep-images) KEEP_IMAGES=true; TOTAL_STEPS=3 ;;
  esac
done

step() {
  echo ""
  echo "──────────────────────────────────────────────"
  echo "  Step $1 of $TOTAL_STEPS — $2"
  echo "──────────────────────────────────────────────"
}

# ── Step 1 ─────────────────────────────────────────
step 1 "Uninstalling Helm release"
helm uninstall "$RELEASE" --namespace "$NAMESPACE" 2>/dev/null \
  && echo "  Release removed." \
  || echo "  Release not found (already gone)."

# ── Step 2 ─────────────────────────────────────────
step 2 "Deleting dynconfig ConfigMap"
echo "  (This ConfigMap is excluded from helm uninstall by resource-policy: keep)"
kubectl delete configmap temporal-dynconfig -n "$NAMESPACE" 2>/dev/null \
  && echo "  ConfigMap deleted." \
  || echo "  ConfigMap not found (already gone)."

# ── Step 3 ─────────────────────────────────────────
step 3 "Deleting namespace '$NAMESPACE'"
echo "  (This removes all remaining resources and PersistentVolumes)"
kubectl delete namespace "$NAMESPACE" 2>/dev/null \
  && echo "  Namespace deletion in progress..." \
  || echo "  Namespace not found (already gone)."
echo "  Waiting for namespace to be fully gone..."
until ! kubectl get namespace "$NAMESPACE" &>/dev/null; do sleep 2; done
echo "  Namespace gone."

# ── Step 4 ─────────────────────────────────────────
if [[ "$KEEP_IMAGES" == "false" ]]; then
  step 4 "Removing Docker images"
  docker rmi temporal-custom-server:latest 2>/dev/null \
    && echo "  temporal-custom-server removed." \
    || echo "  temporal-custom-server not found (already gone)."
  docker rmi temporal-health-poller:latest 2>/dev/null \
    && echo "  temporal-health-poller removed." \
    || echo "  temporal-health-poller not found (already gone)."
else
  echo ""
  echo "  Skipping Docker image removal (--keep-images)."
fi

echo ""
echo "══════════════════════════════════════════════"
echo "  Teardown complete! (all $TOTAL_STEPS steps passed)"
echo "══════════════════════════════════════════════"
echo ""
echo "  To reinstall:"
echo "    bash install.sh"
echo ""
