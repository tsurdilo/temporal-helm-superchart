#!/bin/bash
# install.sh — Full temporal-stack install
#
# Install order:
#   1. Prometheus Operator CRDs (required before kube-prometheus-stack)
#   2. PostgreSQL only (must be ready before Temporal schema jobs run)
#   3. Full stack

set -e

NAMESPACE=${NAMESPACE:-temporal}
RELEASE=${RELEASE:-temporal-stack}

echo "==> Creating namespace: $NAMESPACE"
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

echo "==> Step 1: Installing Prometheus Operator CRDs..."
# Install CRDs only — kube-prometheus-stack brings its own operator, so we only need the CRDs pre-installed
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
echo "    CRDs installed."

echo "==> Step 2: Installing PostgreSQL..."
helm upgrade --install "$RELEASE" . \
  --namespace "$NAMESPACE" \
  --timeout 5m \
  --set temporal.enabled=false \
  --set kube-prometheus-stack.enabled=false \
  --set loki.enabled=false \
  --set promtail.enabled=false \
  --set minio.enabled=false \
  --set healthPoller.enabled=false
echo "    Waiting for PostgreSQL to be ready..."
kubectl rollout status statefulset/"$RELEASE"-postgresql -n "$NAMESPACE" --timeout=5m
echo "    Verifying PostgreSQL is accepting connections..."
until kubectl exec -n "$NAMESPACE" "$RELEASE"-postgresql-0 -- \
  pg_isready -U temporal -d temporal -q 2>/dev/null; do
  sleep 2
done
echo "    PostgreSQL accepting connections."
echo "    Verifying PostgreSQL DNS is reachable from within the cluster..."
until kubectl run pg-dns-check --rm -i --restart=Never \
  --image=busybox:1.36 -n "$NAMESPACE" \
  --command -- sh -c "nc -z $RELEASE-postgresql 5432" &>/dev/null; do
  sleep 3
done
echo "    PostgreSQL DNS reachable."

echo "==> PostgreSQL ready. Step 3: Installing full stack..."
helm upgrade "$RELEASE" . \
  --namespace "$NAMESPACE" \
  --timeout 20m \
  --reset-values

echo "    Waiting for Temporal frontend..."
kubectl rollout status deployment/"$RELEASE"-frontend -n "$NAMESPACE" --timeout=5m
echo "    Waiting for Temporal worker..."
kubectl rollout status deployment/"$RELEASE"-worker -n "$NAMESPACE" --timeout=5m
echo "    Waiting for Grafana..."
kubectl rollout status deployment/"$RELEASE"-grafana -n "$NAMESPACE" --timeout=5m

echo "==> Verifying Temporal default namespace..."
kubectl wait --for=condition=complete job/"$RELEASE"-namespace-init \
  --namespace "$NAMESPACE" --timeout=60s 2>/dev/null || true
kubectl exec -n "$NAMESPACE" deployment/"$RELEASE"-admintools -- \
  temporal --address "$RELEASE"-frontend:7233 operator namespace describe -n default 2>/dev/null | grep -q "default" \
  && echo "    Temporal 'default' namespace ready." \
  || echo "    Warning: could not verify default namespace — check manually."

echo ""
echo "==> Install complete!"
echo ""
echo "  Temporal UI:  http://localhost:30080"
echo "  Grafana:      http://localhost:30300  (admin/admin)"
echo "  Prometheus:   http://localhost:30090"
echo "  MinIO:        http://localhost:30901  (minioadmin/minioadmin)"
