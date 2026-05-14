#!/usr/bin/env bash
# Deploy the cost-onprem Helm chart to a local CRC (CodeReady Containers) cluster.
# Tested on: CRC 2.60.1 / OpenShift 4.21.8 / Apple Silicon (arm64) and x86_64.
#
# Usage:
#   ./scripts/deploy-to-crc.sh              # full deploy (auto-detects arch)
#   ./scripts/deploy-to-crc.sh --skip-infra # skip kafka/keycloak/s4 (re-deploy chart only)
#
# Environment overrides:
#   ARCH                   Force architecture: arm64 or amd64 (default: auto-detected)
#   NAMESPACE              Target namespace (default: cost-onprem)
#   CRC_PASSWORD           kubeadmin password (default: auto-detected from crc console)
#   KEYCLOAK_OPERATOR      rhbk or community (default: community on arm64, rhbk on amd64)
#   KOKU_IMAGE_REPOSITORY  koku image repo (default: quay.io/martin_povolny/koku on arm64)
#   KOKU_IMAGE_TAG         koku image tag (default: latest)
#   S3_ENDPOINT/PORT/SSL   S4 coordinates (defaults set below)
#   KAFKA_BROKER_STORAGE   Kafka broker PVC size (default: 500Mi)
#   KAFKA_CONTROLLER_STORAGE Kafka controller PVC size (default: 500Mi)
#
# CRC prerequisites (run once, then `crc start -p ~/.crc-secret.json`):
#   crc config set enable-cluster-monitoring true
#   crc config set memory 18000
#   crc config set cpus 8       # 4 is insufficient; stack needs ~4400m CPU requests
#   crc config set disk-size 100 # 31GB default is too small; eviction at ~4.5GB free
#   crc setup

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Architecture detection
# ---------------------------------------------------------------------------
if [ -z "${ARCH:-}" ]; then
    case "$(uname -m)" in
        arm64|aarch64) ARCH=arm64 ;;
        x86_64|amd64)  ARCH=amd64 ;;
        *)             ARCH=unknown ;;
    esac
fi

# ---------------------------------------------------------------------------
# Configuration — arch-aware defaults, all overridable via environment
# ---------------------------------------------------------------------------
NAMESPACE="${NAMESPACE:-cost-onprem}"
CRC_PASSWORD="${CRC_PASSWORD:-}"

if [ "$ARCH" = arm64 ]; then
    # arm64 (Apple Silicon): RHBK has no arm64 images; use community Keycloak operator.
    # Default koku image is amd64-only (segfaults under QEMU); use local arm64 build.
    KEYCLOAK_OPERATOR="${KEYCLOAK_OPERATOR:-community}"
    KOKU_IMAGE_REPOSITORY="${KOKU_IMAGE_REPOSITORY:-quay.io/martin_povolny/koku}"
    KOKU_IMAGE_TAG="${KOKU_IMAGE_TAG:-latest}"
    VALUES_EXTRA="${VALUES_EXTRA:-${REPO_ROOT}/cost-onprem/values-crc-arm64.yaml}"
else
    # amd64: use RHBK (default) and the chart's built-in koku image.
    KEYCLOAK_OPERATOR="${KEYCLOAK_OPERATOR:-rhbk}"
    KOKU_IMAGE_REPOSITORY="${KOKU_IMAGE_REPOSITORY:-}"
    KOKU_IMAGE_TAG="${KOKU_IMAGE_TAG:-}"
    VALUES_EXTRA="${VALUES_EXTRA:-}"
fi

# S4 S3 settings (dev/test only)
S3_ENDPOINT="${S3_ENDPOINT:-s4.${NAMESPACE}.svc.cluster.local}"
S3_PORT="${S3_PORT:-7480}"
S3_USE_SSL="${S3_USE_SSL:-false}"

# Kafka PVC sizes — default chart values (100Gi/20Gi) exceed CRC hostpath capacity.
KAFKA_BROKER_STORAGE="${KAFKA_BROKER_STORAGE:-500Mi}"
KAFKA_CONTROLLER_STORAGE="${KAFKA_CONTROLLER_STORAGE:-500Mi}"

SKIP_INFRA=false
for arg in "$@"; do
    case "$arg" in
        --skip-infra) SKIP_INFRA=true ;;
        *) echo "Unknown argument: $arg"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
err()     { echo "[ERROR] $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Step 1 — Login and create namespace
# ---------------------------------------------------------------------------
step1_login() {
    info "Step 1: Login to CRC and create namespace (arch=$ARCH)"

    eval "$(crc oc-env)"

    if [ -z "$CRC_PASSWORD" ]; then
        CRC_PASSWORD=$(crc console --credentials 2>/dev/null | awk '/kubeadmin/{print $NF}')
    fi
    [ -z "$CRC_PASSWORD" ] && err "Could not detect CRC kubeadmin password. Set CRC_PASSWORD."

    oc login -u kubeadmin -p "$CRC_PASSWORD" https://api.crc.testing:6443 \
        --insecure-skip-tls-verify 2>/dev/null \
        || oc login -u kubeadmin -p "$CRC_PASSWORD" https://api.crc.testing:6443
    oc get project "$NAMESPACE" &>/dev/null || oc new-project "$NAMESPACE"

    success "Logged in, namespace '$NAMESPACE' ready"
}

# ---------------------------------------------------------------------------
# Step 2 — Kafka (AMQ Streams)
# ---------------------------------------------------------------------------
step2_kafka() {
    info "Step 2: Deploy Kafka (AMQ Streams)"
    KAFKA_BROKER_STORAGE="$KAFKA_BROKER_STORAGE" \
    KAFKA_CONTROLLER_STORAGE="$KAFKA_CONTROLLER_STORAGE" \
        "$SCRIPT_DIR/deploy-kafka.sh"
    success "Kafka ready"
}

# ---------------------------------------------------------------------------
# Step 3 — Keycloak
# ---------------------------------------------------------------------------
step3_keycloak() {
    info "Step 3: Deploy Keycloak (KEYCLOAK_OPERATOR=$KEYCLOAK_OPERATOR)"
    KEYCLOAK_OPERATOR="$KEYCLOAK_OPERATOR" \
        "$SCRIPT_DIR/deploy-rhbk.sh"
    success "Keycloak ready"
}

# ---------------------------------------------------------------------------
# Step 4 — S4 object storage
# ---------------------------------------------------------------------------
step4_s4() {
    info "Step 4: Deploy S4 object storage"
    "$SCRIPT_DIR/deploy-s4-test.sh" "$NAMESPACE"
    success "S4 ready"
}

# ---------------------------------------------------------------------------
# Step 5 — Helm chart
# ---------------------------------------------------------------------------
step5_chart() {
    info "Step 5: Deploy cost-onprem Helm chart"

    # install-helm-chart.sh does `cd "$SCRIPT_DIR"` internally, so -f paths must be absolute.
    local helm_args=(-f "${REPO_ROOT}/cost-onprem/values-crc.yaml")
    [ -n "$VALUES_EXTRA" ] && helm_args+=(-f "$VALUES_EXTRA")

    USE_LOCAL_CHART=true \
    S3_ENDPOINT="$S3_ENDPOINT" \
    S3_PORT="$S3_PORT" \
    S3_USE_SSL="$S3_USE_SSL" \
        "$SCRIPT_DIR/install-helm-chart.sh" "${helm_args[@]}"

    success "Helm chart deployed"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
cd "$REPO_ROOT"

info "Architecture: $ARCH"
info "Keycloak operator: $KEYCLOAK_OPERATOR"
[ -n "$VALUES_EXTRA" ] && info "Extra values: $VALUES_EXTRA"

step1_login

if [ "$SKIP_INFRA" = false ]; then
    step2_kafka
    step3_keycloak
    step4_s4
fi

step5_chart

info "Done. Verify with:"
info "  kubectl get pods -n $NAMESPACE -l app.kubernetes.io/instance=cost-onprem"
