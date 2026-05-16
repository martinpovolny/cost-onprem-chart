# Cost-Onprem Component Dependencies

Research conducted 2026-05-14 by examining Helm chart templates, values.yaml, and
the koku source code at `../koku`.

---

## Dependency Map

| Component | Type | PostgreSQL DB | Kafka (topics) | S3 buckets | Valkey/Redis | Internal calls | External |
|---|---|---|---|---|---|---|---|
| **cost-api** | Deploy | costonprem_koku | general connectivity | koku-bucket | broker + cache | — | gateway / Keycloak |
| **cost-processor (masu)** | Deploy | costonprem_koku | general connectivity | koku-bucket, ros-data | broker + cache | — | — |
| **listener** | Deploy | costonprem_koku | **consumes** platform.upload.announce | koku-bucket | broker + cache | — | — |
| **celery-beat** | Deploy | costonprem_koku | general connectivity | koku-bucket | broker + cache | — | — |
| **celery-worker-default** | Deploy | costonprem_koku | general connectivity | koku-bucket | broker + cache | — | — |
| **celery-worker-priority** | Deploy | costonprem_koku | general connectivity | koku-bucket | broker + cache | — | — |
| **celery-worker-ocp** | Deploy | costonprem_koku | general connectivity | koku-bucket | broker + cache | — | — |
| **celery-worker-summary** | Deploy | costonprem_koku | general connectivity | koku-bucket | broker + cache | — | — |
| **celery-worker-cost-model** | Deploy | costonprem_koku | general connectivity | koku-bucket | broker + cache | — | — |
| **ros-api** | Deploy | costonprem_ros | general connectivity | — | — | gateway | — |
| **ros-processor** | Deploy | costonprem_ros | **consumes** hccm.ros.events | — | — | Kruize :8080 | — |
| **ros-recommendation-poller** | Deploy | costonprem_ros | **consumes** rosocp.kruize.recommendations | — | — | Kruize :8080 | — |
| **housekeeper** | Deploy | costonprem_ros | **consumes** platform.sources.event-stream | — | — | Koku API :8000, Kruize :8080 | — |
| **ros-partition-cleaner** | CronJob | costonprem_ros | — | — | — | — | — |
| **kruize** | Deploy | costonprem_kruize | — | — | — | — | — |
| **kruize-partition-deleter** | CronJob | costonprem_kruize | — | — | — | — | — |
| **gateway** | Deploy | — | — | — | — | Koku API, ROS API, Ingress | **Keycloak** (JWKS) |
| **ingress** | Deploy | — | **produces** platform.upload.announce | insights-upload-perma | — | — | — |
| **ui** | Deploy | — | — | — | — | — | **Keycloak** (OIDC) |

---

## Kafka Topics

All topic names are defined in `koku/koku/kafka_utils/utils.py`.

| Topic | Producer | Consumer | Notes |
|---|---|---|---|
| `platform.upload.announce` | ingress | listener | Core upload pipeline trigger |
| `platform.upload.validation` | listener | (cloud ingress, unused on-prem) | Validation result after processing |
| `hccm.ros.events` | masu (ros_report_shipper) | ros-processor | ROS CSV S3 presigned URLs |
| `rosocp.kruize.recommendations` | kruize | ros-recommendation-poller | Kruize recommendation results |
| `platform.sources.event-stream` | koku (on source delete) | housekeeper, sources listener | Source lifecycle events |
| `platform.notifications.ingress` | koku notifications | (notifications service) | **Skipped** when `ONPREM=true` |
| `platform.rhsm-subscriptions.service-instance-ingress` | masu subs_data_messenger | (rhsm service) | **Skipped** when `ONPREM=true` |

### On-prem active topics (only these matter for this chart)
- `platform.upload.announce` — required, core pipeline
- `platform.upload.validation` — produced but consumed only by external cloud service; safe to ignore
- `hccm.ros.events` — required when `ros.enabled=true`
- `rosocp.kruize.recommendations` — required when `ros.enabled=true`
- `platform.sources.event-stream` — required for source lifecycle (add/remove providers)

---

## Kafka Client Configuration

- **Library:** `confluent_kafka` (Python)
- **Consumer pattern:** Manual commit (`enable.auto.commit=false`), poll loop
- **Producer pattern:** Singleton, async delivery with callback, `producer.poll(0)` to flush
- **Security:** SASL optional, SSL optional, PLAINTEXT supported
- **Topic auto-create:** Koku uses `AdminClientSingleton` to create topics on startup
- **Consumer groups:**
  - `hccm-group` — listener (upload.announce)
  - `hccm-sources` — sources listener (sources.event-stream)
  - `ros-processor` — ros-processor (hccm.ros.events)
  - `ros-recommendation-poller` — recommendation poller

---

## Valkey / Redis Usage

Redis is used for **three distinct purposes** across the koku codebase, not just as a Celery broker.

### 1. Celery broker and result backend
- All Celery tasks use Redis as the message queue and result store
- Components: all celery-workers, celery-beat, masu, cost-api (task dispatch)
- Config: `CELERY_BROKER_URL`, `CELERY_RESULTS_URL`

### 2. Django API response cache
- Provider view responses cached per tenant (AWS, Azure, GCP, OpenShift reports)
- Sources list, tag rate maps, infrastructure maps
- Cache invalidated by workers after processing completes
- Components: **cost-api** (reads), **celery-workers + masu** (invalidates)
- Cache key prefixes: `aws-view`, `azure-view`, `gcp-view`, `openshift-view`, `sources`, `tag-mapping`

### 3. Distributed task lock (WorkerCache)
- `masu/processor/worker_cache.py` stores per-worker task keys in Redis
- Prevents two workers from processing the same `(provider_uuid, billing_month)` concurrently
- Used in `tasks.py` around every significant processing task
- This is a **correctness guarantee**, not just a performance optimisation
- Components: all celery-workers, masu orchestrator

### Summary
All koku components (cost-api, masu, all workers) touch Redis directly, not only through
Celery. Redis cannot be removed without changes to koku source code.

---

## PostgreSQL Databases

All databases live on a single PostgreSQL server instance.

| Database | Used by | Notes |
|---|---|---|
| `costonprem_koku` | cost-api, masu, all celery-workers, listener, celery-beat | Core koku schema |
| `costonprem_ros` | ros-api, ros-processor, ros-recommendation-poller, housekeeper, ros-partition-cleaner | Only needed when `ros.enabled=true` |
| `costonprem_kruize` | kruize, kruize-partition-deleter | Only needed when `ros.enabled=true` |

Credentials managed via secret `{release}-db-credentials` with per-user keys.

---

## S3 / Object Storage

| Bucket | Used by | Content |
|---|---|---|
| `koku-bucket` | listener, masu, all celery-workers, cost-api | Processed cost reports (Parquet/CSV) |
| `ros-data` | masu (ros_report_shipper) | ROS container-level metrics for ros-processor |
| `insights-upload-perma` | ingress | Raw upload staging (tarballs from OCP operator) |

Addressing style must be **path-style** (not virtual-hosted) — required for NooBaa/Ceph/S4.
Configured via `cost-onprem-aws-config` ConfigMap (`addressing_style = path`) and
`AWS_CONFIG_FILE=/etc/aws/config` env var.

---

## External Dependencies

| Dependency | Used by | Purpose | Replaceable? |
|---|---|---|---|
| **Keycloak / RHBK** | gateway (JWKS), ui (OIDC) | JWT token issuer and validation | Yes, any OIDC provider |
| **Sources API** | sources listener, housekeeper | Source (provider) CRUD | No — koku calls it for credentials |
| **OCP Operator** | (client-side) | Sends cost reports via upload API | No — this is the data source |

---

## Simplification Opportunities

### Remove ROS entirely (`ros.enabled=false`)
Removes 7 components (ros-api, ros-processor, ros-recommendation-poller, housekeeper,
ros-partition-cleaner, kruize, kruize-partition-deleter), 2 Kafka topics, 2 PostgreSQL
databases. Already supported in the chart. Saves ~1.5–2GB RAM on the node.

### Replace Kafka with Redpanda
No code changes in koku (wire-compatible). Removes the AMQ Streams operator and
its CRDs. Replaces multi-pod Kafka cluster with a single Redpanda pod. See
`docs/kafka-to-redpanda.md` for the plan.

### Replace Keycloak with a lighter OIDC provider
gateway and ui only need: a token endpoint, a JWKS endpoint, and a client_credentials
grant. Dex or a static-key approach could replace Keycloak, eliminating the most
unstable component in the stack (35+ restarts on arm64 CRC).
