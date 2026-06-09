#!/bin/bash
# install.sh — Full temporal-stack install
#
# Install order:
#   1. Check / build custom Docker images
#   2. Add Helm repositories
#   3. Install Prometheus Operator CRDs
#   4. Install PostgreSQL and wait for it to be fully ready
#   5. Install full stack
#   6. Wait for all services to be ready
#   7. Verify Temporal default namespace

set -e

NAMESPACE=${NAMESPACE:-temporal}
RELEASE=${RELEASE:-temporal-stack}
TOTAL_STEPS=7

step() {
  echo ""
  echo "──────────────────────────────────────────────"
  echo "  Step $1 of $TOTAL_STEPS — $2"
  echo "──────────────────────────────────────────────"
}

# ── Step 1 ─────────────────────────────────────────
step 1 "Checking custom Docker images"
MISSING=false
docker image inspect temporal-custom-server:latest &>/dev/null || MISSING=true
docker image inspect temporal-health-poller:latest &>/dev/null || MISSING=true
if [[ "$MISSING" == "true" ]]; then
  echo "  Images not found — building now (this takes a few minutes)..."
  APP_VERSION="$(grep 'appVersion' "$(dirname "$0")/Chart.yaml" | awk '{print $2}' | tr -d '"')"
  [[ "$APP_VERSION" != v* ]] && APP_VERSION="v${APP_VERSION}"
  bash "$(dirname "$0")/build.sh" --server-version "$APP_VERSION"
else
  echo "  Images found — skipping build."
fi

# ── Step 2 ─────────────────────────────────────────
step 2 "Adding / updating Helm repositories"
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo add temporal https://go.temporal.io/helm-charts 2>/dev/null || true
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo add grafana https://grafana.github.io/helm-charts 2>/dev/null || true
helm repo update
echo "  Helm repos ready."

# ── Step 3 ─────────────────────────────────────────
step 3 "Installing Prometheus Operator CRDs"
echo "  (Required before kube-prometheus-stack can be deployed)"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_alertmanagerconfigs.yaml --force-conflicts 2>/dev/null || true
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_alertmanagers.yaml --force-conflicts 2>/dev/null || true
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_podmonitors.yaml --force-conflicts 2>/dev/null || true
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_probes.yaml --force-conflicts 2>/dev/null || true
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheusagents.yaml --force-conflicts 2>/dev/null || true
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheuses.yaml --force-conflicts 2>/dev/null || true
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_prometheusrules.yaml --force-conflicts 2>/dev/null || true
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_scrapeconfigs.yaml --force-conflicts 2>/dev/null || true
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml --force-conflicts 2>/dev/null || true
kubectl apply --server-side -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_thanosrulers.yaml --force-conflicts 2>/dev/null || true
echo "  CRDs installed."

# ── Step 4 ─────────────────────────────────────────
step 4 "Installing PostgreSQL"
echo "  (Must be fully ready before Temporal schema jobs run)"
helm upgrade --install "$RELEASE" . \
  --namespace "$NAMESPACE" \
  --timeout 5m \
  --set temporal.enabled=false \
  --set kube-prometheus-stack.enabled=false \
  --set loki.enabled=false \
  --set promtail.enabled=false \
  --set minio.enabled=false \
  --set healthPoller.enabled=false \
  2>&1 | grep -v "warnings.go"
echo "  Waiting for PostgreSQL pod to be ready..."
kubectl rollout status statefulset/"$RELEASE"-postgresql -n "$NAMESPACE" --timeout=5m
echo "  Waiting for PostgreSQL to accept connections..."
until kubectl exec -n "$NAMESPACE" "$RELEASE"-postgresql-0 -- \
  pg_isready -U temporal -d temporal -q 2>/dev/null; do
  sleep 2
done
echo "  Verifying PostgreSQL is reachable from within the cluster..."
echo "  (Pulling postgres:16-alpine for the check — may take a moment on first run)"
until kubectl run pg-cluster-check --rm -i --restart=Never \
  --image=postgres:16-alpine -n "$NAMESPACE" \
  --env="PGPASSWORD=temporal" \
  --command -- psql -h "$RELEASE-postgresql" -U temporal -d temporal -c "SELECT 1" &>/dev/null; do
  sleep 3
done
echo "  PostgreSQL fully ready."

# ── Step 5 ─────────────────────────────────────────
step 5 "Installing full stack"
echo "  (Deploying Temporal, Prometheus, Grafana, Loki, MinIO — this takes 3-5 minutes)"
helm upgrade "$RELEASE" . \
  --namespace "$NAMESPACE" \
  --timeout 20m \
  --reset-values \
  2>&1 | grep -v "warnings.go"
echo "  Helm release deployed."

# ── Step 6 ─────────────────────────────────────────
step 6 "Waiting for services to be ready"
echo "  Waiting for Temporal frontend..."
kubectl rollout status deployment/"$RELEASE"-frontend -n "$NAMESPACE" --timeout=5m
echo "  Waiting for Temporal worker..."
kubectl rollout status deployment/"$RELEASE"-worker -n "$NAMESPACE" --timeout=5m
echo "  Waiting for Grafana..."
kubectl rollout status deployment/"$RELEASE"-grafana -n "$NAMESPACE" --timeout=5m
echo "  All services ready."

# ── Step 7 ─────────────────────────────────────────
step 7 "Verifying Temporal default namespace"
# Job may already be cleaned up by hook-delete-policy — wait only if it still exists
if kubectl get job/"$RELEASE"-namespace-init -n "$NAMESPACE" &>/dev/null; then
  kubectl wait --for=condition=complete job/"$RELEASE"-namespace-init \
    --namespace "$NAMESPACE" --timeout=60s 2>/dev/null || true
fi
until kubectl exec -n "$NAMESPACE" deployment/"$RELEASE"-admintools -- \
  temporal --address "$RELEASE"-frontend:7233 operator namespace describe -n default \
  2>/dev/null | grep -q "default"; do
  sleep 2
done
echo "  Temporal 'default' namespace ready."

echo ""
echo "══════════════════════════════════════════════"
echo "  Install complete! (all $TOTAL_STEPS steps passed)"
echo "══════════════════════════════════════════════"
echo ""
echo "  Temporal UI:  http://localhost:30080"
echo "  Grafana:      http://localhost:30300  (admin/admin)"
echo "  Prometheus:   http://localhost:30090"
echo "  MinIO:        http://localhost:30901  (minioadmin/minioadmin)"
echo ""
