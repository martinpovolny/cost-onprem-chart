# TODO / Known Issues

## `deploy-to-crc.sh` — VALUES_EXTRA supports only one extra overlay

`scripts/deploy-to-crc.sh` passes values to `install-helm-chart.sh` via a single
`VALUES_EXTRA` env var:

```bash
local helm_args=(-f "${REPO_ROOT}/cost-onprem/values-crc.yaml")
[ -n "$VALUES_EXTRA" ] && helm_args+=(-f "$VALUES_EXTRA")
```

On arm64 the default is `VALUES_EXTRA=values-crc-arm64.yaml`. Setting `VALUES_EXTRA`
to a different file (e.g. `values-crc-dev.yaml`) silently drops the arm64 image
override, causing the migration job to segfault under QEMU.

`install-helm-chart.sh` already supports multiple `-f` flags (accumulates into a
`VALUES_FILES` array), so the fix is straightforward: replace the single `VALUES_EXTRA`
with an array or a space-separated list, e.g.:

```bash
# Proposed change in deploy-to-crc.sh
VALUES_EXTRAS=("${REPO_ROOT}/cost-onprem/values-crc-arm64.yaml")
# Caller can append: VALUES_EXTRAS+=("${REPO_ROOT}/cost-onprem/values-crc-dev.yaml")

for f in "${VALUES_EXTRAS[@]}"; do
    [ -n "$f" ] && helm_args+=(-f "$f")
done
```

**Workaround:** call `install-helm-chart.sh` directly with all `-f` flags:

```bash
USE_LOCAL_CHART=true SKIP_S3_SETUP=true \
  scripts/install-helm-chart.sh \
    -f cost-onprem/values-crc.yaml \
    -f cost-onprem/values-crc-arm64.yaml \
    -f cost-onprem/values-crc-dev.yaml
```
