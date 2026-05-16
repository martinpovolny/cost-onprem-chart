# Dev/CRC Resource Reduction

Recommendations for reducing memory consumption and pod count on a local CRC
(CodeReady Containers) dev environment. The baseline is an amd64 CRC node with
`values-crc.yaml` applied (requests already at 25m/64Mi), but production-scale
limits still in effect.

**Baseline (amd64 with ROS enabled):** ~20 pods, ~16 Gi aggregate memory limits.

---

## Summary table

| # | Recommendation | Pods saved | Memory limits saved | Effort |
|---|---------------|-----------|---------------------|--------|
| 1 | Disable ROS + Kruize | 5 | ~4.5 Gi | Values flag |
| 2 | Consolidate Celery workers | 3–4 | ~5 Gi | Values only |
| 3 | Reduce Gunicorn workers to 1 | 0 | ~800 Mi | Values env var |
| 4 | Reduce INITIAL_INGEST_NUM_MONTHS | 0 | 0 (time/CPU) | Values env var |
| 5 | Disable UI stack | 2 | ~256 Mi | Values flag |
| 6 | Disable monitoring | 0 | 0 | Values flag |
| 7 | ~~Wire up the unused `concurrency` field~~ — field removed | 0 | 0 | Done |
| 8 | Reduce PostgreSQL storage | 0 | 0 (disk: −20 Gi) | Values + reinstall |

Applying 1–6 together: **~10 pods**, **~7 Gi aggregate limits**.

---

## 1. Disable ROS + Kruize when not testing ROS

Already applied on arm64 via `values-crc-arm64.yaml`. The same flag works on amd64.

```yaml
# values-crc-dev.yaml
ros:
  enabled: false
```

**Saves:** ros-api, ros-processor, ros-recommendation-poller, ros-housekeeper, kruize
= **5 pods**, **~4.5 Gi** limits. Kruize JVM alone needs 2 Gi — reducing its limit
below that causes liveness probe failure at ~t+80s, so it cannot be trimmed without
patching Kruize's JVM flags.

**Pro:** Single largest win available; one values flag, no code changes.
**Con:** Cannot test the ROS recommendation flow or Kruize integration.

---

## 2. Consolidate Celery workers — 5 pods → 1–2

### Background

The chart runs five separate Celery worker deployments:

| Deployment | Queue | Replicas | Memory limit |
|-----------|-------|---------|-------------|
| `celery-worker-default` | `celery` | 1 | 400 Mi |
| `celery-worker-priority` | `priority` | 1 | 2 Gi |
| `celery-worker-ocp` | `ocp` | 1 | 512 Mi |
| `celery-worker-summary` | `summary` | 1 | 2 Gi |
| `celery-worker-cost-model` | `cost_model` | 1 | 512 Mi |

Each worker runs with **concurrency = 1**. This is hardcoded in
`koku/koku/settings.py` (`CELERY_WORKER_CONCURRENCY = 1`). The `concurrency: 5`
field in `values.yaml` is **not wired into the deployment template** and is silently
ignored (see recommendation 7 for the fix).

`common/queues.py` defines XL and PENALTY_BOX queue variants per queue class
(e.g. `priority_xl`, `priority_penalty`), but `get_customer_queue()` only routes
tasks there for large or penalized customers. A dev environment with a handful of
providers sends all tasks to the DEFAULT queue names only. A single worker listening
to all default queues is functionally equivalent to five workers at concurrency=1,
minus priority enforcement between queue classes.

### Steps

**Option A — consolidate all queues into the `default` worker (fewest pods):**

Add to `values-crc-dev.yaml`:

```yaml
costManagement:
  celery:
    workers:
      default:
        queue: celery,priority,ocp,summary,cost_model
        resources:
          requests:
            cpu: 25m
            memory: 64Mi
          limits:
            cpu: 500m
            memory: 2Gi      # summary tasks can spike; give headroom
      priority:
        replicas: 0
      ocp:
        replicas: 0
      summary:
        replicas: 0
      costModel:
        replicas: 0
```

Apply the upgrade:

```bash
helm upgrade cost-onprem ./cost-onprem -n cost-onprem \
  -f cost-onprem/values.yaml \
  -f cost-onprem/values-crc.yaml \
  -f cost-onprem/values-crc-dev.yaml \
  --wait
```

Verify the surviving worker and its queue subscriptions:

```bash
# One cost-worker pod should remain
kubectl get pods -n cost-onprem -l app.kubernetes.io/component=cost-worker

# Check which queues it is consuming
kubectl exec -n cost-onprem deploy/cost-onprem-celery-worker-default -- \
  sh -c 'cd $APP_HOME && PYTHONPATH=$APP_HOME celery -A koku inspect active_queues'
```

**Option B — two workers (fast + heavy) for better isolation:**

Keep a small worker for fast tasks and one combined worker for memory-heavy queues.
This prevents a slow summary task from blocking source status checks and cost-model
updates:

```yaml
costManagement:
  celery:
    workers:
      default:
        queue: celery,cost_model
        resources:
          requests:
            cpu: 25m
            memory: 64Mi
          limits:
            cpu: 200m
            memory: 400Mi
      priority:
        queue: priority,ocp,summary
        replicas: 1
        resources:
          requests:
            cpu: 25m
            memory: 64Mi
          limits:
            cpu: 500m
            memory: 2Gi
      ocp:
        replicas: 0
      summary:
        replicas: 0
      costModel:
        replicas: 0
```

This still saves 3 pods and ~2.5 Gi of limits while keeping `celery` and `cost_model`
tasks isolated from the heavier `summary` and `ocp` processing.

### Trade-offs

| | Pro | Con |
|-|-----|-----|
| Option A (1 worker) | Saves 4 pods, ~5 Gi limits; one log stream to watch | No priority enforcement; a stuck summary task blocks all queues at concurrency=1 |
| Option B (2 workers) | Summary failures don't starve the fast queues | Saves 3 pods, ~2.5 Gi instead of 4/~5 Gi |
| Both options | Pure values override, no code changes needed | XL/PENALTY_BOX queue variants are unserved — acceptable since dev has no large/penalized customers |

### Reverting

```bash
helm upgrade cost-onprem ./cost-onprem -n cost-onprem \
  -f cost-onprem/values.yaml \
  -f cost-onprem/values-crc.yaml \
  --wait
```

---

## 3. Reduce Gunicorn workers to 1

`values.yaml` sets `GUNICORN_WORKERS: "2"` for the API pod. Each Gunicorn worker is
a separate OS process with a full Django ORM image in memory (~150–300 Mi RSS). With
`GUNICORN_THREADS: "4"` a single worker still handles four concurrent HTTP requests —
plenty for solo dev use.

MASU has no explicit `GUNICORN_WORKERS` override, so it falls back to
`gunicorn_conf.py`: `workers = (POD_CPU_LIMIT * 2 + 1)` = 2 workers at 500m CPU limit.

```yaml
# values-crc-dev.yaml
costManagement:
  api:
    env:
      GUNICORN_WORKERS: "1"
  masu:
    env:
      GUNICORN_WORKERS: "1"
```

**Saves:** ~400–600 Mi aggregate (one fewer process per service).
**Pro:** Pure env var override, no code changes, trivially reversible.
**Con:** Lower request concurrency. Not suitable for running automated load tests
against the local cluster.

---

## 4. Reduce INITIAL_INGEST_NUM_MONTHS

`values.yaml` sets `INITIAL_INGEST_NUM_MONTHS: "2"`. On first provider creation,
MASU fetches and processes this many months of historical data, generating a burst of
Celery tasks and DB writes.

```yaml
# values-crc-dev.yaml
costManagement:
  masu:
    env:
      INITIAL_INGEST_NUM_MONTHS: "1"
```

**Saves:** No pod or memory savings, but halves the initial ingest CPU/DB time and
Kafka message volume. The cluster reaches a stable state faster after a provider is added.

**Pro:** Straightforward env var, reversible.
**Con:** Tests asserting multi-month aggregation will have only one month of data.
`RETAIN_NUM_MONTHS` (set to 3) can stay; it only affects the vacuum sweep, not ingest.

---

## 5. Disable the UI stack

Two pods serve the frontend: the React app container and the oauth-proxy sidecar.
Resource requests are small (50m/64Mi each) but they occupy scheduler slots.

Check whether the chart exposes a toggle:

```bash
grep -r "ui.enabled\|ui\.enabled" cost-onprem/templates/
```

If a flag exists, add to `values-crc-dev.yaml`:

```yaml
ui:
  enabled: false
```

Otherwise set `replicas: 0` on both the UI deployment and the oauth-proxy deployment
via whichever values path the chart exposes.

**Saves:** 2 pods, ~256 Mi limits.
**Pro:** Zero impact on API or CLI workflows.
**Con:** Cannot use the browser UI; API and `oc exec` workflows still work.

---

## 6. Disable monitoring components

`values.yaml` enables `ServiceMonitor` and related Prometheus objects by default.
On a CRC node without a running Prometheus stack, these objects are inert but generate
API server chatter from the operator controller.

```yaml
# values-crc-dev.yaml
monitoring:
  enabled: false
```

**Saves:** No pods, but reduces OpenShift API server background load.
**Pro:** Zero functional impact for dev work.
**Con:** Lose metrics if Prometheus is available on the CRC node.

---

## 7. ~~Wire up the unused `concurrency` field~~ — removed

The `concurrency: 5` field that appeared in every worker block in `values.yaml` was
never read by any deployment template and has been deleted. The effective worker
concurrency is controlled by Django's `CELERY_WORKER_CONCURRENCY = 1` in
`koku/settings.py`. To make it a tunable in the future, add
`CELERY_WORKER_CONCURRENCY` as an env var in each worker deployment template and
introduce a `concurrency` values field backed by a sane default.

---

## 8. Reduce PostgreSQL storage

### Background

`values.yaml` allocates a 30 Gi PVC for the unified PostgreSQL StatefulSet:

```yaml
database:
  server:
    storage:
      size: 30Gi
```

This value flows directly into the StatefulSet's `volumeClaimTemplates` in
`templates/infrastructure/database/database.yaml`:

```yaml
resources:
  requests:
    storage: {{ .Values.database.server.storage.size }}
```

A dev environment with a few providers and one or two months of data uses well under
5 Gi. On CRC, disk comes from the sparse VM image and ODF/Ceph thin-provisioning —
over-provisioning consumes capacity that other workloads may need.

**PVC resize caveat:** Kubernetes allows PVC expansion (if the storage class supports
it) but not shrinking. To reduce an existing PVC you must uninstall the release,
delete the PVC, and reinstall with the smaller size.

### Steps — fresh install

Add to `values-crc-dev.yaml`:

```yaml
database:
  server:
    storage:
      size: "10Gi"
```

Then deploy normally:

```bash
./scripts/deploy-test-cost-onprem.sh --namespace cost-onprem --verbose
# or with the overlay if the script supports extra helm args:
helm install cost-onprem ./cost-onprem -n cost-onprem \
  -f cost-onprem/values.yaml \
  -f cost-onprem/values-crc.yaml \
  -f cost-onprem/values-crc-dev.yaml \
  --wait
```

Verify:

```bash
kubectl get pvc -n cost-onprem
# Expected: postgres-storage-cost-onprem-database-0   Bound   10Gi
```

### Steps — existing deployment (already at 30 Gi)

The PVC cannot be shrunk in place. Back up any data you need to keep, then:

```bash
# 1. Uninstall the chart (removes the StatefulSet; the PVC is left behind by default)
helm uninstall cost-onprem -n cost-onprem

# 2. Confirm the PVC name
kubectl get pvc -n cost-onprem

# 3. Delete the PVC — all database data is lost
kubectl delete pvc postgres-storage-cost-onprem-database-0 -n cost-onprem

# 4. Reinstall with the smaller size
helm install cost-onprem ./cost-onprem -n cost-onprem \
  -f cost-onprem/values.yaml \
  -f cost-onprem/values-crc.yaml \
  -f cost-onprem/values-crc-dev.yaml \
  --wait

# 5. Verify
kubectl get pvc -n cost-onprem
```

If RHBK (Keycloak) was also deployed by the install script, pass `--skip-rhbk` to
avoid recreating the realm and losing client configuration:

```bash
./scripts/deploy-test-cost-onprem.sh --namespace cost-onprem --skip-rhbk --verbose
```

**Saves:** 20 Gi of block storage per deployment. No pod or memory savings.

**Pro:** Meaningful on CRC where ODF thin-provisioning is limited. A reinstall is
already a common dev workflow.
**Con:** Requires a PVC delete (data loss) to take effect on an existing deployment.

### Valkey storage

`values.yaml` also allocates a 5 Gi PVC for Valkey persistence. Losing Valkey state
on restart is acceptable in dev (pending Celery tasks are lost, but no data corruption
occurs). Reduce or keep the same reinstall procedure:

```yaml
# values-crc-dev.yaml
valkey:
  persistence:
    size: "1Gi"
```

Same delete-and-reinstall caveat applies to the Valkey PVC.

---

## Recommended minimal dev overlay

Create `cost-onprem/values-crc-dev.yaml` and layer it last in every Helm command:

```yaml
# values-crc-dev.yaml — layer after values-crc.yaml
# helm upgrade ... -f values-crc.yaml -f values-crc-dev.yaml

ros:
  enabled: false         # saves 5 pods + ~4.5 Gi limits

costManagement:
  api:
    env:
      GUNICORN_WORKERS: "1"

  masu:
    env:
      GUNICORN_WORKERS: "1"
      INITIAL_INGEST_NUM_MONTHS: "1"

  celery:
    workers:
      default:
        queue: celery,priority,ocp,summary,cost_model
        resources:
          requests:
            cpu: 25m
            memory: 64Mi
          limits:
            cpu: 500m
            memory: 2Gi
      priority:
        replicas: 0
      ocp:
        replicas: 0
      summary:
        replicas: 0
      costModel:
        replicas: 0

database:
  server:
    storage:
      size: "10Gi"       # requires PVC delete + reinstall if already at 30Gi

valkey:
  persistence:
    size: "1Gi"          # requires PVC delete + reinstall if already at 5Gi

monitoring:
  enabled: false
```

**Result after applying all recommendations:**

| | Before | After |
|-|--------|-------|
| Pods (cost-onprem ns) | ~18 | ~9 |
| Memory limits (aggregate) | ~16 Gi | ~7 Gi |
| Disk (PVCs) | 35 Gi | 11 Gi |
| Celery workers | 5 | 1 |
