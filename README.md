# Temporal Stack — Helm Super-Chart

## Why this exists

The [official Temporal Helm chart](https://github.com/temporalio/helm-charts) is the foundation of this project — it handles all the complexity of deploying the Temporal server components (frontend, history, matching, worker) and does so extremely well. Without it, building something like this would require an enormous amount of work.

What the upstream chart deliberately leaves to the operator is the surrounding infrastructure — a database, an observability stack, archival storage, and a way to manage dynamic config in Kubernetes. This is by design: those choices are environment-specific and the upstream chart is right not to make them for you.

This chart — a Helm "super-chart" or umbrella chart — builds on top of the upstream chart and makes those choices for a local Docker Desktop Kubernetes environment. It wraps the upstream chart as a subchart and adds the surrounding infrastructure as properly integrated dependencies:

- A PostgreSQL instance for persistence
- Prometheus and Grafana for metrics and dashboards
- A log aggregation stack (Loki + Promtail)
- MinIO for workflow archival
- A ConfigMap-based dynamic config client with live reload

The result is a complete, realistic starting point that reflects how a Temporal cluster actually runs — not just the server in isolation.

## What's included

- Temporal Server (frontend ×2, history ×2, matching ×2, worker ×1, internal-frontend ×1)
- PostgreSQL (three isolated instances: main store, primary visibility, secondary visibility)
- Prometheus + Grafana (pre-loaded dashboards and alerts)
- Loki + Promtail (log aggregation)
- MinIO (workflow and visibility archival)
- Health poller (drives per-host `host_health` metrics)
- ConfigMap-based dynamic config with live reload (no pod restarts required)
- Dual visibility support (hot standby visibility store with parallel writes, opt-in via `dualVisibility.enabled`)
- JWT authentication via bundled Dex OIDC provider — UI login, SDK worker auth, CLI auth all enforced out of the box

Everything is pre-wired. No manual configuration required to get started.

> **Running Docker Compose instead of Kubernetes?** See [my-temporal-dockercompose](https://github.com/tsurdilo/my-temporal-dockercompose) for the companion Docker Compose setup.

---

## Table of contents

- [Prerequisites](#prerequisites)
  - [1. Docker Desktop](#1-docker-desktop)
  - [2. Kubernetes (via Docker Desktop)](#2-kubernetes-via-docker-desktop)
  - [3. kubectl](#3-kubectl)
  - [4. Helm](#4-helm)
  - [5. host.docker.internal in /etc/hosts (auth only)](#5-hostdockerinternal-in-etchosts-auth-only)
- [Installing the chart](#installing-the-chart)
  - [Custom images](#custom-images)
  - [Run the install script](#run-the-install-script)
  - [Verify](#verify)
- [Accessing the services](#accessing-the-services)
- [Uninstalling / Starting Fresh](#uninstalling--starting-fresh)
- [Switching between this chart and Docker Compose](#switching-between-this-chart-and-docker-compose)
- [Updating dashboards](#updating-dashboards)
- [Dynamic config](#dynamic-config)
- [MinIO and Archival](#minio-and-archival)
- [Scaling Temporal Services](#scaling-temporal-services)
- [Dual Visibility](#dual-visibility)
- [Authentication](#authentication)
- [Useful Kubernetes commands](#useful-kubernetes-commands)
- [Troubleshooting](#troubleshooting)
- [Upgrading Temporal Server](#upgrading-temporal-server)

---

## Prerequisites

You need the following installed before you can run this chart.

### 1. Docker Desktop

Download and install Docker Desktop for Mac from:
https://www.docker.com/products/docker-desktop/

Allocate enough resources — recommended minimums:
- **CPU:** 6 cores
- **Memory:** 12 GB
- **Disk:** 60 GB

To set these: Docker Desktop → Settings (gear icon) → Resources.

### 2. Kubernetes (via Docker Desktop)

This chart runs on a local Kubernetes cluster provided by Docker Desktop.

1. Open Docker Desktop
2. Click the **Kubernetes** icon in the left sidebar
3. Click **Create cluster**
4. Select **kubeadm**, keep defaults (1 node, latest version)
5. Click **Create**
6. Wait for the cluster to show **Active**

> **Important:** Select **kubeadm**, not kind. kubeadm supports NodePort services accessible on localhost out of the box, which is how this chart exposes its UIs without port-forwarding.

### 3. kubectl

Docker Desktop installs `kubectl` automatically and sets the `docker-desktop` context — no separate installation needed.

Verify it is pointed at your local cluster:

```bash
kubectl config current-context
# should output: docker-desktop

kubectl get nodes
# should show one node with STATUS: Ready
```

### 4. Helm

Helm is the Kubernetes package manager used to install this chart. Docker Desktop does not bundle it — install separately:

```bash
brew install helm
```

Verify (v3+ required):

```bash
helm version
```

### 5. `host.docker.internal` in `/etc/hosts` (auth only)

When `auth.enabled: true`, the bundled Dex OIDC provider uses `host.docker.internal` as its issuer URL — a hostname that must resolve identically from your browser, from inside Kubernetes pods, and from the Temporal server. Docker Desktop is supposed to add this automatically but sometimes omits it.

Check if it's present:

```bash
grep host.docker.internal /etc/hosts
```

If missing, add it (one-time):

```bash
echo "127.0.0.1 host.docker.internal" | sudo tee -a /etc/hosts
```

If you run with `auth.enabled: false` this step is not required.

---

## Installing the chart

### Custom images

`install.sh` checks for the custom images automatically and builds them if they are missing — no manual build step required on a fresh setup.

The chart uses two locally-built images:

- **`temporal-custom-server`** — Temporal server with several custom extensions compiled in:
  - **ConfigMap dynconfig** ([temporal-configmap-dynconfig](https://github.com/tsurdilo/temporal-configmap-dynconfig)) — watches the `temporal-dynconfig` ConfigMap and applies changes live without pod restarts
  - **Custom authorizer** — wraps the default authorizer and adds task queue blocking via `TEMPORAL_BLOCKED_TASK_QUEUES` env var; `authorizer=default` is always active so no JWT = denied
  - **Custom claim mapper** — falls back to email-based role assignment when the JWT has no `permissions` claim (Dex static passwords); production IDPs that issue `permissions` claims use the default mapper path automatically
  - **Plaintext payload interceptor** — detects unencrypted payload encodings (`json/plain`, `binary/plain`) on all major frontend APIs, logs a warning, and increments a `plaintext_payload_detected_total` metric; observe-only, requests always pass through
- **`temporal-health-poller`** — Calls `AdminHandler.DeepHealthCheck` on each history pod and emits the `host_health` gauge to Prometheus.

The server version is controlled by `appVersion` in `Chart.yaml` — that is the single source of truth. `install.sh` reads it automatically when building images. To target a different version, update `appVersion` in `Chart.yaml` first, then run `install.sh`.

Images are built from `~/devel/temporal/temporal` at the tag matching `appVersion` and cached in Docker Desktop — no registry push needed. To rebuild manually (e.g. after a version change):

```bash
bash build.sh --server-version v1.31.0
```

> See [UPGRADE.md](UPGRADE.md) when changing server versions.

### Run the install script

```bash
cd ~/devel/temporal-helm-superchart
bash install.sh
```

The script handles everything in the correct order:
1. Checks for custom Docker images — builds them automatically if missing
2. Adds and updates all required Helm repositories
3. Installs Prometheus Operator CRDs (required before kube-prometheus-stack)
4. Installs PostgreSQL (all 3 instances when dual visibility is enabled) and waits for them to be fully reachable from within the cluster
5. Installs the full stack — Temporal, Prometheus, Grafana, Loki, MinIO, and Dex (when auth is enabled)
6. Waits for Temporal frontend, worker, Grafana, and Dex to be ready
7. Creates the `default` Temporal namespace (routed via `internal-frontend` to bypass JWT enforcement)

The first install takes 5–10 minutes as images are pulled. You will see output like:

```
  Temporal UI:  http://localhost:30080
                (login: admin@temporal.io / admin)
  Grafana:      http://localhost:30300  (admin/admin)
  Prometheus:   http://localhost:30090
  MinIO:        http://localhost:30901  (minioadmin/minioadmin)
  Temporal gRPC: localhost:7233
                (JWT required for SDK workers + CLI — see README Authentication section)
```

### Verify

```bash
kubectl get pods -n temporal
```

All pods should show `Running` or `Completed`.

---

## Accessing the services

Once installed, the following services are available directly — no port-forwarding required:

| Service | URL | Notes |
|---|---|---|
| Temporal UI | [http://localhost:30080](http://localhost:30080) | Workflow management — redirects to Dex login. Default user: `admin@temporal.io` / `admin`. See [Authentication](#authentication). |
| Grafana | [http://localhost:30300](http://localhost:30300) | Dashboards (admin/admin) |
| Prometheus | [http://localhost:30090](http://localhost:30090) | Metrics |
| MinIO Console | [http://localhost:30901](http://localhost:30901) | Archival storage — login: minioadmin / minioadmin. History and visibility archival is enabled on the `default` namespace automatically at install time. |
| Temporal Frontend (gRPC) | `localhost:7233` | SDK target — default port, no config needed. Kubernetes load-balances across both frontend replicas automatically. **Requires a JWT bearer token** — see [Authentication](#authentication). |
| Dex (OIDC) | [http://host.docker.internal:30556/dex](http://host.docker.internal:30556/dex) | Local identity provider — issues JWTs for UI, CLI, and SDK workers. Must use `host.docker.internal` (not `localhost`) — this hostname resolves identically from browser, pods, and the Temporal server. |

---

## Uninstalling / Starting Fresh

Use `teardown.sh` to completely remove the running cluster. It handles the `helm.sh/resource-policy: keep` ConfigMap, the namespace, and optionally the Docker images — all in one step.

**Teardown + reinstall (reuse existing images):**
```bash
bash teardown.sh --keep-images
bash install.sh
```

**Full reset including a clean image rebuild:**
```bash
bash teardown.sh
bash build.sh --server-version v1.31.0
bash install.sh
```

> By default `teardown.sh` removes the custom Docker images. Always use `--keep-images` if you plan to reinstall without rebuilding, otherwise `install.sh` will fail with `ErrImageNeverPull`.

> The `temporal-dynconfig` ConfigMap has `helm.sh/resource-policy: keep`, so `helm uninstall` alone does not remove it. `teardown.sh` deletes it explicitly before removing the namespace.

---

## Switching between this chart and Docker Compose

See [my-temporal-dockercompose](https://github.com/tsurdilo/my-temporal-dockercompose) for the companion Docker Compose setup.

**You cannot run both at the same time.** Both setups bind port `7233` on localhost for the Temporal frontend — whichever starts second will fail to bind.

### Switch from K8s to Docker Compose

```bash
# 1. Tear down the K8s stack (keep images so you can switch back without rebuilding)
cd ~/devel/temporal-helm-superchart
bash teardown.sh --keep-images

# 2. Start Docker Compose
cd ~/devel/my-temporal-dockercompose
docker compose -f compose-postgres.yml -f compose-services.yml up -d
```

### Switch from Docker Compose back to K8s

```bash
# 1. Stop Docker Compose
cd ~/devel/my-temporal-dockercompose
docker compose -f compose-postgres.yml -f compose-services.yml down

# 2. Reinstall the K8s stack
cd ~/devel/temporal-helm-superchart
bash install.sh
```

The Kubernetes cluster itself keeps running in the background while Docker Compose is active — you only need to tear down the Helm release, not the cluster.

---

## Updating dashboards

Grafana dashboards are stored as Kubernetes ConfigMaps and provisioned at pod startup. To update a dashboard:

1. Replace the JSON file in `files/dashboards/`
2. Run `helm upgrade` to push the updated ConfigMap:

```bash
helm upgrade temporal-stack . --namespace temporal --reuse-values
```

3. Restart the Grafana pod to load the new dashboard:

```bash
kubectl rollout restart deployment/temporal-stack-grafana -n temporal
kubectl rollout status deployment/temporal-stack-grafana -n temporal --timeout=2m
```

Grafana will be back at http://localhost:30300 within ~30 seconds.

---

## Dynamic config

### What it is

Temporal has hundreds of runtime parameters — rate limits, cache sizes, task queue settings, retention policies — that can be changed without restarting the server. These are called [dynamic config](https://docs.temporal.io/references/dynamic-configuration).

In a standard Temporal deployment you manage these via a config file on disk, which means SSHing into servers or redeploying to make a change. This chart replaces that with a **Kubernetes ConfigMap** — a key-value store that lives inside the cluster. The custom server image has [temporal-configmap-dynconfig](https://github.com/tsurdilo/temporal-configmap-dynconfig) compiled in, which watches the ConfigMap for changes using the Kubernetes Watch API. The moment you update the ConfigMap, all server pods see the change within seconds — no restart, no redeploy.

### Viewing the current config

```bash
kubectl get configmap temporal-dynconfig -n temporal -o jsonpath='{.data.config\.yaml}'
```

On a fresh install the ConfigMap is mostly empty — any key not explicitly set falls back to Temporal's compiled-in default.

### Making a change

Create a YAML file with the keys you want to set, then apply it:

```bash
# 1. Create a file with your changes (or edit an existing one)
cat > my-dynconfig.yaml << 'EOF'
frontend.namespaceRPS.visibility:
  - value: 100
    constraints: {}
EOF

# 2. Apply it to the ConfigMap
kubectl create configmap temporal-dynconfig \
  --from-file=config.yaml=my-dynconfig.yaml \
  --namespace temporal \
  --dry-run=client -o yaml | kubectl apply -f -
```

All server pods pick up the change within seconds. No restart required.

### Value format

Each key is a list of values with optional constraints. A value with `constraints: {}` is the global default. You can add per-namespace overrides:

```yaml
frontend.globalNamespaceRPS:
  - value: 500
    constraints:
      namespace: my-high-traffic-namespace   # applies only to this namespace
  - value: 1200
    constraints: {}                           # global fallback for all other namespaces
```

Temporal evaluates constraints top-to-bottom — most specific wins.

### Reverting a value

Remove the key from your YAML file and re-apply. The server falls back to its compiled-in default within seconds.

### Using with multiple clusters

Each ConfigMap is scoped to a Kubernetes namespace. If you run two separate Temporal clusters in two namespaces (e.g. `temporal-a` and `temporal-b`), each has its own `temporal-dynconfig` ConfigMap and its own independent set of dynamic config values — changes to one cluster do not affect the other.

There is no native Kubernetes mechanism to share a ConfigMap across namespaces — a pod in `temporal-a` cannot watch a ConfigMap in `temporal-b`. The recommended approach is to keep a single source-of-truth YAML file under version control and apply it to each namespace when you want to sync:

```bash
kubectl create configmap temporal-dynconfig \
  --from-file=config.yaml=my-dynconfig.yaml \
  --namespace temporal-a \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create configmap temporal-dynconfig \
  --from-file=config.yaml=my-dynconfig.yaml \
  --namespace temporal-b \
  --dry-run=client -o yaml | kubectl apply -f -
```

This keeps config changes auditable and consistent without adding extra tooling.

### Reference

To see all available keys and their compiled-in defaults, check the [dynamic config reference](https://github.com/tsurdilo/temporal-server-operations/tree/main/dynamic_config).

---

## MinIO and Archival

MinIO is deployed as a pod inside the `temporal` namespace and is used as the archival backend for workflow history and visibility. The `default` Temporal namespace has archival enabled automatically at install time — no manual setup required.

The MinIO console is available at [http://localhost:30901](http://localhost:30901) (login: `minioadmin` / `minioadmin`). Archived workflow files appear in the `temporal-history` and `temporal-visibility` buckets.

### Using with multiple clusters

MinIO is namespace-scoped — it is only directly accessible to services in the `temporal` namespace. If you run a second Temporal cluster in a different namespace (e.g. `temporal-b`), its pods cannot reach this MinIO instance by default.

You have two options:

**Option 1 — Separate MinIO per cluster (default, simplest)**
Each cluster gets its own MinIO deployed in its own namespace. Fully isolated, no cross-namespace dependencies. This is what this chart does out of the box.

**Option 2 — Shared MinIO across clusters**
Deploy MinIO once in a dedicated namespace (e.g. `minio`) and point each Temporal cluster at it using the full Kubernetes DNS name:

```
http://temporal-stack-minio.minio.svc.cluster.local:9000
```

Each cluster uses different bucket names (e.g. `cluster-a-history`, `cluster-b-history`) to keep archived data separate. Update `values.yaml` on each cluster to point at the shared endpoint:

```yaml
temporal:
  server:
    archival:
      history:
        provider:
          customStores:
            minio:
              endpoint: "http://temporal-stack-minio.minio.svc.cluster.local:9000"
```

For a local dev setup, Option 1 is the right default. Option 2 is useful when running multiple clusters and you want a single place to browse all archived workflows.

---

## Scaling Temporal Services

The chart defaults are sized for local development (frontend ×2, history ×2, matching ×2, worker ×1). You can scale any service by updating `values.yaml` and running `helm upgrade`.

### Scale via values.yaml (persistent)

Edit `values.yaml` and change the replica counts:

```yaml
temporal:
  server:
    frontend:
      replicaCount: 3
    history:
      replicaCount: 5
    matching:
      replicaCount: 3
    worker:
      replicaCount: 2
```

Then apply:

```bash
helm upgrade temporal-stack . --namespace temporal --reuse-values
```

### Scale via kubectl (temporary)

For a quick one-off change without touching `values.yaml` — note this will be overwritten on the next `helm upgrade`:

```bash
kubectl scale deployment temporal-stack-frontend  -n temporal --replicas=3
kubectl scale deployment temporal-stack-history   -n temporal --replicas=5
kubectl scale deployment temporal-stack-matching  -n temporal --replicas=3
kubectl scale deployment temporal-stack-worker    -n temporal --replicas=2
```


### Verifying a scale-out

After scaling, confirm the new pods are running and that the membership ring picked them up:

```bash
# tdbg uses internal-frontend (port 7236) to bypass JWT enforcement
kubectl exec -n temporal deployment/temporal-stack-admintools -- \
  tdbg --address temporal-stack-internal-frontend:7236 membership list-gossip
```

This shows every ring member per role with member counts and addresses. After scaling frontend to 3 you should see `"member_count": 3` under the `frontend` role. You can also filter by role:

```bash
kubectl exec -n temporal deployment/temporal-stack-admintools -- \
  tdbg --address temporal-stack-internal-frontend:7236 membership list-gossip --role frontend
```

---

## Dual Visibility

This chart supports running two PostgreSQL visibility stores simultaneously — a primary and a secondary. Both stores receive every visibility write in parallel. This gives you a hot standby for visibility queries.

### How it works

`dualVisibility.enabled` is a flag in this chart's `values.yaml` — it is not a Temporal dynamic config key. Setting it to `true` instructs the chart to:
- Deploy a third PostgreSQL instance (`postgresql-visibility-secondary`) alongside the existing `postgresql-main` and `postgresql-visibility` instances
- Configure the Temporal server with both `visibilityStore` (primary) and `secondaryVisibilityStore` (secondary)
- Seed the Temporal dynamic config key `system.secondaryVisibilityWritingMode: dual` into the `temporal-dynconfig` ConfigMap — this is what actually activates parallel writes to both stores
- Leave reads on the primary store by default (`system.enableReadFromSecondaryVisibility: false`)

### Enabling dual visibility

In `values.yaml`:

```yaml
dualVisibility:
  enabled: true
  schemaHookEnabled: true
```

When `dualVisibility.enabled: true` the following Temporal dynamic config keys are automatically seeded into the `temporal-dynconfig` ConfigMap at install time:

| Key | Value | Purpose |
|---|---|---|
| `system.secondaryVisibilityWritingMode` | `"dual"` | Write every visibility record to both stores in parallel |
| `system.enableReadFromSecondaryVisibility` | `false` | Reads come from primary store (secondary is write-only by default) |

These can be changed live at any time by editing the ConfigMap — no pod restarts required. See [Dynamic config](#dynamic-config) for how to do that.

Then run a fresh install:

```bash
bash teardown.sh
bash install.sh
```

The install script detects the flag and automatically:
- Deploys all 3 PostgreSQL instances
- Applies the visibility schema to `postgresql-visibility-secondary` via a custom Helm hook
- Wires `secondaryVisibilityStore` into the Temporal persistence config
- Seeds the dual write dynconfig keys

### Verifying dual write is active

```bash
# Get a JWT first (auth is required)
JWT=$(go run scripts/dex-login.go)

# Start a test workflow
temporal --address localhost:7233 \
  --grpc-meta "authorization=Bearer $JWT" \
  workflow start --type MyWorkflow --task-queue my-queue --workflow-id vis-check-1

# Check primary visibility store
kubectl exec -n temporal temporal-stack-postgresql-visibility-0 -- \
  sh -c "PGPASSWORD=temporal psql -U temporal -d temporal_visibility \
  -c \"SELECT workflow_id, status FROM executions_visibility WHERE workflow_id = 'vis-check-1'\""

# Check secondary visibility store
kubectl exec -n temporal temporal-stack-postgresql-visibility-secondary-0 -- \
  sh -c "PGPASSWORD=temporal psql -U temporal -d temporal_visibility_secondary \
  -c \"SELECT workflow_id, status FROM executions_visibility WHERE workflow_id = 'vis-check-1'\""
```

Both queries should return the same row.

You can also confirm both stores are active at the cluster level:

```bash
temporal --address localhost:7233 \
  --grpc-meta "authorization=Bearer $JWT" \
  operator cluster describe
# VisibilityStore column should show: postgres12,postgres12
```

### Known limitation in the upstream Temporal Helm chart

The upstream chart's schema management derives the schema directory name directly from the datastore name. A secondary visibility store named `"visibility-secondary"` causes it to look for a `visibility-secondary/versioned` schema path that does not exist in the admintools image — only `visibility/versioned` exists.

To work around this, this chart sets `manageSchema: false` on the `visibility-secondary` datastore and ships a custom Helm hook job (`templates/visibility-secondary-schema-job.yaml`) that applies the correct `visibility/versioned` schema to `postgresql-visibility-secondary` before the Temporal server starts.

### Failover: switching reads to secondary during a primary outage

If the primary visibility store degrades, you can switch reads to the secondary live via dynamic config — no restart required:

```bash
# 1. Edit the dynconfig ConfigMap
kubectl edit configmap temporal-dynconfig -n temporal

# Set enableReadFromSecondaryVisibility to true:
# system.enableReadFromSecondaryVisibility:
#   - value: true

# 2. Verify reads now come from secondary (JWT required)
JWT=$(go run scripts/dex-login.go)
temporal --address localhost:7233 \
  --grpc-meta "authorization=Bearer $JWT" \
  workflow list --namespace default
```

When the primary recovers, set `system.enableReadFromSecondaryVisibility` back to `false`. The primary will catch up automatically — any writes that arrived during the outage are replayed from the history store into visibility on the next workflow state change or visibility scan.

> **Important:** dual visibility is a last-resort migration tool, not an HA mechanism. The secondary receives no read traffic under normal operation. A primary store failure degrades reads until you manually flip the dynconfig key. For read HA, use Elasticsearch — it handles shard-level failover transparently without any Temporal-level routing.

For a complete end-to-end failure simulation with exact commands and expected output, see **Phase 9 — Dual Visibility** in [TESTING.md](TESTING.md).

---

## Authentication

Authentication is enabled by default. The chart bundles [Dex](https://dexidp.io/) as a local OIDC identity provider. The Temporal server uses a **custom authorizer and claim mapper** (compiled into the `temporal-custom-server` image) that enforce:

- **No JWT → request denied** — `authorizer=default` is active; any call without a valid bearer token is rejected with `Request unauthorized` before any handler runs
- **JWT present → email-based role mapping** — the custom claim mapper inspects the JWT `email` claim and assigns Temporal roles from a static map (see below); no `permissions` claim in the JWT is required
- **Optional task queue restrictions** — the custom authorizer can block specific task queues from worker polling via the `TEMPORAL_BLOCKED_TASK_QUEUES` env var

### How it works

Dex issues JWTs signed with RS256. The Temporal server fetches Dex's JWKS at startup and every 1 minute, then validates all incoming JWTs locally — no network call per request. After signature validation, the custom claim mapper maps the JWT `email` claim to Temporal roles:

| Email | Roles granted |
|---|---|
| `admin@temporal.io` | `temporal-system:admin`, `default:admin` |
| *(any other valid JWT)* | `default:worker`, `default:reader` |

To change or extend the mapping, edit `images/server/auth/claim_mapper.go` and rebuild (`bash build.sh`).

### Logging in to the UI

Open [http://localhost:30080](http://localhost:30080). You will be redirected to the Dex login page. Use the default static user:

| Email | Password |
|---|---|
| `admin@temporal.io` | `admin` |

After login, Dex issues a JWT and redirects back to the UI. The UI attaches the token to all subsequent API calls automatically.

### Getting a JWT for SDK workers and CLI

Dex only supports the **authorization code** flow — it does not support client credentials or password grants. Use the included helper script, which opens a browser tab, handles the PKCE login locally, and prints the tokens:

```bash
# Opens a browser tab for Dex login (admin@temporal.io / admin)
# stdout: access_token  (use for CLI and --grpc-meta)
# stderr: id_token      (use as Bearer token for SDK workers — carries email/permissions claims)
#         refresh_token (use to auto-refresh before expiry — no browser needed)
cd temporal-helm-superchart
go run scripts/dex-login.go
```

For scripts that only need the token for `$()` capture, stdout is clean:

```bash
export TEMPORAL_TOKEN=$(go run scripts/dex-login.go)
```

The script uses the `temporal-cli` public Dex client (PKCE, no secret) with a local redirect on `localhost:7788`.

> **id_token vs access_token**: Temporal's JWT claim mapper reads the `email` and `permissions` claims from the `id_token`. For SDK workers, pass the `id_token` as the Bearer token. For the `temporal` CLI (`--auth-token`), either token works — the CLI passes it as-is to the server which validates it.

For production IDPs (Okta, Auth0, Keycloak) that support `client_credentials`, use that flow instead:

```bash
JWT=$(curl -s -X POST https://your-idp/oauth2/token \
  -d "grant_type=client_credentials&client_id=temporal-worker&client_secret=..." \
  | jq -r '.access_token')
```

For production IDPs (Okta, Auth0, Keycloak) that support `client_credentials`, use that flow instead:

```bash
JWT=$(curl -s -X POST https://your-idp/oauth2/token \
  -d "grant_type=client_credentials&client_id=temporal-worker&client_secret=..." \
  | jq -r '.access_token')
```

### Using the JWT with the CLI

The `temporal` CLI uses `--grpc-meta` to pass the bearer token:

```bash
export JWT=$(go run scripts/dex-login.go)

# List namespaces
temporal --address localhost:7233 \
  --grpc-meta "authorization=Bearer $JWT" \
  operator namespace list

# List workflows
temporal --address localhost:7233 \
  --grpc-meta "authorization=Bearer $JWT" \
  workflow list --namespace default

# Describe a namespace
temporal --address localhost:7233 \
  --grpc-meta "authorization=Bearer $JWT" \
  operator namespace describe default
```

Unauthenticated calls (without `--grpc-meta`) return `Request unauthorized.` immediately.

### Using the JWT with the Go SDK

Pass the token as a gRPC metadata header using a `HeadersProvider`. The SDK calls `GetHeaders` on every outgoing gRPC call, so the provider is the right place to handle token refresh — check expiry inside `GetHeaders` and re-fetch when needed.

**Static token (local testing):**

```go
import (
    "context"
    "go.temporal.io/sdk/client"
)

type bearerToken struct{ token string }

func (b *bearerToken) GetHeaders(ctx context.Context) (map[string]string, error) {
    return map[string]string{"authorization": "Bearer " + b.token}, nil
}

c, err := client.Dial(client.Options{
    HostPort:        "localhost:7233",
    Namespace:       "default",
    HeadersProvider: &bearerToken{token: jwt},
})
```

**Auto-refreshing token (long-running workers):**

Implement `HeadersProvider` to check the JWT `exp` claim before each call and silently refresh via the IDP's token endpoint when the token is near expiry:

```go
import (
    "context"
    "encoding/base64"
    "encoding/json"
    "net/http"
    "net/url"
    "strings"
    "sync"
    "time"

    "go.temporal.io/sdk/client"
)

type tokenProvider struct {
    mu           sync.Mutex
    token        string
    expiresAt    time.Time
    refreshToken string
    tokenURL     string // e.g. "http://host.docker.internal:30556/dex/token"
    clientID     string // e.g. "temporal-cli"
}

func (p *tokenProvider) GetHeaders(ctx context.Context) (map[string]string, error) {
    p.mu.Lock()
    defer p.mu.Unlock()
    if time.Now().Add(60 * time.Second).After(p.expiresAt) {
        if err := p.refresh(); err != nil {
            return nil, err
        }
    }
    return map[string]string{"authorization": "Bearer " + p.token}, nil
}

func (p *tokenProvider) refresh() error {
    resp, err := http.PostForm(p.tokenURL, url.Values{
        "grant_type":    {"refresh_token"},
        "refresh_token": {p.refreshToken},
        "client_id":     {p.clientID},
    })
    if err != nil {
        return err
    }
    defer resp.Body.Close()
    var result struct {
        IDToken      string `json:"id_token"`
        RefreshToken string `json:"refresh_token"`
    }
    if err := json.NewDecoder(resp.Body).Decode(&result); err != nil {
        return err
    }
    p.token = result.IDToken
    if result.RefreshToken != "" {
        p.refreshToken = result.RefreshToken // Dex may rotate the refresh token
    }
    p.expiresAt = jwtExpiry(result.IDToken)
    return nil
}

// jwtExpiry decodes the JWT payload (no signature verification — server does that)
// and returns the exp claim as a time.Time.
func jwtExpiry(token string) time.Time {
    parts := strings.Split(token, ".")
    if len(parts) != 3 {
        return time.Now().Add(time.Hour)
    }
    payload, err := base64.RawURLEncoding.DecodeString(parts[1])
    if err != nil {
        return time.Now().Add(time.Hour)
    }
    var claims struct {
        Exp int64 `json:"exp"`
    }
    if err := json.Unmarshal(payload, &claims); err != nil || claims.Exp == 0 {
        return time.Now().Add(time.Hour)
    }
    return time.Unix(claims.Exp, 0)
}
```

> **Token source**: `go run scripts/dex-login.go` prints both the `id_token` and `refresh_token`. Pass both to `tokenProvider` at startup. With Dex's default 24 h token lifetime and 1 minute refresh window, workers never need restarting.

### Using the JWT with the Java SDK

Use `AuthorizationGrpcMetadataProvider` with an `AuthorizationTokenSupplier` — not `addGrpcClientInterceptor`. The metadata provider plugs into the SDK's innermost interceptor (`GrpcMetadataProviderInterceptor`) and covers all calls including internal ones like `GetSystemInfo`. Using `addGrpcClientInterceptor` places the interceptor before the SDK's `SystemInfoInterceptor` in the chain, so the auth header is missing from internal bootstrap calls and the connection fails immediately with `PERMISSION_DENIED`.

**Static token (local testing):**

```java
import io.temporal.authorization.AuthorizationGrpcMetadataProvider;
import io.temporal.authorization.AuthorizationTokenSupplier;
import io.temporal.serviceclient.WorkflowServiceStubs;
import io.temporal.serviceclient.WorkflowServiceStubsOptions;

String token = System.getenv("TEMPORAL_TOKEN");

WorkflowServiceStubs service = WorkflowServiceStubs.newServiceStubs(
    WorkflowServiceStubsOptions.newBuilder()
        .setTarget("localhost:7233")
        .addGrpcMetadataProvider(new AuthorizationGrpcMetadataProvider(
            () -> "Bearer " + token))
        .build());
```

**Auto-refreshing token (long-running workers):**

`AuthorizationTokenSupplier` is a `@FunctionalInterface` called on every gRPC call. Implement it to check the JWT `exp` claim and refresh via Dex's token endpoint when the token is near expiry:

```java
import io.temporal.authorization.AuthorizationGrpcMetadataProvider;
import io.temporal.authorization.AuthorizationTokenSupplier;

public class DexTokenSupplier implements AuthorizationTokenSupplier {
    private volatile String cachedToken;
    private volatile Instant expiresAt;
    private final String refreshToken;
    private final String tokenUrl; // "http://host.docker.internal:30556/dex/token"
    private final String clientId; // "temporal-cli"

    public DexTokenSupplier(String initialToken, String refreshToken,
                            String tokenUrl, String clientId) {
        this.cachedToken  = initialToken;
        this.expiresAt    = parseExpiry(initialToken);
        this.refreshToken = refreshToken;
        this.tokenUrl     = tokenUrl;
        this.clientId     = clientId;
    }

    @Override
    public synchronized String supply() {
        if (Instant.now().isAfter(expiresAt.minusSeconds(60))) {
            refresh();
        }
        return "Bearer " + cachedToken;
    }

    private void refresh() {
        // POST grant_type=refresh_token to Dex token endpoint, parse id_token
        // update cachedToken and expiresAt
    }

    private Instant parseExpiry(String jwt) {
        // base64-decode the middle section, read the "exp" claim
        String payload = jwt.split("\\.")[1];
        byte[] decoded = Base64.getUrlDecoder().decode(payload);
        // parse JSON, extract "exp" as epoch seconds
        // return Instant.ofEpochSecond(exp)
    }
}

// Wire it in:
WorkflowServiceStubs service = WorkflowServiceStubs.newServiceStubs(
    WorkflowServiceStubsOptions.newBuilder()
        .setTarget("localhost:7233")
        .addGrpcMetadataProvider(new AuthorizationGrpcMetadataProvider(
            new DexTokenSupplier(idToken, refreshToken,
                "http://host.docker.internal:30556/dex/token", "temporal-cli")))
        .build());
```

> **Token source**: `go run scripts/dex-login.go` prints the `id_token` and `refresh_token`. Pass both at startup. The `supply()` method is called per-gRPC-call; token rotation happens transparently without restarting the worker.

### Namespace and role restrictions

The custom claim mapper grants roles based on email. The mapping is in `images/server/auth/claim_mapper.go`:

| Role | What it allows |
|---|---|
| `reader` | List/describe workflows, get history — read-only |
| `writer` | Start, signal, cancel, terminate workflows + everything `reader` can do |
| `worker` | Poll task queues, heartbeat, complete tasks — nothing else |
| `admin` | Everything including `UpdateNamespace`, `RegisterNamespace`, `DeprecateNamespace` |

To add more users or change permissions, edit the `emailPermissions` map and rebuild:

```go
// images/server/auth/claim_mapper.go
var emailPermissions = map[string][]string{
    "admin@temporal.io":  {"temporal-system:admin", "default:admin"},
    "dev@example.com":    {"default:writer"},
    "reader@example.com": {"default:reader"},
}
```

For production IDPs (Okta, Auth0, Keycloak) that issue JWTs with a `permissions` claim, the custom claim mapper falls back to the default claim mapper path — email mapping is only used when `permissions` is absent.

### Task queue restrictions

The custom authorizer can block specific task queues from worker polling. Set the `TEMPORAL_BLOCKED_TASK_QUEUES` env var on the server pods (comma-separated):

```bash
# Block a task queue — workers that try to poll it get PermissionDenied
kubectl set env deployment/temporal-stack-frontend \
  TEMPORAL_BLOCKED_TASK_QUEUES=InternalQueue,AdminOnlyQueue -n temporal
kubectl set env deployment/temporal-stack-history \
  TEMPORAL_BLOCKED_TASK_QUEUES=InternalQueue,AdminOnlyQueue -n temporal
kubectl set env deployment/temporal-stack-matching \
  TEMPORAL_BLOCKED_TASK_QUEUES=InternalQueue,AdminOnlyQueue -n temporal

# Remove the restriction
kubectl set env deployment/temporal-stack-frontend TEMPORAL_BLOCKED_TASK_QUEUES- -n temporal
kubectl set env deployment/temporal-stack-history  TEMPORAL_BLOCKED_TASK_QUEUES- -n temporal
kubectl set env deployment/temporal-stack-matching TEMPORAL_BLOCKED_TASK_QUEUES- -n temporal
```

Only `PollWorkflowTaskQueue` and `PollActivityTaskQueue` are blocked — other operations on that namespace/task queue (list, describe, start workflow) are unaffected.

### Production: using an external IDP

To use Okta, Auth0, Keycloak, or any OIDC-compliant IDP instead of the bundled Dex:

```yaml
# values.yaml
auth:
  enabled: true
  jwt:
    keySourceURIs:
      - https://your-okta-domain/oauth2/default/v1/keys
  ui:
    providerUrl: https://your-okta-domain/oauth2/default
    clientId: your-okta-client-id
    callbackUrl: https://your-temporal-ui/auth/sso/callback

dex:
  enabled: false   # disable bundled Dex
```

Production IDPs typically issue JWTs with a `permissions` claim. The custom claim mapper detects this and routes to the default mapper path automatically — no code change needed.

### Auto-redirect to OIDC provider (skip the login page)

By default, when auth is enabled the Temporal UI shows an intermediate "Welcome back — Continue to SSO" page before redirecting to the OIDC provider. This is the UI's built-in behaviour and cannot be changed via configuration.

To skip that page and send unauthenticated browsers directly to the Dex (or external IDP) login page, enable the auth redirect proxy:

```yaml
auth:
  autoRedirect:
    enabled: true
```

Then reinstall:

```bash
bash install.sh
```

**How it works:** a small nginx Deployment is placed in front of the Temporal web pod. It checks for the `refresh` cookie — the long-lived (7–30 days) HttpOnly cookie the UI sets after a successful login. If absent, nginx issues a `302` to `/auth/sso?returnUrl=<original-path>`, which the UI server immediately forwards to the OIDC provider login page. nginx also proxies `/dex/` directly to the Dex pod so the entire OAuth flow stays on one origin (required for `SameSite=Strict` cookie handling — see below).

The following paths are handled specially:
- `/dex/*` — proxied to the Dex pod; keeps the OAuth flow on a single hostname
- `/auth/*` — proxied to the web pod unconditionally; the OIDC callback must never be intercepted
- `/login` — always redirected to `/auth/sso`; handles the case where a browser lands on `/login` via a direct URL or a hard reload after logout
- `/_app/`, `/css/`, `/favicon/`, and other static asset paths — proxied unconditionally
- `/api/*` — proxied unconditionally; auth enforced by the server JWT layer, not nginx

**Logout behaviour:** clicking logout in the Temporal UI does a client-side navigation to `/login` using the SvelteKit router (`history.pushState`) — no HTTP request ever reaches nginx, so the `location = /login` rule above cannot intercept it. To handle this, nginx injects a small script into every HTML response (via `sub_filter`) that patches `history.pushState` and `history.replaceState` before the SPA loads. When the logout function calls `navigate('/login')`, the patched push detects the `/login` prefix and calls `window.location.assign('/auth/sso?returnUrl=...')` instead — a real browser navigation that nginx intercepts and redirects to the Dex login page.

Two nginx settings were required to make the injection work:
- `proxy_set_header Accept-Encoding ""` — without this, the upstream sends gzip-compressed HTML based on the browser's `Accept-Encoding` header. nginx's `sub_filter` module cannot scan compressed content, so the injection is silently skipped.
- `proxy_buffering on` — ensures the response is buffered before filters are applied.

The Temporal UI enforces a Content Security Policy via a `<meta>` tag that blocks inline scripts not matching a known SHA256 hash. A second `sub_filter` patches that `<meta>` tag to add the injected script's hash. **If you modify the injected script, recompute the hash:** `echo -n '<script content>' | openssl dgst -sha256 -binary | base64`.

**Port layout when autoRedirect is enabled:**

| Service | Port | Description |
|---|---|---|
| nginx (auth redirect proxy) | `host.docker.internal:30080` | Public UI entry point |
| Temporal web pod (direct) | `localhost:30081` | Direct access, bypasses nginx |

> **Important (Docker Desktop):** access the UI via `http://host.docker.internal:30080`, not `localhost:30080`. The `SameSite=Strict` cookies set during the OAuth flow are tied to the `host.docker.internal` hostname. Using `localhost` breaks the callback because the browser treats them as different origins.

The Temporal web pod moves to `30081` because K8s does not allow two NodePort Services to share the same port.

**External IDP (no Dex):** the `/dex/` proxy location is only needed when Dex is bundled. If you are using an external IDP (Okta, Auth0, Keycloak, etc.), remove the `/dex/` location block from the nginx config. Everything else — the cookie check, `history.pushState` injection, CSP patch, and `/login` redirect — applies unchanged regardless of which IDP you use.

**Disabling auto-redirect:** set `auth.autoRedirect.enabled: false` and reinstall. The nginx Deployment, ConfigMap, and Service are removed; the web Service NodePort returns to `30080`.

---

### Disabling authentication (local dev only)

Not recommended — but if you need a no-auth cluster for quick local testing, set `auth.enabled: false` and `dex.enabled: false` in `values.yaml` and reinstall. The server will use `authorizer=noop` and accept all connections without tokens.

---

## Useful Kubernetes Commands

These are handy commands for exploring and understanding your local cluster.

### Cluster overview

```bash
# See all nodes and their status
kubectl get nodes

# See all namespaces
kubectl get namespaces

# See all pods across every namespace
kubectl get pods -A

# See what StorageClasses are available
kubectl get storageclass
```

### Working with namespaces

```bash
# See everything running in the temporal namespace
kubectl get all -n temporal

# See all pods in the temporal namespace
kubectl get pods -n temporal

# Watch pods in real time (updates live)
kubectl get pods -n temporal -w

# See pods with more detail (node, IP, etc.)
kubectl get pods -n temporal -o wide
```

### Inspecting pods

```bash
# Describe a pod (events, resource limits, mounts — useful for debugging)
kubectl describe pod <pod-name> -n temporal

# Stream logs from a pod
kubectl logs -f <pod-name> -n temporal

# Stream logs from a specific container inside a pod
kubectl logs -f <pod-name> -c <container-name> -n temporal

# Get a shell inside a running pod
kubectl exec -it <pod-name> -n temporal -- /bin/sh
```

### Helm

```bash
# List all installed Helm releases
helm list -A

# Show the current values for an installed release
helm get values temporal-stack -n temporal

# Show all computed values (including defaults)
helm get values temporal-stack -n temporal --all

# Check the status of a release
helm status temporal-stack -n temporal
```

### Cleanup

For a full teardown use `teardown.sh` — it handles the dynconfig ConfigMap and images correctly. See [Uninstalling / Starting Fresh](#uninstalling--starting-fresh).

---

## Troubleshooting

**Pods stuck in `Pending`:**
```bash
kubectl describe pod <pod-name> -n temporal
```
Usually a resource constraint or PVC not binding. Check that your Docker Desktop has enough memory allocated.

**Images not found:**
Build the custom images using `build.sh` — do not use `docker build` directly, as `build.sh` handles the server checkout and go.mod alignment:
```bash
bash build.sh --server-version v1.31.0
```

**Port already in use:**
If port 7233 is in use, your Docker Compose cluster may still be running. Stop it first:
```bash
docker compose down
```

**`Request unauthorized` from CLI or SDK:**
Auth is enabled by default. All calls to port 7233 require a JWT bearer token. Get one with:
```bash
JWT=$(go run scripts/dex-login.go)
temporal --address localhost:7233 --grpc-meta "authorization=Bearer $JWT" operator namespace list
```
See [Authentication](#authentication) for the full CLI and SDK usage.

**Dex login page shows a DNS error (`host.docker.internal` not found):**
Docker Desktop sometimes omits `host.docker.internal` from `/etc/hosts`. Fix:
```bash
echo "127.0.0.1 host.docker.internal" | sudo tee -a /etc/hosts
```
Then reload the browser. This is a one-time fix.

**Browser redirects to Dex but shows `oidc: issuer did not match` or `invalid_client`:**
The Dex issuer URL must match exactly between the server config, the UI env var, and the browser. If you changed the Dex issuer in `values.yaml`, run a full teardown and reinstall — a `helm upgrade` alone does not update the Temporal server's JWKS URI.

**UI shows 403 / redirect loop after Dex login:**
The server received a valid JWT but the claim mapper found no recognised email and granted no roles. Check that the JWT email matches an entry in `emailPermissions` in `images/server/auth/claim_mapper.go`, or that the JWT contains a `permissions` claim if using an external IDP.

**UI loops back to login after Dex login succeeds (SSO callback loop):**
Two possible causes:
1. **Dex restarted** — Dex stores signing keys in memory (`storage: type: memory`). Any pod restart (including after `helm upgrade`) generates new keys. The browser has a cookie with a JWT signed by the old key, which the Temporal server now rejects with `RSA key not found for key ID: ...`. Fix: clear browser cookies/session for `localhost:30080` and log in again. For SDK workers, run `go run scripts/dex-login.go` to get a new token.
2. **Missing JWKS URI** — The Temporal server has no `keySourceURIs` configured and cannot validate any JWT. Check: `helm get values temporal-stack -n temporal | grep -A5 authorization`. If empty, the `authorization:` block is missing from `values.yaml` under `temporal.server.config`. Fix: ensure `authorization:` is inside the same `config:` block as `persistence:` (not a separate sibling `config:` block — YAML silently drops duplicate keys).

**`tdbg` returns `Request unauthorized`:**
`tdbg` does not support passing a JWT. Use `internal-frontend` (port 7236) which bypasses JWT enforcement:
```bash
kubectl exec -n temporal deployment/temporal-stack-admintools -- \
  tdbg --address temporal-stack-internal-frontend:7236 <subcommand>
```

---

## Upgrading Temporal Server

See [UPGRADE.md](UPGRADE.md) for the full step-by-step upgrade runbook, including schema migration, binary rollout, and verification.
