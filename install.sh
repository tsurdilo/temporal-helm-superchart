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

# Read dualVisibility.enabled from values.yaml
DUAL_VIS_ENABLED="$(awk '/^dualVisibility:/{found=1} found && /enabled:/{print $2; exit}' "$(dirname "$0")/values.yaml")"
[[ "$DUAL_VIS_ENABLED" == "true" ]] && DUAL_VIS=true || DUAL_VIS=false

# Read auth.enabled from values.yaml
AUTH_ENABLED="$(awk '/^auth:/{found=1} found && /^ *enabled:/{print $2; exit}' "$(dirname "$0")/values.yaml")"
[[ "$AUTH_ENABLED" == "true" ]] && AUTH=true || AUTH=false

# Read dex.enabled from values.yaml
DEX_ENABLED="$(awk '/^dex:/{found=1} found && /^ *enabled:/{print $2; exit}' "$(dirname "$0")/values.yaml")"
[[ "$DEX_ENABLED" == "true" ]] && DEX=true || DEX=false

# Read tls.frontend.enabled and tls.internode.enabled from values.yaml
TLS_FRONTEND_ENABLED="$(awk '
  /^tls:/        { in_tls=1; next }
  in_tls && /^[^ ]/ { in_tls=0 }
  in_tls && /^  frontend:/ { in_sec=1; next }
  in_tls && in_sec && /^  [^ ]/ { in_sec=0 }
  in_tls && in_sec && /enabled:/ { print $2; exit }
' "$(dirname "$0")/values.yaml")"
[[ "$TLS_FRONTEND_ENABLED" == "true" ]] && TLS_FRONTEND=true || TLS_FRONTEND=false

TLS_INTERNODE_ENABLED="$(awk '
  /^tls:/        { in_tls=1; next }
  in_tls && /^[^ ]/ { in_tls=0 }
  in_tls && /^  internode:/ { in_sec=1; next }
  in_tls && in_sec && /^  [^ ]/ { in_sec=0 }
  in_tls && in_sec && /enabled:/ { print $2; exit }
' "$(dirname "$0")/values.yaml")"
[[ "$TLS_INTERNODE_ENABLED" == "true" ]] && TLS_INTERNODE=true || TLS_INTERNODE=false

echo ""
if [[ "$DUAL_VIS" == "true" ]]; then
  echo "  ✦ Dual visibility: ENABLED (3 PostgreSQL instances, secondaryVisibilityStore wired)"
else
  echo "  ✦ Dual visibility: DISABLED (2 PostgreSQL instances, single visibility store)"
fi
if [[ "$AUTH" == "true" ]]; then
  if [[ "$DEX" == "true" ]]; then
    echo "  ✦ Auth: ENABLED (bundled Dex IDP)"
  else
    echo "  ✦ Auth: ENABLED (external IDP)"
  fi
else
  echo "  ✦ Auth: DISABLED"
fi

# When auth + Dex are enabled, warn if host.docker.internal is missing.
# Docker Desktop should add this automatically but sometimes omits it.
# See README "Prerequisites" for the one-time fix.
if [[ "$AUTH" == "true" && "$DEX" == "true" ]]; then
  if ! ping -c1 -W1 host.docker.internal &>/dev/null 2>&1; then
    echo ""
    echo "  ⚠️  WARNING: host.docker.internal does not resolve on this machine."
    echo "     Dex SSO login will fail in the browser. Fix with:"
    echo "     echo '127.0.0.1 host.docker.internal' | sudo tee -a /etc/hosts"
    echo ""
  fi
fi
if [[ "$TLS_FRONTEND" == "true" ]]; then
  echo "  ✦ Frontend TLS: ENABLED"
else
  echo "  ✦ Frontend TLS: DISABLED"
fi
if [[ "$TLS_INTERNODE" == "true" ]]; then
  echo "  ✦ Internode TLS: ENABLED"
else
  echo "  ✦ Internode TLS: DISABLED"
fi

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
  BUILD_VERSION="$(grep 'appVersion' "$(dirname "$0")/Chart.yaml" | awk '{print $2}' | tr -d '"')"
  [[ "$BUILD_VERSION" != v* ]] && BUILD_VERSION="v${BUILD_VERSION}"
  echo "  Building server version: $BUILD_VERSION (set appVersion in Chart.yaml to change)"
  bash "$(dirname "$0")/build.sh" --server-version "$BUILD_VERSION"
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
if [[ "$DUAL_VIS" == "true" ]]; then
  echo "  (Deploying 3 instances: main, visibility, visibility-secondary)"
else
  echo "  (Deploying 2 instances: main, visibility)"
fi
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
  --set dualVisibility.schemaHookEnabled=false \
  2>&1 | grep -v "warnings.go"

echo "  Waiting for PostgreSQL pods to be ready..."
kubectl rollout status statefulset/"$RELEASE"-postgresql-main -n "$NAMESPACE" --timeout=5m
kubectl rollout status statefulset/"$RELEASE"-postgresql-visibility -n "$NAMESPACE" --timeout=5m
if [[ "$DUAL_VIS" == "true" ]]; then
  kubectl rollout status statefulset/"$RELEASE"-postgresql-visibility-secondary -n "$NAMESPACE" --timeout=5m
fi

echo "  Waiting for PostgreSQL to accept connections..."
until kubectl exec -n "$NAMESPACE" "$RELEASE"-postgresql-main-0 -- \
  pg_isready -U temporal -d temporal -q 2>/dev/null; do
  sleep 2
done

echo "  Verifying all PostgreSQL instances are reachable from within the cluster..."
echo "  (Pulling postgres:16-alpine for the check — may take a moment on first run)"
until kubectl run pg-cluster-check --rm -i --restart=Never \
  --image=postgres:16-alpine -n "$NAMESPACE" \
  --env="PGPASSWORD=temporal" \
  --command -- psql -h "$RELEASE-postgresql-main" -U temporal -d temporal -c "SELECT 1" &>/dev/null; do
  sleep 3
done
echo "    postgresql-main ready."

until kubectl run pg-vis-check --rm -i --restart=Never \
  --image=postgres:16-alpine -n "$NAMESPACE" \
  --env="PGPASSWORD=temporal" \
  --command -- psql -h "$RELEASE-postgresql-visibility" -U temporal -d temporal_visibility -c "SELECT 1" &>/dev/null; do
  sleep 3
done
echo "    postgresql-visibility ready."

if [[ "$DUAL_VIS" == "true" ]]; then
  until kubectl run pg-vis-sec-check --rm -i --restart=Never \
    --image=postgres:16-alpine -n "$NAMESPACE" \
    --env="PGPASSWORD=temporal" \
    --command -- psql -h "$RELEASE-postgresql-visibility-secondary" -U temporal -d temporal_visibility_secondary -c "SELECT 1" &>/dev/null; do
    sleep 3
  done
  echo "    postgresql-visibility-secondary ready."
fi

echo "  All PostgreSQL instances fully ready."

# ── Step 5 ─────────────────────────────────────────
step 5 "Installing full stack"
echo "  (Deploying Temporal, Prometheus, Grafana, Loki, MinIO — this takes 3-5 minutes)"
DUAL_VIS_SET_FLAG=""
if [[ "$DUAL_VIS" == "true" ]]; then
  echo "  Dual visibility enabled — wiring secondaryVisibilityStore."
  DUAL_VIS_SET_FLAG="--set temporal.server.config.persistence.secondaryVisibilityStore=visibility-secondary"
fi

# Auth --set flags
# These cannot live in values.yaml as subchart values because Helm does not allow
# sibling templates to mutate subchart values dynamically. Instead we inject them
# here as --set flags at install time when auth.enabled: true.
AUTH_SET_FLAGS=""
if [[ "$AUTH" == "true" ]]; then
  echo "  Auth enabled — wiring server authorization config and UI env."

  # Resolve JWKS URI: use Dex service URL when bundled, otherwise read from values
  if [[ "$DEX" == "true" ]]; then
    DEX_ISSUER="$(awk '/^dex:/{found=1} found && /issuer:/{print $2; exit}' "$(dirname "$0")/values.yaml")"
    JWKS_URI="${DEX_ISSUER}/keys"
    PROVIDER_URL="$DEX_ISSUER"
  else
    JWKS_URI="$(awk '/^auth:/{found=1} found && /keySourceURIs:/{getline; print $2; exit}' "$(dirname "$0")/values.yaml")"
    PROVIDER_URL="$(awk '/^auth:/{found=1} found && /providerUrl:/{print $2; exit}' "$(dirname "$0")/values.yaml")"
  fi

  PERMISSIONS_CLAIM="$(awk '/^auth:/{found=1} found && /permissionsClaimName:/{print $2; exit}' "$(dirname "$0")/values.yaml")"
  CLIENT_ID="$(awk '/^auth:/{found=1} found && /clientId:/{print $2; exit}' "$(dirname "$0")/values.yaml")"
  CALLBACK_URL="$(awk '/^auth:/{found=1} found && /callbackUrl:/{print $2; exit}' "$(dirname "$0")/values.yaml" | tr -d '"')"
  SCOPES="$(awk '/^auth:/{found=1} found && /scopes:/{print $2; exit}' "$(dirname "$0")/values.yaml" | tr -d '"')"
  SECRET_NAME="$(awk '/^auth:/{found=1} found && /existingSecret:/{print $2; exit}' "$(dirname "$0")/values.yaml" | tr -d '"')"
  SECRET_KEY="$(awk '/^auth:/{found=1} found && /existingSecretKey:/{print $2; exit}' "$(dirname "$0")/values.yaml" | tr -d '"')"

  AUTH_SET_FLAGS="
    --set temporal.server.config.authorization.jwtKeyProvider.keySourceURIs[0]=${JWKS_URI}
    --set temporal.server.config.authorization.jwtKeyProvider.refreshInterval=1m
    --set temporal.server.config.authorization.permissionsClaimName=${PERMISSIONS_CLAIM}
    --set temporal.server.config.authorization.authorizer=default
    --set temporal.server.config.authorization.claimMapper=default
    --set temporal.web.additionalEnvConfigMapName=${RELEASE}-auth-ui-env
    --set temporal.web.additionalEnvSecretName=${SECRET_NAME}
  "
fi

# TLS --set flags
# Cert files are mounted from K8s Secrets at fixed paths (/certs/frontend, /certs/internode).
# The Secret must contain: tls.crt (server cert), tls.key (server key), ca.crt (CA cert).
# Volumes/mounts are injected via temporal.server.additionalVolumes/additionalVolumeMounts
# (supported by upstream chart: server-deployment.yaml:148,177).
# server.config.tls is a full passthrough: server-configmap.yaml:48.
TLS_SET_FLAGS=""
VOL_IDX=0

if [[ "$TLS_FRONTEND" == "true" ]]; then
  echo "  Frontend TLS enabled — mounting cert Secret and wiring tls.frontend config."
  FRONTEND_SECRET="$(awk '
    /^tls:/        { in_tls=1; next }
    in_tls && /^[^ ]/ { in_tls=0 }
    in_tls && /^  frontend:/ { in_sec=1; next }
    in_tls && in_sec && /^  [^ ]/ { in_sec=0 }
    in_tls && in_sec && /existingSecret:/ { gsub(/"/, "", $2); print $2; exit }
  ' "$(dirname "$0")/values.yaml")"
  FRONTEND_SERVER_NAME="$(awk '
    /^tls:/        { in_tls=1; next }
    in_tls && /^[^ ]/ { in_tls=0 }
    in_tls && /^  frontend:/ { in_sec=1; next }
    in_tls && in_sec && /^  [^ ]/ { in_sec=0 }
    in_tls && in_sec && /serverName:/ { gsub(/"/, "", $2); print $2; exit }
  ' "$(dirname "$0")/values.yaml")"
  FRONTEND_REQUIRE_CLIENT_AUTH="$(awk '
    /^tls:/        { in_tls=1; next }
    in_tls && /^[^ ]/ { in_tls=0 }
    in_tls && /^  frontend:/ { in_sec=1; next }
    in_tls && in_sec && /^  [^ ]/ { in_sec=0 }
    in_tls && in_sec && /requireClientAuth:/ { print $2; exit }
  ' "$(dirname "$0")/values.yaml")"

  TLS_SET_FLAGS="$TLS_SET_FLAGS
    --set temporal.server.additionalVolumes[${VOL_IDX}].name=frontend-tls
    --set temporal.server.additionalVolumes[${VOL_IDX}].secret.secretName=${FRONTEND_SECRET}
    --set temporal.server.additionalVolumeMounts[${VOL_IDX}].name=frontend-tls
    --set temporal.server.additionalVolumeMounts[${VOL_IDX}].mountPath=/certs/frontend
    --set temporal.server.additionalVolumeMounts[${VOL_IDX}].readOnly=true
    --set temporal.server.config.tls.frontend.server.certFile=/certs/frontend/tls.crt
    --set temporal.server.config.tls.frontend.server.keyFile=/certs/frontend/tls.key
    --set temporal.server.config.tls.frontend.server.requireClientAuth=${FRONTEND_REQUIRE_CLIENT_AUTH}
    --set \"temporal.server.config.tls.frontend.server.clientCaFiles[0]=/certs/frontend/ca.crt\"
    --set temporal.server.config.tls.frontend.client.serverName=${FRONTEND_SERVER_NAME}
    --set \"temporal.server.config.tls.frontend.client.rootCaFiles[0]=/certs/frontend/ca.crt\"
  "
  VOL_IDX=$((VOL_IDX + 1))
fi

if [[ "$TLS_INTERNODE" == "true" ]]; then
  echo "  Internode TLS enabled — mounting cert Secret and wiring tls.internode config."
  INTERNODE_SECRET="$(awk '
    /^tls:/        { in_tls=1; next }
    in_tls && /^[^ ]/ { in_tls=0 }
    in_tls && /^  internode:/ { in_sec=1; next }
    in_tls && in_sec && /^  [^ ]/ { in_sec=0 }
    in_tls && in_sec && /existingSecret:/ { gsub(/"/, "", $2); print $2; exit }
  ' "$(dirname "$0")/values.yaml")"
  INTERNODE_SERVER_NAME="$(awk '
    /^tls:/        { in_tls=1; next }
    in_tls && /^[^ ]/ { in_tls=0 }
    in_tls && /^  internode:/ { in_sec=1; next }
    in_tls && in_sec && /^  [^ ]/ { in_sec=0 }
    in_tls && in_sec && /serverName:/ { gsub(/"/, "", $2); print $2; exit }
  ' "$(dirname "$0")/values.yaml")"

  TLS_SET_FLAGS="$TLS_SET_FLAGS
    --set temporal.server.additionalVolumes[${VOL_IDX}].name=internode-tls
    --set temporal.server.additionalVolumes[${VOL_IDX}].secret.secretName=${INTERNODE_SECRET}
    --set temporal.server.additionalVolumeMounts[${VOL_IDX}].name=internode-tls
    --set temporal.server.additionalVolumeMounts[${VOL_IDX}].mountPath=/certs/internode
    --set temporal.server.additionalVolumeMounts[${VOL_IDX}].readOnly=true
    --set temporal.server.config.tls.internode.server.certFile=/certs/internode/tls.crt
    --set temporal.server.config.tls.internode.server.keyFile=/certs/internode/tls.key
    --set temporal.server.config.tls.internode.server.requireClientAuth=true
    --set \"temporal.server.config.tls.internode.server.clientCaFiles[0]=/certs/internode/ca.crt\"
    --set temporal.server.config.tls.internode.client.serverName=${INTERNODE_SERVER_NAME}
    --set \"temporal.server.config.tls.internode.client.rootCaFiles[0]=/certs/internode/ca.crt\"
  "
  VOL_IDX=$((VOL_IDX + 1))
fi

# Show a progress ticker while helm runs — without this the user sees nothing
# for 3-5 minutes and may think the install is stuck.
# Prints pod counts every 15s. Red + hint if any pods are in an error state.
_ticker() {
  local i=0
  while kill -0 "$1" 2>/dev/null; do
    sleep 15
    i=$((i + 15))
    local RUNNING PENDING NOT_READY
    RUNNING=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -c " Running " || true)
    PENDING=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -cE "Pending|ContainerCreating|Init:" || true)
    NOT_READY=$(kubectl get pods -n "$NAMESPACE" --no-headers 2>/dev/null | grep -cE "CrashLoopBackOff|Error|OOMKilled|ImagePullBackOff|ErrImagePull" || true)
    if [[ "$NOT_READY" -gt 0 ]]; then
      printf "  ... %ds elapsed — %d running, %d pending, \033[31m%d errored\033[0m (kubectl get pods -n %s for details)\n" \
        "$i" "$RUNNING" "$PENDING" "$NOT_READY" "$NAMESPACE"
    else
      printf "  ... %ds elapsed — %d running, %d pending\n" "$i" "$RUNNING" "$PENDING"
    fi
  done
}

helm upgrade "$RELEASE" . \
  --namespace "$NAMESPACE" \
  --timeout 20m \
  --reset-values \
  $DUAL_VIS_SET_FLAG \
  $AUTH_SET_FLAGS \
  $TLS_SET_FLAGS \
  ${EXTRA_HELM_FLAGS:-} \
  2>&1 | grep -v "warnings.go" &
HELM_PID=$!
_ticker $HELM_PID &
TICKER_PID=$!
wait $HELM_PID
HELM_EXIT=$?
wait $TICKER_PID 2>/dev/null
if [[ $HELM_EXIT -ne 0 ]]; then
  echo "  ERROR: helm upgrade failed (exit $HELM_EXIT)"
  exit $HELM_EXIT
fi
echo "  Helm release deployed."

# ── Step 6 ─────────────────────────────────────────
step 6 "Waiting for services to be ready"
# SKIP_SERVER_WAIT=true skips frontend/worker health checks.
# Used by upgrade-test.sh Phase A where the binary is v1.31.0 but schema is still
# v1.18 — the server crashes until schema is migrated in Phase B.
if [[ "${SKIP_SERVER_WAIT:-false}" == "true" ]]; then
  echo "  SKIP_SERVER_WAIT set — skipping server rollout wait (upgrade-test Phase A mode)."
  echo "  Waiting for admintools only..."
  kubectl rollout status deployment/"$RELEASE"-admintools -n "$NAMESPACE" --timeout=3m
  echo "  Admintools ready. Schema setup complete — server will start after schema migration."
else
  echo "  Waiting for Temporal frontend..."
  kubectl rollout status deployment/"$RELEASE"-frontend -n "$NAMESPACE" --timeout=5m
  echo "  Waiting for Temporal worker..."
  kubectl rollout status deployment/"$RELEASE"-worker -n "$NAMESPACE" --timeout=5m
  echo "  Waiting for Grafana..."
  kubectl rollout status deployment/"$RELEASE"-grafana -n "$NAMESPACE" --timeout=5m
  if [[ "$DEX" == "true" ]]; then
    echo "  Waiting for Dex..."
    kubectl rollout status deployment/"$RELEASE"-dex -n "$NAMESPACE" --timeout=3m
    echo "  Dex ready."
  fi
  echo "  All services ready."
fi

# ── Step 7 ─────────────────────────────────────────
step 7 "Verifying Temporal default namespace"
if [[ "${SKIP_SERVER_WAIT:-false}" == "true" ]]; then
  echo "  SKIP_SERVER_WAIT set — skipping namespace verification (upgrade-test Phase A mode)."
else
  # Job may already be cleaned up by hook-delete-policy — wait only if it still exists
  if kubectl get job/"$RELEASE"-namespace-init -n "$NAMESPACE" &>/dev/null; then
    kubectl wait --for=condition=complete job/"$RELEASE"-namespace-init \
      --namespace "$NAMESPACE" --timeout=60s 2>/dev/null || true
  fi
  # Use internal-frontend when auth is enabled — no JWT needed for cluster-internal ops
  if [[ "$AUTH" == "true" ]]; then
    VERIFY_ADDR="$RELEASE-internal-frontend:7236"
  else
    VERIFY_ADDR="$RELEASE-frontend:7233"
  fi
  until kubectl exec -n "$NAMESPACE" deployment/"$RELEASE"-admintools -- \
    temporal --address "$VERIFY_ADDR" operator namespace describe -n default \
    2>/dev/null | grep -q "default"; do
    sleep 2
  done
  echo "  Temporal 'default' namespace ready."
fi

echo ""
echo "══════════════════════════════════════════════"
echo "  Install complete! (all $TOTAL_STEPS steps passed)"
echo "══════════════════════════════════════════════"
echo ""
echo "  Temporal UI:  http://localhost:30080"
if [[ "$AUTH" == "true" ]]; then
  echo "                (login: admin@temporal.io / admin)"
fi
echo "  Grafana:      http://localhost:30300  (admin/admin)"
echo "  Prometheus:   http://localhost:30090"
echo "  MinIO:        http://localhost:30901  (minioadmin/minioadmin)"
echo "  Temporal gRPC: localhost:7233"
if [[ "$AUTH" == "true" ]]; then
  echo "                (JWT required for SDK workers + CLI — see README Authentication section)"
fi
echo ""
