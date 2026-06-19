# Metrics and Dashboards — SaaS vs On-Prem Gap Analysis

## Purpose

Compare the Prometheus metrics, Grafana dashboards, alerting rules, and
ServiceMonitor coverage between the SaaS deployment (app-interface/hccm)
and the on-prem Helm chart. Identify what can be reused, what needs
adaptation, and what is missing entirely.

---

## ServiceMonitor Comparison

### SaaS (app-interface, 5 ServiceMonitors, 15s interval)

| ServiceMonitor | Target Service | Port | Path | Notes |
|---------------|---------------|------|------|-------|
| koku | koku | metrics | /metrics | Application metrics |
| postgresql-exporter | postgresql-exporter | 9187 | /metrics | Dedicated PG exporter sidecar |
| rdsexporter | rdsexporter | 9042, 9041 | /enhanced, /basic | AWS RDS-specific |
| redis-exporter | redis-exporter | 9121 | /metrics | Dedicated Redis exporter sidecar |
| trino | trino | metrics | /metrics | Query engine (not in on-prem) |

### On-Prem (chart, 7 ServiceMonitors, 30s interval)

| ServiceMonitor | Target Service | Port | Path | Notes |
|---------------|---------------|------|------|-------|
| koku-api | cost-management API | 8000 | /metrics | Django Prometheus metrics |
| ros-api | ROS API | 9000 | /metrics | Python Prometheus client |
| ros-processor | ROS Processor | 9000 | /metrics | Python multiprocess |
| ros-recommendation-poller | ROS Poller | 9000 | /metrics | Python multiprocess |
| kruize | Kruize | 8080 | /q/metrics | Quarkus/MicroProfile |
| gateway | Envoy | 9901 | /stats/prometheus | Proxy stats |
| rbac-api | RBAC API | 8080 | /metrics | Python Prometheus client |

### Gap Analysis

| What | SaaS | On-Prem | Gap |
|------|------|---------|-----|
| PostgreSQL metrics | Dedicated `postgresql-exporter` sidecar (pg_stat_*, pg_locks_*) | None — only `pg_isready` health probe | **No DB metrics at all** |
| Redis/Valkey metrics | Dedicated `redis-exporter` sidecar (redis_*) | None — only `valkey-cli ping` health probe | **No cache metrics at all** |
| RDS metrics | `rdsexporter` (enhanced + basic) | N/A (no RDS on-prem) | Not applicable |
| Trino metrics | `trino` ServiceMonitor | N/A (no Trino on-prem) | Not applicable |
| MASU (data processor) | Scraped via koku ServiceMonitor (shared) | No ServiceMonitor — has /metrics on :9000 but not scraped | **Metrics exist but not collected** |
| Listener | Scraped via koku ServiceMonitor (shared) | No ServiceMonitor — has /metrics on :9000 but not scraped | **Metrics exist but not collected** |
| Celery workers | Metrics via PROMETHEUS_MULTIPROC_DIR, scraped by koku SM | No ServiceMonitor, no metrics port exposed | **Metrics exist in /tmp but unreachable** |
| Ingress | N/A (SaaS uses different ingress) | Has metrics port 9090, but NO ServiceMonitor | **Port configured, not scraped** |
| Scrape interval | 15s | 30s | Different baseline — on-prem may miss short spikes |

**Key finding:** On-prem is missing metrics for PostgreSQL, Valkey, MASU,
Listener, Celery workers, and Ingress. Of these, PostgreSQL and Valkey are
the most impactful — the SaaS dashboards depend heavily on `pg_stat_*` and
`redis_*` metrics that simply don't exist on-prem.

---

## Custom Application Metrics (koku)

These are defined in `koku/masu/prometheus_stats.py` and exported via the
`/metrics` endpoint on port 9000. They are available on-prem wherever a
ServiceMonitor scrapes that port.

### Counters

| Metric | Labels | Description |
|--------|--------|-------------|
| `get_report_files_attempts_count` | provider_type | Ingest attempts |
| `report_file_download_error_count` | provider_type | Download errors |
| `process_report_attempts_count` | provider_type | Processing attempts |
| `process_report_error_count` | provider_type | Processing errors |
| `report_summary_attempts_count` | provider_type | Summary attempts |
| `charge_update_attempts_count` | — | Derived cost updates |
| `cost_summary_attempts_count` | — | Cost summary updates |
| `kafka_connection_errors` | — | Kafka connection failures |
| `celery_errors` | — | Celery task errors |
| `sources_kafka_retry_errors` | — | Sources Kafka retries |
| `sources_provider_op_retry_errors` | — | Sources provider op retries |
| `sources_http_client_errors` | — | Sources HTTP client errors |
| `rhel_els_vcpu_hours` | provider_type | RHEL ELS vCPU hours |
| `rhel_els_system_count` | provider_type | RHEL ELS systems |

### Gauges (Celery queue backlogs)

22 queue-depth gauges, one per Celery queue. These are the backbone of the
SaaS alerting rules (recording rules aggregate them as `koku:celery:*_queue`).

| Metric | Queue |
|--------|-------|
| `download_backlog` | download |
| `download_xl_backlog` | download_xl |
| `download_penalty_backlog` | download_penalty |
| `summary_backlog` | summary |
| `summary_xl_backlog` | summary_xl |
| `summary_penalty_backlog` | summary_penalty |
| `priority_backlog` | priority |
| `priority_xl_backlog` | priority_xl |
| `priority_penalty_backlog` | priority_penalty |
| `refresh_backlog` | refresh |
| `refresh_xl_backlog` | refresh_xl |
| `refresh_penalty_backlog` | refresh_penalty |
| `cost_model_backlog` | cost_model |
| `cost_model_xl_backlog` | cost_model_xl |
| `cost_model_penalty_backlog` | cost_model_penalty |
| `default_backlog` | default |
| `ocp_backlog` | OCP |
| `ocp_xl_backlog` | OCP_xl |
| `ocp_penalty_backlog` | OCP_penalty |
| `hcs_backlog` | HCS |
| `subs_extraction_backlog` | subs_extraction |
| `subs_transmission_backlog` | subs_transmission |

**On-prem status:** These metrics are emitted by koku but only scraped if
the exporting pod has a ServiceMonitor. Currently only the API pod's metrics
are scraped. The queue gauges are emitted from worker pods (via
`PROMETHEUS_MULTIPROC_DIR`) which have no ServiceMonitor — so **queue depth
metrics are likely not collected on-prem**.

### Histograms

| Metric | Labels | Description |
|--------|--------|-------------|
| `rtu_populate_duration_seconds` | provider_type | Time to populate rates_to_usage rows |
| `rtu_aggregate_duration_seconds` | provider_type | Time to aggregate daily summary |
| `rtu_markup_duration_seconds` | provider_type | Time to populate markup rows |

### Django Prometheus Middleware Metrics

Automatically instrumented by `django_prometheus`:
- `django_http_responses_total_by_status_total` (status)
- `django_http_requests_total_by_view_transport_method_total` (view, method)
- `django_http_requests_latency_seconds_by_view_method` (view, method)

**On-prem status:** Available via the Koku API ServiceMonitor.

### Business Metrics (HCCM custom)

Used in the main HCCM dashboard for source/customer health:
- `hccm_count_active_providers` (account_id, source_type)
- `hccm_count_filtered_accounts`
- `hccm_count_filtered_users`
- `hccm_count_providers_by_setup_state_and_filtered_account` (setup_complete)
- `hccm_count_invalid_sources` (account_id, source_type)
- `hccm_count_stale_providers` (account_id, source_type)
- `hccm_count_incomplete_manifests`

**On-prem status:** These are emitted by koku. Available if scraped.

---

## Grafana Dashboards

### SaaS Dashboards (4 in koku repo + 2 referenced)

#### 1. Cost Management — HCCM (main)
**UID:** R0HueuFGk | **Panels:** 35+

| Section | Panels | Key Metrics Used | On-Prem Feasible? |
|---------|--------|-----------------|-------------------|
| HTTP Requests | Requests/min by status, errors, by view, latency | `django_http_*` | Yes — scraped via API ServiceMonitor |
| Celery Queues | 22 queue timeseries + gauges | `koku:celery:*_queue` (recording rules) | **No** — queue gauges not scraped (worker pods) |
| Sources Health | Active/configured/invalid/stale sources by type/account | `hccm_count_*` | Yes — if scraped |
| Customer Stats | Active customers, users, accounts | `hccm_count_filtered_*` | Yes — if scraped |
| PostgreSQL | Tenant schema size | `postgresql_schema_size_bytes` | **No** — requires postgresql-exporter |
| RDS | CPU, memory, IOPs, disk usage | `rdsosmetrics_*` | N/A — no RDS on-prem |

#### 2. Cost Management — PostgreSQL
**UID:** Qt5PC09Wk | **Panels:** 6

| Panel | Key Metrics | On-Prem Feasible? |
|-------|------------|-------------------|
| Row Activity | `pg_stat_database_tup_*` (deleted, fetched, inserted, updated, returned) | **No** — requires postgresql-exporter |
| Max Tx Duration | `pg_stat_activity_max_tx_duration` | **No** |
| Background Writer | `pg_stat_bgwriter_*` | **No** |
| Lock Activity | `pg_locks_count` by mode | **No** |
| DB Conflicts | `pg_stat_database_conflicts_*` | **No** |
| Block Activity | `pg_stat_database_blks_*` (hit, read) | **No** |

**Verdict:** Entire dashboard is unusable on-prem without adding a
PostgreSQL exporter.

#### 3. Cost Management — Redis
**UID:** Z4R11nuWk | **Panels:** 12

| Panel | Key Metrics | On-Prem Feasible? |
|-------|------------|-------------------|
| Uptime / Clients | `redis_uptime_in_seconds`, `redis_connected_clients` | **No** — requires redis-exporter |
| Memory Usage | `redis_memory_used_bytes`, `redis_memory_max_bytes` | **No** |
| Commands/sec | `redis_commands_processed_total`, `redis_commands_total` | **No** |
| Hit/Miss Rate | `redis_keyspace_hits_total`, `redis_keyspace_misses_total` | **No** |
| Network I/O | `redis_net_input_bytes_total`, `redis_net_output_bytes_total` | **No** |
| Keys / Expiry | `redis_db_keys`, `redis_expired_keys_total`, `redis_evicted_keys_total` | **No** |

**Verdict:** Entire dashboard is unusable on-prem without adding a
Redis/Valkey exporter.

#### 4. Cost Management — Trino
**UID:** 6WhuBODGk | **Panels:** 12

Not applicable to on-prem (no Trino). Skip entirely.

#### 5. SLO Dashboard (referenced, not in repo)
- Availability: `api_3scale_gateway_api_status` — **Not available on-prem**
  (no 3scale). Would need to be replaced with `django_http_*` metrics from
  the Koku API.
- Latency: `api_3scale_gateway_api_time_bucket` — Same, needs replacement.

#### 6. Strimzi Kafka Dashboard (referenced in alerts)
**UID:** 8wCTC5Tmz — Not in koku repo. SaaS-specific.

---

## Alerting Rules — SaaS to On-Prem Mapping

### Recording Rules (20 total)

Each recording rule aggregates a queue backlog gauge into a
`koku:celery:*_queue` metric. Example:

```
record: koku:celery:download_queue
expr: max(download_backlog{namespace="hccm-prod", pod=~".+worker.+"})
```

**On-prem adaptation:** Change `namespace` label. But the underlying
`download_backlog` gauge must first be scraped — currently it is not.

### Alert Rules — Portability Assessment

| Alert | SaaS Expr | On-Prem Portable? | Adaptation Needed |
|-------|-----------|-------------------|-------------------|
| **API pod absent** | `absent(up{service="koku-clowder-api"})` | Yes | Change service label to match on-prem |
| **5xx error rate >10%** | `api_3scale_gateway_api_status{status="5xx"}` | **No** | Replace with `django_http_responses_total_by_status_total{status=~"5.."}` |
| **API latency >4s** | `api_3scale_gateway_api_time_bucket{le="4000.0"}` | **No** | Replace with `django_http_requests_latency_seconds_by_view_method` |
| **Celery errors** | `rate(celery_errors_total[5m]) > 0` | Yes | Change namespace |
| **Stale sources** | `hccm_count_stale_providers` delta | Yes | Change namespace |
| **Invalid sources** | `hccm_count_invalid_sources` delta | Yes | Change namespace |
| **Incomplete manifests** | `hccm_count_incomplete_manifests` delta | Yes | Change namespace |
| **Presto heartbeat** | `presto_heartbeatdetector_activecount` | N/A | No Presto on-prem |
| **Presto resources** | `presto_execution_querymanager_insufficientresourcesfailures` | N/A | No Presto on-prem |
| **Queue overload (x22)** | `koku:celery:*_queue > threshold` | **Blocked** | Requires queue gauges to be scraped first |
| **Pod restarts** | `kube_pod_container_status_restarts_total > 5/hr` | Yes | Change namespace |
| **Job failures** | `kube_job_status_failed` delta | Yes | Change namespace |
| **RDS free space** | `rdsosmetrics_fileSys_usedPercent` predict_linear | **No** | Replace with PV usage metrics for local PostgreSQL |
| **Kafka upload lag** | `aws_kafka_sum_offset_lag_sum > 10000` | **No** | Replace with Strimzi/AMQ Streams consumer lag metrics |
| **Kafka sources lag** | `aws_kafka_sum_offset_lag_sum > 800` | **No** | Same — Strimzi metrics |

### Summary of Alert Portability

| Category | Count | Portable | Needs Adaptation | Not Applicable |
|----------|-------|----------|-----------------|----------------|
| API health | 3 | 1 | 2 (replace 3scale metrics) | 0 |
| Data quality | 3 | 3 | 0 | 0 |
| Celery errors | 1 | 1 | 0 | 0 |
| Queue overload | 22 | 0 | 22 (need scraping fix) | 0 |
| Presto | 2 | 0 | 0 | 2 |
| Pod/Job health | 2 | 2 | 0 | 0 |
| RDS storage | 2 | 0 | 2 (replace with PV) | 0 |
| Kafka lag | 3 | 0 | 3 (replace with Strimzi) | 0 |
| **Total** | **38** | **7** | **29** | **2** |

---

## SLO Definitions

### SaaS SLOs (from app-interface)

| SLO | Target | Window | Metric | On-Prem Feasible? |
|-----|--------|--------|--------|-------------------|
| API Availability | 90% (non-5xx) | 28d | `api_3scale_gateway_api_status` | Needs replacement with `django_http_*` |
| API Latency | 90% (<4s) | 28d | `api_3scale_gateway_api_time_bucket` | Needs replacement with `django_http_*` |

### On-Prem SLO Equivalent

```promql
# Availability (adapted for on-prem)
1.00 - (
  sum(rate(django_http_responses_total_by_status_total{
    namespace="cost-onprem", status=~"5.."}[28d]))
  /
  sum(rate(django_http_responses_total_by_status_total{
    namespace="cost-onprem"}[28d]))
)

# Latency (adapted for on-prem)
sum(rate(django_http_requests_latency_seconds_by_view_method_bucket{
  namespace="cost-onprem", le="4.0"}[28d]))
/
sum(rate(django_http_requests_latency_seconds_by_view_method_count{
  namespace="cost-onprem"}[28d]))
```

---

## On-Prem Components with No Metrics at All

| Component | Type | Why No Metrics | Impact |
|-----------|------|---------------|--------|
| PostgreSQL | StatefulSet | No exporter sidecar | No DB monitoring, PG dashboard unusable |
| Valkey (Redis) | Deployment | No exporter sidecar | No cache monitoring, Redis dashboard unusable |
| Celery Workers (x10) | Deployments | No metrics port, no ServiceMonitor | Queue depth alerts blocked, no task throughput visibility |
| Celery Beat | Deployment | No metrics port | Scheduler health invisible |
| RBAC Worker | Deployment | No metrics port | Async RBAC task health invisible |
| ROS Housekeeper | Deployment | No metrics port | Maintenance job health invisible |
| Ingress | Deployment | Port 9090 configured but not scraped | Upload pipeline entry point unmonitored |
| MASU | Deployment | Has port 9000 but no ServiceMonitor | Data processor metrics lost |
| Listener | Deployment | Has port 9000 but no ServiceMonitor | Kafka consumer metrics lost |
| CronJobs (2) | CronJob | Ephemeral — Prometheus can't scrape | Only observable via logs |

---

## Recommended Work — Priority Order

### Must-do (unblocks alerting and dashboards)

1. **Add ServiceMonitors for MASU and Listener** — These already expose
   `/metrics` on :9000. Just need ServiceMonitor resources. Unblocks
   queue-depth alerting because the `*_backlog` gauges are exported from
   MASU (which runs `collect_queue_metrics`).

2. **Add postgresql-exporter sidecar** — Required for the PostgreSQL
   dashboard and DB-related alerts. The SaaS uses a dedicated exporter;
   on-prem should add one as an optional sidecar gated by a values.yaml
   flag (`database.metrics.enabled`).

3. **Add redis-exporter sidecar for Valkey** — Required for the Redis
   dashboard. Same pattern: optional sidecar with ServiceMonitor.

### Should-do (enables dashboards and SLOs)

4. **Port the HCCM main dashboard** — Strip RDS panels, replace with local
   PG metrics. Celery queue section works once MASU ServiceMonitor is added.
   Sources/customer panels work as-is.

5. **Port the PostgreSQL dashboard** — Works directly once
   postgresql-exporter is added. Only change: `kubernetes_namespace` label
   to match on-prem namespace.

6. **Port the Redis dashboard** — Works directly once redis-exporter is
   added. Change `instance` label to match on-prem pod naming.

7. **Create on-prem PrometheusRules** — Port the 7 directly-portable alerts.
   Adapt the 29 that need metric substitution. Add on-prem-specific rules
   (PV usage, pod OOMKilled). Include recording rules for queue aggregation.

8. **Define on-prem SLOs** — Replace 3scale metrics with Django metrics
   (PromQL shown above).

### Nice-to-have

9. **Expose Celery worker metrics** — Either add a metrics port to worker
   deployments or run a metrics aggregator sidecar. Enables per-worker
   monitoring beyond queue depth.

10. **Add Ingress ServiceMonitor** — Port 9090 is already configured, just
    needs a ServiceMonitor.

11. **Skip Trino dashboard** — Not applicable to on-prem.

---

## Sources

### Repositories

| Repo | Files examined |
|------|---------------|
| koku | `dashboards/*.configmap.yaml` (4 dashboards), `koku/masu/prometheus_stats.py` (custom metrics) |
| cost-onprem-chart | `cost-onprem/templates/monitoring/servicemonitor.yaml`, `cost-onprem/templates/rbac/servicemonitor.yaml`, `cost-onprem/values.yaml` |
| app-interface | `resources/insights-prod/hccm-prod/*.servicemonitor.yml` (5), `resources/insights-prod/hccm-prod/hccm.prometheusrules.yaml` (47 alerts + 20 recording rules), `resources/insights-prod/hccm-prod/hccm-msk.prometheusrules.yaml` (3 alerts), `data/services/insights/hccm/slo-documents/hccm-slo.yml` |

### SaaS Monitoring URLs

- Grafana (prod): https://grafana.app-sre.devshift.net/d/R0HueuFGk/cost-management
- Grafana (stage): https://grafana.stage.devshift.net/d/R0HueuFGk/cost-management
- SLO dashboard: https://grafana.app-sre.devshift.net/d/slo-dashboard/slo-dashboard
- Prometheus (prod): https://prometheus.crcp01ue1.devshift.net/graph
- Prometheus (stage): https://prometheus.crcs02ue1.devshift.net/graph
