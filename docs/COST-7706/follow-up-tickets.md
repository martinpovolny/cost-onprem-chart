# Follow-Up Tickets from COST-7706 Spike

Ready to create in JIRA under project COST. Each section is a ticket.
Parent epic: [COST-7543](https://redhat.atlassian.net/browse/COST-7543).

---

## 1. Quick wins: ServiceMonitors, log levels, GlitchTip config

**Type:** Task | **Effort:** S (1-2 days) | **Phase:** 1 — Quick wins
**Component:** Operators

### Background

The COST-7706 observability spike identified several small chart changes
that immediately improve monitoring with minimal risk. These are all
configuration or template additions — no application code changes.

### Scope of Work

1. Add ServiceMonitor for MASU (already exposes `/metrics` on :9000, just
   not scraped)
2. Add ServiceMonitor for Listener (same — `/metrics` on :9000, not scraped)
3. Add ServiceMonitor for Ingress (port 9090 already configured, not scraped)
4. Expose GlitchTip/Sentry config in `values.yaml`: add `sentry.enabled`,
   `sentry.dsn`, `sentry.environment`; wire env vars into all koku
   deployment templates
5. Add JSON log format option: expose `DJANGO_LOG_FORMATTER: json` in
   `values.yaml`
6. Fix default log levels: change MASU from `DEBUG` to `INFO`, Kruize from
   `debug` to `info` for production defaults

### Related Issues and PRs

- [COST-7706](https://redhat.atlassian.net/browse/COST-7706) — spike that identified these gaps
- [COST-7543](https://redhat.atlassian.net/browse/COST-7543) — parent epic
- Plan items: T4, T7, T14, T15, T16 in `docs/COST-7706/plan.md`

### Acceptance Criteria

- [ ] MASU, Listener, and Ingress have ServiceMonitor resources
- [ ] `values.yaml` has `sentry.enabled`, `sentry.dsn`, `sentry.environment`
- [ ] `values.yaml` has `logging.format` option (json/text)
- [ ] Default log levels are INFO for all components

---

## 2. Add health probes to Celery worker deployments

**Type:** Task | **Effort:** M (3-5 days) | **Phase:** 4 — Supportability
**Component:** Operators

### Background

10 Celery worker deployments (default, priority, summary, ocp, cost-model,
download, refresh, hcs, subs-extraction, subs-transmission), plus the RBAC
worker and ROS housekeeper, have no liveness or readiness probes. A stuck
worker stays "Running" and consumes a queue slot indefinitely — Kubernetes
cannot detect the failure.

### Scope of Work

1. Evaluate probe strategies — need to resolve research TODO R3 first:
   - Exec-based `celery inspect ping` (latency? reliability?)
   - Heartbeat file age check (simplicity, failure modes)
   - Sidecar HTTP endpoint (overhead, complexity)
2. Implement chosen probe strategy for all 12 worker deployments
3. Add startup probes to slow-starting components (Kruize 60s, ROS
   Processor 120s, RBAC API 30s) — currently these can be killed by
   liveness probes during slow startup

### Related Issues and PRs

- [COST-7706](https://redhat.atlassian.net/browse/COST-7706) — gap #1 and #4
- Plan items: T1, T2, T3 in `docs/COST-7706/plan.md`

### Acceptance Criteria

- [ ] All Celery worker deployments have liveness + readiness probes
- [ ] Kruize, ROS Processor, RBAC API have startup probes
- [ ] Probe strategy decision documented

---

## 3. Port SaaS PrometheusRules to on-prem chart

**Type:** Task | **Effort:** M (3-5 days) | **Phase:** 2 — Alerting
**Component:** Operators

### Background

The SaaS deployment has 40+ PrometheusRule alert rules configured via
app-interface. The on-prem chart has zero. Operators get no automated
notification of failures — all monitoring is manual `kubectl` inspection.

Analysis in `docs/COST-7706/metrics-and-dashboards.md` mapped all SaaS
rules: 7 are directly portable, 29 need adaptation, 2 are N/A (Presto).

### Scope of Work

1. Port the 7 directly-applicable rules (API down, 5xx rate, pod restarts,
   job failures, incomplete manifests, invalid sources, stale sources)
2. Adapt 10 high-priority rules (Celery queue overload, API latency — replace
   3scale with django metrics, replace RDS with local PG, replace MSK with
   local Kafka)
3. Add on-prem-specific alerts not needed in SaaS:
   - PV usage > 80%
   - Database connection count near limit
   - CrashLoopBackOff / OOMKilled detection
4. All rules gated behind `monitoring.alerts.enabled: true` in values.yaml

### Related Issues and PRs

- [COST-7706](https://redhat.atlassian.net/browse/COST-7706) — gap #3
- SaaS rules: `app-interface/resources/insights-prod/hccm-prod/hccm.prometheusrules.yaml`
- Plan items: T9, T10 in `docs/COST-7706/plan.md`

### Acceptance Criteria

- [ ] PrometheusRule resource added to chart templates
- [ ] At least 15 alert rules covering API health, Celery queues, data quality, pod stability
- [ ] On-prem-specific alerts for PV, OOM, CrashLoop
- [ ] Alert severity levels match SaaS conventions

---

## 4. Port Grafana dashboards to on-prem

**Type:** Task | **Effort:** M (3-5 days) | **Phase:** 3 — Dashboards
**Component:** Operators

### Background

4 Grafana dashboards exist in the koku repo (`dashboards/`) built for SaaS.
The on-prem chart ships no dashboards. Customers have metrics being scraped
but no way to visualize them without building dashboards from scratch.

### Scope of Work

1. Adapt the main HCCM dashboard (API, Celery, processing pipeline) — strip
   Trino/RDS/CloudWatch panels, update datasource names, fix namespace/label
   selectors
2. Adapt the PostgreSQL dashboard — works with postgresql-exporter sidecar
3. Adapt the Redis/Valkey dashboard — update instance labels
4. Skip the Trino dashboard (not applicable to on-prem)
5. Package as ConfigMaps or JSON files in the chart, gated behind
   `monitoring.dashboards.enabled: true`

### Related Issues and PRs

- [COST-7706](https://redhat.atlassian.net/browse/COST-7706) — gap #7
- SaaS dashboards: `koku/dashboards/*.configmap.yaml`
- SaaS Grafana: https://grafana.app-sre.devshift.net/d/R0HueuFGk/cost-management
- Plan items: T11, T12, T13 in `docs/COST-7706/plan.md`
- Depends on: infrastructure exporters (T5 postgresql-exporter, T6 redis-exporter)

### Acceptance Criteria

- [ ] 3 Grafana dashboards shipped in chart (main, PostgreSQL, Redis)
- [ ] Dashboards work with default on-prem ServiceMonitor labels
- [ ] No references to SaaS-only infrastructure (RDS, CloudWatch, Trino, 3scale)

---

## 5. Create must-gather image for cost-management on-prem

**Type:** Task | **Effort:** L (1-2 weeks) | **Phase:** 4 — Supportability
**Component:** Operators

### Background

No must-gather image was found in cost-onprem-chart, koku, or
koku-metrics-operator repos. Before starting this work, confirm with the
broader team that one doesn't already exist elsewhere (Brew, Quay, a
separate repo).

Reference: `docs/COST-7706/must-gather-howto.md` documents the OpenShift
must-gather pattern with examples from ODF, GitOps, KubeVirt, Pipelines.

### Scope of Work

1. **First:** Verify no must-gather image already exists (check Quay, Brew,
   operator CSV, ask Luke Couzens)
2. Create collection scripts that gather:
   - Pod status, describe, logs (last 1000 lines + previous container)
   - Helm release info and computed values
   - CR status (CostManagementMetricsConfig)
   - Kubernetes events in namespace
   - Database connection stats (pg_stat_activity, pg_stat_database)
   - Celery queue lengths
   - Prometheus metric snapshot (if accessible)
3. Build must-gather container image
4. Test with `oc adm must-gather --image=<image>`
5. Publish to registry and reference from operator CSV

### Related Issues and PRs

- [COST-7706](https://redhat.atlassian.net/browse/COST-7706) — gap #2
- [COST-7540](https://redhat.atlassian.net/browse/COST-7540) — GA observability tooling
- Reference: `docs/COST-7706/must-gather-howto.md`
- Plan items: T18, R1 in `docs/COST-7706/plan.md`

### Acceptance Criteria

- [ ] Must-gather image builds and runs with `oc adm must-gather`
- [ ] Collected bundle includes logs, CR status, events, DB stats, queue info
- [ ] Image published to registry
- [ ] Operator CSV references the must-gather image

---

## 6. Create on-prem debugging playbook

**Type:** Task | **Effort:** M (3-5 days) | **Phase:** 4 — Supportability
**Component:** Operators

### Background

`docs/operations/troubleshooting.md` covers several scenarios but is not
structured as a systematic debugging playbook. 21 SaaS runbooks were
inventoried in the spike — 17 are applicable to on-prem (10 directly, 7
with adaptation). The on-prem playbook should cover these failure modes
with on-prem-specific commands and paths.

### Scope of Work

1. Read the 10 directly-applicable SaaS runbooks (see R2 in plan.md) and
   extract failure scenarios
2. Create a structured debugging guide organized by symptom:
   - "No data appearing" — check listener logs, Kafka, upload status
   - "Slow processing" — check queue depths, worker count, DB locks
   - "Authentication failing" — check Keycloak, RBAC, token expiry
   - "ROS recommendations missing" — check processor, Kruize, TLS
   - "High memory usage" — check which component, tune resources
   - "Pod restart loops" — check OOM, probe failures, resource limits
3. Include exact `kubectl`/`oc` commands and expected output for each step
4. Reference the built-in endpoints (`/status/`, `/masu/db-performance/`,
   `/masu/celery_queue_lengths/`)

### Related Issues and PRs

- [COST-7706](https://redhat.atlassian.net/browse/COST-7706) — gap #9
- SaaS runbooks: `app-interface/docs/tenant-services/console.redhat.com/app-sops/hccm/`
- Plan items: T19, R2 in `docs/COST-7706/plan.md`

### Acceptance Criteria

- [ ] Debugging playbook published in `docs/operations/`
- [ ] Covers at least 6 common failure scenarios
- [ ] Each scenario has exact `oc`/`kubectl` commands and expected output
- [ ] References built-in diagnostic endpoints

---

## 7. Database backup/restore automation

**Type:** Task | **Effort:** M (3-5 days) | **Phase:** 4 — Supportability
**Component:** Operators

### Background

Only a manual `pg_dump` one-liner exists in the installation guide. On-prem
customers need automated, validated backups with a restore procedure.

### Scope of Work

1. Add a CronJob template to the chart for periodic `pg_dump` with PVC or
   S3 storage target
2. Add backup validation (verify dump is non-empty, record size/timestamp)
3. Document restore procedure with step-by-step instructions
4. Gate behind `backup.enabled: true` in values.yaml
5. Document retention policy options

### Related Issues and PRs

- [COST-7706](https://redhat.atlassian.net/browse/COST-7706) — gap #5
- Plan items: T20 in `docs/COST-7706/plan.md`

### Acceptance Criteria

- [ ] CronJob template in chart for automated `pg_dump`
- [ ] Backup target configurable (PVC or S3)
- [ ] Restore procedure documented
- [ ] Backup validation confirms dump integrity

---

## 8. Operator observability: Events, Conditions, custom metrics

**Type:** Task | **Effort:** L (1-2 weeks) | **Phase:** 5 — Operator
**Component:** Operators

### Background

The koku-metrics-operator uses custom CR status fields but does not emit
Kubernetes Events or use the standard Conditions API. It has zero custom
Prometheus metrics — only controller-runtime defaults. This makes it
invisible to standard monitoring and support tooling.

### Scope of Work

1. Add `EventRecorder` for key lifecycle events:
   - Reconciliation start/complete
   - Upload success/failure
   - Authentication failure
   - Report generation milestones
2. Add standard Conditions API to CR status:
   - Available, Degraded, Progressing
   - Note: this is a breaking API change, coordinate with operator team
3. Add custom Prometheus metrics:
   - Reports generated (counter)
   - Upload success/failure (counter)
   - Prometheus query latency (histogram)
   - PVC usage (gauge)
   - Data collection errors (counter)
4. Wire leader election HealthzAdaptor into `/healthz`

### Related Issues and PRs

- [COST-7706](https://redhat.atlassian.net/browse/COST-7706) — gaps #6, #8, #13
- Plan items: T8, T21, T22, T23 in `docs/COST-7706/plan.md`

### Acceptance Criteria

- [ ] Operator emits Kubernetes Events for reconciliation and upload lifecycle
- [ ] CR status includes standard Conditions (Available, Degraded, Progressing)
- [ ] At least 5 custom Prometheus metrics exposed
- [ ] Non-leader replicas report not-ready via `/healthz`

---

## Gaps Tracked but Not Yet Ticketed

These items from the spike are lower priority or need more research before
they can be scoped as tickets. They are documented in
[observability.md](observability.md) gaps #14-20 and [plan.md](plan.md)
items T24-T28.

| Gap | Summary | Blocker |
|-----|---------|---------|
| Upgrade/rollback validation | No post-upgrade health gate, no rollback docs | Depends on operator timeline (R7) |
| Capacity/exhaustion alerts | PV, Valkey memory, DB connections trending | Can be folded into ticket #3 (alerting) |
| Certificate lifecycle | No expiry monitoring, no renewal docs | Needs cert inventory |
| Data freshness metric | "All pods Ready but no data flowing" invisible | Needs app-level gauge in koku |
| Event persistence | K8s events expire after ~1h, weekend outages invisible | Customer responsibility (document) |
| Network connectivity checks | No synthetic probes for dependency paths | Extend check-installation.sh |
| Version drift detection | No audit trail for partial upgrades | Low priority |
| Kafka observability | Consumer lag, dead-letter topics, on-prem Kafka distribution | Depends on R6 research |
| ROS and RBAC deep audit | Only Helm-template-level audit done | Depends on R5 research |
