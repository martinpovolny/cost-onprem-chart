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
# (needs runAsUser=0, SYS_RESOURCE capability). Pre-create the service account
# so we can grant the SCC before the StatefulSet pod is scheduled.
if kubectl api-resources 2>/dev/null | grep -q securitycontextconstraints; then
    info "OpenShift detected — granting privileged SCC to Redpanda service account..."
    # Pre-create the service account so the SCC grant succeeds before helm install
    # tries to schedule the pod. The SA name matches the Redpanda chart default.
    kubectl create serviceaccount redpanda -n "$KAFKA_NAMESPACE" \
        --dry-run=client -o yaml | kubectl apply -f - 2>/dev/null
    # Redpanda's tuning init container requires privileged + SYS_RESOURCE (for kernel
    # tuning). Without this grant the pod is rejected by OpenShift SCCs.
    oc adm policy add-scc-to-user privileged \
        "system:serviceaccount:${KAFKA_NAMESPACE}:redpanda" \
        2>&1 | grep -v "already has" || true
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

helm upgrade --install redpanda redpanda/redpanda \
    "${VERSION_FLAG[@]}" \
    --namespace "$KAFKA_NAMESPACE" \
    --wait \
    --timeout 5m \
    --set statefulset.replicas=1 \
    --set-string "resources.cpu.cores=1" \
    --set "resources.memory.container.max=${MEMORY_MAX}" \
    --set "storage.persistentVolume.size=${STORAGE_SIZE}" \
    --set tls.enabled=false \
    --set "listeners.kafka.port=9092" \
    --set "listeners.kafka.authenticationMethod=none" \
    --set "config.cluster.auto_create_topics_enabled=true" \
    --set console.enabled=false \
    --set monitoring.enabled=false \
    "${DEV_MODE_FLAGS[@]}" \
    --values - <<'REDPANDA_VALUES'
provisioning:
  enabled: true
  topics:
    - name: platform.upload.announce
      partitions: 1
      replicationFactor: 1
    - name: platform.upload.validation
      partitions: 1
      replicationFactor: 1
    - name: platform.notifications.ingress
      partitions: 1
      replicationFactor: 1
    - name: hccm.ros.events
      partitions: 1
      replicationFactor: 1
    - name: platform.rhsm-subscriptions.service-instance-ingress
      partitions: 1
      replicationFactor: 1
    - name: platform.sources.event-stream
      partitions: 1
      replicationFactor: 1
REDPANDA_VALUES

success "Redpanda deployed"
info "Bootstrap server: redpanda.${KAFKA_NAMESPACE}.svc.cluster.local:9092"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
info "Waiting for Redpanda to be ready..."
kubectl rollout status statefulset/redpanda -n "$KAFKA_NAMESPACE" --timeout=120s

info ""
info "Cluster info:"
kubectl exec -n "$KAFKA_NAMESPACE" redpanda-0 -- rpk cluster info 2>/dev/null || true

info "Topics after provisioning:"
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
