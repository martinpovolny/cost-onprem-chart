# cost-onprem CRC development targets
#
# Prerequisites: CRC must already be configured and running.
#   crc config set enable-cluster-monitoring true
#   crc config set memory 18000
#   crc config set cpus 8
#   crc config set disk-size 100
#   crc setup && crc start -p ~/.crc-secret.json
#
# Usage:
#   make crc-deploy          # deploy all components (arch auto-detected)
#   make crc-test            # run tests, skip ROS and UI
#   make crc-test-ui         # run tests including UI (requires display)
#   make crc-all             # deploy + test
#   make crc-redeploy        # uninstall chart only, then reinstall (keep kafka/keycloak/s4)
#   make crc-info            # show current cluster state

# ---------------------------------------------------------------------------
# Architecture detection
# ---------------------------------------------------------------------------
UNAME_M := $(shell uname -m)
ifeq ($(UNAME_M),arm64)
  ARCH := arm64
else ifeq ($(UNAME_M),aarch64)
  ARCH := arm64
else
  ARCH := amd64
endif

# ---------------------------------------------------------------------------
# Configurable variables
# ---------------------------------------------------------------------------
NAMESPACE       ?= cost-onprem
KEYCLOAK_NS     ?= keycloak

# Arch-aware defaults — override on the command line if needed:
#   make crc-deploy KEYCLOAK_OPERATOR=rhbk
ifeq ($(ARCH),arm64)
  KEYCLOAK_OPERATOR ?= community
else
  KEYCLOAK_OPERATOR ?= rhbk
endif

# Kafka backend: redpanda (default, lighter) or amqstreams (OLM operator, production-grade)
#   make crc-deploy KAFKA_BACKEND=amqstreams
KAFKA_BACKEND ?= redpanda

# ---------------------------------------------------------------------------
# Targets
# ---------------------------------------------------------------------------
.PHONY: crc-all crc-deploy crc-redeploy crc-test crc-test-ui crc-test-ros crc-info crc-logs

## Full deploy + test cycle (no UI tests, no ROS tests on arm64)
crc-all: crc-deploy crc-test

## Deploy all components (kafka, keycloak, s4, helm chart)
crc-deploy:
	@echo "==> Deploying cost-onprem to CRC (arch=$(ARCH), keycloak=$(KEYCLOAK_OPERATOR), kafka=$(KAFKA_BACKEND))"
	ARCH=$(ARCH) KEYCLOAK_OPERATOR=$(KEYCLOAK_OPERATOR) NAMESPACE=$(NAMESPACE) \
	    KAFKA_BACKEND=$(KAFKA_BACKEND) \
	    ./scripts/deploy-to-crc.sh

## Reinstall only the Helm chart (skip kafka/keycloak/s4)
crc-redeploy:
	@echo "==> Reinstalling Helm chart (skipping infra)"
	ARCH=$(ARCH) KEYCLOAK_OPERATOR=$(KEYCLOAK_OPERATOR) NAMESPACE=$(NAMESPACE) \
	    ./scripts/deploy-to-crc.sh --skip-infra

## Run tests — skip ROS (expected failures when ros.enabled=false) and UI
crc-test:
	@echo "==> Running tests (no ROS, no UI) on namespace=$(NAMESPACE)"
	NAMESPACE=$(NAMESPACE) ./scripts/run-pytest.sh --no-ros --no-ui

## Run tests including UI (requires a display / headed browser)
crc-test-ui:
	@echo "==> Running tests including UI on namespace=$(NAMESPACE)"
	NAMESPACE=$(NAMESPACE) ./scripts/run-pytest.sh --no-ros

## Run ROS-specific tests (only useful when ros.enabled=true)
crc-test-ros:
	@echo "==> Running ROS tests on namespace=$(NAMESPACE)"
	NAMESPACE=$(NAMESPACE) ./scripts/run-pytest.sh --ros

## Show cluster state summary
crc-info:
	@eval $$(crc oc-env) && \
	echo "=== Pods ($(NAMESPACE)) ===" && \
	kubectl get pods -n $(NAMESPACE) && \
	echo "" && \
	echo "=== Pods (kafka) ===" && \
	kubectl get pods -n kafka && \
	echo "" && \
	echo "=== Pods ($(KEYCLOAK_NS)) ===" && \
	kubectl get pods -n $(KEYCLOAK_NS) && \
	echo "" && \
	echo "=== Routes ($(NAMESPACE)) ===" && \
	kubectl get routes -n $(NAMESPACE) && \
	echo "" && \
	echo "=== Helm releases ===" && \
	helm list -A

## Tail logs for a component. Usage: make crc-logs COMPONENT=listener
crc-logs:
	@eval $$(crc oc-env) && \
	kubectl logs -n $(NAMESPACE) \
	    -l app.kubernetes.io/component=$(COMPONENT) \
	    --tail=100 --follow
