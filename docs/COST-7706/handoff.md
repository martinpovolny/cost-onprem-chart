# COST-7706 Handoff — Observability and Debuggability Spike

**Jira:** [COST-7706](https://redhat.atlassian.net/browse/COST-7706)
**Epic:** [COST-7543](https://redhat.atlassian.net/browse/COST-7543)
**Assignee:** Martin Povolny
**Date:** 2026-06-30
**Status:** Complete — closing spike, follow-up tickets created

---

## What This Spike Produced

A comprehensive gap analysis of observability and debuggability for the
cost-management on-prem deployment. The analysis covers health checks,
Prometheus metrics, alerting, Grafana dashboards, logging, error tracking,
must-gather, operator observability, and SRE concerns (capacity, certs,
data freshness, connectivity).

### Artifacts

| Document | Lines | Contents |
|----------|-------|----------|
| [observability.md](observability.md) | 638 | Main gap analysis — 20 work items across 4 priority tiers, full inventory of what exists and what's missing |
| [metrics-and-dashboards.md](metrics-and-dashboards.md) | 404 | SaaS vs on-prem comparison: Prometheus metrics, ServiceMonitors, Grafana dashboards, alerting rules (40+ SaaS rules mapped to on-prem applicability) |
| [logging-and-error-tracking.md](logging-and-error-tracking.md) | 367 | Logging config audit, structured logging, GlitchTip/Sentry integration, Celery error handling, per-component log levels |
| [observability-review.md](observability-review.md) | 335 | Adversarial review — 10 findings on gaps and blind spots in the analysis |
| [plan.md](plan.md) | 231 | Implementation plan — 7 research TODOs, 28 tickets in 8 themes, 6-phase sequencing |
| [must-gather-howto.md](must-gather-howto.md) | 160 | Reference material for building a custom must-gather image |
| [JIRA-COST-7706.md](JIRA-COST-7706.md) | 28 | Original Jira ticket text |

### Repositories Inspected

- **cost-onprem-chart** — Helm templates, probes, ServiceMonitors, values.yaml, scripts, docs
- **koku** — Health endpoints, logging, Prometheus metrics, Sentry, DB performance tools, Grafana dashboards, clowdapp.yaml
- **koku-metrics-operator** — Health probes, logging, metrics, CR status, leader election
- **app-interface** — PrometheusRules (40+ rules), ServiceMonitors, SLO definitions, runbooks (21 found, 17 applicable to on-prem)

### External Research

- Consulted Ivan Necas (inecas), Martin Bukatov (mbukatov), Ladislav Smola (ladas) on log collection patterns for on-prem products
- Reviewed Thomas Stetson's performance testing observability branch ([flpath-4061-cop-perf-observability](https://github.com/testetson22/cost-onprem-chart/tree/flpath-4061-cop-perf-observability))
- Identified must-gather pattern from ODF, GitOps, KubeVirt, Pipelines operators

---

## Key Findings

### What Already Works Well
- **14 of 14 stateless components** have liveness + readiness probes
- Koku has **mature logging** with per-module levels, structured JSON, Celery-aware formatting
- **19 custom Prometheus gauges** for queue depths, plus django_prometheus auto-instrumentation
- **6 ServiceMonitors** already in the chart (ROS API, ROS Processor, ROS Poller, Kruize, Koku API, Envoy)
- Built-in **DB performance dashboard** at `/api/cost-management/v1/masu/db-performance/`
- **Sentry SDK integration** exists in koku (just needs enabling for on-prem)

### Critical Gaps
1. **Celery workers have no health probes** — 10+ worker deployments invisible to Kubernetes when stuck
2. **Zero alerting rules** in the on-prem chart — SaaS has 40+ PrometheusRules, none ported
3. **No Grafana dashboards shipped** — 4 SaaS dashboards exist and can be adapted
4. **Must-gather unknown** — no image found in these repos (may exist elsewhere)
5. **GlitchTip disabled** — error tracking hardcoded off with no config exposed
6. **No on-prem debugging playbook** — troubleshooting doc exists but isn't structured by symptom
7. **Database backup is a manual one-liner** — no automation, no restore procedure

### Open Research Questions (Not Fully Resolved)
- **R1:** Does a must-gather image already exist somewhere? (Ask Luke Couzens / broader team)
- **R3:** Best probe strategy for Celery workers (exec inspect, heartbeat file, sidecar)
- **R6:** What Kafka distribution is used on-prem? Consumer lag tracking?
- **R7:** Operator timeline — when does Helm get replaced? (Determines Helm-specific investment)

---

## Follow-Up Tickets Created

Tickets are grouped from the 28 items in [plan.md](plan.md). Phase 1 (quick wins) is designed to be done in a single sprint.

| Jira Key | Title | Priority | Phase |
|----------|-------|----------|-------|
| TBD | Quick wins: ServiceMonitors, log levels, GlitchTip config | P1 | Phase 1 |
| TBD | Add health probes to Celery worker deployments | P0 | Phase 4 |
| TBD | Port SaaS PrometheusRules to on-prem chart | P0 | Phase 2 |
| TBD | Port Grafana dashboards to on-prem | P1 | Phase 3 |
| TBD | Create must-gather image for cost-management on-prem | P0 | Phase 4 |
| TBD | Create on-prem debugging playbook | P2 | Phase 4 |
| TBD | Database backup/restore automation | P1 | Phase 4 |
| TBD | Operator observability: Events, Conditions, custom metrics | P1 | Phase 5 |

*(Keys will be filled in after ticket creation)*

---

## Suggested Sequencing for Handoff

### Phase 1 — Quick wins (1 sprint)
Add ServiceMonitors for MASU + Listener + Ingress, expose GlitchTip/Sentry config in values.yaml, enable JSON log format option, fix default log levels (MASU=DEBUG→INFO). These are small chart changes that immediately improve observability.

### Phase 2 — Alerting foundation (1 sprint)
Port 17 directly-applicable SaaS PrometheusRules. Add startup probes. Add infrastructure exporters (postgresql-exporter, redis-exporter).

### Phase 3 — Dashboards (1 sprint)
Adapt 3 SaaS Grafana dashboards for on-prem. Document log aggregation integration.

### Phase 4 — Supportability (1-2 sprints)
Celery worker probes, must-gather image, debugging playbook, database backup automation.

### Phase 5-6 — Operator and resilience (when prioritized)
Operator Events/Conditions/metrics. Upgrade/rollback validation. Capacity alerts. Certificate monitoring. Data freshness metric.

---

## Where Everything Lives

| Artifact | Location |
|----------|----------|
| Gap analysis docs | `cost-onprem-chart/docs/COST-7706/` (this directory) |
| Branch | `mpovolny/COST-7706` in cost-onprem-chart |
| Wiki task (spike) | `wiki/tasks/COST-7706.md` in personal-wki |
| Wiki task (epic) | `wiki/tasks/COST-7543.md` in personal-wki |
| SaaS alerting rules | `app-interface/resources/insights-prod/hccm-prod/hccm.prometheusrules.yaml` |
| SaaS Grafana dashboards | `koku/dashboards/*.configmap.yaml` |
| SaaS runbooks | `app-interface/docs/tenant-services/console.redhat.com/app-sops/hccm/` |
| QE perf observability | `testetson22/cost-onprem-chart` branch `flpath-4061-cop-perf-observability` |
| Google Doc (baseline) | https://docs.google.com/document/d/1dNG_MmUjmY_PeoScUMB-3R2b5RgENh_V5xM3ghPSE_A |
| Google Doc (review) | https://docs.google.com/document/d/1cifnMyjofZqYF7yvOZINOaz5WcDjwnegr4rVJcQc9-0 |
