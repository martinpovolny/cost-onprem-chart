#!/usr/bin/env bash
# Mirror Redpanda images to a personal Quay.io registry for use in CRC/OpenShift dev.
#
# Solves the unauthenticated pull rate limit on docker.redpanda.com that affects
# fresh CRC instances.  Mirrors all platforms (amd64 + arm64) so the same image tag
# works on both Apple Silicon (local dev) and x86_64 (CRC on foobar).
#
# Usage:
#   ./scripts/util/mirror_panda.sh
#
# Prerequisites:
#   docker login quay.io           # authenticate with your Quay.io account
#   docker buildx version ≥ 0.8   # ships with Docker Desktop 4.x+
#
# Environment overrides:
#   QUAY_USER       Quay.io username (default: martin_povolny)
#   REDPANDA_TAG    Redpanda image tag to mirror (default: auto-detect from helm chart)
#   OPERATOR_TAG    Redpanda operator tag to mirror (default: auto-detect from helm chart)
#   SOURCE_REGISTRY Source image registry (default: docker.io/redpandadata)
#
# After mirroring, set in deploy-redpanda.sh or as env var:
#   REDPANDA_IMAGE_REGISTRY=quay.io/martin_povolny

set -euo pipefail

QUAY_USER="${QUAY_USER:-martin_povolny}"
QUAY_REGISTRY="quay.io/${QUAY_USER}"
SOURCE_REGISTRY="${SOURCE_REGISTRY:-docker.io/redpandadata}"

info()    { echo "[INFO]  $*"; }
success() { echo "[OK]    $*"; }
err()     { echo "[ERROR] $*" >&2; exit 1; }

command -v docker &>/dev/null || err "docker not found"
command -v helm   &>/dev/null || err "helm not found (needed to detect image versions)"
docker buildx version &>/dev/null \
    || err "docker buildx not found (required for multi-arch copy)"

# ---------------------------------------------------------------------------
# Auto-detect versions from the installed redpanda helm chart
# ---------------------------------------------------------------------------
info "Detecting Redpanda image versions from helm chart..."
helm repo add redpanda https://charts.redpanda.com 2>/dev/null || true
helm repo update redpanda 2>/dev/null | grep -E 'Successfully|Update Complete' || true

REDPANDA_TAG="${REDPANDA_TAG:-$(helm show chart redpanda/redpanda 2>/dev/null \
    | awk '/^appVersion:/{print $2}')}"
OPERATOR_TAG="${OPERATOR_TAG:-$(helm show values redpanda/redpanda 2>/dev/null \
    | awk '/sideCars:/{f=1} f && /image:/{g=1} f && g && /tag:/{print $2; exit}')}"

[ -n "$REDPANDA_TAG" ]  || err "Could not detect Redpanda tag. Set REDPANDA_TAG manually."
[ -n "$OPERATOR_TAG" ]  || err "Could not detect operator tag. Set OPERATOR_TAG manually."

info "Redpanda tag:  $REDPANDA_TAG"
info "Operator tag:  $OPERATOR_TAG"

# ---------------------------------------------------------------------------
# Mirror all platforms (amd64 + arm64) using docker buildx imagetools
# ---------------------------------------------------------------------------
mirror() {
    local src="$1" dst="$2"
    info "Mirroring all platforms: $src → $dst"
    # --append would add to existing, but we want a clean copy each time.
    docker buildx imagetools create --tag "$dst" "$src"
    success "Mirrored $src → $dst"
}

mirror "${SOURCE_REGISTRY}/redpanda:${REDPANDA_TAG}"          "${QUAY_REGISTRY}/redpanda:${REDPANDA_TAG}"
mirror "${SOURCE_REGISTRY}/redpanda-operator:${OPERATOR_TAG}" "${QUAY_REGISTRY}/redpanda-operator:${OPERATOR_TAG}"

echo ""
success "Mirror complete (amd64 + arm64)."
info "IMPORTANT: ensure both repositories are set to Public on quay.io/${QUAY_USER}"
info "  https://quay.io/repository/${QUAY_USER}/redpanda"
info "  https://quay.io/repository/${QUAY_USER}/redpanda-operator"
echo ""
info "To use these images in deploy-redpanda.sh:"
info "  REDPANDA_IMAGE_REGISTRY=${QUAY_REGISTRY} ./scripts/deploy-redpanda.sh"
info ""
info "Or set it as the default (already done) in scripts/deploy-redpanda.sh."
