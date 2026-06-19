# Logging and Error Tracking — SaaS vs On-Prem

## Purpose

Document the current state of logging, structured error output, and
exception tracking (GlitchTip/Sentry) across the cost-onprem stack.
Identify what works on-prem today, what is disabled, and what gaps exist.

---

## Logging Architecture (koku)

Koku uses Python's `logging` module with Django integration. The
configuration lives in `koku/koku/settings.py` (LOGGING dict).

### Formatters

Two formatters available, selected via `DJANGO_LOG_FORMATTER` env var:

| Formatter | Pattern | Use Case |
|-----------|---------|----------|
| `simple` (default) | `[%(asctime)s] %(levelname)s %(task_root_id)s %(task_parent_id)s %(task_id)s %(process)d %(message)s` | Production |
| `verbose` | `%(levelname)s %(asctime)s %(module)s %(process)d %(thread)d %(task_id)s %(task_parent_id)s %(task_root_id)s %(message)s` | Debugging |

Both use `TaskFormatter` (`koku/koku/log.py`) which extends Celery's
`ColorFormatter` to inject task context into every log line:
- `task_id` — current Celery task UUID
- `task_name` — task function name
- `task_root_id` — root of the task chain
- `task_parent_id` — parent task in the chain

When not running inside a Celery task, all four fields default to `"None"`.

### Handlers

| Handler | Type | When Active | Notes |
|---------|------|-------------|-------|
| `console` | StreamHandler (stdout) | Always (default) | Container-friendly |
| `file` | FileHandler | If configured via `LOG_DIRECTORY` | Writes to `app.log` |
| `watchtower` | CloudWatchLogHandler | If `CW_AWS_ACCESS_KEY_ID` is set | SaaS only |
| `celery` | StreamHandler | Celery workers | Same as console |

Selected via `DJANGO_LOG_HANDLERS` (comma-separated, default: `"console"`).

### Loggers (18 configured)

| Logger | Default Level | Propagate | Notes |
|--------|--------------|-----------|-------|
| `gunicorn.access` | via handler | Yes | HTTP access logs |
| `gunicorn.error` | via handler | Yes | Gunicorn errors |
| `django` | `DJANGO_LOG_LEVEL` | Yes | Django framework |
| `api` | `KOKU_LOG_LEVEL` | Yes | API application |
| `celery` | via handler | **No** | Celery tasks |
| `cost_models` | `KOKU_LOG_LEVEL` | Yes | Cost model processing |
| `forecast` | `KOKU_LOG_LEVEL` | Yes | Forecasting |
| `hcs` | `KOKU_LOG_LEVEL` | Yes | Hybrid Cloud Service |
| `kafka_utils` | `KOKU_LOG_LEVEL` | Yes | Kafka integration |
| `koku` | `KOKU_LOG_LEVEL` | Yes | Main application |
| `providers` | `KOKU_LOG_LEVEL` | Yes | Cloud providers |
| `reporting` | `KOKU_LOG_LEVEL` | Yes | Reporting |
| `reporting_common` | `KOKU_LOG_LEVEL` | Yes | Common reporting |
| `masu` | `KOKU_LOG_LEVEL` | **No** | Data ingestion |
| `sources` | `KOKU_LOG_LEVEL` | Yes | Sources service |
| `subs` | `KOKU_LOG_LEVEL` | Yes | Subscriptions |
| `UnleashClient` | `UNLEASH_LOG_LEVEL` | Yes | Feature flags |
| `apscheduler` | WARNING | Yes | Scheduled jobs |

### Structured Logging — `log_json()`

Defined in `koku/api/common/__init__.py`. Used 563+ times across the
codebase. Produces structured JSON-compatible output:

```python
LOG.info(log_json(
    tracing_id=request_id,
    msg="Processing report",
    schema=self.schema,
    provider_uuid=uuid,
    manifest_id=manifest.id
))
```

Fields commonly included: `tracing_id`, `schema`, `provider_uuid`,
`manifest_id`, `table_name`, `running_time`, `row_count`, `log_ref`,
`cost_type`.

**On-prem gap:** `tracing_id` is available but not auto-populated from
request headers (e.g., `X-Request-ID`). Correlation across services requires
manual passing.

---

## Per-Component Log Configuration (on-prem chart)

All configured in `values.yaml`. Log output goes to stdout (container logs).

| Component | Log Level Env Vars | Defaults | Format |
|-----------|-------------------|----------|--------|
| **Koku API** | `GUNICORN_LOG_LEVEL`, `KOKU_LOG_LEVEL`, `DJANGO_LOG_LEVEL` | INFO, INFO, INFO | plain text (simple) |
| **MASU** | `KOKU_LOG_LEVEL`, `DJANGO_LOG_LEVEL` | **DEBUG**, INFO | plain text |
| **Listener** | `KOKU_LOG_LEVEL`, `DJANGO_LOG_LEVEL` | INFO, INFO | plain text |
| **Celery Beat** | `KOKU_LOG_LEVEL`, `DJANGO_LOG_LEVEL` | INFO, INFO | plain text |
| **Celery Workers** | `CELERY_LOG_LEVEL` | info (hardcoded in cmd) | Celery default |
| **ROS API** | `LOG_LEVEL` | INFO | app default |
| **ROS Processor** | `LOG_LEVEL` | INFO | app default |
| **ROS Poller** | `LOG_LEVEL` | INFO | app default |
| **ROS Housekeeper** | `LOG_LEVEL` | INFO | app default |
| **RBAC API** | `DJANGO_LOG_LEVEL`, `RBAC_LOG_LEVEL` | INFO, INFO | plain text |
| **RBAC Worker** | (hardcoded) | info | Celery default |
| **Kruize** | `LOGGING_LEVEL`, `ROOT_LOGGING_LEVEL` | **debug**, error | Java logging |
| **Ingress** | `INGRESS_LOGLEVEL` | INFO | Go default |
| **Gateway (Envoy)** | `--log-level` | info | **JSON** (structured access logs) |

### SaaS Defaults (app-interface koku-logging.configmap.yml)

```yaml
django-log-level: INFO
koku-log-level: INFO
masu-log-level: INFO
django-log-formatter: simple
django-log-handlers: console
```

### On-Prem vs SaaS Log Level Differences

| Component | SaaS | On-Prem | Note |
|-----------|------|---------|------|
| MASU | INFO | **DEBUG** | On-prem has elevated log level — likely a dev-era default |
| Kruize | (unknown) | **debug** | Full HTTP req/resp logging enabled — verbose |
| All others | INFO | INFO | Match |

**Recommendation:** MASU and Kruize defaults should be reviewed. DEBUG in
production generates high log volume with minimal operational benefit.

---

## Error Tracking — GlitchTip / Sentry

### How It Works (koku)

The integration lives in `koku/koku/sentry.py`:

```python
sentry_sdk.init(
    dsn=KOKU_SENTRY_DSN,
    environment=KOKU_SENTRY_ENVIRONMENT,
    traces_sampler=traces_sampler
)
```

**Traces sampler:** 5% default sampling rate. Blocked endpoints (0% sampling):
- `/api/cost-management/v1/status/`
- `/api/cost-management/v1/source-status/`

**What gets captured:**
- Unhandled exceptions (automatic)
- Performance traces (5% of requests)
- Celery task failures (via Sentry's Celery integration)
- Full stack traces with local variables

**Environment variables:**
| Var | Purpose | On-Prem Default |
|-----|---------|-----------------|
| `KOKU_ENABLE_SENTRY` | Toggle | `"False"` (disabled) |
| `KOKU_SENTRY_DSN` | Endpoint URL | Not set |
| `KOKU_SENTRY_ENVIRONMENT` | Environment tag | Not set |

### SaaS Setup

- **Backend:** GlitchTip at https://glitchtip.devshift.net/
- **DSN:** Stored in Kubernetes secret (`GLITCHTIP_SECRET_NAME`)
- **Coverage:** Injected into ALL koku components (API, MASU, listener,
  every Celery worker) via `deploy/clowdapp.yaml`
- **Alert flow:** GlitchTip exceptions → Slack channel → engineer triage

### On-Prem Status

**Completely disabled.** The chart sets `KOKU_ENABLE_SENTRY: "False"` and
does not expose DSN configuration in values.yaml. On-prem customers have:
- No exception aggregation
- No stack trace collection
- No error rate trending
- No performance tracing

Errors are only visible in pod logs (ephemeral, no aggregation).

### What GlitchTip Would Provide On-Prem

GlitchTip is open-source and self-hostable. If enabled, customers would get:
- **Exception grouping:** Deduplicated stack traces with occurrence counts
- **Error trends:** Rate of new vs recurring errors over time
- **Performance tracing:** Request duration breakdown (5% sampled)
- **Release tracking:** Errors correlated with deployed versions
- **Alerting:** Email/webhook notifications on new error types

---

## Celery Error Handling

### LogErrorsTask (`koku/koku/celery.py`)

All koku Celery tasks inherit from `LogErrorsTask`:

```python
class LogErrorsTask(Task):
    def on_failure(self, exc, task_id, args, kwargs, einfo):
        if fk_violation := FKViolation(exc):
            LOG.warning("task failed: %s", fk_violation)
        else:
            LOG.exception("Task failed: %s", exc, exc_info=exc)
```

- FK violations logged as warnings (expected under concurrent processing)
- All other failures logged with full traceback via `LOG.exception()`

### Retry Configuration

Tasks use Celery's built-in retry mechanism:
- `autoretry_for`: Exception types that trigger retry
- `max_retries`: Default 5 (`MAX_UPDATE_RETRIES` in settings)
- `retry_backoff`: Exponential backoff enabled
- `retry_backoff_max`: 600 seconds
- `retry_jitter`: Randomized delay to prevent thundering herd

### Dead-Letter Handling

**None.** After `max_retries` exhausted, failed tasks are logged and
abandoned. There is no dead-letter queue, no persistent failure record
beyond logs, and no mechanism to replay failed tasks.

**On-prem impact:** A task that fails after 5 retries disappears silently.
The only evidence is log lines — which are ephemeral in a container
environment without log aggregation.

---

## API Error Formatting

### custom_exception_handler (`koku/api/common/exception_handler.py`)

Registered as Django REST Framework's `DEFAULT_EXCEPTION_HANDLER`. Produces
structured error responses:

```json
{
    "errors": [
        {
            "detail": "Provider not found",
            "source": "provider.uuid",
            "status": 404
        }
    ]
}
```

Handles nested validation errors by building hierarchical `source` paths
(e.g., `"cost_model.rates.0.tiered_rates"`).

---

## Gaps and Work Items

### 1. No error tracking on-prem (GlitchTip disabled)

Expose Sentry/GlitchTip config in values.yaml:
```yaml
errorTracking:
  enabled: false
  dsn: ""
  environment: "production"
  tracesSampleRate: 0.05
```
Wire into all koku deployment templates. Document GlitchTip self-hosting.

### 2. No structured JSON log format by default

The chart defaults to plain text (`simple` formatter). For log aggregation
(ELK, Loki), JSON output is strongly preferred.

Work: Add `DJANGO_LOG_FORMATTER: json` option in values.yaml. Koku's
`log_json()` already produces structured output — but the log line itself
is still wrapped in the plain-text formatter. A proper JSON formatter would
make every log line machine-parseable.

### 3. MASU and Kruize default to DEBUG

MASU defaults to `KOKU_LOG_LEVEL: DEBUG` and Kruize defaults to
`LOGGING_LEVEL: debug` with `logAllHttpReqAndResponse: true`. This
generates excessive log volume in production with no operational benefit.

Work: Change defaults to INFO. Document how to temporarily enable DEBUG
for troubleshooting.

### 4. No log aggregation guidance

On-prem customers have no documentation on how to ship logs to a
centralized system. Container logs are ephemeral.

Work: Document integration patterns:
- OpenShift Logging (ClusterLogging operator → Loki/Elasticsearch)
- Sidecar-based shipping (Fluentd/Fluent Bit)
- JSON format + `kubectl logs` piped to external tools

### 5. No dead-letter queue for failed Celery tasks

After max retries, tasks are logged and lost. No mechanism to inspect,
replay, or alert on permanently failed tasks.

Work: Evaluate options:
- Celery result backend with failure tracking
- Prometheus counter for permanently-failed tasks (currently only
  `celery_errors` counts all errors, not terminal failures)
- Custom DLQ topic in Kafka for failed task metadata

### 6. No correlation ID propagation

`tracing_id` field exists in `log_json()` but is not auto-populated from
HTTP request headers. Tracing a request across API → Celery → MASU → DB
requires manual log searching.

Work: Add middleware to extract `X-Request-ID` (or generate one) and
propagate it through the Celery task chain. This is an application-level
change in koku, not a chart change.

### 7. ROS and RBAC logging depth unknown

ROS services use `LOG_LEVEL` env var but we haven't audited their
application-level logging patterns. Do they use structured logging? Do
they integrate with Sentry? What error handling patterns do they use?

Work: Audit ROS (Go) and RBAC (Django) logging at the application level.

### 8. Envoy gateway is the only component with JSON logs

The Envoy access log format includes structured fields (method, path,
status, duration, upstream_host, request_id). All other components use
plain text. This inconsistency makes unified log parsing difficult.

---

## Summary

| Area | SaaS | On-Prem | Gap |
|------|------|---------|-----|
| Log format | Plain text (simple) | Plain text (simple) | No JSON option exposed |
| Log aggregation | Kibana (5d stage, 15d prod) | None (container logs only) | No guidance or tooling |
| Error tracking | GlitchTip (all components) | Disabled | DSN not configurable |
| Stack traces | GlitchTip + Sentry SDK | Pod logs only | Lost on pod restart |
| Celery errors | GlitchTip + LOG.exception | LOG.exception only | No aggregation |
| Dead-letter queue | None (same gap) | None | Failed tasks lost |
| Correlation IDs | Partial (tracing_id) | Partial (tracing_id) | Not auto-populated |
| Log levels | INFO everywhere | MASU=DEBUG, Kruize=debug | Over-verbose defaults |
| Structured logging | `log_json()` (563+ uses) | Same (inherited) | Formatter wraps in plain text |

## Sources

| Source | What we examined |
|--------|-----------------|
| `koku/koku/settings.py` | LOGGING dict, handlers, formatters, loggers, CloudWatch config |
| `koku/koku/log.py` | TaskFormatter, TaskRootLogging |
| `koku/koku/sentry.py` | GlitchTip/Sentry init, traces sampler, block list |
| `koku/koku/celery.py` | LogErrorsTask, retry config, LoggingCelery |
| `koku/api/common/__init__.py` | log_json() function |
| `koku/api/common/exception_handler.py` | custom_exception_handler |
| `cost-onprem-chart/cost-onprem/values.yaml` | Per-component log level defaults |
| `app-interface/.../koku-logging.configmap.yml` | SaaS logging defaults |
| `koku/deploy/clowdapp.yaml` | GLITCHTIP_SECRET_NAME references |
