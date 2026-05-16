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
#   KAFKA_NAMESPACE      Namespace for Redpanda (default: kafka — same as AMQ Streams)
#   REDPANDA_VERSION     Helm chart version to pin (default: latest)
#   STORAGE_SIZE         PVC size for data (default: 2Gi)
#   MEMORY_MAX           Container memory limit (default: 512Mi in dev mode, 2Gi in prod)
#   REDPANDA_DEV_MODE    Enable developer mode — bypasses Seastar memory checks,
#                        suitable for CRC/local testing (default: true)
#
# Developer mode (REDPANDA_DEV_MODE=true, the default):
#   Passes developer_mode=true to Redpanda, which disables production memory/CPU
#   validation. This allows the broker to run with ~512Mi instead of the 2Gi minimum
#   that Seastar requires in production. NOT suitable for production deployments.
#
# Bootstrap server after deploy:
#   redpanda.kafka.svc.cluster.local:9092

set -euo pipefail

# Use KAFKA_NAMESPACE (not NAMESPACE) to avoid inheriting deploy-to-crc.sh's
# NAMESPACE=cost-onprem export.
KAFKA_NAMESPACE="${KAFKA_NAMESPACE:-kafka}"
REDPANDA_VERSION="${REDPANDA_VERSION:-}"
STORAGE_SIZE="${STORAGE_SIZE:-2Gi}"
REDPANDA_DEV_MODE="${REDPANDA_DEV_MODE:-true}"

# Memory defaults: 1Gi is sufficient in dev mode (chart template requires ≥611Mi);
# 2Gi required in production to satisfy Seastar's physical memory checks.
if [ "$REDPANDA_DEV_MODE" = "true" ]; then
    MEMORY_MAX="${MEMORY_MAX:-1Gi}"
else
    MEMORY_MAX="${MEMORY_MAX:-2Gi}"
fi

info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
err()     { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Prerequisites
# ---------------------------------------------------------------------------
command -v helm &>/dev/null || err "helm not found. Install helm 3.x first."

# ---------------------------------------------------------------------------
# Helm repo
# ---------------------------------------------------------------------------
info "Adding Redpanda Helm repo..."
helm repo add redpanda https://charts.redpanda.com 2>/dev/null || true
helm repo update redpanda

# ---------------------------------------------------------------------------
# Namespace + OpenShift SCC
# ---------------------------------------------------------------------------
kubectl get namespace "$KAFKA_NAMESPACE" &>/dev/null || kubectl create namespace "$KAFKA_NAMESPACE"

# On OpenShift, Redpanda's tuning init container requires privileged SCC
# (needs runAsUser=0, SYS_RESOURCE capability).
# Strategy: install with replicas=0 so Helm creates the SA without scheduling any
# pod, grant the SCC, then scale to replicas=1 and wait for the pod.
OPENSHIFT=false
if kubectl api-resources 2>/dev/null | grep -q securitycontextconstraints; then
    OPENSHIFT=true
    info "OpenShift detected — will grant privileged SCC after SA creation"
    # Require oc — without it the SCC grant is silently skipped and pods never start.
    if ! command -v oc &>/dev/null; then
        error "oc CLI not found in PATH ($PATH). Cannot grant SCC on OpenShift."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Install / upgrade
# ---------------------------------------------------------------------------
info "Installing Redpanda into namespace '$KAFKA_NAMESPACE'..."

VERSION_FLAG=()
[ -n "$REDPANDA_VERSION" ] && VERSION_FLAG=(--version "$REDPANDA_VERSION")

DEV_MODE_FLAGS=()
if [ "$REDPANDA_DEV_MODE" = "true" ]; then
    info "Developer mode enabled — bypassing Seastar production memory checks"
    DEV_MODE_FLAGS=(--set "config.node.developer_mode=true")
fi

HELM_COMMON_FLAGS=(
    "${VERSION_FLAG[@]+"${VERSION_FLAG[@]}"}"
    --namespace "$KAFKA_NAMESPACE"
    --set-string "resources.cpu.cores=1"
    --set "resources.memory.container.max=${MEMORY_MAX}"
    --set "storage.persistentVolume.size=${STORAGE_SIZE}"
    --set tls.enabled=false
    --set "listeners.kafka.port=9092"
    --set "listeners.kafka.authenticationMethod=none"
    --set "config.cluster.auto_create_topics_enabled=true"
    --set console.enabled=false
    --set monitoring.enabled=false
    "${DEV_MODE_FLAGS[@]+"${DEV_MODE_FLAGS[@]}"}"
)

if [ "$OPENSHIFT" = "true" ]; then
    # Phase 1: create resources (including the SA) without scheduling any pods.
    info "Phase 1: creating Helm resources (replicas=0) so SA exists for SCC grant..."
    helm upgrade --install redpanda redpanda/redpanda \
        "${HELM_COMMON_FLAGS[@]}" \
        --set statefulset.replicas=0 \
        --wait --timeout 5m

    # Phase 2: grant privileged SCC to the Helm-owned SA.
    if ! oc adm policy add-scc-to-user privileged \
            "system:serviceaccount:${KAFKA_NAMESPACE}:redpanda" 2>&1 \
            | grep -qE "added|already has"; then
        error "Failed to grant privileged SCC to redpanda service account"
        exit 1
    fi
    info "Privileged SCC granted to system:serviceaccount:${KAFKA_NAMESPACE}:redpanda"

    # Phase 3: scale to 1 replica and wait for the pod.
    info "Phase 3: scaling Redpanda to 1 replica..."
    helm upgrade redpanda redpanda/redpanda \
        "${HELM_COMMON_FLAGS[@]}" \
        --set statefulset.replicas=1 \
        --wait --timeout 10m
else
    helm upgrade --install redpanda redpanda/redpanda \
        "${HELM_COMMON_FLAGS[@]}" \
        --set statefulset.replicas=1 \
        --wait --timeout 10m
fi

success "Redpanda deployed"
info "Bootstrap server: redpanda.${KAFKA_NAMESPACE}.svc.cluster.local:9092"

# ---------------------------------------------------------------------------
# Verify + create topics
# ---------------------------------------------------------------------------
info "Waiting for Redpanda to be ready..."
kubectl rollout status statefulset/redpanda -n "$KAFKA_NAMESPACE" --timeout=120s

info ""
info "Cluster info:"
kubectl exec -n "$KAFKA_NAMESPACE" redpanda-0 -c redpanda -- rpk cluster info 2>/dev/null || true

# Create required topics (idempotent — rpk ignores already-existing topics)
TOPICS=(
    platform.upload.announce
    platform.upload.validation
    platform.notifications.ingress
    hccm.ros.events
    platform.rhsm-subscriptions.service-instance-ingress
    platform.sources.event-stream
)
info "Creating Kafka topics..."
for topic in "${TOPICS[@]}"; do
    kubectl exec -n "$KAFKA_NAMESPACE" redpanda-0 -c redpanda -- \
        rpk topic create "$topic" --partitions 1 --replicas 1 2>/dev/null \
        && info "  created: $topic" \
        || info "  exists:  $topic"
done

info "Topics:"
kubectl exec -n "$KAFKA_NAMESPACE" redpanda-0 -c redpanda -- rpk topic list 2>/dev/null || true

# ---------------------------------------------------------------------------
# Write bootstrap env file (same format as deploy-kafka.sh)
# ---------------------------------------------------------------------------
cat > /tmp/kafka-bootstrap-servers.env <<EOF
KAFKA_BOOTSTRAP_SERVERS=redpanda.${KAFKA_NAMESPACE}.svc.cluster.local:9092
INSIGHTS_KAFKA_HOST=redpanda.${KAFKA_NAMESPACE}.svc.cluster.local
INSIGHTS_KAFKA_PORT=9092
EOF

success "Bootstrap env written to /tmp/kafka-bootstrap-servers.env"
info ""
info "To verify topics:"
info "  kubectl exec -n $KAFKA_NAMESPACE redpanda-0 -c redpanda -- rpk topic list"
