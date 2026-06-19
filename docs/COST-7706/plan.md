# COST-7706: Observability and Debuggability — Plan

**Jira:** [COST-7706](https://redhat.atlassian.net/browse/COST-7706) (Spike)
**Assignee:** Martin Povolny
**Status:** In Progress

---

## Deliverables

The spike deliverable is a document + Jira issues. No code changes are
expected from COST-7706 itself — it produces the backlog for future sprints.

1. [x] Gap analysis document ([observability.md](observability.md))
2. [x] Metrics/dashboards SaaS vs on-prem comparison ([metrics-and-dashboards.md](metrics-and-dashboards.md))
3. [x] Logging/error-tracking audit ([logging-and-error-tracking.md](logging-and-error-tracking.md))
4. [x] Adversarial review ([observability-review.md](observability-review.md))
5. [x] This plan
6. [ ] Jira issues created for implementation work (see below)
7. [ ] Spike closed

---

## Research TODOs (before creating Jira issues)

These are open questions that need answers from the team or further
investigation before we can write good tickets.

### R1. Must Gather — does it already exist?
- [ ] Ask team: is there a must-gather image for cost-management on-prem?
- [ ] Check if the costmanagement-metrics-operator CSV references one
- [ ] Check Quay/Brew for published images
- [ ] Check if SaaS has a Bug Splat / PG dump equivalent

**Ask:** Luke Couzens, cost-management team

### R2. SaaS runbooks — review for on-prem gaps

**Source:** https://gitlab.cee.redhat.com/service/app-interface/-/tree/master/docs/tenant-services/console.redhat.com/app-sops/hccm

**Local:** `../app-interface/docs/tenant-services/console.redhat.com/app-sops/hccm/`

21 runbooks exist. On-prem applicability assessment:

| Runbook | Applies to on-prem? | Notes |
|---------|---------------------|-------|
| `App-koku-api-In-hccm-Absent.rst` | **Yes** | API pod down |
| `App-koku-5xx-In-hccm.rst` | **Yes** | High error rate (adapt from 3scale to django metrics) |
| `App-koku-api-latency.md` | **Yes** | Slow API (adapt metrics) |
| `Celery-errors-In-hccm.rst` | **Yes** | Celery task failures |
| `App-insights-hccm-worker-queue-overload.rst` | **Yes** | Queue backlog — critical for on-prem (no autoscaling) |
| `App-cost-pod-restarts-In-hccm.rst` | **Yes** | Pod restart loops |
| `App-job-failures-In-hccm.rst` | **Yes** | CronJob/Job failures |
| `App-cost-incomplete-manifests-In-hccm.rst` | **Yes** | Data quality issue |
| `App-cost-invalid-sources-In-hccm.rst` | **Yes** | Source config errors |
| `App-cost-stale-sources-In-hccm.rst` | **Yes** | Source connectivity |
| `App-cost-upload-lag-In-hccm.rst` | **Adapt** | Kafka lag — replace MSK metrics with Strimzi/AMQ |
| `App-cost-sources-lag-In-hccm.rst` | **Adapt** | Kafka lag — same |
| `RDS-free-space-very-low.rst` | **Adapt** | Replace RDS with local PG PV usage |
| `hccm-disaster-recovery.md` | **Adapt** | DR procedures need on-prem equivalent |
| `hccm-smoke-test.md` | **Review** | May inform on-prem post-install checks |
| `hccm-load-test.md` | **Review** | May inform capacity planning |
| `SLO.md` | **Adapt** | Replace 3scale SLIs with django metrics |
| `hccm-slo-availability.md` | **Adapt** | Same |
| `hccm-slo-latency.md` | **Adapt** | Same |
| `App-cost-changed-presto-heartbeats-In-hccm.rst` | No | No Presto on-prem |
| `App-cost-presto-insufficent-resources-In-hccm.rst` | No | No Presto on-prem |

**TODOs:**
- [x] List all failure scenarios documented (21 runbooks found)
- [x] Assess on-prem applicability (10 direct, 7 adapt, 2 review, 2 N/A)
- [ ] Read the 10 directly-applicable runbooks and compare against `docs/operations/troubleshooting.md`
- [ ] Identify gaps (scenarios that apply to on-prem but aren't documented)

### R3. Celery worker health probe strategy
- [ ] Evaluate: exec `celery inspect ping` — latency, reliability
- [ ] Evaluate: heartbeat file age check — simplicity, failure modes
- [ ] Evaluate: sidecar HTTP endpoint — overhead, complexity
- [ ] Decide on approach before creating implementation ticket

### R4. Queue scaling and penalty queues on-prem
- [ ] Verify which Celery queues exist in on-prem chart (xl, penalty variants)
- [ ] Check if queue-splitting is documented for operators
- [ ] Determine appropriate alert thresholds (use SaaS baselines from app-interface)

### R5. Audit ROS and RBAC at application level
- [ ] ROS: logging framework, structured logging, error tracking, custom metrics
- [ ] RBAC: logging config, metrics export, error handling patterns
- [ ] Neither got deep analysis — only Helm-template-level audit done so far

### R6. Kafka observability on-prem
- [ ] What Kafka distribution is used on-prem? (Strimzi / AMQ Streams / other)
- [ ] Is consumer lag tracked anywhere?
- [ ] Is there a dead-letter topic for failed messages?
- [ ] What metrics does the on-prem Kafka expose?

### R7. Operator timeline
- [ ] When is the operator expected to replace Helm charts?
- [ ] Determines whether Helm-specific work items are worth pursuing

---

## Implementation Tickets to Create

Grouped by theme. Each becomes a Jira issue under COST project.
Effort: S = hours, M = days, L = weeks.

### Theme 1: Health Checks and Probes

| # | Title | Effort | Depends On | Notes |
|---|-------|--------|------------|-------|
| T1 | Add health probes to Celery worker deployments | M | R3 (probe strategy) | 10 worker deployments + RBAC worker + ROS housekeeper |
| T2 | Add startup probes to slow-starting components | S | — | Kruize, ROS Processor, RBAC API |
| T3 | Review probe quality (fragile /metrics probes) | S | — | ROS Processor, ROS Poller use /metrics as health check |

### Theme 2: Metrics and Monitoring

| # | Title | Effort | Depends On | Notes |
|---|-------|--------|------------|-------|
| T4 | Add ServiceMonitors for MASU and Listener | S | — | Both already expose /metrics on :9000, just need ServiceMonitor resources. **Unblocks queue-depth alerting.** |
| T5 | Add postgresql-exporter sidecar | M | — | Optional, gated by values.yaml flag. Unblocks PG dashboard. |
| T6 | Add redis-exporter sidecar for Valkey | M | — | Optional, gated by values.yaml flag. Unblocks Redis dashboard. |
| T7 | Add ServiceMonitor for Ingress | S | — | Port 9090 already configured, just not scraped |
| T8 | Add custom Prometheus metrics to koku-metrics-operator | L | — | Operator has 0 custom metrics today |

### Theme 3: Alerting

| # | Title | Effort | Depends On | Notes |
|---|-------|--------|------------|-------|
| T9 | Port SaaS PrometheusRules to on-prem chart | M | T4 (MASU SM) | 7 directly portable, 29 need adaptation. See [metrics-and-dashboards.md](metrics-and-dashboards.md#alerting-rules--saas-to-on-prem-mapping) |
| T10 | Add on-prem-specific alerts (PV, OOM, CrashLoop) | S | T9 | Alerts that SaaS doesn't need |

### Theme 4: Dashboards

| # | Title | Effort | Depends On | Notes |
|---|-------|--------|------------|-------|
| T11 | Port HCCM main Grafana dashboard to on-prem | M | T4, T5 | Strip RDS/Trino panels, adapt datasources |
| T12 | Port PostgreSQL Grafana dashboard | S | T5 | Works directly once exporter added |
| T13 | Port Redis/Valkey Grafana dashboard | S | T6 | Change instance labels |

### Theme 5: Logging and Error Tracking

| # | Title | Effort | Depends On | Notes |
|---|-------|--------|------------|-------|
| T14 | Expose GlitchTip/Sentry config in values.yaml | S | — | Add sentry.enabled, sentry.dsn, sentry.environment |
| T15 | Add JSON log format option | S | — | Expose DJANGO_LOG_FORMATTER: json in values.yaml |
| T16 | Fix default log levels (MASU=DEBUG, Kruize=debug) | S | — | Change to INFO for production |
| T17 | Document log aggregation integration | S | — | OpenShift Logging, ELK, Loki patterns |

### Theme 6: Supportability

| # | Title | Effort | Depends On | Notes |
|---|-------|--------|------------|-------|
| T18 | Create must-gather image | L | R1 (check if exists) | Skip if one already exists |
| T19 | Create on-prem debugging playbook | M | R2 (runbook review) | Structured by symptom, with exact oc/kubectl commands |
| T20 | Document database backup/restore procedure | M | — | CronJob or external strategy + restore runbook |

### Theme 7: Operator Observability (koku-metrics-operator)

| # | Title | Effort | Depends On | Notes |
|---|-------|--------|------------|-------|
| T21 | Add Kubernetes Events to operator | M | — | EventRecorder for reconciliation lifecycle |
| T22 | Add Conditions API to operator CR status | L | — | Available, Degraded, Progressing — breaking API change |
| T23 | Integrate leader election with health probes | S | — | Wire HealthzAdaptor |

### Theme 8: On-Prem Resilience (conditional on operator timeline)

| # | Title | Effort | Depends On | Notes |
|---|-------|--------|------------|-------|
| T24 | Add upgrade/rollback validation | M | R7 (timeline) | Skip if operator ships within 6 months |
| T25 | Add capacity/exhaustion alerts | S | T9 | PV usage, Valkey memory, DB connections |
| T26 | Document certificate lifecycle and renewal | S | — | Inventory all TLS certs, document expiry |
| T27 | Add data freshness metric | M | — | Time-since-last-ingestion gauge, staleness alert |
| T28 | Add connectivity preflight check | M | R7 (timeline) | Validate all dependencies before install/upgrade |

---

## Suggested Sequencing

### Phase 1 — Quick wins (unblock monitoring)
**Target:** Next sprint | **Items:** T4, T7, T14, T15, T16

These are small changes (add ServiceMonitors, expose config, fix defaults)
that immediately improve observability with minimal risk.

### Phase 2 — Alerting foundation
**Target:** Sprint +1 | **Items:** T2, T3, T5, T6, T9, T10

Add infrastructure exporters and port SaaS alerting rules. After this
phase, on-prem has automated failure detection.

### Phase 3 — Dashboards and visibility
**Target:** Sprint +2 | **Items:** T11, T12, T13, T17, T27

Port Grafana dashboards and document log aggregation. After this phase,
operators have visual monitoring and can integrate with their logging stack.

### Phase 4 — Supportability
**Target:** Sprint +3 | **Items:** T1, T18, T19, T20

Worker health probes (after R3 research), must-gather (after R1 check),
debugging playbook (after R2 runbook review), database backup docs.

### Phase 5 — Operator improvements
**Target:** When prioritized | **Items:** T21, T22, T23, T8

Changes to koku-metrics-operator codebase. Lower urgency for on-prem
Helm deployment but important for the future operator.

### Phase 6 — On-prem resilience
**Target:** If operator timeline > 6 months | **Items:** T24, T25, T26, T28

Helm-specific or long-term improvements. Conditional on R7 (operator
timeline). Some items (T25, T26) are chart-agnostic and should be done
regardless.

---

## Progress Tracking

| Phase | Status | Notes |
|-------|--------|-------|
| Research TODOs (R1–R7) | Not started | Block some implementation tickets |
| Phase 1 — Quick wins | Not started | |
| Phase 2 — Alerting | Not started | |
| Phase 3 — Dashboards | Not started | |
| Phase 4 — Supportability | Not started | |
| Phase 5 — Operator | Not started | |
| Phase 6 — Resilience | Not started | |
| Jira issues created | Not started | Create after research TODOs answered |
| COST-7706 spike closed | Not started | After Jira issues filed |
