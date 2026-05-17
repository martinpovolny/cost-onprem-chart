# CRC Dev Deployment Plan

**Goal:** Deploy cost-onprem to a local CRC (CodeReady Containers) cluster on both
ARM64 (Apple Silicon) and AMD64 (x86_64), repeatably, with a passing test suite.

## Quick reference

```
make crc-wipe               # full teardown (kafka, keycloak, cost-onprem namespaces)
make crc-deploy-arm64-dev   # full deploy on Apple Silicon + dev overlay
make crc-deploy-amd64-dev   # full deploy on x86_64 + dev overlay
make crc-redeploy-dev       # reinstall chart only (keep infra)
make crc-test               # run tests (no ROS, no UI)
```

## Architecture differences

| | ARM64 (Apple Silicon) | AMD64 (x86_64) |
|---|---|---|
| Keycloak operator | community (no RHBK arm64 image) | rhbk |
| koku image | `quay.io/martin_povolny/koku:latest` (native arm64 build) | chart default |
| ROS | disabled (`ros.enabled: false`) — no arm64 image | enabled |
| Extra values | `values-crc-arm64.yaml` + `values-crc-dev.yaml` | `values-crc-dev.yaml` only |

## Values file layering

```
values.yaml          (chart defaults)
  └─ values-crc.yaml           (CRC resource overrides, both arches)
       └─ values-crc-arm64.yaml   (arm64 image + ROS override, arm64 only)
            └─ values-crc-dev.yaml   (dev overlay: 1 gunicorn worker, 1 celery worker, ROS off)
```

## Dev overlay (`values-crc-dev.yaml`) effects

- Celery: 5 workers consolidated into 1 (all queues merged), replicas 0 for priority/ocp/summary/costModel
- Gunicorn: 1 worker on koku-api and masu (vs default 2+)
- ROS: disabled
- Monitoring: disabled
- PVC sizes reduced (cosmetic on CRC — hostpath provisioner always gives 99Gi)

## Current status (2026-05-17)

### ARM64

- Full `crc-wipe` → `crc-deploy-arm64-dev` cycle verified working end-to-end
- `make crc-test` result: **167 passed, 12 failed, 17 skipped** (196 selected from 267 total)

### AMD64

- Makefile target and script support is in place (`make crc-deploy-amd64-dev`)
- Not yet tested end-to-end — needs a run on an AMD64 CRC host

## Known test failures

### ROS pods not running (5 failures) — test gap, not a bug

Tests in `helm/test_deployment.py` and `e2e/test_smoke.py` check for `ros-api` and
`ros-processor` pods but are not marked `@pytest.mark.ros`, so `-m "not ros"` does
not skip them. When `ros.enabled=false` these pods don't exist and the tests fail.

Affected tests:
- `TestDeploymentHealth::test_ros_api_pod_ready`
- `TestDeploymentHealth::test_ros_processor_pod_ready`
- `TestE2ESmoke::test_all_critical_pods_running`
- `TestCompleteDataFlow::test_07_kruize_experiments_created` (depends on ROS events)
- `TestCompleteDataFlow::test_09_recommendations_accessible_via_api`

**Fix needed:** add `@pytest.mark.ros` to these tests so `--no-ros` skips them.

### Gateway timeouts / 503 (7 failures) — likely dev-overlay side effect

External-route requests timeout or get 503 from the gateway during the test run.
Internal-route tests (same endpoints, direct pod access) pass. The gateway health
check in `install-helm-chart.sh` also passes. Hypothesis: with `GUNICORN_WORKERS=1`,
a slow request blocks all others, causing downstream timeouts for the gateway's
upstream health check.

Affected tests (all `TestSourcesExternal*`, `TestE2ESmoke::test_gateway_*` and `test_backend_api_*`).

**Options:**
- Raise `GUNICORN_WORKERS` to 2 in the dev overlay (trades memory for reliability)
- Investigate if specific endpoints are slow (sources list on first hit?)

## Remaining work

- [ ] Run `crc-wipe` → `crc-deploy-amd64-dev` → `crc-test` on an AMD64 host
- [ ] Add `@pytest.mark.ros` to the 5 ROS-adjacent tests listed above
- [ ] Investigate gateway 503 / decide on GUNICORN_WORKERS in dev overlay
- [ ] Update Makefile header comment (tracked in `TODO.md`)
- [ ] Refresh ingress image tag in `values-crc-arm64.yaml` before it expires

## CRC prerequisites (one-time setup)

```bash
crc config set enable-cluster-monitoring true
crc config set memory 18000
crc config set cpus 8
crc config set disk-size 100
crc setup && crc start -p ~/.crc-secret.json
```

See `plan-test-deploy-to-crc.txt` for the full historical log of decisions and fixes.
