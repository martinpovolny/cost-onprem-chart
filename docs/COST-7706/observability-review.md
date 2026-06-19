# Adversarial Review — docs/observability.md

**Date:** 2026-06-14
**Scope:** Review of the observability gap analysis document for accuracy,
completeness, actionability, and honest handling of unknowns.

---

## Strengths

- **Honest about unknowns.** The "Open Questions" section and must-gather
  "status unknown" framing are genuinely useful — most audit docs fake
  certainty.
- **SaaS-to-on-prem framing is strong.** Citing concrete app-interface file
  paths and SaaS URLs makes the gap tangible, not abstract.
- **Operator transition context is smart.** The "prefer app-layer investments"
  guidance prevents wasted Helm-specific work.
- **Sources section adds credibility.** Reviewers can verify claims.

---

## Findings

### 1. No owner, timeline, or effort estimate on any work item

**Severity:** High

The document lists 20 work items across P0–P3 with no assignee, no target
sprint, and no effort estimate. Without these, it reads as a wish list rather
than a plan. The acceptance criteria state "Jira issues opened" — but which
of the 20 items actually become Jira issues? All 20? That's unrealistic for
a single sprint or even a quarter.

**Risk:** The document gets acknowledged and filed. Nothing happens because
nobody owns anything and there's no sense of scale.

**Recommendation:**
- Add T-shirt effort estimates (S = hours, M = days, L = weeks) to each item.
- Identify which items are prerequisites for others (e.g., PrometheusRules
  depend on alert threshold research).
- Propose a sequencing: what ships in the first release vs. what can wait for
  the operator migration.
- When creating Jira issues, batch related items (e.g., items 3 + 15 are
  both about alerting/capacity).

---

### 2. Priority tiers (P0–P3) lack justification

**Severity:** Medium

The document assigns priorities but doesn't explain the ranking criteria.
Some assignments seem to reflect implementation ease rather than business
impact:

| Item | Current | Question |
|------|---------|----------|
| 4. Startup probes | P0 | Startup probe restarts are noisy but self-recovering. Is this really "critical for supportability"? |
| 17. Data freshness | P3 | A system where all pods are Ready but no data flows is the *core product failure*. Why is this P3? |
| 5. Database backup | P1 | Data loss with no restore procedure is arguably more critical than missing Grafana dashboards (also P1). |
| 19. Network connectivity checks | P3 | Connectivity failures are the #1 on-prem support issue by volume in most products. Why P3? |

**Risk:** Teams work P0 items first and defer P3 indefinitely. If P3 contains
the items that actually generate support cases, the prioritization is
counterproductive.

**Recommendation:** Define the ranking criteria explicitly. Suggested axes:
- **Support case frequency:** How often does this gap cause a customer to
  file a support case?
- **Time to diagnose without the fix:** How many hours does it take to
  troubleshoot this manually?
- **Blast radius:** Does this affect one component or the entire deployment?
- **Survives operator migration:** Will this work carry over?

Re-rank based on these axes. Data freshness and Kafka observability likely
move up; startup probes and leader election health likely move down.

---

### 3. "What We Already Have" is uncritically positive

**Severity:** Medium

The health check table shows 14 components with probes and presents this as
solid coverage. But several probes are fragile:

**Probes using `/metrics` as a health endpoint (ROS Processor, ROS Poller):**
A Prometheus metrics endpoint returning HTTP 200 means "the HTTP handler is
alive," not "the component is functioning correctly." The ROS Processor could
be wedged on a bad Kruize connection, failing to process any data, and still
serve `/metrics` happily. This is a liveness probe, not a readiness probe —
but it's used for both.

**Kruize using `/listPerformanceProfiles` as a probe:**
This is a functional endpoint backed by a database query. If the DB is slow
(lock contention, vacuum), the probe times out and Kubernetes kills the pod.
This conflates "component health" with "database performance" and can cause
cascading restarts during DB pressure — exactly when you need Kruize most.

**Ingress using `/` as a probe:**
Returns 200 if the HTTP server is up but says nothing about whether upstream
services (Koku API, ROS API) are routable.

**Recommendation:** Add a column to the health check table: "Probe quality"
(strong / adequate / fragile). Flag the fragile probes and consider whether
improving probe quality should be a work item (potentially more impactful
than adding startup probes).

---

### 4. ROS and RBAC components are under-examined

**Severity:** Medium

The koku backend received deep analysis: logging config, Prometheus metrics,
Sentry integration, DB performance tools, Celery task inspection. ROS (Go
services) and RBAC (Django, separate codebase from koku) got surface-level
treatment.

**What we don't know about ROS:**
- What logging framework does ROS use? Is it structured? Are log levels
  configurable via env vars?
- What custom metrics does ROS export beyond the defaults? The doc says
  `/metrics` on :9000 but doesn't list what's in those metrics.
- How are ROS processing errors tracked? If the processor fails to parse
  a report or can't reach Kruize, where does that error go?
- Does ROS have any error tracking integration (Sentry/GlitchTip)?

**What we don't know about RBAC:**
- RBAC has its own Django deployment and worker. Does it share koku's logging
  config or have its own?
- Does RBAC export any Prometheus metrics? There's no RBAC ServiceMonitor
  in the chart.
- The RBAC worker has no health probes (noted in item 1) — but we also
  don't know what the worker does or what failure looks like.

**Risk:** The document implies comprehensive coverage across the stack, but
two of the four application components (ROS, RBAC) were only audited at the
Helm template level, not the application level.

**Recommendation:** Add a TODO to audit ROS and RBAC at the same depth as
koku. This could be a follow-up investigation or a prerequisite before
creating Jira issues for ROS/RBAC-related work items.

---

### 5. No mention of Kafka observability

**Severity:** High

Kafka is a critical dependency: the listener consumes cost reports from it,
sources events flow through it, and Kafka connectivity loss is already a
documented failure mode in `troubleshooting.md`. Despite this, the document
never asks the fundamental question: **what does Kafka observability look
like on-prem?**

The SaaS uses Amazon MSK with managed monitoring, and the app-interface has
dedicated MSK alerts (`hccm-msk.prometheusrules.yaml`) for upload lag and
sources lag. On-prem Kafka is likely Strimzi or AMQ Streams, which have a
completely different monitoring model.

**What's missing:**
- **Consumer lag monitoring:** Is the listener keeping up? Is sources lag
  growing? This is the single most important Kafka metric for this system.
- **Topic health:** Are topics present and properly configured (retention,
  partitions)?
- **Broker connectivity:** Can the listener actually reach the Kafka cluster?
  (Partially covered by item 19, but deserves its own treatment.)
- **Dead-letter topic:** When message processing fails repeatedly, where do
  messages go? Is there a DLT? If not, are failed messages silently dropped?
- **Kafka exporter:** Should the chart ship a Kafka exporter
  (`kafka_exporter`, Strimzi's built-in metrics) or assume the customer
  monitors Kafka separately?

**Risk:** Kafka issues are often the root cause of "no data appearing"
symptoms. Without Kafka observability, diagnosis requires SSH-level access
to the Kafka cluster and knowledge of `kafka-consumer-groups.sh` — exactly
the tribal knowledge the document aims to eliminate.

**Recommendation:** Add Kafka as a first-class observability topic. At
minimum:
- Add a Kafka section to "What We Already Have" (what the listener logs
  about Kafka connectivity and processing).
- Add an open question about Kafka monitoring strategy on-prem.
- Add Kafka consumer lag to the PrometheusRules work item (item 3).
- Add Kafka topic verification to the preflight/connectivity check (item 19).

---

### 6. Database backup item ignores multiple databases

**Severity:** Low

Work item 5 discusses `pg_dump` for the koku database, but the deployment
runs separate databases (or schemas) for:
- **Koku** — cost data, manifests, processing status
- **RBAC** — roles, permissions, policies
- **Kruize** — experiment data, recommendations

The single `pg_dump` command in the installation guide backs up
`costonprem_koku` only. If the RBAC or Kruize databases are lost, the
system is broken even if koku data is restored.

**Recommendation:** Expand item 5 to cover all databases. Clarify whether
they run in the same PostgreSQL instance (single `pg_dumpall`) or separate
instances (separate backup jobs needed). The must-gather bundle (item 2)
should also capture schema metadata for all databases.

---

### 7. No mention of log volume or storage cost

**Severity:** Low

Item 11 recommends enabling structured JSON logging and integrating with
ELK/Loki, but doesn't address the resource implications. The deployment runs
10+ Celery workers, API, MASU, listener, ROS components, and RBAC — each
producing logs. With `KOKU_LOG_LEVEL: DEBUG` (the current MASU default) and
JSON formatting, log volume could be significant.

**Questions the doc should raise:**
- What is the expected log volume at different log levels (INFO vs DEBUG)?
- Should the chart default to DEBUG for MASU in production, or is that a
  development-era setting that was never changed?
- If a customer enables log aggregation, what storage should they budget?
- Are there any high-frequency log lines that should be rate-limited or
  sampled (e.g., per-record processing logs in Celery workers)?

**Recommendation:** Add a note to item 11 about log volume implications.
Consider whether the default log levels in values.yaml are appropriate for
production on-prem (DEBUG for MASU seems aggressive).

---

### 8. Helm-to-operator transition undermines several work items

**Severity:** Medium

The context section correctly advises "prefer app-layer investments over
Helm-specific tooling." But then P3 contains several explicitly Helm-specific
items:

| Item | Helm-specific? |
|------|---------------|
| 14. Upgrade/rollback observability | Yes — Helm hooks, `helm rollback` |
| 19. Network preflight check | Partially — "Helm hook" suggested |
| 20. Version drift detection | Partially — "Helm release" comparison |

If the operator replaces Helm within 6–12 months, these items are throwaway
work. If the operator timeline is 18+ months, they're worth doing.

**The document doesn't state the operator timeline**, so the reader can't
make this judgment.

**Recommendation:**
- Add the expected operator timeline to the Context section (even if
  approximate: "H2 2026" vs "2027+").
- Tag Helm-specific items with a note: "Skip if operator ships within
  N months."
- For items like preflight checks and version drift, frame the work in
  terms of the operator (where it becomes status conditions and
  reconciliation logic) with a Helm interim solution noted as optional.

---

### 9. SaaS internal URLs may become stale or access-restricted

**Severity:** Informational

The document includes ~10 internal Red Hat URLs (Grafana, Kibana, Prometheus,
GlitchTip, GitLab runbooks). These are useful today for the team
investigating these gaps, but:
- Internal URLs change when infrastructure is migrated
- Access may be restricted (not all team members can reach all URLs)
- A committed doc with internal URLs can leak infrastructure details if the
  repo becomes public

**Recommendation:** This is acceptable for a working document. If the doc
evolves into customer-facing documentation, strip internal URLs. Consider
adding an "Internal references — may require VPN/access" header to the
external references section.

---

### 10. No mention of multi-tenancy or user action audit logging

**Severity:** Medium

On-prem deployments may serve multiple teams within an organization. The
document covers infrastructure observability thoroughly but ignores
application-level audit logging:

- **Who accessed what cost data?** Django request logs exist but aren't
  structured for audit queries.
- **Who changed cost models or rate settings?** No audit trail for
  configuration changes.
- **Who created/deleted sources?** Sources CRUD is logged but not in an
  auditable format.
- **RBAC permission changes:** Who granted/revoked roles? The RBAC service
  likely logs this, but it's not called out.

The SaaS handles this partially via the 3scale gateway (which logs all API
requests with identity headers) and CloudWatch. On-prem has neither.

For regulated industries (finance, healthcare, government), audit logging
may be a hard compliance requirement for deploying cost-management.

**Recommendation:** Add an open question: "Does on-prem need audit logging
for compliance?" If yes, this becomes a P1 work item: structured audit
events for sensitive operations (data access, configuration changes,
permission changes) with a retention and export mechanism.

---

## Summary

| # | Finding | Severity | Action |
|---|---------|----------|--------|
| 1 | No owner/timeline/effort on work items | High | Add T-shirt sizes, sequencing |
| 2 | Priority tiers lack justification | Medium | Define ranking criteria, re-rank |
| 3 | Health check table uncritically positive | Medium | Add probe quality assessment |
| 4 | ROS and RBAC under-examined | Medium | TODO: audit at app level |
| 5 | Kafka observability missing entirely | High | Add as first-class topic |
| 6 | Database backup ignores multiple DBs | Low | Expand item 5 scope |
| 7 | Log volume not addressed | Low | Add sizing note to item 11 |
| 8 | Helm-specific items vs operator timeline | Medium | Add timeline, tag conditional items |
| 9 | Internal URLs may rot | Informational | Acceptable for working doc |
| 10 | No audit logging for user actions | Medium | Add open question for compliance |

### Overall assessment

The document is a strong gap analysis — better than most first-pass audits.
Its main weakness is that it's an inventory of gaps, not yet an execution
plan. Adding effort estimates, explicit priority criteria, and the two
missing topics (Kafka, audit logging) would make it actionable.
