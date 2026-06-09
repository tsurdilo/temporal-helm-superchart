# Testing Plan

This document covers what to test, how to test it, and what to look for at each step. Work through it in order — each phase builds on the previous one.

---

## Phase 1 — Fresh Install

Validate that `install.sh` produces a fully running cluster from scratch every time.

```bash
# Tear down completely (removes Helm release, dynconfig ConfigMap, namespace, and Docker images)
bash teardown.sh
```

Verify it is fully gone before proceeding:

```bash
kubectl get namespace temporal
# Expected: Error from server (NotFound): namespaces "temporal" not found

kubectl get pv | grep temporal
# Expected: no output (PVs are auto-deleted because the storage class reclaimPolicy is Delete)
```

```bash
# Fresh install — automatically builds images if missing, adds Helm repos, installs full stack
bash install.sh
```

**What to verify:**

```bash
kubectl get pods -n temporal
```

Expected: all pods `Running` or `Completed`, no `CrashLoopBackOff`, no `Pending`.

```bash
kubectl get pods -n temporal | grep -v Running | grep -v Completed
```

Expected: no output (every pod is Running or Completed).

**Services accessible:**
- Temporal UI → [http://localhost:30080](http://localhost:30080) — loads, shows `default` namespace
- Grafana → [http://localhost:30300](http://localhost:30300) — loads, login admin/admin works
- Prometheus → [http://localhost:30090](http://localhost:30090) — loads, Status → Targets shows temporal ServiceMonitors

---

## Phase 2 — Temporal Namespace and SDK Connectivity

Validate that the `default` namespace was created and the SDK can connect.

```bash
kubectl exec -n temporal deployment/temporal-stack-admintools -- \
  temporal --address temporal-stack-frontend:7233 operator namespace list
```

Expected: both `default` and `temporal-system` namespaces listed.

**SDK connectivity — run a test workflow:**

```bash
# Start a worker using the Temporal CLI (uses localhost:7233 by default)
temporal workflow execute \
  --type MyWorkflow \
  --task-queue test \
  --namespace default \
  --input '"hello"'
```

Or from any Go/Java/Python SDK app pointing at `localhost:7233` with no extra config.

**What to look for:**
- Workflow appears in the Temporal UI at http://localhost:30080
- No `RESOURCE_EXHAUSTED` or connection errors

---

## Phase 3 — Metrics and Grafana Dashboards

Validate that Temporal metrics flow end-to-end into Grafana.

**Check Prometheus is scraping Temporal:**

Go to http://localhost:30090/targets

Look for targets named `temporal` — they should show state `UP`. If `DOWN`, check the ServiceMonitor:

```bash
kubectl get servicemonitor -n temporal
kubectl describe servicemonitor temporal-stack-frontend -n temporal
```

**Check the server dashboard:**

1. Open Grafana → http://localhost:30300
2. Dashboards → Browse → look for `Temporal` folder
3. Open `Temporal Server Overview`
4. Set namespace variable to `default`
5. Run a few workflows, then check:
   - `Service Requests` panel shows traffic
   - `Service Errors` panel is zero or near-zero
   - `Persistence Latencies` panel shows latency (p50/p95/p99)

**Check namespace label is correct:**

In Prometheus, run:
```promql
service_requests{namespace="default"}
```

Expected: returns results with `namespace="default"`. If it shows `namespace="temporal"` (the K8s namespace), the metric relabeling is broken — check `values.yaml` `metricRelabelings`.

**Check SDK dashboards loaded:**

In Grafana → Dashboards, verify these are present:
- `Temporal SDK Go`
- `Temporal SDK Java (Micrometer)`
- `Temporal SDK Java (OTel)`
- `Temporal SDK Core`

They will show no data until an SDK app with metrics enabled connects — that's expected.

**Check history health dashboard:**

Open `Temporal History Health` dashboard. The `Host Health` panel should show `1` (SERVING) for each history pod. This is driven by the health poller — if the panel is empty, check:

```bash
kubectl logs -n temporal deployment/temporal-stack-health-poller --tail=20
```

Expected: `cluster state: Serving` and per-host `state=Serving` lines every 15 seconds.

---

## Phase 4 — Alert Rules

Validate that the PrometheusRule was picked up by Prometheus.

Go to http://localhost:30090/rules

Look for a group named `temporal-server-essential`. You should see all 14 alerts listed with state `inactive` (no data triggering them).

If the group is missing:
```bash
kubectl get prometheusrule -n temporal
kubectl describe prometheusrule temporal-stack-temporal-server-alerts -n temporal
```

Check that `kube-prometheus-stack` is configured to pick up PrometheusRules from the `temporal` namespace:
```bash
helm get values temporal-stack -n temporal | grep -A5 "prometheusSpec"
```

The `ruleNamespaceSelectorNilUsesHelmValues: false` or a matching namespace selector is required. If not set, add it to `values.yaml`:
```yaml
kube-prometheus-stack:
  prometheus:
    prometheusSpec:
      ruleNamespaceSelectorNilUsesHelmValues: false
```

Then upgrade:
```bash
helm upgrade temporal-stack . --namespace temporal --reuse-values
```

---

## Phase 5 — Dynamic Config

Validate that a dynamic config change propagates live to the server pods.

**Check the current dynamic config (what is in the ConfigMap):**
```bash
kubectl get configmap temporal-dynconfig -n temporal -o jsonpath='{.data.config\.yaml}'
```

**Check the current static config (what the server was started with):**
```bash
kubectl exec -n temporal deployment/temporal-stack-frontend -- cat /etc/temporal/config/config_template.yaml
```

The static config is baked into the pod at deploy time via a ConfigMap mounted at `/etc/temporal/config/`. Changes here require a pod restart (i.e. `helm upgrade`). Dynamic config keys override static values at runtime with no restart required.

**Apply a change — block all RPS on the default namespace:**

Use `kubectl patch` to ensure exact YAML formatting (manual `kubectl edit` can silently break YAML parsing):

```bash
kubectl patch configmap temporal-dynconfig -n temporal --type=merge -p \
  '{"data":{"config.yaml":"frontend.namespacerps:\n  - value: 0\n    constraints:\n      namespace: default\n"}}'
```

> Note: `value: 0` means 0 RPS. The first request or two may still succeed due to burst — send several quickly to confirm throttling is active.

**Verify it took effect — run several workflow starts in quick succession:**
```bash
for i in {1..5}; do
  temporal workflow start \
    --type MyWorkflow \
    --task-queue test \
    --namespace default \
    --input '"hello"' &
done
wait
```

Expected: the first 1–2 requests succeed (burst allowance), then subsequent ones hang or fail. The Temporal CLI retries on rate-limit errors internally rather than printing `RESOURCE_EXHAUSTED` immediately — the hang IS the throttle. Kill any stuck processes with:
```bash
ps aux | grep "temporal workflow" | grep -v grep | awk '{print $2}' | xargs kill -9
```

Check the frontend logs to confirm the quota change was applied:
```bash
kubectl logs -n temporal deployment/temporal-stack-frontend --since=30s | grep -i "quota changed"
```

**Revert — remove the namespacerps override:**

Get the current config, remove the `frontend.namespacerps` block, and re-apply:

```bash
kubectl get configmap temporal-dynconfig -n temporal -o jsonpath='{.data.config\.yaml}' > /tmp/dynconfig.yaml
# Edit /tmp/dynconfig.yaml — delete the frontend.namespacerps lines
kubectl create configmap temporal-dynconfig \
  --from-file=config.yaml=/tmp/dynconfig.yaml \
  --namespace temporal \
  --dry-run=client -o yaml | kubectl apply -f -
```

Wait a few seconds, then verify workflows start again:
```bash
temporal workflow start --type MyWorkflow --task-queue test --namespace default --input '"hello"'
```

Expected: starts immediately (no hang).

---

## Phase 6 — Health Poller and host_health Metric

Validate that `host_health` is emitted by the poller and visible in Prometheus.

```bash
# Check poller is running and making successful calls
kubectl logs -n temporal deployment/temporal-stack-health-poller -f
```

Expected output every 15s:
```
cluster state: Serving
  service=history host=10.x.x.x:7234 state=Serving
  service=history host=10.x.x.x:7234 state=Serving
```

**Check the metric in Prometheus:**

Go to http://localhost:30090 and query:
```promql
host_health
```

Expected: one time series per history pod, each with value `1` (SERVING).

---

## Phase 7 — MinIO Archival (when enabled)

> MinIO and archival are enabled by default and the `default` namespace is pre-configured for archival at install time — no extra steps needed.

> The `default` namespace already has archival enabled — the `namespace-init` job configures it automatically at install time. No need to create a separate namespace.

**Verify archival is enabled on the default namespace:**
```bash
kubectl exec -n temporal deployment/temporal-stack-admintools -- \
  temporal --address temporal-stack-frontend:7233 operator namespace describe -n default \
  | grep -i archival
```

You should see `HistoryArchivalState: Enabled` and `VisibilityArchivalState: Enabled`.

**Run a workflow and let it complete:**
```bash
temporal workflow execute \
  --type MyWorkflow \
  --task-queue test \
  --namespace default
```

**Verify the workflow was archived:**
```bash
temporal workflow list \
  --namespace default \
  --archived
```

**Verify files exist in MinIO:**

The MinIO console is exposed on NodePort 30901 — no port-forwarding needed:

Open [http://localhost:30901](http://localhost:30901) and log in with `minioadmin` / `minioadmin`.

Navigate to **Buckets** and check `temporal-history` and `temporal-visibility` — each should contain archived files under a path matching the workflow's namespace and run ID.

---

## Phase 8 — Upgrade Runbook Smoke Test

Validate the upgrade runbook works end-to-end with a minor version hop. See [UPGRADE.md](UPGRADE.md) for the full procedure. For a smoke test:

1. Check current schema version:
   ```bash
   kubectl exec -it -n temporal deployment/temporal-stack-admintools -- \
     PGPASSWORD=temporal psql -h temporal-stack-postgresql -U temporal -d temporal \
     -c "SELECT curr_version FROM schema_version;"
   ```
2. Confirm `temporal-sql-tool` is present in admintools:
   ```bash
   kubectl exec -n temporal deployment/temporal-stack-admintools -- \
     temporal-sql-tool --help
   ```
3. Confirm schema paths exist in admintools:
   ```bash
   kubectl exec -n temporal deployment/temporal-stack-admintools -- \
     ls /etc/temporal/schema/postgresql/v12/temporal/versioned/
   ```

---

## Checklist Summary

| # | Test | Pass |
|---|------|------|
| 1 | Fresh install completes, all pods Running | |
| 2 | Temporal UI loads at localhost:30080 | |
| 3 | Grafana loads at localhost:30300 | |
| 4 | Prometheus loads at localhost:30090 | |
| 5 | `default` Temporal namespace exists | |
| 6 | SDK connects at localhost:7233 (run a workflow) | |
| 7 | Workflow visible in Temporal UI | |
| 8 | Prometheus scrapes Temporal (targets UP) | |
| 9 | `service_requests{namespace="default"}` returns data | |
| 10 | Server Overview dashboard shows traffic | |
| 11 | All 4 SDK dashboards present in Grafana | |
| 12 | History Health dashboard shows host_health=1 | |
| 13 | All 14 alert rules visible in Prometheus `/rules` | |
| 14 | Dynamic config change propagates without restart | |
| 15 | Health poller logs show `cluster state: Serving` | |
| 16 | `host_health` metric visible in Prometheus | |
| 17 | MinIO archival (when enabled) — archived workflow retrievable | |
| 18 | `temporal-sql-tool` and schema paths present in admintools | |
