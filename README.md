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

Everything is pre-wired. No manual configuration required to get started.

> **Running Docker Compose instead of Kubernetes?** See [my-temporal-dockercompose](https://github.com/tsurdilo/my-temporal-dockercompose) for the companion Docker Compose setup.

---

## Table of contents

- [Prerequisites](#prerequisites)
  - [1. Docker Desktop](#1-docker-desktop)
  - [2. Kubernetes (via Docker Desktop)](#2-kubernetes-via-docker-desktop)
  - [3. kubectl](#3-kubectl)
  - [4. Helm](#4-helm)
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

---

## Installing the chart

### Custom images

`install.sh` checks for the custom images automatically and builds them if they are missing — no manual build step required on a fresh setup.

The chart uses two locally-built images:

- **`temporal-custom-server`** — Temporal server with [temporal-configmap-dynconfig](https://github.com/tsurdilo/temporal-configmap-dynconfig) compiled in, enabling live dynamic config reloads from the Kubernetes ConfigMap. Also includes a **plaintext payload interceptor** on the frontend gRPC server — detects unencrypted payload encodings (`json/plain`, `binary/plain`) across all major APIs (workflow start, signal, query, update, activity heartbeat, schedules, and task completions), logs a warning, and increments a `plaintext_payload_detected_total` counter metric. Observe-only — requests are always allowed through.
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
1. Adds and updates all required Helm repositories
2. Installs Prometheus Operator CRDs (required before kube-prometheus-stack)
3. Installs PostgreSQL and waits for it to be fully ready and reachable from within the cluster
4. Installs the full stack
5. Waits for Temporal frontend, worker, and Grafana to be ready
6. Creates the `default` Temporal namespace with archival enabled automatically

The first install takes 5–10 minutes as images are pulled. You will see output like:

```
==> Install complete!

  Temporal UI:  http://localhost:30080
  Grafana:      http://localhost:30300  (admin/admin)
  Prometheus:   http://localhost:30090
  MinIO:        http://localhost:30901  (minioadmin/minioadmin)
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
| Temporal UI | [http://localhost:30080](http://localhost:30080) | Workflow management |
| Grafana | [http://localhost:30300](http://localhost:30300) | Dashboards (admin/admin) |
| Prometheus | [http://localhost:30090](http://localhost:30090) | Metrics |
| MinIO Console | [http://localhost:30901](http://localhost:30901) | Archival storage — login: minioadmin / minioadmin. History and visibility archival is enabled on the `default` namespace automatically at install time. |
| Temporal Frontend (gRPC) | `localhost:7233` | SDK target — default port, no config needed. Kubernetes load-balances across both frontend replicas automatically. |

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

Grafana dashboards are stored as Kubernetes ConfigMaps and provisioned automatically. To update a dashboard:

1. Replace the JSON file in `files/dashboards/`
2. Run `helm upgrade`:

```bash
helm upgrade temporal-stack . --namespace temporal
```

Grafana picks up the change automatically — no restart required.

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
kubectl exec -n temporal deployment/temporal-stack-admintools -- \
  tdbg --address temporal-stack-frontend:7233 membership list-gossip
```

This shows every ring member per role with member counts and addresses. After scaling frontend to 3 you should see `"member_count": 3` under the `frontend` role. You can also filter by role:

```bash
kubectl exec -n temporal deployment/temporal-stack-admintools -- \
  tdbg --address temporal-stack-frontend:7233 membership list-gossip --role frontend
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
# Start a test workflow
temporal --address localhost:7233 workflow start \
  --type MyWorkflow --task-queue my-queue --workflow-id vis-check-1

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
temporal operator cluster describe
# VisibilityStore column should show: postgres12,postgres12
```

### Known limitation in the upstream Temporal Helm chart

The upstream chart's schema management derives the schema directory name directly from the datastore name. A secondary visibility store named `"visibility-secondary"` causes it to look for a `visibility-secondary/versioned` schema path that does not exist in the admintools image — only `visibility/versioned` exists.

To work around this, this chart sets `manageSchema: false` on the `visibility-secondary` datastore and ships a custom Helm hook job (`templates/visibility-secondary-schema-job.yaml`) that applies the correct `visibility/versioned` schema to `postgresql-visibility-secondary` before the Temporal server starts.

> **TODO:** Failover runbook (switching reads to secondary when primary degrades, recovery sequence, backfill after primary comes back up) will be added once operational behaviour under failure is fully validated. See PLANNING.md for the current draft.

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

---

## Upgrading Temporal Server

See [UPGRADE.md](UPGRADE.md) for the full step-by-step upgrade runbook, including schema migration, binary rollout, and verification.
