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

## Phase 9 — Dual Visibility

> This phase only applies when `dualVisibility.enabled: true` in `values.yaml`. Skip if running single visibility.

### Step 1 — Verify dual visibility is active

Confirm all three PostgreSQL instances are running and the secondary store is wired up:

```bash
kubectl get pods -n temporal | grep postgresql
```

Expected: three pods running — `postgresql-main-0`, `postgresql-visibility-0`, `postgresql-visibility-secondary-0`.

Check the server config confirms dual visibility is wired:

```bash
kubectl exec -n temporal deployment/temporal-stack-frontend -- \
  cat /etc/temporal/config/config_template.yaml | grep -A5 "secondaryVisibilityStore"
```

Expected: `secondaryVisibilityStore: visibility-secondary` is present.

Check the dynconfig has dual visibility keys set:

```bash
kubectl get configmap temporal-dynconfig -n temporal -o jsonpath='{.data.config\.yaml}' \
  | grep -A2 "secondaryVisibilityWritingMode\|enableReadFromSecondaryVisibility"
```

Expected:
```
system.secondaryVisibilityWritingMode:
  - value: "dual"
system.enableReadFromSecondaryVisibility:
  - value: false
```

---

### Step 2 — Verify dual write: both stores receive workflow data

Run a workflow:

```bash
temporal workflow execute \
  --type MyWorkflow \
  --task-queue test \
  --namespace default \
  --input '"hello"'
```

Note the workflow ID from the output. Then confirm the visibility row landed in **both** stores:

```bash
# Primary visibility store
kubectl run vis-check-primary --rm -i --image=postgres:16-alpine --restart=Never -n temporal \
  --command -- /bin/sh -c \
  "PGPASSWORD=temporal psql -h temporal-stack-postgresql-visibility \
   -U temporal -d temporal_visibility -t -c \
   \"SELECT workflow_id, workflow_type_name, status FROM executions_visibility LIMIT 5;\"" \
  2>/dev/null

# Secondary visibility store
kubectl run vis-check-secondary --rm -i --image=postgres:16-alpine --restart=Never -n temporal \
  --command -- /bin/sh -c \
  "PGPASSWORD=temporal psql -h temporal-stack-postgresql-visibility-secondary \
   -U temporal -d temporal_visibility_secondary -t -c \
   \"SELECT workflow_id, workflow_type_name, status FROM executions_visibility LIMIT 5;\"" \
  2>/dev/null
```

Expected: same workflow rows appear in both stores. Row counts should match.

---

### Step 3 — Verify reads come from primary by default

With `enableReadFromSecondaryVisibility: false` (default), all list/query operations hit the primary store. Confirm:

```bash
temporal workflow list --namespace default --address localhost:7233
```

Expected: workflows listed. This is reading from primary.

To confirm reads are NOT yet going to secondary, temporarily scale down primary visibility and verify list fails:

```bash
kubectl scale statefulset temporal-stack-postgresql-visibility -n temporal --replicas=0
```

Wait ~30-60 seconds, then:

```bash
temporal workflow list --namespace default --address localhost:7233
```

Expected: error or timeout — primary is down and reads are not yet redirected to secondary.

> **Note:** `workflow list` may still succeed for 30-60 seconds after scaling down. The frontend maintains a SQL connection pool and the OS TCP stack does not immediately detect the dead pod — existing pooled connections keep serving until a keepalive or failed query forces them to drop. This is normal. Once all pooled connections to the dead pod are exhausted, list will start failing.

Scale primary back up before continuing:

```bash
kubectl scale statefulset temporal-stack-postgresql-visibility -n temporal --replicas=1
kubectl rollout status statefulset/temporal-stack-postgresql-visibility -n temporal --timeout=2m
kubectl wait pod/temporal-stack-postgresql-visibility-0 -n temporal \
  --for=condition=Ready --timeout=2m
```

---

### Step 4 — Switch reads to secondary via dynconfig

Patch dynconfig to redirect reads to the secondary store:

```bash
kubectl get configmap temporal-dynconfig -n temporal -o jsonpath='{.data.config\.yaml}' > /tmp/dynconfig.yaml
```

Edit `/tmp/dynconfig.yaml` and set:

```yaml
system.enableReadFromSecondaryVisibility:
  - value: true
```

Apply:

```bash
kubectl create configmap temporal-dynconfig \
  --from-file=config.yaml=/tmp/dynconfig.yaml \
  --namespace temporal \
  --dry-run=client -o yaml | kubectl apply -f -
```

Wait a few seconds for the change to propagate, then verify reads still return data (now from secondary):

```bash
temporal workflow list --namespace default --address localhost:7233
```

Expected: same workflows listed — secondary store has the same data.

Revert to reading from primary before continuing:

```bash
kubectl get configmap temporal-dynconfig -n temporal \
  -o jsonpath='{.data.config\.yaml}' \
  | sed -e '/enableReadFromSecondaryVisibility/{' -e 'n' -e 's/  - value: true/  - value: false/' -e '}' \
  > /tmp/dynconfig.yaml

kubectl create configmap temporal-dynconfig \
  --from-file=config.yaml=/tmp/dynconfig.yaml \
  --namespace temporal \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

### Step 5 — Simulate primary visibility store failure

Scale down the primary visibility postgres:

```bash
kubectl scale statefulset temporal-stack-postgresql-visibility -n temporal --replicas=0
```

Confirm it is fully gone — wait until this shows only the secondary pod:

```bash
kubectl get pods -n temporal | grep postgresql-visibility
```

Expected:
```
temporal-stack-postgresql-visibility-secondary-0   1/1   Running   0   ...
```

Run several workflows while primary is down:

```bash
for i in {1..3}; do
  temporal workflow start \
    --type MyWorkflow \
    --task-queue test \
    --namespace default \
    --input "\"test-during-outage-$i\"" \
    --workflow-id "outage-test-$i"
done
```

Workflows will start (workflow state is in the main DB, not visibility) but visibility writes will fail. Observe history service retrying visibility tasks — check history logs:

```bash
kubectl logs -n temporal deployment/temporal-stack-history --tail=50 | grep -i "visibility\|failed\|retry"
```

Expected output similar to:
```
{"level":"error","msg":"Operation failed with an error.","error":"no usable database connection found",
"stacktrace":"...RecordWorkflowExecutionStarted...dualWriteWrapper...visibility_manager_dual.go..."}
```

Key things to confirm in the log output:
- `no usable database connection found` — primary is down and the connection pool has given up
- `RecordWorkflowExecutionStarted` — visibility write triggered by workflow start, failing as expected
- `visibility_manager_dual.go` / `dualWriteWrapper` — dual visibility manager is handling the failure
- `visiblity_manager_metrics.go` — the error is being tracked as a metric, Prometheus is counting these failures

Tasks back off starting at 1 second, increasing by 1.1x per attempt, capping at 3 minutes. **There is no retry limit** — tasks keep retrying until the store comes back.

Check that the workflows still appear in the UI and are running (workflow state is unaffected — only visibility is degraded):

```bash
temporal workflow describe --workflow-id outage-test-1 --namespace default --address localhost:7233
```

Expected output contains:
```
Status: Running
```

You can also check all three outage workflows at once:

```bash
for i in {1..3}; do
  echo "outage-test-$i:"
  temporal workflow describe --workflow-id outage-test-$i --namespace default --address localhost:7233 \
    | grep "Status"
done
```

Expected: all three show `Status: Running`. Workflow execution (task scheduling, state transitions, timers) is driven by the main DB and history service — visibility is a write-aside store and its failure does not affect execution.

---

### Step 6 — Manual read failover to secondary during outage

While primary is still down, redirect reads to secondary so `workflow list` and the UI still work.

Fetch the current config, flip the flag, and reapply:

```bash
kubectl get configmap temporal-dynconfig -n temporal \
  -o jsonpath='{.data.config\.yaml}' \
  | sed -e '/enableReadFromSecondaryVisibility/{' -e 'n' -e 's/  - value: false/  - value: true/' -e '}' \
  > /tmp/dynconfig.yaml

# Verify the change looks right before applying
grep -A2 "enableReadFromSecondaryVisibility" /tmp/dynconfig.yaml
# Expected:
# system.enableReadFromSecondaryVisibility:
#   - value: true

kubectl create configmap temporal-dynconfig \
  --from-file=config.yaml=/tmp/dynconfig.yaml \
  --namespace temporal \
  --dry-run=client -o yaml | kubectl apply -f -
```

Now verify list works again (reading from secondary):

```bash
temporal workflow list --namespace default --address localhost:7233
```

Expected: workflows listed from secondary store. The 3 workflows started during the outage will **not** appear yet — their visibility writes are still queued and pending (history is retrying them). This is expected.

---

### Step 7 — Restore primary and verify convergence

Scale primary visibility back up:

```bash
kubectl scale statefulset temporal-stack-postgresql-visibility -n temporal --replicas=1
kubectl rollout status statefulset/temporal-stack-postgresql-visibility -n temporal --timeout=2m
kubectl wait pod/temporal-stack-postgresql-visibility-0 -n temporal \
  --for=condition=Ready --timeout=2m
```

Watch history logs — the queued visibility tasks should now drain:

```bash
kubectl logs -n temporal deployment/temporal-stack-history -f | grep -i "visibility"
```

Wait ~30 seconds, then verify the 3 outage workflows now appear in the primary store:

```bash
kubectl run vis-check-recovery --rm -i --image=postgres:16-alpine --restart=Never -n temporal \
  --command -- /bin/sh -c \
  "PGPASSWORD=temporal psql -h temporal-stack-postgresql-visibility \
   -U temporal -d temporal_visibility -t -c \
   \"SELECT workflow_id FROM executions_visibility WHERE workflow_id LIKE 'outage-test-%';\"" \
  2>/dev/null
```

Expected: `outage-test-1`, `outage-test-2`, `outage-test-3` all present — queued tasks executed and primary converged with secondary.

---

### Step 8 — Restore dynconfig to normal dual-write mode

Revert `enableReadFromSecondaryVisibility` back to `false`:

```bash
kubectl get configmap temporal-dynconfig -n temporal \
  -o jsonpath='{.data.config\.yaml}' \
  | sed -e '/enableReadFromSecondaryVisibility/{' -e 'n' -e 's/  - value: true/  - value: false/' -e '}' \
  > /tmp/dynconfig.yaml

grep -A2 "enableReadFromSecondaryVisibility" /tmp/dynconfig.yaml

kubectl create configmap temporal-dynconfig \
  --from-file=config.yaml=/tmp/dynconfig.yaml \
  --namespace temporal \
  --dry-run=client -o yaml | kubectl apply -f -
```

Verify normal operation is restored:

```bash
temporal workflow list --namespace default --address localhost:7233
```

Expected: all workflows listed, reads back on primary.

---

## Phase 10 — Authentication

> Auth is enabled by default. This phase verifies the full JWT enforcement chain:
> no-JWT rejection, Dex SSO login, token issuance via PKCE, authenticated CLI access,
> the custom email-based claim mapper, and task queue blocking.
>
> **Prerequisites:** Dex is running, `host.docker.internal` resolves (see Prerequisite 5 in README).

### Step 1 — Verify Dex is running and JWKS is reachable

```bash
kubectl get pods -n temporal | grep dex
```

Expected: `temporal-stack-dex-xxx   1/1   Running`

Check Dex startup logs:

```bash
kubectl logs -n temporal deployment/temporal-stack-dex | grep -E "config|listening"
```

Expected output includes:
```
config static client  client_name="Temporal UI"
config static client  client_name="Temporal CLI/SDK"
config connector: local passwords enabled
listening on  server=http address=0.0.0.0:5556
```

Verify the JWKS endpoint is reachable from the host:

```bash
curl -s http://host.docker.internal:30556/dex/keys \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'Keys: {len(d[\"keys\"])}, alg: {d[\"keys\"][0][\"alg\"]}')"
```

Expected: `Keys: 2, alg: RS256`

Also verify the Temporal server loaded them (check frontend startup logs):

```bash
kubectl logs -n temporal deployment/temporal-stack-frontend --since=10m \
  | grep -i "blocked\|task queue blocked" | head -5
```

If `TEMPORAL_BLOCKED_TASK_QUEUES` was set at startup you'll see `Task queue blocked from worker polling` lines. Normally empty on a fresh install.

---

### Step 2 — Verify unauthenticated calls are rejected

From the host, call the Temporal gRPC API without a JWT:

```bash
temporal --address localhost:7233 operator namespace list 2>&1
```

Expected:
```
time=... level=ERROR msg="failed listing namespaces: Request unauthorized."
```

This confirms `authorizer=default` is active and the custom authorizer is running.

Also verify from inside the cluster using admintools (no JWT):

```bash
kubectl exec -n temporal deployment/temporal-stack-admintools -- \
  temporal --address temporal-stack-frontend:7233 operator namespace describe default 2>&1
```

Expected: `Request unauthorized.`

---

### Step 3 — Verify the UI requires login and SSO works

Open [http://localhost:30080](http://localhost:30080) in a browser.

Expected: browser redirects to Dex login page at `http://host.docker.internal:30556/dex/auth?...`

> If the browser lands on a DNS error instead of the Dex login page, `host.docker.internal`
> is not resolving. Run: `echo "127.0.0.1 host.docker.internal" | sudo tee -a /etc/hosts`
> then reload.

Log in with `admin@temporal.io` / `admin`.

Expected: redirected back to `http://localhost:30080/namespaces/default/workflows`. The namespace list is visible and no 403 errors appear in the browser console.

---

### Step 4 — Get a JWT for CLI and SDK testing

Dex only supports the authorization code flow — use the included helper script, which opens a
browser tab, handles PKCE locally, and prints the access token:

```bash
cd temporal-helm-superchart
JWT=$(go run scripts/dex-login.go)
echo $JWT | cut -c1-40   # should start with eyJ
```

When the browser tab opens, log in with `admin@temporal.io` / `admin`. The script captures the
callback at `localhost:7788` and exits. The token is printed to stdout.

Save it for subsequent steps:

```bash
export JWT=$(go run scripts/dex-login.go)
```

---

### Step 5 — Verify authenticated CLI works

```bash
temporal --address localhost:7233 \
  --grpc-meta "authorization=Bearer $JWT" \
  operator namespace list
```

Expected: both `temporal-system` and `default` namespaces returned with no error.

```bash
temporal --address localhost:7233 \
  --grpc-meta "authorization=Bearer $JWT" \
  operator namespace describe default
```

Expected: namespace details for `default` returned.

```bash
temporal --address localhost:7233 \
  --grpc-meta "authorization=Bearer $JWT" \
  workflow list --namespace default
```

Expected: workflow list returned (empty is fine — no error means auth passed).

---

### Step 6 — Verify the custom claim mapper: email → admin role

The JWT for `admin@temporal.io` has no `permissions` claim (Dex static passwords don't support
custom claims). The custom claim mapper detects this and falls back to email-based role
assignment: `admin@temporal.io` → `temporal-system:admin + default:admin`.

Confirm that admin-level operations work with this token:

```bash
# UpdateNamespace requires admin role — should succeed
temporal --address localhost:7233 \
  --grpc-meta "authorization=Bearer $JWT" \
  operator namespace update --namespace default --description "auth test"
```

Expected: no error, namespace description updated.

```bash
# Reset description
temporal --address localhost:7233 \
  --grpc-meta "authorization=Bearer $JWT" \
  operator namespace update --namespace default --description ""
```

Confirm the claim mapper logged the email-based mapping (frontend logs):

```bash
kubectl logs -n temporal deployment/temporal-stack-frontend --since=5m \
  | grep -i "claim\|email\|permission" | head -10
```

---

### Step 7 — Verify task queue blocking

Set a blocked task queue on all server pods:

```bash
for svc in frontend history matching; do
  kubectl set env deployment/temporal-stack-$svc \
    TEMPORAL_BLOCKED_TASK_QUEUES=HelloActivityTaskQueue -n temporal
done

# Wait for rollout
kubectl rollout status deployment/temporal-stack-frontend -n temporal --timeout=60s
```

Confirm the authorizer loaded the block at startup:

```bash
kubectl logs -n temporal deployment/temporal-stack-frontend --since=2m \
  | grep "Task queue blocked"
```

Expected:
```
{"level":"info","msg":"Task queue blocked from worker polling.","wf-task-queue-name":"HelloActivityTaskQueue",...}
```

Now verify that polling the blocked queue is denied, while a different queue goes through:

```bash
# Blocked queue — must be denied
TEMPORAL_TOKEN=$JWT go run scripts/poll-test.go HelloActivityTaskQueue
# Expected: Poll(HelloActivityTaskQueue): rpc error: code = PermissionDenied desc = Request unauthorized.

# Different queue — must be allowed
TEMPORAL_TOKEN=$JWT go run scripts/poll-test.go SomeOtherQueue
# Expected: Poll(SomeOtherQueue): ✅ allowed (no task — queue is NOT blocked)
```

The test script is at `scripts/poll-test.go` in the repo.

Clean up after the test:

```bash
for svc in frontend history matching; do
  kubectl set env deployment/temporal-stack-$svc TEMPORAL_BLOCKED_TASK_QUEUES- -n temporal
done
```

---

### Step 8 — Verify internal services bypass JWT enforcement

Internal Temporal services (history, matching, worker-service) connect via `internal-frontend`
(port 7236) which bypasses JWT auth entirely. Confirm they are healthy and have no auth errors:

```bash
kubectl get pods -n temporal | grep -E "history|matching|worker" | grep -v admintools
```

Expected: all Running, no CrashLoopBackOff.

```bash
kubectl logs -n temporal deployment/temporal-stack-history --since=2m \
  | grep -i "unauthorized\|permission denied" | head -5
```

Expected: no output — internal services never hit the JWT gate.

Also verify the namespace-init job completed successfully (it uses internal-frontend too):

```bash
kubectl get job -n temporal | grep namespace-init
```

Expected: `COMPLETIONS: 1/1`

---

### Step 9 — Verify JWKS refresh is working (no key errors after 1 minute)

Wait ~2 minutes after install, then check for any JWKS fetch errors:

```bash
kubectl logs -n temporal deployment/temporal-stack-frontend --since=5m \
  | grep -i "error.*key\|key.*error\|jwks" | head -10
```

Expected: no errors. The server re-fetches Dex keys every 1 minute silently in the background.

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
| 19 | (dual vis) All 3 PostgreSQL pods running | |
| 20 | (dual vis) Workflow rows appear in both visibility stores | |
| 21 | (dual vis) Read from secondary returns same results as primary | |
| 22 | (dual vis) Reads fail when primary down and `enableReadFromSecondaryVisibility=false` | |
| 23 | (dual vis) Reads succeed from secondary after dynconfig switch | |
| 24 | (dual vis) Workflows execute normally during primary visibility outage | |
| 25 | (dual vis) History retries visibility writes during outage (logs show retries) | |
| 26 | (dual vis) Primary converges after restore — outage workflows appear in primary | |
| 27 | Dex pod running, JWKS endpoint returns RS256 keys | |
| 28 | UI redirects to Dex login at host.docker.internal:30556 | |
| 29 | UI login with admin@temporal.io / admin succeeds | |
| 30 | Unauthenticated CLI returns `Request unauthorized` | |
| 31 | `go run scripts/dex-login.go` returns a JWT starting with `eyJ` | |
| 32 | Authenticated CLI `operator namespace list` succeeds with `--grpc-meta` | |
| 33 | Authenticated CLI `operator namespace describe default` succeeds | |
| 34 | Authenticated CLI `workflow list` succeeds | |
| 35 | `operator namespace update` succeeds (confirms admin role via email mapping) | |
| 36 | Poll blocked task queue returns `PermissionDenied` | |
| 37 | Poll non-blocked task queue returns empty (allowed) | |
| 38 | Frontend logs show no JWKS key errors after 2 minutes | |
| 39 | Internal services (history/matching) have no auth errors in logs | |
| 40 | namespace-init job shows `COMPLETIONS: 1/1` | |
| 35 | History/matching pods show no unauthorized errors (internal-frontend bypass working) | |
