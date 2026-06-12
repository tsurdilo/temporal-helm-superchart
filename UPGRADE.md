# Upgrading Temporal Server

## Why upgrades require manual steps

The upstream Temporal Helm chart does not handle schema migrations. When you run `helm upgrade` with a new server version it simply rolls out pods with the new binary — if the database schema is behind what that binary expects, the pods will refuse to start with:

```
sql schema version compatibility check failed: version mismatch for keyspace/database: "temporal"
```

Schema migrations are always the operator's responsibility. The correct upgrade order is:

1. **Migrate the schema first** (against both `temporal` and `temporal_visibility` databases)
2. **Then upgrade the binary** (`helm upgrade`)

Never reverse this order.

---

This runbook covers upgrading the Temporal Server version in this Helm chart. The chart runs three isolated PostgreSQL instances — one per database — so every upgrade involves schema migrations before touching the binary: `temporal` (main), `temporal_visibility` (primary visibility), and `temporal_visibility_secondary` (secondary visibility, only when `dualVisibility.enabled: true`).

> **Schema must be updated before any new server binary starts.** A server instance that finds its schema behind what the binary expects will refuse to start. Complete all schema migration steps fully before upgrading the binary.

---

## Quick Reference

| Step | Action |
|------|--------|
| 1 | Update `temporal` (main) DB schema |
| 2 | Update `temporal_visibility` (primary visibility) DB schema |
| 3 | Update `temporal_visibility_secondary` (secondary visibility) DB schema — only if `dualVisibility.enabled: true` |
| 4 | Update the chart — binary rolls via Kubernetes rolling update |
| 5 | Verify |

---

## What Needs to Change

This chart has two version pins that must be updated together:

| File | Field | Example |
|------|-------|---------|
| `Chart.yaml` | `temporal` dependency version | `1.2.0` → `1.3.0` |
| `values.yaml` | `temporal.server.image.tag` | `latest` (rebuild custom image) |
| `templates/temporal-namespace-init.yaml` | admintools image tag | `1.31.0` → `1.32.0` |

The custom server image (`temporal-custom-server`) is built against a local Temporal server checkout. Upgrading also means updating the server source checkout and rebuilding.

---

## Steps 1–3 — Run Schema Migrations

Schema migrations run from within the `admintools` pod, which ships `temporal-sql-tool`.

```bash
RELEASE=temporal-stack
NS=temporal

# Verify all PostgreSQL instances are reachable
kubectl exec -n "$NS" "${RELEASE}-postgresql-main-0" -- pg_isready -U temporal -q
kubectl exec -n "$NS" "${RELEASE}-postgresql-visibility-0" -- pg_isready -U temporal -q

# Get a shell in admintools
kubectl exec -it -n "$NS" deployment/${RELEASE}-admintools -- /bin/bash
```

Inside the admintools pod, run schema upgrades for each database. The `--schema-dir` paths point to the schemas embedded in the admintools image at the target version.

**Step 1 — Main DB (`temporal-stack-postgresql-main`):**
```bash
temporal-sql-tool \
  --ep temporal-stack-postgresql-main \
  --port 5432 \
  --plugin postgres12 \
  --user temporal \
  --password temporal \
  --db temporal \
  update-schema \
  --schema-dir /etc/temporal/schema/postgresql/v12/temporal/versioned
```

**Step 2 — Primary visibility DB (`temporal-stack-postgresql-visibility`):**
```bash
temporal-sql-tool \
  --ep temporal-stack-postgresql-visibility \
  --port 5432 \
  --plugin postgres12 \
  --user temporal \
  --password temporal \
  --db temporal_visibility \
  update-schema \
  --schema-dir /etc/temporal/schema/postgresql/v12/visibility/versioned
```

**Step 3 — Secondary visibility DB (`temporal-stack-postgresql-visibility-secondary`) — only if `dualVisibility.enabled: true`:**
```bash
temporal-sql-tool \
  --ep temporal-stack-postgresql-visibility-secondary \
  --port 5432 \
  --plugin postgres12 \
  --user temporal \
  --password temporal \
  --db temporal_visibility_secondary \
  update-schema \
  --schema-dir /etc/temporal/schema/postgresql/v12/visibility/versioned
```

**Verify schema versions (still in admintools):**
```bash
# Main DB
PGPASSWORD=temporal psql -h temporal-stack-postgresql-main -U temporal -d temporal \
  -c "SELECT curr_version FROM schema_version;"

# Primary visibility DB
PGPASSWORD=temporal psql -h temporal-stack-postgresql-visibility -U temporal -d temporal_visibility \
  -c "SELECT curr_version FROM schema_version;"

# Secondary visibility DB (only if dualVisibility.enabled: true)
PGPASSWORD=temporal psql -h temporal-stack-postgresql-visibility-secondary -U temporal -d temporal_visibility_secondary \
  -c "SELECT curr_version FROM schema_version;"
```

All queries should return the version expected by the target Temporal release. Exit the pod when done.

---

## Step 4 — Update the Chart and Rebuild the Custom Image

### 4a. Update the Temporal server source checkout

```bash
cd ~/devel/temporal/temporal
git fetch --tags
git checkout v<target-version>
```

### 4b. Rebuild the custom server image

From the `~/devel` directory (the build context):

```bash
cd ~/devel/temporal-helm-superchart
bash build.sh
```

### 4c. Update the chart version pins

In `Chart.yaml`, bump the temporal dependency version:
```yaml
dependencies:
  - name: temporal
    version: "<new-chart-version>"
    repository: "https://go.temporal.io/helm-charts"
```

In `templates/temporal-namespace-init.yaml`, update the admintools image tag:
```yaml
image: temporalio/admin-tools:<new-version>
```

Run `helm dependency update` to pull the new chart:
```bash
helm dependency update .
```

### 4d. Set the rolling update drain window

Before applying the new chart, set two dynamic config values to give history shards a clean handoff window during the rolling update:

```bash
DRAIN_PATCH=$(kubectl get configmap temporal-dynconfig -n temporal \
  -o jsonpath='{.data.config\.yaml}')$'\n'"history.shutdownDrainDuration:"$'\n'"  - value: 10s"$'\n'"    constraints: {}"$'\n'"history.startupMembershipJoinDelay:"$'\n'"  - value: 10s"$'\n'"    constraints: {}"
kubectl patch configmap temporal-dynconfig -n temporal --type=merge \
  -p "{\"data\":{\"config.yaml\":$(echo "$DRAIN_PATCH" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')}}"
```

> **Note:** Use `kubectl patch` not `kubectl apply` here — the dynconfig ConfigMap is owned by Helm and `kubectl apply` will set a conflicting field manager that causes the next `helm upgrade` to fail.

### 4e. Apply the chart upgrade

> **Auth during the rolling update:** JWT enforcement stays active throughout the rolling upgrade — the custom authorizer is part of `temporal-custom-server` and carries over to the new binary. Existing tokens issued by Dex remain valid (Dex is not restarted). Workers and CLI connections using valid JWTs will continue to work during the pod turnover. Workers without JWTs will continue to be rejected exactly as before.

```bash
helm upgrade temporal-stack . --namespace temporal --reuse-values
```

Watch the rolling update:
```bash
kubectl rollout status deployment/temporal-stack-frontend -n temporal
kubectl rollout status deployment/temporal-stack-history -n temporal
kubectl rollout status deployment/temporal-stack-matching -n temporal
kubectl rollout status deployment/temporal-stack-worker -n temporal
```

---

## Step 5 — Verify

**Check all pods are running:**
```bash
kubectl get pods -n temporal
```

**Check server version:**
```bash
# Use internal-frontend (port 7236) — bypasses JWT enforcement so no token needed
kubectl exec -n temporal deployment/temporal-stack-admintools -- \
  temporal --address temporal-stack-internal-frontend:7236 operator cluster describe
```

**Check for startup errors:**
```bash
kubectl logs -n temporal deployment/temporal-stack-frontend --tail=50 | grep -i "error\|schema\|version"
```

A schema mismatch at startup looks like:
```
sql schema version compatibility check failed: version mismatch for keyspace/database: "temporal"
Expected version: X.X cannot be greater than Actual version: Y.Y
```
If you see this, the schema migration did not fully apply. Re-run Steps 1–3 (Step 3 only if `dualVisibility.enabled: true`).

**Reset drain window config:**

Once all pods are healthy, remove the drain config values added in Step 3d:
```bash
kubectl get configmap temporal-dynconfig -n temporal -o json \
  | python3 -c "
import sys, json, re
cm = json.load(sys.stdin)
yaml = cm['data'].get('config.yaml', '')
yaml = re.sub(r'history\.shutdownDrainDuration:.*?constraints: \{\}\n', '', yaml, flags=re.DOTALL)
yaml = re.sub(r'history\.startupMembershipJoinDelay:.*?constraints: \{\}\n', '', yaml, flags=re.DOTALL)
cm['data']['config.yaml'] = yaml
print(json.dumps(cm))
" | kubectl apply -f - >/dev/null
```

---

## Upgrade Path

Upgrade one minor version at a time:

```
v1.20.x → v1.21.x → v1.22.x → ...
```

The schema tool applies all intermediate schema versions automatically in a single run — you do not need to run it once per schema version. But jumping multiple minor versions increases the risk of hitting data compatibility issues. Run this full runbook once per minor version hop.

### Schema version reference (PostgreSQL)

Use this to determine whether Steps 1 & 2 (schema migration) are required for your hop. If both schema versions are unchanged between source and target, skip Steps 1 & 2.

| Server version | main DB schema | visibility DB schema |
|---|---|---|
| v1.25.x | v1.14 | v1.6 |
| v1.26.x | v1.14 | v1.6 |
| v1.27.x | **v1.15** | **v1.9** |
| v1.28.x | **v1.17** | v1.9 |
| v1.29.x | **v1.18** | v1.9 |
| v1.30.x | v1.18 | **v1.13** |
| v1.31.0 | **v1.19** | **v1.14** |

Every minor version from v1.27 onward bumps at least one schema. **Always run Steps 1 & 2 when upgrading between any of these versions.**

**Example — v1.30 → v1.31:** main bumps v1.18 → v1.19, visibility bumps v1.13 → v1.14. Both migrations required.

To check the schema for any version yourself:
```bash
git -C ~/devel/temporal/temporal show <tag>:schema/postgresql/v12/temporal/versioned/ | sort -V | tail -1
git -C ~/devel/temporal/temporal show <tag>:schema/postgresql/v12/visibility/versioned/ | sort -V | tail -1
```

---

## Worked Example: v1.30.0 → v1.31.0 (full end-to-end)

Run the full upgrade test with a single script:

```bash
bash upgrade-test.sh
```

This script handles everything in order — no manual steps needed beforehand. It adds/updates the required Helm repos, checks your kubectl context, tears down any existing install, builds both images, installs at v1.30.0, runs schema migrations, then upgrades to v1.31.0. `Chart.yaml` is always restored to v1.31.0 at the end, whether the script succeeds or fails.

**Only prerequisite:** Docker Desktop running with Kubernetes enabled and `~/devel/temporal/temporal` checked out.

What the script does:

This walks through the complete upgrade from a fresh v1.30.0 install to v1.31.0, including schema migrations. Both databases require migration for this hop:
- **main:** v1.18 → v1.19
- **visibility:** v1.13 → v1.14

**Version mapping used by the script:**

| | Server | Helm chart | admintools image |
|---|---|---|---|
| From | v1.30.0 | 1.1.1 | temporalio/admin-tools:1.30.3 |
| To | v1.31.0 | 1.2.0 | temporalio/admin-tools:1.31.0 |

**Phase A — installs at v1.30.0:**
- A1: Tears down any existing install and waits for namespace deletion
- A2: Temporarily patches `Chart.yaml` and `templates/temporal-namespace-init.yaml` to v1.30.x pins
- A3: Builds the custom server image at v1.30.0 via `build.sh`
- A4: Runs `install.sh` for a fresh install
- A5: Verifies the cluster is running at v1.30.0
- A6: Confirms schema is at main=1.18, visibility=1.13

**Phase B — upgrades to v1.31.0:**
- B1: Spins up a temporary `temporalio/admin-tools:1.31.0` pod and runs schema migrations against all active databases: `temporal` (main v1.18→v1.19), `temporal_visibility` (v1.13→v1.14), and `temporal_visibility_secondary` (v1.13→v1.14, only if `dualVisibility.enabled: true`). Pod is deleted automatically when done.
- B2: Verifies schema is now main=1.19, visibility=1.14 (and visibility-secondary=1.14 if dual vis enabled)
- B3: Builds the custom server image at v1.31.0
- B4: Restores `Chart.yaml` and namespace-init to v1.31.0 pins
- B5: Sets the drain window in dynconfig
- B6: Runs `helm upgrade` and waits for all deployments to roll out
- B7: Verifies the cluster is running at v1.31.0
- B8: Removes the drain window keys from the dynconfig ConfigMap programmatically

---

## If a Pod Fails to Start After the Binary Update

The most common cause is a schema version mismatch. Check the pod logs:

```bash
kubectl logs -n temporal <failing-pod-name> | head -50
```

If the error mentions schema version, go back to Steps 1–3 and verify each database. If the error is a PostgreSQL connection failure, check that the schema migration jobs completed successfully against the correct PostgreSQL instance (`postgresql-main`, `postgresql-visibility`, or `postgresql-visibility-secondary`) — the server jobs may have started before migrations finished.

To force a clean restart after fixing the schema:
```bash
kubectl rollout restart deployment/temporal-stack-history -n temporal
kubectl rollout restart deployment/temporal-stack-matching -n temporal
kubectl rollout restart deployment/temporal-stack-frontend -n temporal
kubectl rollout restart deployment/temporal-stack-worker -n temporal
```
