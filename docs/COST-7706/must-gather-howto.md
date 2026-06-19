# Must-Gather — How It Works

Reference material for building a custom must-gather image for
cost-management on-prem.

---

## Flow

1. You run `oc adm must-gather --image=<your-image>`
2. OpenShift creates a **new pod** in a temporary project on the cluster
3. The pod runs your image, which executes `/usr/bin/gather` (the entry point)
4. The `gather` script uses `oc` commands to collect data into `/must-gather/`
5. When the script finishes, `oc adm must-gather` **rsyncs** the
   `/must-gather/` directory from the pod to your local machine
6. The pod is cleaned up

## What Your Custom Image Needs

- A `gather` bash script as the entry point at `/usr/bin/gather`
- The `oc` CLI binary (copied from `origin-cli` builder image)
- Standard unix tools (`tar`, `rsync`, `gzip`)
- Your collection logic — typically `oc get`, `oc logs`, `oc adm inspect`

## Dockerfile Pattern

From the [NFD operator](https://github.com/openshift/cluster-nfd-operator/blob/master/Dockerfile.must-gather):

```dockerfile
FROM quay.io/openshift/origin-cli:4.20 as builder
FROM registry.access.redhat.com/ubi9/ubi-minimal:9.4

RUN microdnf install -y tar rsync findutils gzip
COPY --from=builder /usr/bin/oc /usr/bin/oc
COPY must-gather/* /usr/bin/

CMD ["/usr/bin/gather"]
```

Multi-stage build: `origin-cli` provides `oc`, UBI-minimal provides the
base. Your scripts go into `/usr/bin/`.

## Example `gather` Script for Cost Management

```bash
#!/bin/bash
set -euo pipefail

BASE_DIR="${1:-/must-gather}"
NAMESPACE="${NAMESPACE:-cost-onprem}"

mkdir -p "$BASE_DIR/logs" "$BASE_DIR/resources" "$BASE_DIR/db"

echo "Collecting namespace resources..."
oc adm inspect "ns/$NAMESPACE" --dest-dir="$BASE_DIR/resources" &

echo "Collecting CostManagementMetricsConfig CRs..."
oc get costmanagementmetricsconfig -A -o yaml \
  > "$BASE_DIR/resources/cr-status.yaml" 2>/dev/null &

echo "Collecting Helm release info..."
oc get secret -n "$NAMESPACE" \
  -l owner=helm -o yaml \
  > "$BASE_DIR/resources/helm-releases.yaml" 2>/dev/null &

echo "Collecting events..."
oc get events -n "$NAMESPACE" \
  --sort-by='.lastTimestamp' \
  > "$BASE_DIR/resources/events.txt" 2>/dev/null &

echo "Collecting pod logs..."
for pod in $(oc get pods -n "$NAMESPACE" -o name 2>/dev/null); do
  name=$(basename "$pod")
  oc logs -n "$NAMESPACE" "$pod" --all-containers --tail=1000 \
    > "$BASE_DIR/logs/${name}.log" 2>/dev/null &
  oc logs -n "$NAMESPACE" "$pod" --all-containers --previous --tail=1000 \
    > "$BASE_DIR/logs/${name}-previous.log" 2>/dev/null &
done

echo "Collecting DB connection stats..."
DB_POD=$(oc get pods -n "$NAMESPACE" \
  -l app.kubernetes.io/component=database \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$DB_POD" ]; then
  oc exec -n "$NAMESPACE" "$DB_POD" -- \
    psql -U koku -d costonprem_koku -c \
    "SELECT * FROM pg_stat_activity WHERE state != 'idle'" \
    > "$BASE_DIR/db/pg_stat_activity.txt" 2>/dev/null &
  oc exec -n "$NAMESPACE" "$DB_POD" -- \
    psql -U koku -d costonprem_koku -c \
    "SELECT * FROM pg_stat_database WHERE datname = 'costonprem_koku'" \
    > "$BASE_DIR/db/pg_stat_database.txt" 2>/dev/null &
fi

echo "Collecting Celery queue lengths..."
API_POD=$(oc get pods -n "$NAMESPACE" \
  -l app.kubernetes.io/component=api \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$API_POD" ]; then
  oc exec -n "$NAMESPACE" "$API_POD" -- \
    curl -s http://localhost:9000/metrics \
    > "$BASE_DIR/resources/prometheus-metrics.txt" 2>/dev/null &
fi

echo "Collecting Prometheus metric snapshot (if accessible)..."
oc get --raw /api/v1/namespaces/"$NAMESPACE"/pods \
  > "$BASE_DIR/resources/pods-api.json" 2>/dev/null &

# Wait for all background jobs
echo "Waiting for collection to complete..."
wait

echo "Must-gather collection complete."
sync
```

## Design Principles

- Scripts run **inside the cluster** as a pod with `cluster-admin` privileges
- **Parallel collection** is encouraged (background jobs + `wait`)
- **Maximize collection** — don't fail the whole gather if one part errors
  (use `2>/dev/null` and `&` liberally)
- Each operator owns its own must-gather image and scripts
- Output goes under `/must-gather/` which gets rsynced to the user's machine

## Usage

```bash
# Run with custom image
oc adm must-gather --image=<registry>/cost-onprem-must-gather:<tag>

# Save to specific directory
oc adm must-gather --image=<registry>/cost-onprem-must-gather:<tag> \
  --dest-dir=./cost-mgmt-diagnostics

# Combine with base must-gather
oc adm must-gather \
  --image=<registry>/cost-onprem-must-gather:<tag> \
  --image=quay.io/openshift/origin-must-gather:latest
```

## Real-World Examples

| Operator | Image | Repo |
|----------|-------|------|
| NFD | `origin-nfd-must-gather` | [cluster-nfd-operator](https://github.com/openshift/cluster-nfd-operator/blob/master/Dockerfile.must-gather) |
| Local Storage | `origin-local-storage-mustgather` | [local-storage-operator](https://github.com/openshift/local-storage-operator/blob/main/docs/must-gather.md) |
| ODF | `odf-must-gather-rhel9` | [odf-must-gather](https://github.com/red-hat-storage/odf-must-gather) |
| KubeVirt | `must-gather` | [kubevirt/must-gather](https://github.com/kubevirt/must-gather) |
| OpenStack | `openstack-must-gather` | [openstack-must-gather](https://github.com/openstack-k8s-operators/openstack-must-gather) |
| Pipelines | `must-gather` | [openshift-pipelines/must-gather](https://github.com/openshift-pipelines/must-gather) |
| GitOps | `must-gather-rhel8` | [gitops-must-gather](https://github.com/redhat-developer/gitops-must-gather) |

## References

- [openshift/must-gather](https://github.com/openshift/must-gather) — reference implementation
- [collection-scripts/](https://github.com/openshift/must-gather/tree/main/collection-scripts) — script directory
- [gather entry point](https://github.com/openshift/must-gather/blob/main/collection-scripts/gather) — main script
- [OpenShift docs: gathering cluster data](https://docs.redhat.com/en/documentation/openshift_container_platform/4.10/html/support/gathering-cluster-data)
- [Must-gather operator blog post](https://www.redhat.com/en/blog/simplifying-openshift-case-information-gathering-workflow-must-gather-operator) — automated collection + upload to support cases
