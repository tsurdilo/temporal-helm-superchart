#!/bin/bash
# upgrade-test.sh — End-to-end upgrade test: installs at v1.30.0, then upgrades to v1.31.0.
#
# This script temporarily patches Chart.yaml and the namespace-init template to use
# v1.30.x chart/image pins, installs the stack, runs schema migrations, then upgrades
# to v1.31.0. Chart.yaml is restored to v1.31.0 at the end regardless of outcome.
#
# Usage:
#   bash upgrade-test.sh
#
# Prerequisites:
#   - Docker Desktop running with Kubernetes enabled (context: docker-desktop)
#   - ~/devel/temporal/temporal checkout present (used by build.sh)
#   Everything else (helm repos, images) is handled by this script.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─────────────────────────────────────────────────────────────────
# PRE-FLIGHT
# ─────────────────────────────────────────────────────────────────

echo "==> Checking prerequisites..."

# Kubernetes context
KUBE_CTX=$(kubectl config current-context 2>/dev/null || echo "")
if [[ "$KUBE_CTX" != "docker-desktop" ]]; then
  echo "ERROR: kubectl context is '$KUBE_CTX', expected 'docker-desktop'."
  echo "       Switch with: kubectl config use-context docker-desktop"
  exit 1
fi
echo "    kubectl context: $KUBE_CTX"

# Server checkout
SERVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)/temporal/temporal"
if [[ ! -d "$SERVER_DIR/.git" ]]; then
  echo "ERROR: Temporal server checkout not found at $SERVER_DIR"
  echo "       Clone it with: git clone https://github.com/temporalio/temporal $SERVER_DIR"
  exit 1
fi
echo "    Server checkout: $SERVER_DIR"

echo "==> Adding/updating Helm repositories..."
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo add temporal https://go.temporal.io/helm-charts 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update
echo "    Helm repos ready."

NAMESPACE=temporal
RELEASE=temporal-stack

FROM_SERVER=v1.30.0
TO_SERVER=v1.31.0
FROM_CHART=1.1.1
TO_CHART=1.2.0
FROM_ADMINTOOLS=1.30.3
TO_ADMINTOOLS=1.31.0

# Restore Chart.yaml and namespace-init to v1.31.0 on exit (success or failure)
restore() {
  echo ""
  echo "==> Restoring chart files to $TO_SERVER ..."
  sed -i '' "s|version: \"$FROM_CHART\"|version: \"$TO_CHART\"|" "$SCRIPT_DIR/Chart.yaml"
  sed -i '' "s|admin-tools:$FROM_ADMINTOOLS|admin-tools:$TO_ADMINTOOLS|" \
    "$SCRIPT_DIR/templates/temporal-namespace-init.yaml"
  helm dependency update "$SCRIPT_DIR" --quiet
  echo "    Chart restored to $TO_SERVER."
}
trap restore EXIT

# ─────────────────────────────────────────────────────────────────
# PHASE A — Install at v1.30.0
# ─────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  PHASE A — Installing Temporal $FROM_SERVER"
echo "══════════════════════════════════════════════════════════════"

echo ""
echo "==> A1: Tearing down any existing install..."
helm uninstall "$RELEASE" --namespace "$NAMESPACE" 2>/dev/null || true
kubectl delete namespace "$NAMESPACE" 2>/dev/null || true
echo "    Waiting for namespace to be fully gone..."
until ! kubectl get namespace "$NAMESPACE" &>/dev/null; do sleep 2; done
echo "    Namespace gone."

echo ""
echo "==> A2: Patching chart to $FROM_SERVER (chart $FROM_CHART, admintools $FROM_ADMINTOOLS)..."
sed -i '' "s|version: \"$TO_CHART\"|version: \"$FROM_CHART\"|" "$SCRIPT_DIR/Chart.yaml"
sed -i '' "s|admin-tools:$TO_ADMINTOOLS|admin-tools:$FROM_ADMINTOOLS|" \
  "$SCRIPT_DIR/templates/temporal-namespace-init.yaml"
helm dependency update "$SCRIPT_DIR" --quiet
echo "    Chart patched."

echo ""
echo "==> A3: Building custom server image at $FROM_SERVER..."
bash "$SCRIPT_DIR/build.sh" --server-version "$FROM_SERVER"

echo ""
echo "==> A4: Installing stack at $FROM_SERVER..."
bash "$SCRIPT_DIR/install.sh"

echo ""
echo "==> A5: Verifying install at $FROM_SERVER..."
kubectl exec -n "$NAMESPACE" deployment/"$RELEASE"-admintools -- \
  temporal --address "$RELEASE"-frontend:7233 operator cluster describe \
  | grep -i "server\|version" || true

echo ""
echo "==> A6: Checking schema versions..."
MAIN_SCHEMA=$(kubectl exec -it -n "$NAMESPACE" deployment/"$RELEASE"-admintools -- \
  PGPASSWORD=temporal psql -h "$RELEASE"-postgresql -U temporal -d temporal \
  -t -c "SELECT curr_version FROM schema_version;" 2>/dev/null | tr -d '[:space:]')
VIS_SCHEMA=$(kubectl exec -it -n "$NAMESPACE" deployment/"$RELEASE"-admintools -- \
  PGPASSWORD=temporal psql -h "$RELEASE"-postgresql -U temporal -d temporal_visibility \
  -t -c "SELECT curr_version FROM schema_version;" 2>/dev/null | tr -d '[:space:]')
echo "    main=$MAIN_SCHEMA  visibility=$VIS_SCHEMA"
if [[ "$MAIN_SCHEMA" != "1.18" ]]; then
  echo "ERROR: expected main schema 1.18, got $MAIN_SCHEMA"; exit 1
fi
if [[ "$VIS_SCHEMA" != "1.13" ]]; then
  echo "ERROR: expected visibility schema 1.13, got $VIS_SCHEMA"; exit 1
fi
echo "    Schema versions confirmed."

# ─────────────────────────────────────────────────────────────────
# PHASE B — Upgrade to v1.31.0
# ─────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  PHASE B — Upgrading to Temporal $TO_SERVER"
echo "══════════════════════════════════════════════════════════════"

echo ""
echo "==> B1: Running schema migrations via temporary admintools pod ($TO_ADMINTOOLS)..."
kubectl run schema-migration --rm -i \
  --image=temporalio/admin-tools:"$TO_ADMINTOOLS" \
  --restart=Never \
  -n "$NAMESPACE" \
  --command -- /bin/sh -c "
set -e
echo '--- Migrating main DB: v1.18 -> v1.19 ---'
temporal-sql-tool \
  --ep ${RELEASE}-postgresql --port 5432 \
  --plugin postgres12 --user temporal --password temporal \
  --db temporal \
  update-schema \
  --schema-dir /etc/temporal/schema/postgresql/v12/temporal/versioned

echo '--- Migrating visibility DB: v1.13 -> v1.14 ---'
temporal-sql-tool \
  --ep ${RELEASE}-postgresql --port 5432 \
  --plugin postgres12 --user temporal --password temporal \
  --db temporal_visibility \
  update-schema \
  --schema-dir /etc/temporal/schema/postgresql/v12/visibility/versioned

echo '--- Schema migration complete ---'
"

echo ""
echo "==> B2: Verifying post-migration schema versions..."
MAIN_SCHEMA=$(kubectl exec -it -n "$NAMESPACE" deployment/"$RELEASE"-admintools -- \
  PGPASSWORD=temporal psql -h "$RELEASE"-postgresql -U temporal -d temporal \
  -t -c "SELECT curr_version FROM schema_version;" 2>/dev/null | tr -d '[:space:]')
VIS_SCHEMA=$(kubectl exec -it -n "$NAMESPACE" deployment/"$RELEASE"-admintools -- \
  PGPASSWORD=temporal psql -h "$RELEASE"-postgresql -U temporal -d temporal_visibility \
  -t -c "SELECT curr_version FROM schema_version;" 2>/dev/null | tr -d '[:space:]')
echo "    main=$MAIN_SCHEMA  visibility=$VIS_SCHEMA"
if [[ "$MAIN_SCHEMA" != "1.19" ]]; then
  echo "ERROR: expected main schema 1.19, got $MAIN_SCHEMA"; exit 1
fi
if [[ "$VIS_SCHEMA" != "1.14" ]]; then
  echo "ERROR: expected visibility schema 1.14, got $VIS_SCHEMA"; exit 1
fi
echo "    Schema versions confirmed."

echo ""
echo "==> B3: Building custom server image at $TO_SERVER..."
bash "$SCRIPT_DIR/build.sh" --server-version "$TO_SERVER"

echo ""
echo "==> B4: Restoring chart to $TO_SERVER (chart $TO_CHART, admintools $TO_ADMINTOOLS)..."
sed -i '' "s|version: \"$FROM_CHART\"|version: \"$TO_CHART\"|" "$SCRIPT_DIR/Chart.yaml"
sed -i '' "s|admin-tools:$FROM_ADMINTOOLS|admin-tools:$TO_ADMINTOOLS|" \
  "$SCRIPT_DIR/templates/temporal-namespace-init.yaml"
helm dependency update "$SCRIPT_DIR" --quiet
echo "    Chart restored."

echo ""
echo "==> B5: Setting drain window..."
kubectl patch configmap temporal-dynconfig -n "$NAMESPACE" --type=merge -p \
  "{\"data\":{\"config.yaml\":\"history.shutdownDrainDuration:\n  - value: 10s\n    constraints: {}\nhistory.startupMembershipJoinDelay:\n  - value: 10s\n    constraints: {}\n\"}}"

echo ""
echo "==> B6: Upgrading Helm release to $TO_SERVER..."
helm upgrade "$RELEASE" "$SCRIPT_DIR" --namespace "$NAMESPACE" --reuse-values

echo "    Waiting for rollout..."
kubectl rollout status deployment/"$RELEASE"-frontend  -n "$NAMESPACE" --timeout=5m
kubectl rollout status deployment/"$RELEASE"-history   -n "$NAMESPACE" --timeout=5m
kubectl rollout status deployment/"$RELEASE"-matching  -n "$NAMESPACE" --timeout=5m
kubectl rollout status deployment/"$RELEASE"-worker    -n "$NAMESPACE" --timeout=5m

echo ""
echo "==> B7: Verifying upgrade to $TO_SERVER..."
kubectl get pods -n "$NAMESPACE" | grep -v Completed
echo ""
kubectl exec -n "$NAMESPACE" deployment/"$RELEASE"-admintools -- \
  temporal --address "$RELEASE"-frontend:7233 operator cluster describe \
  | grep -i "server\|version" || true

echo ""
echo "==> B8: Removing drain window config..."
kubectl get configmap temporal-dynconfig -n "$NAMESPACE" -o json \
  | python3 -c "
import sys, json, re
cm = json.load(sys.stdin)
yaml = cm['data'].get('config.yaml', '')
yaml = re.sub(r'history\.shutdownDrainDuration:.*?constraints: \{\}\n', '', yaml, flags=re.DOTALL)
yaml = re.sub(r'history\.startupMembershipJoinDelay:.*?constraints: \{\}\n', '', yaml, flags=re.DOTALL)
cm['data']['config.yaml'] = yaml
print(json.dumps(cm))
" | kubectl apply -f - >/dev/null
echo "    Drain window removed."

echo ""
echo "══════════════════════════════════════════════════════════════"
echo "  Upgrade test complete: $FROM_SERVER → $TO_SERVER"
echo "══════════════════════════════════════════════════════════════"
echo ""
echo "  Temporal UI:  http://localhost:30080"
echo "  Grafana:      http://localhost:30300  (admin/admin)"
echo "  Prometheus:   http://localhost:30090"
