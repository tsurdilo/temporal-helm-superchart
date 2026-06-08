# Temporal Stack — Helm Super-Chart

A self-contained Helm chart that deploys a full Temporal Server cluster on Kubernetes, including:

- Temporal Server (frontend ×2, history ×2, matching ×2, worker ×1, internal-frontend ×1)
- PostgreSQL (main store + visibility store)
- Prometheus + Grafana (pre-loaded dashboards and alerts)
- Loki + Promtail (log aggregation)
- MinIO (workflow and visibility archival)
- Health poller (drives per-host `host_health` metrics)

Everything is pre-wired. No manual configuration required to get started.

> **Running Docker Compose instead of Kubernetes?** See [my-temporal-dockercompose](https://github.com/tsurdilo/my-temporal-dockercompose) for the companion Docker Compose and Swarm setup.

---

## Table of contents

- [Prerequisites](#prerequisites)
  - [1. Docker Desktop](#1-docker-desktop)
  - [2. Kubernetes (via Docker Desktop)](#2-kubernetes-via-docker-desktop)
  - [3. kubectl](#3-kubectl)
  - [4. Helm](#4-helm)
- [Installing the chart](#installing-the-chart)
  - [Add required Helm repositories](#add-required-helm-repositories)
  - [Build the custom images](#build-the-custom-images)
  - [Run the install script](#run-the-install-script)
  - [Verify](#verify)
- [Accessing the services](#accessing-the-services)
- [Uninstalling](#uninstalling)
- [Starting fresh](#starting-fresh)
- [Switching between this chart and Docker Compose](#switching-between-this-chart-and-docker-compose)
- [Updating dashboards](#updating-dashboards)
- [Dynamic config](#dynamic-config)
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

kubectl is the Kubernetes command-line tool. Install it with:

```bash
brew install kubectl
```

Verify it is pointed at your local cluster:

```bash
kubectl config current-context
# should output: docker-desktop

kubectl get nodes
# should show one node with STATUS: Ready
```

### 4. Helm

Helm is the Kubernetes package manager used to install this chart.

```bash
brew install helm
```

Verify:

```bash
helm version
```

---

## Installing the chart

### Add required Helm repositories

```bash
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo add temporal https://go.temporal.io/helm-charts
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

### Build the custom images

The chart uses two locally-built Docker images. Build them before installing:

```bash
# from the repo root — always specify the server version to match Chart.yaml
bash build.sh --server-version v1.31.0
```

This checks out that tag in `~/devel/temporal/temporal`, aligns the `go.temporal.io/api` version across all modules, then builds two images into Docker Desktop's image cache (no registry push needed):

- **`temporal-custom-server`** — Temporal server with [temporal-configmap-dynconfig](https://github.com/tsurdilo/temporal-configmap-dynconfig) compiled in. This is what enables live dynamic config reloads from the Kubernetes ConfigMap.
- **`temporal-health-poller`** — Sidecar that calls `AdminHandler.DeepHealthCheck` on each history pod and emits the `host_health` gauge to Prometheus.

The script prints the server tag and commit it built against so you always know what is in the image:
```
==> Building against server: v1.31.0 (83881961d)
```

The version passed to `--server-version` must match the Temporal chart version in `Chart.yaml`. See [UPGRADE.md](UPGRADE.md) when changing versions.

### Run the install script

```bash
cd ~/devel/temporal-helm-superchart
bash install.sh
```

The script handles everything in the correct order:
1. Installs Prometheus Operator CRDs
2. Installs PostgreSQL and waits for it to be fully ready
3. Installs the full stack
4. Waits for Temporal frontend, worker, and Grafana to be ready
5. Creates the `default` Temporal namespace automatically

The first install takes 5–10 minutes as images are pulled. You will see output like:

```
==> Install complete!

  Temporal UI:  http://localhost:30080
  Grafana:      http://localhost:30300  (admin/admin)
  Prometheus:   http://localhost:30090
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

**Teardown + reinstall (keep existing images):**
```bash
bash teardown.sh
bash install.sh
```

**Full reset including a clean image rebuild:**
```bash
bash teardown.sh
bash build.sh --server-version v1.31.0
bash install.sh
```

**Teardown only (keep images in Docker cache):**
```bash
bash teardown.sh --keep-images
```

> The `temporal-dynconfig` ConfigMap has `helm.sh/resource-policy: keep`, so `helm uninstall` alone does not remove it. `teardown.sh` deletes it explicitly before removing the namespace.

---

## Switching between this chart and Docker Compose

If you are running Temporal via Docker Compose instead of Kubernetes, see [my-temporal-dockercompose](https://github.com/tsurdilo/my-temporal-dockercompose) — a companion repo covering Docker Compose and Swarm deployments with the same production-oriented configuration.

You can switch freely between running Temporal on Kubernetes (this chart) and running it via Docker Compose. They are completely independent — Kubernetes does not interfere with Docker containers.

> **Important:** Both setups use port 7233 for the Temporal frontend. You cannot run both at the same time.

### Switch from K8s to Docker Compose

```bash
# 1. Uninstall the chart
helm uninstall temporal-stack --namespace temporal

# 2. Start the Docker Compose cluster (from your compose repo)
cd ~/path/to/my-temporal-dockercompose
docker compose up -d
```

### Switch from Docker Compose back to K8s

```bash
# 1. Stop the Docker Compose cluster
cd ~/path/to/my-temporal-dockercompose
docker compose down

# 2. Reinstall the chart
cd ~/path/to/temporal-helm-superchart
bash install.sh
```

Your Kubernetes cluster keeps running in the background while Docker Compose is active — you do not need to stop or restart it.

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

Temporal's [dynamic config](https://docs.temporal.io/references/dynamic-configuration) controls hundreds of runtime parameters — rate limits, cache sizes, task queue partitions, retention policies, and more. This chart uses a Kubernetes ConfigMap as the dynamic config backend, powered by [temporal-configmap-dynconfig](https://github.com/tsurdilo/temporal-configmap-dynconfig) — a custom dynamic config client that watches the ConfigMap via the Kubernetes Watch API and applies changes to the server live, with no pod restarts required.

### Where it lives

```bash
kubectl get configmap temporal-dynconfig -n temporal -o jsonpath='{.data.config\.yaml}'
```

On a fresh install the ConfigMap contains seeded defaults. Any key not present falls back to Temporal's compiled-in default.

### Making a change

Edit the ConfigMap directly:

```bash
kubectl edit configmap temporal-dynconfig -n temporal
```

This opens the ConfigMap in your default editor (`$EDITOR`). Edit the `config.yaml` value under `data:`, save, and close. All server pods pick up the change within seconds — no restart required.

Example — raise the visibility list RPS (defaults to 10, a common source of `RESOURCE_EXHAUSTED` errors):

```yaml
data:
  config.yaml: |
    frontend.namespaceRPS.visibility:
      - value: 100
        constraints: {}
```

### Value format

Each key maps to a list of constrained values. A value with `constraints: {}` is the global default. You can add per-namespace overrides above it:

```yaml
frontend.globalNamespaceRPS:
  - value: 500
    constraints:
      namespace: high-traffic-namespace
  - value: 1200
    constraints: {}
```

Temporal evaluates constraints in order — most specific wins.

### Applying a file

If you prefer to keep your dynamic config in a file under version control:

```bash
kubectl create configmap temporal-dynconfig \
  --from-file=config.yaml=my-dynconfig.yaml \
  --namespace temporal \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Reverting a value to the compiled-in default

Remove the key from `config.yaml`. All pods revert to Temporal's compiled-in default within seconds.

### Viewing what is currently loaded

```bash
kubectl get configmap temporal-dynconfig -n temporal -o jsonpath='{.data.config\.yaml}'
```

To see Temporal's compiled-in defaults for any key, check the [dynamic config reference](https://github.com/temporalio/temporal/blob/main/service/config/development-cass.yaml) in the Temporal server source.

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

### Port forwarding

```bash
# Forward a single service to localhost
kubectl port-forward svc/<service-name> <local-port>:<service-port> -n temporal

# Example: Temporal UI on localhost:8080
kubectl port-forward svc/temporal-stack-web 8080:8080 -n temporal
```

### Cleanup

```bash
# Delete everything in the temporal namespace (data included)
kubectl delete namespace temporal

# Recreate it fresh
kubectl create namespace temporal
```

---

## Troubleshooting

**Pods stuck in `Pending`:**
```bash
kubectl describe pod <pod-name> -n temporal
```
Usually a resource constraint or PVC not binding. Check that your Docker Desktop has enough memory allocated.

**Images not found:**
Make sure you built the custom images before installing — Docker Desktop shares its image cache with Kubernetes automatically:
```bash
docker build -t temporal-custom-server:latest -f images/server/Dockerfile .
docker build -t temporal-health-poller:latest -f images/poller/Dockerfile .
```

**Port already in use:**
If port 7233 is in use, your Docker Compose cluster may still be running. Stop it first:
```bash
docker compose down
```

---

## Upgrading Temporal Server

See [UPGRADE.md](UPGRADE.md) for the full step-by-step upgrade runbook, including schema migration, binary rollout, and verification.
