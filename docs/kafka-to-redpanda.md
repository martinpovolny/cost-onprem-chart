# Replace Kafka (AMQ Streams) with Redpanda

## Why

AMQ Streams is the heaviest infrastructure dependency in this chart that is not directly
tied to the cost management application logic. It requires:

- An OLM-based operator (strimzi / AMQ Streams) — installs CRDs, cluster-scoped RBAC, operator pod
- A KRaft controller quorum (3 pods in production, 1+ in dev)
- Broker pods (1+ in dev)
- A readiness polling loop before the cluster is usable

On a CRC dev cluster this takes 5–10 minutes to deploy and consumes ~1.5–2GB of RAM
for what is essentially a message bus carrying a handful of low-throughput topics.

Redpanda is wire-compatible with the Kafka protocol (same `confluent_kafka` client,
same bootstrap server format, same topic/consumer-group semantics). **No changes to
koku source code are needed.**

---

## What changes

| | AMQ Streams (current) | Redpanda (proposed) |
|---|---|---|
| Operator | AMQ Streams / Strimzi (OLM) | None |
| CRDs | Kafka, KafkaTopic, KafkaUser, ... | None |
| Pods (dev/CRC) | operator + 1 controller + 1 broker = 3 pods | 1 pod |
| RAM requests (dev) | ~1.5–2 GB | ~256 MB |
| Deploy time (CRC) | 5–10 min | < 1 min |
| Topic creation | KafkaTopic CRs or auto-create | auto-create (enabled by default) |
| Bootstrap server | `cost-onprem-kafka-kafka-bootstrap.kafka.svc.cluster.local:9092` | `redpanda.kafka.svc.cluster.local:9092` |
| Client library | `confluent_kafka` (unchanged) | `confluent_kafka` (unchanged) |
| koku code changes | — | None |
| Chart env var change | `INSIGHTS_KAFKA_HOST/PORT` | Same vars, different value |

---

## Savings on CRC

- **~1.5 GB RAM freed** — operator + controller + broker currently consume most of the
  headroom between Keycloak+Kafka and the 18 GB node limit
- **3 fewer pods** running at all times
- **`deploy-kafka.sh` complexity removed** — the current script works around operator image
  digest parsing, CSV name fallback detection, PVC size overrides, and a multi-minute
  readiness poll loop
- **No OLM subscription management** — no channel, source, install plan approval

---

## Steps

### 1. Create `scripts/deploy-redpanda.sh`

Replaces `scripts/deploy-kafka.sh`. Installs Redpanda via Helm into the `kafka` namespace
(same namespace as before, keeping bootstrap DNS compatible with existing values).

See the script below.

### 2. Update `scripts/deploy-to-crc.sh`

Add a `KAFKA_BACKEND` env var (default: `redpanda`) and call the appropriate script:

```bash
KAFKA_BACKEND="${KAFKA_BACKEND:-redpanda}"   # or "amqstreams"
```

In `step2_kafka()`:
```bash
step2_kafka() {
    if [ "$KAFKA_BACKEND" = "amqstreams" ]; then
        KAFKA_BROKER_STORAGE="$KAFKA_BROKER_STORAGE" \
        KAFKA_CONTROLLER_STORAGE="$KAFKA_CONTROLLER_STORAGE" \
            "$SCRIPT_DIR/deploy-kafka.sh"
    else
        "$SCRIPT_DIR/deploy-redpanda.sh"
    fi
}
```

### 3. Update `cost-onprem/values-crc.yaml`

Override the bootstrap server for CRC deployments (both arm64 and amd64):

```yaml
kafka:
  bootstrapServers: redpanda.kafka.svc.cluster.local:9092
```

### 4. Update `Makefile`

`crc-deploy` already passes `KAFKA_BACKEND` through the environment if set. No change
needed — `KAFKA_BACKEND=amqstreams make crc-deploy` still works for testing against
real AMQ Streams.

---

## Rollback

Set `KAFKA_BACKEND=amqstreams` to revert to the original AMQ Streams deployment.
The Helm chart's default `kafka.bootstrapServers` value still points to the AMQ Streams
address — only `values-crc.yaml` overrides it for CRC.

---

## Script: `scripts/deploy-redpanda.sh`

```bash
#!/usr/bin/env bash
# Deploy Redpanda as a Kafka-compatible broker for cost-onprem dev/test.
#
# Redpanda is wire-compatible with the Kafka protocol — no changes to koku or the
# Helm chart are needed beyond pointing INSIGHTS_KAFKA_HOST at the Redpanda service.
#
# Usage:
#   ./scripts/deploy-redpanda.sh
#
# Environment overrides:
#   NAMESPACE          Redpanda namespace (default: kafka — matches AMQ Streams default)
#   REDPANDA_VERSION   Helm chart version to pin (default: latest)
#   STORAGE_SIZE       PVC size for data (default: 2Gi)
#   MEMORY_MAX         Container memory limit (default: 512Mi)
#
# Bootstrap server after deploy:
#   redpanda.kafka.svc.cluster.local:9092

set -euo pipefail

NAMESPACE="${NAMESPACE:-kafka}"
REDPANDA_VERSION="${REDPANDA_VERSION:-}"   # empty = latest
STORAGE_SIZE="${STORAGE_SIZE:-2Gi}"
MEMORY_MAX="${MEMORY_MAX:-512Mi}"

info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
err()     { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
command -v helm &>/dev/null || err "helm not found. Install helm first."

# ---------------------------------------------------------------------------
# Helm repo
# ---------------------------------------------------------------------------
info "Adding Redpanda Helm repo..."
helm repo add redpanda https://charts.redpanda.com 2>/dev/null || true
helm repo update redpanda

# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------
info "Installing Redpanda into namespace '$NAMESPACE'..."
kubectl get namespace "$NAMESPACE" &>/dev/null || kubectl create namespace "$NAMESPACE"

VERSION_FLAG=()
[ -n "$REDPANDA_VERSION" ] && VERSION_FLAG=(--version "$REDPANDA_VERSION")

helm upgrade --install redpanda redpanda/redpanda \
    "${VERSION_FLAG[@]}" \
    --namespace "$NAMESPACE" \
    --wait \
    --timeout 5m \
    --set statefulset.replicas=1 \
    --set "resources.cpu.cores=1" \
    --set "resources.memory.container.max=${MEMORY_MAX}" \
    --set "storage.persistentVolume.size=${STORAGE_SIZE}" \
    --set tls.enabled=false \
    --set "listeners.kafka.port=9092" \
    --set "listeners.kafka.authenticationMethod=none" \
    --set "config.cluster.auto_create_topics_enabled=true" \
    --set console.enabled=false \
    --set monitoring.enabled=false

success "Redpanda deployed"
info "Bootstrap server: redpanda.${NAMESPACE}.svc.cluster.local:9092"
info ""
info "To verify:"
info "  kubectl exec -n $NAMESPACE redpanda-0 -- rpk cluster info"
info "  kubectl exec -n $NAMESPACE redpanda-0 -- rpk topic list"

# ---------------------------------------------------------------------------
# Write bootstrap env file (mirrors what deploy-kafka.sh produces)
# ---------------------------------------------------------------------------
cat > /tmp/kafka-bootstrap-servers.env <<EOF
KAFKA_BOOTSTRAP_SERVERS=redpanda.${NAMESPACE}.svc.cluster.local:9092
INSIGHTS_KAFKA_HOST=redpanda.${NAMESPACE}.svc.cluster.local
INSIGHTS_KAFKA_PORT=9092
EOF

success "Bootstrap env written to /tmp/kafka-bootstrap-servers.env"
```

---

## Topics reference

These topics are created automatically by koku's `AdminClientSingleton` on first
connection. No manual topic creation is needed with `auto_create_topics_enabled=true`.

| Topic | Creator | Consumer |
|---|---|---|
| `platform.upload.announce` | koku AdminClient | listener |
| `platform.upload.validation` | koku AdminClient | (external, unused on-prem) |
| `hccm.ros.events` | koku AdminClient | ros-processor |
| `rosocp.kruize.recommendations` | koku AdminClient | ros-recommendation-poller |
| `platform.sources.event-stream` | koku AdminClient | housekeeper, sources listener |

---

## Production considerations

Redpanda is suitable for **dev/test/CRC** use. For production on-prem deployments:

- Redpanda is not a Red Hat product — support path differs from AMQ Streams
- Multi-broker Redpanda is supported but requires tuning replication factors
- AMQ Streams (Strimzi) remains the recommended path for OpenShift production
- The `KAFKA_BACKEND` env var makes it straightforward to keep AMQ Streams as the
  production default while using Redpanda for lightweight dev environments
