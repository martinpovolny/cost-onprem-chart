# Baseline Observability and Debuggability

**Jira:** [COST-7706](https://redhat.atlassian.net/browse/COST-7706)
**Epic:** [COST-7543](https://redhat.atlassian.net/browse/COST-7543)

## Goal

Identify areas that require baseline observability and debuggability across the
cost-onprem stack (Helm chart, koku backend, koku-metrics-operator). Produce a
gap analysis and actionable work items so that on-premise deployments can be
monitored, diagnosed, and supported without requiring deep tribal knowledge.

### Related Documents

| Document | Contents |
|----------|----------|
| [metrics-and-dashboards.md](metrics-and-dashboards.md) | Prometheus metrics, Grafana dashboards, alerting rules — full SaaS vs on-prem comparison with PromQL queries and portability assessment |
| [logging-and-error-tracking.md](logging-and-error-tracking.md) | Logging configuration, formatters, structured logging, GlitchTip/Sentry integration, Celery error handling, per-component log levels |
| [observability-review.md](observability-review.md) | Adversarial review of this document — 10 findings on gaps and blind spots |
| [plan.md](plan.md) | Implementation plan — research TODOs, 28 tickets grouped by theme, phased sequencing |
| [must-gather-howto.md](must-gather-howto.md) | Reference material for building a custom must-gather image |
| [JIRA-COST-7706.md](JIRA-COST-7706.md) | Original Jira ticket text |

### Follow-Up Tickets

| Jira | Title | Status |
|------|-------|--------|
| [COST-7692](https://redhat.atlassian.net/browse/COST-7692) | Implement monitoring and alerting (ServiceMonitors, PrometheusRules, Events) | To Do — Elkana Hendler |
| [COST-7780](https://redhat.atlassian.net/browse/COST-7780) | Investigate must-gather support for cost-management on-prem | New |
| [COST-7782](https://redhat.atlassian.net/browse/COST-7782) | Port SaaS alerting rules and Grafana dashboards to on-prem chart | New |
| [COST-7783](https://redhat.atlassian.net/browse/COST-7783) | Investigate Celery worker observability for on-prem | New |
| [COST-7784](https://redhat.atlassian.net/browse/COST-7784) | Coordinate operator observability with COST-7692 | New |

### Context

The current on-prem deployment uses Helm charts. An operator is planned that
will replace the Helm charts as the deployment mechanism. **Operator timeline
is not yet confirmed** — this affects whether Helm-specific work items
(upgrade validation, Helm hooks, preflight checks) are worth pursuing. Items
tagged with "⚑ Helm-specific" below should be skipped if the operator ships
within 6 months.

Observability work should be designed with this transition in mind:
- Features built into the **koku backend** (metrics, health endpoints, logging)
  carry over regardless of deployment method.
- Features built into the **Helm chart** (PrometheusRules, ServiceMonitors,
  must-gather, Helm hooks) will need to be re-implemented in the operator.
- The operator itself becomes a first-class component that needs its own
  observability (status conditions, events, custom metrics) — similar to
  the gaps already identified in koku-metrics-operator.

When prioritizing work, prefer investments in the application layer (koku,
ROS, RBAC) over Helm-specific tooling, since application-level
observability survives the migration to an operator.

### Priority Ranking Criteria

Work items are ranked on four axes:

1. **Support case frequency** — How often does this gap cause a customer to
   file a support case?
2. **Time to diagnose without the fix** — How many hours does it take to
   troubleshoot this manually?
3. **Blast radius** — Does this affect one component or the entire deployment?
4. **Survives operator migration** — Will this work carry over?

---

## What We Already Have

### Health Checks (chart)

Every major component already has liveness and readiness probes, though
probe quality varies. Some probes use endpoints that don't reflect actual
component health (e.g., `/metrics` returns 200 even if the component is
wedged; functional endpoints like Kruize's `/listPerformanceProfiles` can
time out under DB pressure and cause cascading restarts).

| Component | Liveness | Readiness | Endpoint | Probe Quality |
|-----------|----------|-----------|----------|---------------|
| Koku API | Yes | Yes | `/livez`, `/readyz` on :9000 | Strong |
| MASU | Yes | Yes | `/livez`, `/readyz` on :9000 | Strong |
| Listener | Yes | Yes | `/livez`, `/readyz` on :9000 | Strong |
| ROS API | Yes | Yes | `/status` on :8000 | Adequate |
| ROS Processor | Yes | Yes | `/metrics` on :9000 | Fragile — `/metrics` returns 200 even if processor is wedged on Kruize |
| ROS Rec. Poller | Yes | Yes | `/metrics` on :9000 | Fragile — same issue as ROS Processor |
| Kruize | Yes | Yes | `/listPerformanceProfiles` on :8080 | Fragile — DB-backed query can timeout under lock contention |
| RBAC API | Yes | Yes | `/api/rbac/v1/status/` | Adequate |
| Gateway (Envoy) | Yes | Yes | `/ready` on :9901 | Strong |
| Ingress | Yes | Yes | `/` on :8081 | Fragile — says nothing about upstream routability |
| PostgreSQL | Yes | Yes | `pg_isready` exec | Strong |
| Valkey | Yes | Yes | `valkey-cli ping` exec | Strong |
| UI (nginx) | Yes | Yes | `/` on :8080 | Adequate |
| UI (oauth-proxy) | Yes | Yes | `/ping` on :8443 | Adequate |

### Koku Backend Status Endpoint

`/api/cost-management/v1/status/` returns: API version, Celery worker stats
(`?celery=true`), Git commit, DB connection count, Python version, installed
modules. A lightweight `?liveness` variant returns `{"alive": true}`.

MASU exposes internal endpoints for Celery queue inspection:
- `/api/cost-management/v1/masu/running_celery_tasks/`
- `/api/cost-management/v1/masu/celery_queue_tasks/`
- `/api/cost-management/v1/masu/celery_queue_lengths/`

### Logging (koku)

> **Detail:** [logging-and-error-tracking.md](logging-and-error-tracking.md)

Koku has mature, configurable logging:
- Per-module log levels: `DJANGO_LOG_LEVEL`, `KOKU_LOG_LEVEL`,
  `GUNICORN_LOG_LEVEL`, `CELERY_LOG_LEVEL`, `UNLEASH_LOG_LEVEL`
- Structured JSON output via `log_json()` with tracing IDs
- Custom `TaskFormatter` injects Celery `task_id`, `task_name`,
  `task_root_id`, `task_parent_id` into every log line
- CloudWatch handler available (watchtower)

**Note on ROS and RBAC:** Logging was audited in depth for koku only. ROS
(Go services) and RBAC (separate Django codebase) were examined at the
Helm template level but not at the application level. Open questions: What
logging framework does ROS use? Is it structured? Does RBAC share koku's
logging config or have its own? Does either have Sentry/GlitchTip
integration? See open question #10 below.

### Prometheus Metrics (koku)

> **Detail:** [metrics-and-dashboards.md](metrics-and-dashboards.md)

- Django Prometheus middleware (`django_prometheus`) auto-instruments requests
- Custom counters: report downloads, processing errors, Kafka errors,
  sources retry errors (19 queue-depth gauges)
- `/metrics` endpoint on the probe server (:9000), multiprocess-safe

### Prometheus Metrics (chart)

- 6 ServiceMonitor resources (ROS API, ROS Processor, ROS Poller, Kruize,
  Koku API, Envoy gateway), all scraping at 30s interval
- NetworkPolicies explicitly allow `openshift-monitoring` namespace to
  reach metrics ports
- Toggle: `monitoring.enabled: true` in values.yaml

### Database Observability (koku)

- Built-in DB performance dashboard at
  `/api/cost-management/v1/masu/db-performance/`:
  lock-info, stat-activity, stat-statements, schema-sizes, explain-query
- Status endpoint queries `pg_stat_database` for connection counts

### Error Tracking — GlitchTip / Sentry (koku)

> **Detail:** [logging-and-error-tracking.md](logging-and-error-tracking.md#error-tracking--glitchtip--sentry)

Koku has built-in Sentry SDK integration (`koku/koku/sentry.py`) controlled by:
- `KOKU_ENABLE_SENTRY` — toggle (on-prem chart defaults to `"False"`)
- `KOKU_SENTRY_DSN` — endpoint URL
- `KOKU_SENTRY_ENVIRONMENT` — environment tag

In the SaaS deployment, the DSN points to a **GlitchTip** instance (an
open-source Sentry-compatible error tracker). The DSN is stored in a
GlitchTip secret (`GLITCHTIP_SECRET_NAME` / `GLITCHTIP_KEY_NAME`) and
injected into every koku component (API, MASU, listener, all Celery workers)
via `deploy/clowdapp.yaml`. Traces are sampled at 5%.

**SaaS production monitoring stack (for reference):**

> **Note:** Internal Red Hat URLs below — may require VPN/access and may
> change if infrastructure is migrated.

- **GlitchTip:** https://glitchtip.devshift.net/ (stage and prod) —
  alerts flow to a dedicated Slack channel, engineers follow Slack alerts
  into GlitchTip for exception details
- **Grafana (stage):** https://grafana.stage.devshift.net/d/R0HueuFGk/cost-management
- **Grafana (prod):** https://grafana.app-sre.devshift.net/d/R0HueuFGk/cost-management
- **Prometheus (stage):** https://prometheus.crcs02ue1.devshift.net/graph
- **Prometheus (prod):** https://prometheus.crcp01ue1.devshift.net/graph
- **Kibana (stage):** https://kibana.apps.crcs02ue1.urby.p1.openshiftapps.com/app/discover
  (last 5 days)
- **Kibana (prod):** https://kibana.apps.crcp01ue1.o9m8.p1.openshiftapps.com/app/discover
  (last 15 days)

**On-prem status:** None of the above are available. GlitchTip is disabled
(`KOKU_ENABLE_SENTRY: "False"`), no Grafana dashboards are shipped, and
there is no log aggregation guidance (Kibana/Loki/ELK).

### Error Handling (koku)

- Custom Django exception handler with structured error bodies
- Celery retry with exponential backoff, attempt tracking

### Operator (koku-metrics-operator)

- Liveness/readiness at `/healthz`, `/readyz` (:8081)
- Structured zap logging via controller-runtime
- ServiceMonitor for `/metrics` (:8080)
- Extensive CR status subresource: `AuthenticationStatus`,
  `PrometheusStatus`, `UploadStatus`, `PackagingStatus`, `ReportsStatus`,
  `SourceStatus`, `StorageStatus`
- Leader election with configurable lease timings

### Grafana Dashboards (koku SaaS — not yet ported to on-prem)

> **Detail:** [metrics-and-dashboards.md](metrics-and-dashboards.md#grafana-dashboards) — full panel-by-panel portability assessment

The [koku dashboards](https://github.com/project-koku/koku/tree/main/dashboards) directory contains 4 Grafana dashboard
ConfigMaps built for the SaaS deployment:

| Dashboard | File | Covers |
|-----------|------|--------|
| HCCM Main | `grafana-dashboard-insights-hccm.configmap.yaml` | API, Celery, processing pipeline |
| PostgreSQL | `grafana-dashboard-insights-hccm-postgresql.configmap.yaml` | DB connections, queries |
| Redis | `grafana-dashboard-insights-hccm-redis.configmap.yaml` | Cache hit rates, memory |
| Trino | `grafana-dashboard-insights-hccm-trino.configmap.yaml` | Query engine stats |

These are SaaS-oriented (reference CloudWatch, app-sre infrastructure) and
would need adaptation for on-prem (different datasource names, no Trino in
on-prem, different namespace/label selectors). But they are a valuable
starting point rather than building from scratch.

### Existing Documentation and Scripts

- [docs/operations/troubleshooting.md](https://github.com/insights-onprem/cost-onprem-chart/blob/main/docs/operations/troubleshooting.md) — OOMKilled, Kafka, namespace labels, Kruize, S3 signature errors
- [scripts/check-installation.sh](https://github.com/insights-onprem/cost-onprem-chart/blob/main/scripts/check-installation.sh) — post-install health check
- [scripts/force-operator-package-upload.sh](https://github.com/insights-onprem/cost-onprem-chart/blob/main/scripts/force-operator-package-upload.sh) — pipeline smoke test
- Manual `pg_dump` command documented in installation guide

### Resource Definitions

All major components have CPU/memory requests and limits defined in
values.yaml with a sizing guide in [docs/operations/resource-requirements.md](https://github.com/insights-onprem/cost-onprem-chart/blob/main/docs/operations/resource-requirements.md).

---

## What We Do Not Yet Understand / Open Questions

1. **Celery worker health model** — Workers are long-running processes without
   HTTP endpoints. What is the right probe strategy? Options: exec-based
   `celery inspect ping`, a sidecar with `/healthz`, or heartbeat file age
   checks. Need to evaluate latency and reliability of each.

2. **Must Gather scope** — What data should a must-gather bundle contain? At
   minimum: pod logs, describe output, CR status, Helm values, events, DB
   connection stats. But should it include PG dumps, Prometheus metric
   snapshots, or Kafka consumer-group lag? Need to define the boundary between
   "quick triage" and "full diagnostic" bundles.

3. **Alert thresholds** — We have no PrometheusRules. Before writing them we
   need to baseline normal behavior: What is a normal Celery queue depth? What
   restart rate is acceptable? What API latency is expected? These numbers
   should come from production observation, not guesswork.

4. **Operator event model** — The koku-metrics-operator uses custom status
   fields instead of standard Kubernetes Conditions and Events. Is this
   intentional (simpler for the user) or an oversight? Migrating to Conditions
   would enable standard tooling (e.g., `oc wait --for=condition=Ready`) but
   is a breaking API change.

5. **Database backup strategy for on-prem** — Only a manual `pg_dump` one-liner
   exists. On-prem customers need automated, validated backups. Should this be
   a CronJob in the chart, a separate operator, or documented as the
   customer's responsibility?

6. **Distributed tracing** — Koku has Sentry and per-task logging but no
   OpenTelemetry/correlation-ID propagation across services. Is end-to-end
   tracing a priority for on-prem, or is per-component logging sufficient?

7. **Infrastructure metrics gap** — PostgreSQL, Valkey, and Kafka have no
   exporters in the chart. Should the chart ship sidecar exporters, or assume
   the customer already monitors their infrastructure?

8. **SaaS runbooks / playbooks** — The SaaS PrometheusRules reference
   runbooks (likely in `https://gitlab.cee.redhat.com/service/app-interface/-/tree/master/docs/tenant-services/console.redhat.com/app-sops/hccm`).
   These document known failure modes and recovery procedures that have been
   validated in production. **TODO:** Review SaaS runbooks to identify
   which failure scenarios also apply to on-prem and whether our
   [docs/operations/troubleshooting.md](https://github.com/insights-onprem/cost-onprem-chart/blob/main/docs/operations/troubleshooting.md) covers them. Gaps become input for
   the on-prem debugging playbook (work item 9).

9. **Task queue scaling on-prem** — The SaaS has a known history of Celery
   task queues getting overwhelmed (drive tasks from large customers). This
   was solved in SaaS via autoscaling and separate queues for large reports.
   On-prem has no autoscaling (static replica counts, no HPA). Need to
   determine: are the queue-splitting and penalty queues already in the
   on-prem chart? If so, are they documented? What alerting thresholds
   should warn operators before queues back up?

10. **ROS and RBAC application-level audit** — Koku received deep analysis
    (logging, metrics, Sentry, DB tools). ROS (Go services) and RBAC
    (separate Django codebase) were only audited at the Helm template level.
    Unknown: ROS logging framework, custom metrics beyond defaults, error
    tracking integration, RBAC Prometheus metrics, RBAC worker failure modes.
    This should be a follow-up investigation before creating ROS/RBAC-specific
    work items.

11. **Kafka observability on-prem** — Kafka is a critical dependency: the
    listener consumes cost reports from it, sources events flow through it,
    and Kafka connectivity loss is already a documented failure mode. The SaaS
    uses Amazon MSK with managed monitoring and dedicated alerts
    (`hccm-msk.prometheusrules.yaml`). On-prem Kafka is likely Strimzi or
    AMQ Streams, with a different monitoring model. Key unknowns:
    - **Consumer lag:** Is the listener keeping up? Is sources lag growing?
      This is the single most important Kafka metric for this system.
    - **Topic health:** Are topics present and properly configured?
    - **Dead-letter topic:** When message processing fails, where do
      messages go? Are they silently dropped?
    - **Kafka exporter:** Should the chart ship one, or assume customer
      monitors Kafka separately?

12. **Operator timeline** — When is the operator expected to replace Helm
    charts? This determines whether Helm-specific work items (upgrade
    validation, Helm hooks, preflight checks) are worth pursuing.

13. **Audit logging for user actions** — On-prem deployments may serve
    multiple teams. The document covers infrastructure observability but
    ignores application-level audit logging: who accessed what cost data,
    who changed cost models, who created/deleted sources, who modified RBAC
    permissions. The SaaS handles this partially via the 3scale gateway and
    CloudWatch; on-prem has neither. For regulated industries (finance,
    healthcare, government), audit logging may be a hard compliance requirement.

---

## Identified Gaps — Work Items

### P0 — Critical for supportability

*Ranked by: high support case frequency, hours to diagnose manually, full-deployment blast radius.*

#### 1. Celery workers have no health probes
**Components affected:** 10 Celery worker deployments (default, priority,
summary, ocp, cost-model, download, refresh, hcs, subs-extraction,
subs-transmission), RBAC worker, ROS housekeeper.

Kubernetes cannot detect stuck workers. A wedged worker stays "Running" and
consumes a queue slot indefinitely.

**Mitigating factor:** Queue lengths are already collected and visible in
Grafana, so stuck workers are detectable via growing queues — but
auto-remediation (Kubernetes restarting wedged workers) does not happen
without probes.

**Work:** Evaluate probe strategies (exec celery inspect, heartbeat file,
sidecar). Implement liveness + readiness probes for all worker deployments.

#### 2. Must Gather — status unknown
**Components affected:** All (chart, koku, operator).

No must-gather image or collection scripts were found in the cost-onprem-chart,
koku, or koku-metrics-operator repositories. However, it is possible that
must-gather support exists elsewhere (e.g., a separate repo, the downstream
build system, or the SaaS support tooling) and we simply haven't located it.

**Jira:** [COST-7780](https://redhat.atlassian.net/browse/COST-7780) — investigation ticket created.

**Work (if confirmed missing):** Create a must-gather image with collection
scripts. See [Must-Gather — How It Works](https://docs.google.com/document/d/1liS-jpWTSGJryzBjbFz5CqA2uadmwIS6BZgVKyi5TZI/edit) for the pattern, Dockerfile, example gather
script, and 7 real-world operator examples.

#### 3. No alerting rules (PrometheusRules) in on-prem chart
**Components affected:** Chart.

The on-prem chart has no PrometheusRule resources. Operators have no automated
notification of failures — all monitoring is manual `kubectl` inspection.

The SaaS deployment has extensive alerting configured via app-interface. The
following PrometheusRule files exist and contain 40+ alert rules:

- `app-interface/resources/insights-prod/hccm-prod/hccm.prometheusrules.yaml`
- `app-interface/resources/insights-prod/hccm-prod/hccm-msk.prometheusrules.yaml`
- `app-interface/resources/insights-stage/hccm-stage/hccm.prometheusrules.yaml`
- `app-interface/resources/insights-stage/hccm-stage/hccm-aws.prometheusrules.yaml`

**SaaS alerts cover:**
- API health: pod availability, 5xx error rate, latency
- Celery queue overload: 12+ queue types (download, summary, priority,
  refresh, cost_model, default, ocp, hcs, subs_extraction, etc.)
- Data quality: stale/invalid sources, incomplete manifests
- Kafka/MSK: upload lag (>10,000 threshold), sources lag (>800)
- RDS: free space prediction (14-day and 1-day horizons)
- Presto: heartbeat and resource failures
- Pod restarts and job failures

All alerts include dashboard links, runbook references, and severity levels.

**SaaS also has SLO definitions** (`app-interface/data/services/insights/hccm/slo-documents/hccm-slo.yml`):
- API Availability: 90% target (non-5xx via 3scale gateway)
- API Latency: 90% target (requests under 4 seconds)

**Note:** [COST-7692](https://redhat.atlassian.net/browse/COST-7692) already
covers ServiceMonitors, basic PrometheusRules, and operator Events. This work
item covers the additional SaaS rules not in COST-7692.

**Jira:** [COST-7782](https://redhat.atlassian.net/browse/COST-7782) — port
alerting rules and Grafana dashboards.

**Work:** Review the SaaS PrometheusRules and adapt for on-prem:
- Strip SaaS-specific alerts (RDS, MSK, Presto/Trino, 3scale)
- Keep and adapt: API health, Celery queue depth, pod availability,
  data quality alerts
- Add on-prem-specific alerts not needed in SaaS:
  - PV usage > 80%
  - Database connection count near limit
  - CrashLoopBackOff / OOMKilled detection
- Port SLO definitions where applicable
- Add Kafka consumer lag alerts (adapted from MSK alerts for Strimzi/AMQ)

### P1 — Important for operations

*Ranked by: moderate support case frequency, significant diagnosis time,
survives operator migration.*

#### 4. Data pipeline end-to-end health ("data freshness")
Individual components have health probes, but there is no signal for "is the
system actually processing data end-to-end?" An operator cannot easily answer:
- When was the last report successfully ingested?
- When was the last summary table updated?
- Is the ROS pipeline producing recommendations?

A system where every pod is "Ready" but no data flows for 24 hours is
invisible today. **This is the core product failure mode** — all other
observability is secondary if the operator can't tell whether the system
is actually working.

**Work:** Define a "data freshness" metric or status endpoint that reports
time-since-last-successful-ingestion. This could be a Prometheus gauge
exported by the listener/masu, a dashboard panel, or a periodic health check
CronJob. Add a corresponding alert for staleness exceeding a threshold.

#### 5. Database backup/restore automation
**Status:** Single manual `pg_dump` command documented. No restore procedure.
No validation. No scheduling.

**Note:** The deployment may run separate databases (or schemas) for koku,
RBAC, and Kruize. The documented `pg_dump` command only backs up
`costonprem_koku`. If RBAC or Kruize data is lost, the system is broken
even if koku data is restored. Clarify whether they share a single
PostgreSQL instance (single `pg_dumpall`) or need separate backup jobs.

**Work:** Either add a CronJob template to the chart for periodic `pg_dump`
(covering all databases) with PVC or S3 storage, or document the recommended
external backup strategy and provide a restore runbook.

#### 6. Operator lacks Kubernetes Events and Conditions
**Components affected:** koku-metrics-operator.

The operator updates CR `.status` fields but does not emit Kubernetes Events
or use the standard Conditions API. This makes it invisible to standard
monitoring tools (`oc get events`, `oc wait --for=condition=`).

**Note:** [COST-7692](https://redhat.atlassian.net/browse/COST-7692) includes
Kubernetes Events in its scope.

**Work:** Add `EventRecorder` for key lifecycle events (reconciliation
start/complete, upload success/failure, authentication failure). Migrate
status to include standard Conditions (Available, Degraded, Progressing).

#### 7. Grafana dashboards need porting from SaaS
**Status:** ServiceMonitors exist, metrics are scraped, but the on-prem chart
has no pre-built dashboards.

Existing SaaS dashboards that can serve as a starting point:
- [grafana-dashboard-insights-hccm.configmap.yaml](https://github.com/project-koku/koku/blob/main/dashboards/grafana-dashboard-insights-hccm.configmap.yaml) — main HCCM dashboard
- [grafana-dashboard-insights-hccm-postgresql.configmap.yaml](https://github.com/project-koku/koku/blob/main/dashboards/grafana-dashboard-insights-hccm-postgresql.configmap.yaml) — DB metrics
- [grafana-dashboard-insights-hccm-redis.configmap.yaml](https://github.com/project-koku/koku/blob/main/dashboards/grafana-dashboard-insights-hccm-redis.configmap.yaml) — cache metrics
- [grafana-dashboard-insights-hccm-trino.configmap.yaml](https://github.com/project-koku/koku/blob/main/dashboards/grafana-dashboard-insights-hccm-trino.configmap.yaml) — query engine (N/A for on-prem)
- SaaS Grafana: `grafana.app-sre.devshift.net/d/R0HueuFGk/cost-management`
- SaaS SLO dashboard: `grafana.app-sre.devshift.net/d/slo-dashboard/slo-dashboard`

**Jira:** [COST-7782](https://redhat.atlassian.net/browse/COST-7782) — combined
with alerting rules.

**Work:** Adapt the koku SaaS dashboards for on-prem:
- Strip Trino/RDS/CloudWatch-specific panels
- Update datasource names and namespace/label selectors
- Add panels for on-prem-specific concerns (PV usage, Valkey instead of
  ElastiCache, local PostgreSQL instead of RDS)
- Package as ConfigMaps or JSON files in the chart

#### 8. Operator has zero custom Prometheus metrics
**Components affected:** koku-metrics-operator.

Only controller-runtime default metrics are exposed. No business-logic
metrics for: reports generated, upload success/failure, Prometheus query
latency, PVC usage, data collection errors.

**Work:** Add custom Prometheus counters/gauges/histograms for key operator
operations.

#### 9. No startup probes on slow-starting components
**Components affected:** Kruize (60s initial delay), ROS Processor (120s
initial delay), RBAC API (30s initial delay).

Without startup probes, liveness probes during slow startup can kill pods
before they finish initializing, causing restart loops under load. This is
noisy but self-recovering — lower impact than items above.

**Work:** Add `startupProbe` with generous `failureThreshold` to components
with `initialDelaySeconds` > 20s. Then reduce or remove
`initialDelaySeconds` from liveness probes.

#### 10. Network connectivity and dependency checks
On-prem has more network failure modes than SaaS: firewalls, proxies, DNS
misconfigurations. Connectivity failures are the #1 on-prem support issue
by volume in most products. There are no synthetic probes for:
- Koku API to PostgreSQL
- Listener to Kafka broker
- MASU to S3/object storage
- Operator to console.redhat.com (if uploading)
- UI to Keycloak (authentication)

Failures in these paths surface as cryptic application errors, not
connectivity diagnostics.

**Work:** Add a diagnostic script (or extend `check-installation.sh`) that
validates connectivity to all dependencies. Consider a "preflight check"
⚑ Helm hook that runs before install/upgrade to catch networking issues
early. In the operator model, this becomes a reconciliation precondition
with status conditions.

### P2 — Improvements

#### 11. Minimum on-prem debugging playbook
**Status:** [docs/operations/troubleshooting.md](https://github.com/insights-onprem/cost-onprem-chart/blob/main/docs/operations/troubleshooting.md) covers several scenarios but
is not structured as a systematic debugging playbook.

**Work:** Create a structured debugging guide organized by symptom:
- "No data appearing" — check listener logs, Kafka, upload status
- "Slow processing" — check queue depths, worker count, DB locks
- "Authentication failing" — check Keycloak, RBAC, token expiry
- "ROS recommendations missing" — check processor, Kruize, TLS
- "High memory usage" — check which component, tune resources

Include the exact `kubectl`/`oc` commands and expected output for each step.

#### 12. Infrastructure metrics exporters
**Status:** No PostgreSQL, Valkey, or Kafka exporters in the on-prem chart.

The SaaS deployment in app-interface has dedicated ServiceMonitors for:
- `postgresql-exporter.servicemonitor.yml`
- `rdsexporter.servicemonitor.yml`
- `redis-exporter.servicemonitor.yml`
- `trino.servicemonitor.yml`

**Work:** Evaluate adding optional sidecar exporters
(`postgres_exporter`, `redis_exporter`) with ServiceMonitors, gated behind
a values.yaml flag. The SaaS exporter configs can inform what metrics are
worth collecting. Alternatively, document that customers should bring
their own infrastructure monitoring.

#### 13. Structured logging for on-prem
**Status:** Koku supports JSON logging internally but the chart defaults to
plain text console output.

**Log volume note:** The deployment runs 10+ Celery workers, API, MASU,
listener, ROS, and RBAC — each producing logs. With `KOKU_LOG_LEVEL: DEBUG`
(the current MASU default) and JSON formatting, log volume could be
significant. The default log levels in values.yaml should be reviewed
for production on-prem (`DEBUG` for MASU seems aggressive). Consider
documenting expected log volume at different log levels and storage budget
guidance for customers enabling log aggregation.

**Work:** Add values.yaml options to enable JSON log formatting
(`DJANGO_LOG_FORMATTER: json`) and document integration with common log
aggregation stacks (ELK, Loki). Fix default log levels: MASU `DEBUG` →
`INFO`, Kruize `debug` → `info`.

#### 14. GlitchTip / Sentry error tracking disabled on-prem
**Status:** Koku has full Sentry SDK integration and the SaaS uses GlitchTip
as the backend. On-prem has it hardcoded to disabled (`KOKU_ENABLE_SENTRY:
"False"`) with no DSN exposed in values.yaml.

**Work:** Expose GlitchTip/Sentry configuration in values.yaml so on-prem
customers can optionally point koku at their own GlitchTip (or Sentry)
instance. Requires:
- Add `sentry.enabled`, `sentry.dsn`, `sentry.environment` to values.yaml
- Wire the env vars into all koku deployment templates
- Document setup (GlitchTip is self-hostable and lightweight)

#### 15. Operator leader election health integration
**Status:** Leader election is configured but health probes don't reflect
leader status. The `HealthzAdaptor` is vendored but not wired in.

**Work:** Integrate leader election health check with `/healthz` endpoint so
non-leader replicas report not-ready. Add metrics for election events.

### P3 — SRE considerations for on-prem environments

These items are less visible in a SaaS context (where the platform team
handles them) but become critical when customers run the stack themselves.

#### 16. Upgrade and rollback observability ⚑ Helm-specific
On-prem operators need to know whether a Helm upgrade succeeded, partially
applied, or left the system in a broken state. Currently there are no
post-upgrade health gates, no Helm test that validates the full stack after
upgrade, and no documented rollback procedure beyond `helm rollback`.

**Work:** Add a Helm post-upgrade test (or enhance the existing
`check-installation.sh`) that validates all components are healthy after
upgrade. Document rollback procedures and known upgrade pitfalls (immutable
label changes, database migrations). In the operator model, this becomes
reconciliation status conditions and automated rollback.

#### 17. Capacity planning and resource exhaustion
SaaS autoscales; on-prem doesn't. There is no monitoring for:
- Database PVC approaching capacity
- Valkey memory usage vs. limit (eviction risk)
- S3/object storage bucket size growth
- Pod resource usage trending toward limits (slow OOMKill buildup)

**Work:** Add alerts and/or dashboard panels for storage and memory
exhaustion. Document sizing guidance for different customer scales (small /
medium / large cluster counts). Consider adding capacity-related alerts to
the PrometheusRules (work item 3).

#### 18. Certificate and secret expiry monitoring
The deployment uses multiple TLS certificates: OpenShift service CA, Keycloak
TLS, oauth-proxy certs, and potentially Kafka TLS. On-prem certificates
expire silently — a cert expiry at 2 AM is a classic on-prem outage with no
warning.

**Work:** Inventory all certificates and secrets used by the chart.
Evaluate adding cert-expiry alerts (e.g., via `x509_cert_not_after` from
kube-prometheus or a lightweight sidecar). At minimum, document certificate
lifecycles and renewal procedures.

#### 19. Persistent event and restart history
Kubernetes Events expire after ~1 hour by default. OOMKill and
CrashLoopBackOff history is lost. On-prem operators investigating a Monday
morning outage cannot see what happened over the weekend.

**Work:** Document that customers should configure event persistence (e.g.,
via `kube-event-exporter` or OpenShift logging). Consider adding a
Prometheus counter for container restarts per component so restart history
survives event garbage collection.

#### 20. Version and configuration drift detection ⚑ Helm-specific
On-prem deployments age and drift. An operator may run an outdated image,
manually edit a ConfigMap, or have a partial upgrade. There is no audit
trail or version consistency check.

**Work:** Expose deployed image tags and chart version via the status
endpoint or a ConfigMap. Consider a periodic check (CronJob or dashboard
panel) that compares running images against expected versions from the Helm
release. In the operator model, this becomes drift detection in the
reconciliation loop.

#### 21. Audit logging for user actions
On-prem deployments may serve multiple teams within an organization. No
application-level audit logging exists for: who accessed what cost data,
who changed cost models or rate settings, who created/deleted sources, who
modified RBAC permissions. The SaaS handles this partially via the 3scale
gateway (which logs all API requests with identity headers) and CloudWatch.
On-prem has neither.

For regulated industries (finance, healthcare, government), audit logging
may be a hard compliance requirement.

**Work:** Determine whether on-prem needs audit logging for compliance. If
yes: add structured audit events for sensitive operations (data access,
configuration changes, permission changes) with a retention and export
mechanism.

---

## Summary

| Area | Current State | Key Gap |
|------|--------------|---------|
| Health checks | 14/26 deployments have probes | Celery workers, RBAC worker, ROS housekeeper missing; some probes fragile |
| Status endpoints | Comprehensive (koku) | Not externally documented for on-prem operators |
| Logging | Mature, configurable (koku) | ROS/RBAC not audited; no structured logging default; no aggregation guidance; MASU defaults to DEBUG |
| Prometheus metrics | Good (koku), minimal (operator) | Operator has 0 custom metrics, no infra exporters |
| Alerting | SaaS has 40+ rules (app-interface) | None ported to on-prem chart yet (COST-7692 in progress) |
| Kafka | SaaS has MSK monitoring + alerts | On-prem Kafka observability completely missing |
| Must Gather | Unknown — not found in these repos | Investigation: COST-7780 |
| Database backup | Manual one-liner (koku only) | No automation, no restore procedure, RBAC/Kruize DBs not covered |
| Dashboards | 4 SaaS dashboards in koku repo | Need porting to on-prem: COST-7782 |
| Debugging playbook | Partial troubleshooting doc | Not structured by symptom |
| Error tracking | SaaS uses GlitchTip; on-prem disabled | Expose DSN config in values.yaml |
| Data freshness | No end-to-end signal | "All pods Ready but no data flowing" is invisible |
| Operator observability | CR status only | No Events, no Conditions, no custom metrics (COST-7692 planned) |
| Audit logging | Not present | Compliance risk for regulated industries |
| Upgrade / rollback | No post-upgrade health gate | ⚑ Helm-specific — skip if operator ships soon |
| Capacity planning | Resource limits defined | No exhaustion alerts, no sizing guidance by scale |
| Certificate expiry | Not monitored | Silent expiry is a classic on-prem outage |
| Event persistence | K8s default (~1h) | Weekend outages leave no trace |
| Network connectivity | No synthetic checks | #1 on-prem support issue by volume |
| Version drift | No consistency check | ⚑ Helm-specific — skip if operator ships soon |

---

## Sources Investigated

### Repositories inspected

| Repo | Path | What we looked at |
|------|------|-------------------|
| [cost-onprem-chart](https://github.com/insights-onprem/cost-onprem-chart) | Helm templates (probes, ServiceMonitors, NetworkPolicies), values.yaml, scripts/, docs/operations/ |
| [koku](https://github.com/project-koku/koku) | Health endpoints, logging config, Prometheus metrics, Sentry integration, DB performance tools, Celery task inspection endpoints, Grafana dashboards, clowdapp.yaml (GlitchTip config) |
| [koku-metrics-operator](https://github.com/project-koku/koku-metrics-operator) | Health probes, logging (zap/logr), metrics server config, CR status types, leader election, manager setup |
| app-interface (internal) | PrometheusRules, ServiceMonitors, SLO definitions, service definition, deploy-clowder.yml, ConfigMaps |

### Key files examined

**[cost-onprem-chart](https://github.com/insights-onprem/cost-onprem-chart):**
- [cost-onprem/templates/cost-management/](https://github.com/insights-onprem/cost-onprem-chart/tree/main/cost-onprem/templates/cost-management) — all deployment YAMLs for probe audit
- [cost-onprem/templates/monitoring/servicemonitor.yaml](https://github.com/insights-onprem/cost-onprem-chart/blob/main/cost-onprem/templates/monitoring/servicemonitor.yaml) — 6 ServiceMonitors
- [cost-onprem/values.yaml](https://github.com/insights-onprem/cost-onprem-chart/blob/main/cost-onprem/values.yaml) — logging, monitoring, resource config
- [docs/operations/troubleshooting.md](https://github.com/insights-onprem/cost-onprem-chart/blob/main/docs/operations/troubleshooting.md) — existing failure mode docs
- [scripts/check-installation.sh](https://github.com/insights-onprem/cost-onprem-chart/blob/main/scripts/check-installation.sh) — post-install health check

**[koku](https://github.com/project-koku/koku):**
- [koku/koku/probe_server.py](https://github.com/project-koku/koku/blob/main/koku/koku/probe_server.py) — `/livez`, `/readyz`, `/metrics` on :9000
- [koku/masu/api/status.py](https://github.com/project-koku/koku/blob/main/koku/masu/api/status.py) — `/api/cost-management/v1/status/` endpoint
- [koku/masu/prometheus_stats.py](https://github.com/project-koku/koku/blob/main/koku/masu/prometheus_stats.py) — custom Prometheus counters and gauges
- [koku/koku/sentry.py](https://github.com/project-koku/koku/blob/main/koku/koku/sentry.py) — GlitchTip/Sentry integration
- [koku/koku/log.py](https://github.com/project-koku/koku/blob/main/koku/koku/log.py) — TaskFormatter for Celery-aware logging
- [koku/masu/api/db_performance/](https://github.com/project-koku/koku/tree/main/koku/masu/api/db_performance) — DB observability views
- [dashboards/](https://github.com/project-koku/koku/tree/main/dashboards) — 4 Grafana dashboards (SaaS)
- [deploy/clowdapp.yaml](https://github.com/project-koku/koku/blob/main/deploy/clowdapp.yaml) — GLITCHTIP_SECRET_NAME references

**[koku-metrics-operator](https://github.com/project-koku/koku-metrics-operator):**
- [cmd/main.go](https://github.com/project-koku/koku-metrics-operator/blob/main/cmd/main.go) — health probes, leader election, metrics server
- [api/v1beta1/metricsconfig_types.go](https://github.com/project-koku/koku-metrics-operator/blob/main/api/v1beta1/metricsconfig_types.go) — CR status subresource definitions
- [config/manager/manager.yaml](https://github.com/project-koku/koku-metrics-operator/blob/main/config/manager/manager.yaml) — pod probes, leader election flags
- [config/prometheus/monitor.yaml](https://github.com/project-koku/koku-metrics-operator/blob/main/config/prometheus/monitor.yaml) — ServiceMonitor

**app-interface (internal):**
- `resources/insights-prod/hccm-prod/hccm.prometheusrules.yaml` — 40+ alert rules
- `resources/insights-prod/hccm-prod/hccm-msk.prometheusrules.yaml` — Kafka alerts
- `resources/insights-prod/hccm-prod/koku.servicemonitor.yml` — koku scraping
- `resources/insights-prod/hccm-prod/postgresql-exporter.servicemonitor.yml`
- `resources/insights-prod/hccm-prod/redis-exporter.servicemonitor.yml`
- `data/services/insights/hccm/slo-documents/hccm-slo.yml` — SLO targets
- `data/services/insights/hccm/app.yml` — service definition, dashboard links

### External references

> **Note:** Internal Red Hat URLs — may require VPN/access and may change
> if infrastructure is migrated.

- [OpenShift must-gather docs](https://docs.redhat.com/en/documentation/openshift_container_platform/4.17/html/support/gathering-cluster-data) — must-gather mechanism and `--image` flag
- [openshift/must-gather](https://github.com/openshift/must-gather) — reference implementation for custom must-gather images
- SaaS GlitchTip: https://glitchtip.devshift.net/
- SaaS Grafana (prod): https://grafana.app-sre.devshift.net/d/R0HueuFGk/cost-management
- SaaS Grafana (stage): https://grafana.stage.devshift.net/d/R0HueuFGk/cost-management
- SaaS Prometheus (prod): https://prometheus.crcp01ue1.devshift.net/graph
- SaaS Prometheus (stage): https://prometheus.crcs02ue1.devshift.net/graph
- SaaS Kibana (prod): https://kibana.apps.crcp01ue1.o9m8.p1.openshiftapps.com/app/discover
- SaaS Kibana (stage): https://kibana.apps.crcs02ue1.urby.p1.openshiftapps.com/app/discover
- SaaS SLO dashboard: https://grafana.app-sre.devshift.net/d/slo-dashboard/slo-dashboard
- SaaS runbooks (referenced by alerts): `https://gitlab.cee.redhat.com/service/app-interface/-/tree/master/docs/tenant-services/console.redhat.com/app-sops/hccm`
