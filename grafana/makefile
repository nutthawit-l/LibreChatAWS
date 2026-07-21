CLUSTER_NAME ?= core-cluster
NAMESPACE ?= grafana
RELEASE ?= grafana-k8s-monitoring
CHART_REPO ?= https://grafana.github.io/helm-charts
CHART ?= k8s-monitoring
# Pin for reproducible PoC deploys; bump intentionally
CHART_VERSION ?= 4.3.0
VALUES_OUT := $(CURDIR)/.values.generated.yaml

-include .env
export

# Allow CLUSTER_NAME / NAMESPACE from .env to win when set
CLUSTER_NAME := $(or $(CLUSTER_NAME),core-cluster)
NAMESPACE := $(or $(NAMESPACE),grafana)

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Grafana Cloud on EKS (core-cluster)"
	@echo ""
	@echo "Targets:"
	@echo "  check       Verify kube context + helm + .env"
	@echo "  repo        Add/update grafana Helm repo"
	@echo "  secrets     Create/update grafana-cloud Secret from .env"
	@echo "  values      Render values.yaml.tpl → .values.generated.yaml"
	@echo "  deploy      Install/upgrade k8s-monitoring → Grafana Cloud"
	@echo "  status      Show Alloy / kube-state-metrics / node-exporter pods"
	@echo "  endpoints   Print in-cluster OTLP URLs for LibreChat"
	@echo "  logs        Tail Alloy metrics collector logs"
	@echo "  destroy     Uninstall Helm release + delete namespace"
	@echo ""
	@echo "Prereq: EKS up (make -C ../eks setup), kubectl context set"
	@echo "Usage:"
	@echo "  cp .env.example .env   # fill Grafana Cloud URLs + token"
	@echo "  make deploy"
	@echo ""
	@echo "Variables:"
	@echo "  CLUSTER_NAME=$(CLUSTER_NAME)  NAMESPACE=$(NAMESPACE)"
	@echo "  RELEASE=$(RELEASE)  CHART_VERSION=$(CHART_VERSION)"

.PHONY: check
check:
	@test -f .env || (echo "Missing .env — cp .env.example .env && edit" && exit 1)
	@command -v helm >/dev/null || (echo "Missing helm. Install: https://helm.sh/docs/intro/install/" && exit 1)
	@command -v kubectl >/dev/null || (echo "Missing kubectl" && exit 1)
	@command -v envsubst >/dev/null || (echo "Missing envsubst (gettext)" && exit 1)
	@kubectl config current-context
	@kubectl get --raw=/readyz >/dev/null 2>&1 \
		|| (echo "Cannot reach EKS API (timeout / connection lost)."; \
		    echo "Try: aws eks update-kubeconfig --name $(CLUSTER_NAME) --region us-east-1"; \
		    echo "Then: kubectl get ns"; exit 1)
	@TOK=$$(grep ^GRAFANA_CLOUD_TOKEN= .env | cut -d= -f2-); \
	if [ -z "$$TOK" ] || echo "$$TOK" | grep -Eq '^(glc_x+|change-me)'; then \
		echo "Set a real GRAFANA_CLOUD_TOKEN in .env"; exit 1; \
	fi
	@echo "Cluster label: $(CLUSTER_NAME) | Namespace: $(NAMESPACE)"

.PHONY: repo
repo:
	helm repo add grafana $(CHART_REPO) 2>/dev/null || true
	helm repo update grafana

.PHONY: secrets
secrets: check
	kubectl get ns $(NAMESPACE) >/dev/null 2>&1 || kubectl create namespace $(NAMESPACE)
	# --validate=false avoids OpenAPI download timeouts on flaky EKS API links
	kubectl -n $(NAMESPACE) create secret generic grafana-cloud \
		--from-literal=token="$$(grep ^GRAFANA_CLOUD_TOKEN= .env | cut -d= -f2-)" \
		--from-literal=metrics-user="$$(grep ^GRAFANA_CLOUD_METRICS_USER= .env | cut -d= -f2-)" \
		--from-literal=logs-user="$$(grep ^GRAFANA_CLOUD_LOGS_USER= .env | cut -d= -f2-)" \
		--from-literal=otlp-user="$$(grep ^GRAFANA_CLOUD_OTLP_INSTANCE_ID= .env | cut -d= -f2-)" \
		--dry-run=client -o yaml | kubectl apply --validate=false -f -
	@echo "Secret grafana-cloud applied in ns/$(NAMESPACE)"

.PHONY: values
values: check
	@set -a && . ./.env && set +a && \
		CLUSTER_NAME="$(CLUSTER_NAME)" NAMESPACE="$(NAMESPACE)" \
		envsubst '$${CLUSTER_NAME} $${GRAFANA_CLOUD_METRICS_URL} $${GRAFANA_CLOUD_METRICS_USER} $${GRAFANA_CLOUD_LOGS_URL} $${GRAFANA_CLOUD_LOGS_USER} $${GRAFANA_CLOUD_OTLP_URL} $${GRAFANA_CLOUD_OTLP_INSTANCE_ID} $${GRAFANA_CLOUD_TOKEN}' \
		< values.yaml.tpl > $(VALUES_OUT)
	@echo "Wrote $(VALUES_OUT)"

.PHONY: deploy
deploy: repo secrets values
	helm upgrade --install $(RELEASE) grafana/$(CHART) \
		--version $(CHART_VERSION) \
		--namespace $(NAMESPACE) --create-namespace \
		--values $(VALUES_OUT) \
		--wait --timeout 10m
	@$(MAKE) --no-print-directory status
	@$(MAKE) --no-print-directory endpoints

.PHONY: status
status:
	@echo "==== Helm release ===="
	helm -n $(NAMESPACE) status $(RELEASE) 2>/dev/null || true
	@echo ""
	@echo "==== Pods ===="
	kubectl -n $(NAMESPACE) get pods -o wide 2>/dev/null || true
	@echo ""
	@echo "==== Services ===="
	kubectl -n $(NAMESPACE) get svc 2>/dev/null || true

.PHONY: endpoints
endpoints:
	@echo ""
	@echo "Grafana Cloud cluster label: $(CLUSTER_NAME)"
	@echo ""
	@echo "In-cluster OTLP (for LibreChat / apps in any namespace):"
	@OTLP_SVC=$$(kubectl -n $(NAMESPACE) get svc -o name 2>/dev/null | grep -E 'alloy-receiver|receiver' | head -1 | sed 's|^service/||'); \
	if [ -n "$$OTLP_SVC" ]; then \
		echo "  OTEL_EXPORTER_OTLP_ENDPOINT=http://$${OTLP_SVC}.$(NAMESPACE).svc.cluster.local:4318"; \
		echo "  OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf"; \
		echo "  (gRPC) http://$${OTLP_SVC}.$(NAMESPACE).svc.cluster.local:4317"; \
	else \
		echo "  (receiver Service not found yet — wait for Alloy pods, then re-run make endpoints)"; \
		echo "  Expected pattern: http://$(RELEASE)-alloy-receiver.$(NAMESPACE).svc.cluster.local:4318"; \
	fi
	@echo ""
	@echo "Prometheus scrape annotations (optional on LibreChat pods/services):"
	@echo "  prometheus.io/scrape: \"true\""
	@echo "  prometheus.io/port: \"<metrics-port>\""
	@echo "  prometheus.io/path: \"/metrics\""
	@echo ""
	@echo "In Grafana Cloud UI: Explore → Prometheus/Loki → filter cluster=\"$(CLUSTER_NAME)\""
	@echo "Kubernetes Monitoring: Infrastructure → Kubernetes → cluster $(CLUSTER_NAME)"

.PHONY: logs
logs:
	@POD=$$(kubectl -n $(NAMESPACE) get pods -o name 2>/dev/null | grep -E 'alloy-metrics|metrics' | head -1); \
	if [ -z "$$POD" ]; then echo "No alloy-metrics pod yet"; exit 1; fi; \
	kubectl -n $(NAMESPACE) logs -f $$POD --all-containers=true

.PHONY: destroy
destroy:
	helm -n $(NAMESPACE) uninstall $(RELEASE) --wait 2>/dev/null || true
	kubectl delete namespace $(NAMESPACE) --ignore-not-found
	rm -f $(VALUES_OUT)
	@echo "Removed Helm release $(RELEASE) and namespace $(NAMESPACE)."
