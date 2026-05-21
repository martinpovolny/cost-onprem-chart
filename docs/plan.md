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
- Gunicorn: 2 workers on koku-api and masu (raised from 1 — see gateway 503 section below)
- ROS: disabled
- Monitoring: disabled
- PVC sizes reduced (cosmetic on CRC — hostpath provisioner always gives 99Gi)

## Current status (2026-05-21)

### ARM64

- Full `crc-wipe` → `crc-deploy-arm64-dev` cycle verified working end-to-end
- `make crc-test` result: **167 passed, 12 failed, 17 skipped** (196 selected from 267 total)

### AMD64 (foobar, 2026-05-21)

- Full `crc-wipe` → `crc-deploy-amd64-dev` cycle verified working end-to-end
- `make crc-test` result: **171 passed, 12 failed, 13 skipped** (196 selected from 267 total)
- AMD64 passes 4 more tests than ARM64 (ROS is enabled by default on amd64, but
  `ros.enabled=false` in the dev overlay means those pods still don't run — the extra
  passes likely come from timing differences)

## Known test failures (12, both arches)

### ROS pods not running (5 failures) — test gap, not a bug

Tests check for `ros-api` and `ros-processor` pods but are not marked
`@pytest.mark.ros`, so `--no-ros` does not skip them. With `ros.enabled=false` in
the dev overlay these pods don't exist and the tests fail.

Affected tests:
- `suites/helm/test_deployment.py::TestDeploymentHealth::test_ros_api_pod_ready`
- `suites/helm/test_deployment.py::TestDeploymentHealth::test_ros_processor_pod_ready`
- `suites/e2e/test_smoke.py::TestE2ESmoke::test_all_critical_pods_running`
- `suites/e2e/test_complete_flow.py::TestCompleteDataFlow::test_07_kruize_experiments_created`
- `suites/e2e/test_complete_flow.py::TestCompleteDataFlow::test_09_recommendations_accessible_via_api`

**Fix needed:** add `@pytest.mark.ros` to these tests so `--no-ros` skips them.

### Gateway timeouts / 503 (7 failures) — needs investigation

External-route requests timeout or get 503 during the test run. Internal-route tests
(same endpoints, direct pod access) pass. Raising `GUNICORN_WORKERS` from 1 to 2
eliminated the cascading cost_validation errors (which failed because gateway 503s
silently broke pre-test source cleanup) but did not fix these 7 direct failures.

Affected tests:
- `suites/e2e/test_smoke.py::TestE2ESmoke::test_gateway_accepts_authenticated_requests`
- `suites/e2e/test_smoke.py::TestE2ESmoke::test_backend_api_accessible`
- `suites/sources/test_sources_api.py::TestSourcesExternalHealth::test_sources_endpoint_accessible_via_gateway`
- `suites/sources/test_sources_api.py::TestSourcesExternalSourceTypes::test_sources_endpoint_returns_source_type_info`
- `suites/sources/test_sources_api.py::TestSourcesExternalCRUD::test_create_and_delete_source_via_gateway`
- `suites/sources/test_sources_api.py::TestSourcesExternalCRUD::test_get_nonexistent_source_returns_404`
- `suites/sources/test_sources_api.py::TestSourcesExternalFiltering::test_filter_sources_by_source_type`

**To investigate:** are these tests hitting a slow first-request cold-start on the
sources endpoint, or is the gateway legitimately overloaded even with 2 workers?
Check if the failures are consistent across runs or intermittent.

## Remaining work

- [x] Run `crc-wipe` → `crc-deploy-amd64-dev` → `crc-test` on an AMD64 host
- [ ] Add `@pytest.mark.ros` to the 5 ROS-adjacent tests listed above
- [ ] Investigate the 7 gateway 503 failures (sources + e2e external-route tests)
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
