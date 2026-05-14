# cost-onprem Project Log

Chronological record of significant work sessions, decisions, and findings.

---

## 2026-05-13 — CRC deployment complete

### Goal
Deploy the cost-onprem Helm chart to a local CRC (CodeReady Containers) cluster on
Apple Silicon (arm64) for local development and test-running.

### Cluster state at end of session

**CRC:** 2.60.1 / OpenShift 4.21.8 / vfkit / Apple Silicon (arm64)
- 8 CPUs, 18 GB RAM, 100 GB disk
- Credentials: `kubeadmin / RvEjd-fwDVH-Zvwzz-IIT6E`
- API: `https://api.crc.testing:6443`
- Console: `https://console-openshift-console.apps-crc.testing`

**Namespaces**

| Namespace | Contents |
|---|---|
| `cost-onprem` | Main application stack + S4 object storage |
| `kafka` | AMQ Streams operator + KRaft Kafka cluster (3 brokers, 3 controllers) |
| `keycloak` | Community Keycloak operator + instance + PostgreSQL |
| `hostpath-provisioner` | CRC CSI storage driver |

**Pods — `cost-onprem`**

| Pod | Status | Notes |
|---|---|---|
| `cost-onprem-koku-api` | Running | Django REST API (arm64 image) |
| `cost-onprem-koku-masu` | Running | Cost data processor |
| `cost-onprem-koku-listener` | Running | Kafka consumer |
| `cost-onprem-koku-migrate` | Completed | DB migration (ran once at install) |
| `cost-onprem-celery-beat` | Running | Celery scheduler |
| `cost-onprem-celery-worker-default` | Running | |
| `cost-onprem-celery-worker-ocp` | Running | |
| `cost-onprem-celery-worker-priority` | Running | |
| `cost-onprem-celery-worker-summary` | Running | |
| `cost-onprem-celery-worker-cost-model` | Running | |
| `cost-onprem-gateway` (×2) | Running | Envoy proxy / JWT auth |
| `cost-onprem-ingress` | Running | Upload ingress (Go binary, QEMU) |
| `cost-onprem-kruize` | Running | Resource optimization (Java/JVM) |
| `cost-onprem-ui` (2 containers) | Running | React UI + oauth2-proxy |
| `cost-onprem-database` | Running | PostgreSQL StatefulSet |
| `cost-onprem-valkey` | Running | Redis-compatible cache |
| `s4-*` | Running | S3-compatible object storage (dev/test) |

**Services — `cost-onprem`**

| Service | Port | Consumer |
|---|---|---|
| `cost-onprem-database` | 5432 | koku, kruize, ros (disabled) |
| `cost-onprem-gateway` | 80, 9901 (admin) | external route |
| `cost-onprem-ingress` | 8081 | upload endpoint |
| `cost-onprem-koku-api` | 8000 | gateway |
| `cost-onprem-koku-masu` | 8000 | internal |
| `cost-onprem-kruize` | 8080 | ros-processor (disabled) |
| `cost-onprem-ui` | 8443 | external route |
| `cost-onprem-valkey` | 6379 | celery, koku |
| `s4` | 7480 (S3), 5000 (UI) | koku, ingress |

**Routes (external access)**

```
https://cost-onprem-gateway-cost-onprem.apps-crc.testing/api  → gateway → koku-api
https://cost-onprem-ui-cost-onprem.apps-crc.testing           → UI
```

**Helm releases**

| Release | Namespace | Chart | Status |
|---|---|---|---|
| `cost-onprem` | `cost-onprem` | `cost-onprem-0.2.20-rc4` | deployed |
| `s4` | `cost-onprem` | `s4-0.1.0` | deployed |

### Useful commands

```bash
eval $(crc oc-env)

# All pods
kubectl get pods -n cost-onprem
kubectl get pods -n kafka
kubectl get pods -n keycloak

# Routes
kubectl get routes -n cost-onprem

# Helm state
helm list -A

# Logs
kubectl logs -n cost-onprem -l app.kubernetes.io/component=listener --tail=50
kubectl logs -n cost-onprem -l app.kubernetes.io/component=cost-management-api --tail=50
kubectl logs -n cost-onprem -l app.kubernetes.io/component=ros-optimization --tail=50
```

### What was skipped

**ROS (Resource Optimization Service)** — disabled via `ros.enabled=false` in
`cost-onprem/values-crc.yaml`. The `ros-ocp-backend` binary is Go/amd64-only and crashes
under QEMU on Apple Silicon (`runtime: lock count too large for lfstack.push`).
All 11 ROS templates are guarded with `{{- if .Values.ros.enabled }}` and do not deploy.
This affects: ros-api, ros-processor, ros-poller, ros-housekeeper, kruize-experiments.
Kruize itself *is* running (Java, works under QEMU) but has nothing to feed it.

### Next steps

1. **Run tests** (Step 7 in `docs/plan-test-deploy-to-crc.txt`):
   ```bash
   NAMESPACE=cost-onprem ./scripts/run-pytest.sh
   ```
   Expected: ~88 tests, ~3 minutes. Extended tests require ODF/S3 and are skipped by default.

2. **Refresh ingress image tag** before 2026-05-18 (tag `f8da496` expires then):
   ```bash
   curl -s "https://quay.io/api/v1/repository/redhat-user-workloads/hcc-integrations-tenant/ingress/tag/?limit=5&onlyActiveTags=true" \
     | python3 -c "import sys,json; [print(t['name'],t.get('expiration','')) for t in json.load(sys.stdin)['tags'] if not t['name'].startswith('sha256')]"
   # Update ingress.image.tag in cost-onprem/values-crc.yaml, then reinstall.
   ```

3. **ROS on arm64** (future): build a native arm64 `ros-ocp-backend` image and push it,
   then set `ros.enabled=true` in `values-crc.yaml`.

### Key fixes discovered during this session

| Problem | Fix |
|---|---|
| Kafka PVCs (100Gi) too large for CRC | `KAFKA_BROKER_STORAGE=500Mi KAFKA_CONTROLLER_STORAGE=500Mi` |
| Kafka operator version check fails on digest-ref images | CSV name fallback in `deploy-kafka.sh` |
| RHBK has no arm64 images | `KEYCLOAK_OPERATOR=community` in `deploy-rhbk.sh` |
| Community Keycloak v26 needs `https://` in hostname fields | `KEYCLOAK_HOSTNAME_URL` / `KEYCLOAK_ADMIN_URL` prefix added |
| Default koku image is amd64, segfaults under QEMU | `quay.io/martin_povolny/koku:latest` (native arm64 build) |
| `ros-ocp-backend` crashes under QEMU | `ros.enabled=false` guard added to all 11 ROS templates |
| `install-helm-chart.sh -f` breaks with relative paths | Script does `cd "$SCRIPT_DIR"` internally; use absolute path |
| Wrong values keys for ingress/kruize/database resources | Use `.Values.resources.{application,kruize,database}` |
| Memory requests exhaust 18GB node (Keycloak+Kafka take ~15GB) | All cost-onprem requests set to 64Mi in `values-crc.yaml` |
| Ingress image tag `3a7a2cf` deleted from quay.io | Updated to `f8da496` (expires 2026-05-18) |
| Kruize JVM OOM with 512Mi limit | `resources.kruize.limits.memory: 2Gi` in `values-crc.yaml` |
