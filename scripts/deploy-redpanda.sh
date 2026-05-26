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
#   KAFKA_NAMESPACE           Namespace for Redpanda (default: kafka)
#   REDPANDA_VERSION          Helm chart version to pin (default: latest)
#   STORAGE_SIZE              PVC size for data (default: 2Gi)
#   MEMORY_MAX                Container memory limit (default: 1Gi dev / 2Gi prod)
#   REDPANDA_DEV_MODE         Enable developer mode (default: true)
#   REDPANDA_IMAGE_REGISTRY   Image registry prefix (default: quay.io/martin_povolny)
#                             Mirrored images avoid rate limits on docker.redpanda.com.
#                             Run scripts/util/mirror_panda.sh to refresh the mirror.
#
# Developer mode (REDPANDA_DEV_MODE=true, the default):
#   Disables Seastar production memory/CPU validation. Allows ~1Gi instead of 2Gi.
#   NOT suitable for production deployments.
#
# OpenShift SCC note:
#   Redpanda's tuning init container requires privileged SCC (runAsUser=0, SYS_RESOURCE).
#   The chart does not honour statefulset.replicas=0 — it always creates at least 1
#   replica and tries to schedule a pod immediately. On a fresh cluster the pod gets
#   rejected before any SCC grant can happen.
#   Fix: pre-create the ServiceAccount and grant the SCC BEFORE running helm install.
#
# Bootstrap server after deploy:
#   redpanda.kafka.svc.cluster.local:9092

set -euo pipefail

KAFKA_NAMESPACE="${KAFKA_NAMESPACE:-kafka}"
REDPANDA_VERSION="${REDPANDA_VERSION:-}"
STORAGE_SIZE="${STORAGE_SIZE:-2Gi}"
REDPANDA_DEV_MODE="${REDPANDA_DEV_MODE:-true}"
# Mirrored images on quay.io avoid the unauthenticated pull rate limit on
# docker.redpanda.com that affects fresh CRC instances. See scripts/util/mirror_panda.sh.
REDPANDA_IMAGE_REGISTRY="${REDPANDA_IMAGE_REGISTRY:-quay.io/martin_povolny}"

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
# Namespace
# ---------------------------------------------------------------------------
kubectl get namespace "$KAFKA_NAMESPACE" &>/dev/null || kubectl create namespace "$KAFKA_NAMESPACE"

# ---------------------------------------------------------------------------
# OpenShift SCC — must be granted BEFORE helm install
# ---------------------------------------------------------------------------
# Redpanda's tuning init container requires privileged SCC (runAsUser=0, SYS_RESOURCE).
# The chart does not support replicas=0 — a pod is always scheduled immediately on
# helm install. We pre-create the SA and grant the SCC before helm runs so the pod
# is not rejected on admission.
OPENSHIFT=false
# Direct SCC query is more reliable than api-resources in nohup/subshell contexts.
if kubectl get scc privileged &>/dev/null 2>&1; then
    OPENSHIFT=true
    command -v oc &>/dev/null \
        || err "oc CLI not found in PATH ($PATH). Required to grant SCC on OpenShift."

    info "OpenShift detected — pre-creating redpanda SA and granting privileged SCC..."
    # Create the SA with Helm ownership labels/annotations so Helm can adopt it.
    # Without these, 'helm install' fails with "invalid ownership metadata".
    kubectl apply -f - <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  name: redpanda
  namespace: ${KAFKA_NAMESPACE}
  labels:
    app.kubernetes.io/managed-by: Helm
  annotations:
    meta.helm.sh/release-name: redpanda
    meta.helm.sh/release-namespace: ${KAFKA_NAMESPACE}
EOF

    if ! oc adm policy add-scc-to-user privileged \
            "system:serviceaccount:${KAFKA_NAMESPACE}:redpanda" 2>&1 \
            | grep -qE "added|already has"; then
        err "Failed to grant privileged SCC to redpanda service account"
    fi
    info "Privileged SCC granted to system:serviceaccount:${KAFKA_NAMESPACE}:redpanda"

    info "Waiting for SCC grant to propagate to admission controller..."
    for i in $(seq 1 24); do
        if oc auth can-i use "scc/privileged" \
                --as="system:serviceaccount:${KAFKA_NAMESPACE}:redpanda" 2>/dev/null \
                | grep -q "^yes"; then
            info "SCC grant confirmed (attempt $i)"
            break
        fi
        [ "$i" -eq 24 ] && err "SCC grant did not propagate after 2 minutes"
        sleep 5
    done
fi

# ---------------------------------------------------------------------------
# Install / upgrade
# ---------------------------------------------------------------------------
info "Installing Redpanda into namespace '$KAFKA_NAMESPACE' (registry: $REDPANDA_IMAGE_REGISTRY)..."

VERSION_FLAG=()
[ -n "$REDPANDA_VERSION" ] && VERSION_FLAG=(--version "$REDPANDA_VERSION")

DEV_MODE_FLAGS=()
if [ "$REDPANDA_DEV_MODE" = "true" ]; then
    info "Developer mode enabled — bypassing Seastar production memory checks"
    DEV_MODE_FLAGS=(--set "config.node.developer_mode=true")
fi

helm upgrade --install redpanda redpanda/redpanda \
    "${VERSION_FLAG[@]+"${VERSION_FLAG[@]}"}" \
    --namespace "$KAFKA_NAMESPACE" \
    --set-string "resources.cpu.cores=1" \
    --set "resources.memory.container.max=${MEMORY_MAX}" \
    --set "storage.persistentVolume.size=${STORAGE_SIZE}" \
    --set tls.enabled=false \
    --set "listeners.kafka.port=9092" \
    --set "listeners.kafka.authenticationMethod=none" \
    --set "config.cluster.auto_create_topics_enabled=true" \
    --set console.enabled=false \
    --set monitoring.enabled=false \
    --set "image.repository=${REDPANDA_IMAGE_REGISTRY}/redpanda" \
    --set "statefulset.sideCars.image.repository=${REDPANDA_IMAGE_REGISTRY}/redpanda-operator" \
    --set statefulset.replicas=1 \
    "${DEV_MODE_FLAGS[@]+"${DEV_MODE_FLAGS[@]}"}" \
    --wait --timeout 10m

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
