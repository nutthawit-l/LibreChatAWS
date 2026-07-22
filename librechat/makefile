CLUSTER_NAME ?= core-cluster
REGION ?= us-east-1
NAMESPACE ?= librechat
RELEASE ?= librechat
CHART ?= oci://ghcr.io/danny-avila/librechat-chart/librechat
# Pin when known; empty = latest chart from OCI
CHART_VERSION ?=
NVIDIA_DEVICE_PLUGIN_VERSION ?= v0.17.1
GROQ_MODEL ?= llama-3.3-70b-versatile
OLLAMA_MODEL ?= qwen2.5:0.5b
OPENAI_API_KEY ?=

DOMAIN ?= librechat.ntwtech.com
ACM_CERTIFICATE_ARN ?= $(shell sed -n 's/^ACM_CERTIFICATE_ARN=//p' ../ingress/.env 2>/dev/null)

CACHE_DIR := $(CURDIR)/.cache
VALUES_OUT := $(CACHE_DIR)/values.yaml
SECRET_ENV := $(CACHE_DIR)/credentials.env

-include .env
export

# S3 keys in .env are for the LibreChat app only. If exported, they override host
# AWS CLI credentials and break kubectl EKS token auth (aws-iam-authenticator).
S3_AWS_ACCESS_KEY_ID := $(AWS_ACCESS_KEY_ID)
S3_AWS_SECRET_ACCESS_KEY := $(AWS_SECRET_ACCESS_KEY)
unexport AWS_ACCESS_KEY_ID
unexport AWS_SECRET_ACCESS_KEY

DOMAIN := $(or $(DOMAIN),librechat.ntwtech.com)
DOMAIN_CLIENT := $(or $(DOMAIN_CLIENT),https://$(DOMAIN))
DOMAIN_SERVER := $(or $(DOMAIN_SERVER),https://$(DOMAIN))
GROQ_MODEL := $(or $(GROQ_MODEL),llama-3.3-70b-versatile)
OLLAMA_MODEL := $(or $(OLLAMA_MODEL),qwen2.5:0.5b)
ALLOW_REGISTRATION := $(or $(ALLOW_REGISTRATION),true)
ALLOW_EMAIL_LOGIN := $(or $(ALLOW_EMAIL_LOGIN),true)
AWS_REGION := $(or $(AWS_REGION),$(REGION))
OTEL_TRACING_ENABLED := $(or $(OTEL_TRACING_ENABLED),true)
OTEL_SERVICE_NAME := $(or $(OTEL_SERVICE_NAME),librechat)
OTEL_EXPORTER_OTLP_ENDPOINT := $(or $(OTEL_EXPORTER_OTLP_ENDPOINT),http://grafana-k8s-monitoring-alloy-receiver.grafana.svc.cluster.local:4318)
OTEL_EXPORTER_OTLP_PROTOCOL := $(or $(OTEL_EXPORTER_OTLP_PROTOCOL),http/protobuf)
OTEL_TRACES_EXPORTER := $(or $(OTEL_TRACES_EXPORTER),otlp)
POSTGRES_HOST := $(or $(POSTGRES_HOST),postgres.postgres.svc.cluster.local)
POSTGRES_PORT := $(or $(POSTGRES_PORT),5432)
POSTGRES_DB := $(or $(POSTGRES_DB),librechat_vectordb)
POSTGRES_USER := $(or $(POSTGRES_USER),librechat)

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "LibreChat + Groq + self-host Ollama on EKS ($(CLUSTER_NAME))"
	@echo ""
	@echo "Targets:"
	@echo "  check              Verify tools / kube context / .env"
	@echo "  gen-secrets        Fill empty CREDS_* / JWT_* / MEILI_* in .env"
	@echo "  secrets            Apply K8s secrets from .env"
	@echo "  init-postgres      Create RAG DB + pgvector (optional; RAG API off with Groq)"
	@echo "  apply-gpu-pool     Apply Karpenter gpu NodeClass/NodePool (g5g/arm64; needs G vCPU quota > 0)"
	@echo "  install-gpu-plugin Install NVIDIA device plugin (DaemonSet)"
	@echo "  deploy-llm         Apply gpu-pool + Ollama on g5g + pull \$$(OLLAMA_MODEL)"
	@echo "  status-llm         Ollama pods / svc"
	@echo "  diagnose-llm       Debug pending Ollama / GPU NodeClaims"
	@echo "  values             Render values.yaml.tpl → .cache/values.yaml"
	@echo "  deploy             Helm install/upgrade LibreChat"
	@echo "  status             Pods / svc / ingress"
	@echo "  endpoints          ALB hostname + DNS hint"
	@echo "  destroy-llm        Remove in-cluster Ollama (alias: destroy-ollama)"
	@echo "  destroy            Uninstall Helm + delete namespace librechat"
	@echo "  destroy-unpod      Delete legacy unpod namespace (migration)"
	@echo ""
	@echo "Prereq: ingress, mongo, redis, s3; GROQ_API_KEY in .env"
	@echo "Usage:"
	@echo "  cp .env.example .env && make gen-secrets"
	@echo "  # set GROQ_API_KEY=... (and OPENAI_API_KEY= same value)"
	@echo "  make install-gpu-plugin && make deploy-llm"
	@echo "  make secrets && make deploy"
	@echo ""
	@echo "Variables:"
	@echo "  DOMAIN=$(DOMAIN)  NAMESPACE=$(NAMESPACE)  RELEASE=$(RELEASE)"
	@echo "  ACM_CERTIFICATE_ARN=$(ACM_CERTIFICATE_ARN)"
	@echo "  GROQ_MODEL=$(GROQ_MODEL)"
	@echo "  OLLAMA_MODEL=$(OLLAMA_MODEL)"

.PHONY: check
check:
	@test -f .env || (echo "Missing .env — cp .env.example .env" && exit 1)
	@command -v helm >/dev/null || (echo "Missing helm" && exit 1)
	@command -v kubectl >/dev/null || (echo "Missing kubectl" && exit 1)
	@command -v envsubst >/dev/null || (echo "Missing envsubst (gettext)" && exit 1)
	@command -v openssl >/dev/null || (echo "Missing openssl" && exit 1)
	@kubectl config current-context
	@kubectl get --raw=/readyz >/dev/null 2>&1 \
		|| (echo "Cannot reach EKS API."; \
		    echo "Try: aws eks update-kubeconfig --name $(CLUSTER_NAME) --region $(REGION)"; exit 1)
	@test -n "$(MONGO_URI)" || (echo "MONGO_URI empty in .env" && exit 1)
	@test -n "$(REDIS_URI)" || (echo "REDIS_URI empty in .env" && exit 1)
	@test -n "$(CREDS_KEY)" || (echo "CREDS_KEY empty — run make gen-secrets" && exit 1)
	@test -n "$(JWT_SECRET)" || (echo "JWT_SECRET empty — run make gen-secrets" && exit 1)
	@test -n "$(GROQ_API_KEY)" || (echo "GROQ_API_KEY empty — set in .env (https://console.groq.com/keys)" && exit 1)
	@echo "Domain: $(DOMAIN) | Namespace: $(NAMESPACE) | Model: $(GROQ_MODEL)"

.PHONY: gen-secrets
gen-secrets:
	@test -f .env || cp .env.example .env
	@chmod +x scripts/gen-secrets.sh
	@./scripts/gen-secrets.sh .env

.PHONY: secrets
secrets: check
	kubectl get ns $(NAMESPACE) >/dev/null 2>&1 || kubectl apply -f k8s/ollama/namespace.yaml
	@mkdir -p $(CACHE_DIR)
	@umask 077; \
	{ \
		echo "CREDS_KEY=$(CREDS_KEY)"; \
		echo "CREDS_IV=$(CREDS_IV)"; \
		echo "JWT_SECRET=$(JWT_SECRET)"; \
		echo "JWT_REFRESH_SECRET=$(JWT_REFRESH_SECRET)"; \
		echo "MEILI_MASTER_KEY=$(MEILI_MASTER_KEY)"; \
		echo "AWS_ACCESS_KEY_ID=$(S3_AWS_ACCESS_KEY_ID)"; \
		echo "AWS_SECRET_ACCESS_KEY=$(S3_AWS_SECRET_ACCESS_KEY)"; \
		echo "AWS_REGION=$(AWS_REGION)"; \
		echo "AWS_BUCKET_NAME=$(AWS_BUCKET_NAME)"; \
		echo "GROQ_API_KEY=$(GROQ_API_KEY)"; \
		echo "OPENAI_API_KEY=$(or $(OPENAI_API_KEY),$(GROQ_API_KEY))"; \
	} > "$(SECRET_ENV)"
	kubectl -n $(NAMESPACE) create secret generic librechat-credentials-env \
		--from-env-file="$(SECRET_ENV)" \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl -n $(NAMESPACE) create secret generic librechat-vectordb \
		--from-literal=postgres-password="$(POSTGRES_PASSWORD)" \
		--from-literal=password="$(POSTGRES_PASSWORD)" \
		--from-literal=replication-password="$(POSTGRES_PASSWORD)" \
		--dry-run=client -o yaml | kubectl apply -f -
	@rm -f "$(SECRET_ENV)"
	@echo "Secrets applied in namespace $(NAMESPACE)"

.PHONY: init-postgres
init-postgres: check
	@echo "Ensuring database $(POSTGRES_DB) + pgvector on postgres/postgres..."
	@PASS=$$(kubectl -n postgres get secret postgres-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' 2>/dev/null | base64 -d); \
	USER=$$(kubectl -n postgres get secret postgres-credentials -o jsonpath='{.data.POSTGRES_USER}' 2>/dev/null | base64 -d); \
	ADMIN_DB=$$(kubectl -n postgres get secret postgres-credentials -o jsonpath='{.data.POSTGRES_DB}' 2>/dev/null | base64 -d); \
	test -n "$$PASS" || (echo "postgres-credentials missing — make -C ../postgres deploy" && exit 1); \
	kubectl -n postgres exec statefulset/postgres -- \
		env PGPASSWORD="$$PASS" psql -U "$$USER" -d "$$ADMIN_DB" -v ON_ERROR_STOP=1 \
		-c "SELECT 1 FROM pg_database WHERE datname='$(POSTGRES_DB)'" | grep -q 1 \
		|| kubectl -n postgres exec statefulset/postgres -- \
			env PGPASSWORD="$$PASS" psql -U "$$USER" -d "$$ADMIN_DB" -v ON_ERROR_STOP=1 \
			-c "CREATE DATABASE $(POSTGRES_DB);"; \
	kubectl -n postgres exec statefulset/postgres -- \
		env PGPASSWORD="$$PASS" psql -U "$$USER" -d "$(POSTGRES_DB)" -v ON_ERROR_STOP=1 \
		-c "CREATE EXTENSION IF NOT EXISTS vector;"
	@echo "Postgres RAG DB ready: $(POSTGRES_DB)"
	@echo "Note: POSTGRES_USER in librechat/.env must match the Postgres role (see ../postgres/.env)."

.PHONY: install-gpu-plugin
install-gpu-plugin:
	kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/$(NVIDIA_DEVICE_PLUGIN_VERSION)/deployments/static/nvidia-device-plugin.yml
	@echo "NVIDIA device plugin applied ($(NVIDIA_DEVICE_PLUGIN_VERSION)). Pods requesting nvidia.com/gpu can schedule."

.PHONY: apply-gpu-pool
apply-gpu-pool:
	kubectl apply -f ../eks/karpenter/nodeclass-gpu.yaml
	kubectl apply -f ../eks/karpenter/nodepool-gpu.yaml
	@echo "gpu-pool: arm64 + g5g (2xlarge preferred). Confirm: kubectl get nodepool gpu-pool -o yaml | grep -A2 arch"

.PHONY: diagnose-llm
diagnose-llm:
	@echo "==== Ollama pods ===="
	kubectl -n $(NAMESPACE) get pods,pvc,svc -l app=ollama -o wide || true
	@echo ""
	@echo "==== Pod describe (events) ===="
	kubectl -n $(NAMESPACE) describe pod -l app=ollama 2>/dev/null | sed -n '/Events:/,$$p' || true
	@echo ""
	@echo "==== EC2NodeClass gpu (resolved AMIs) ===="
	kubectl get ec2nodeclass gpu -o jsonpath='{range .status.amis[*]}{.id}{"\t"}{.name}{"\t"}{.requirements}{"\n"}{end}' 2>/dev/null || true
	@echo ""
	@echo "==== NodePool / NodeClaims ===="
	kubectl get nodepool gpu-pool -o jsonpath='{.spec.template.spec.requirements}' 2>/dev/null; echo
	kubectl get nodeclaims -o wide 2>/dev/null || true
	@echo ""
	@echo "==== GPU nodes ===="
	kubectl get nodes -l karpenter.sh/nodepool=gpu-pool -o wide 2>/dev/null || true
	@echo ""
	@echo "==== NVIDIA device plugin ===="
	kubectl -n kube-system get pods -l name=nvidia-device-plugin-ds -o wide 2>/dev/null || true
	@echo ""
	@echo "==== Karpenter errors (last 20) ===="
	kubectl -n kube-system logs -l app.kubernetes.io/name=karpenter --tail=80 2>/dev/null \
		| grep -iE 'gpu-pool|error|arch|ami|incompatible|g5g' | tail -20 || true

.PHONY: deploy-llm
deploy-llm: apply-gpu-pool install-gpu-plugin
	@echo "Prereq: Running On-Demand G/VT vCPU quota > 0 (aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA --region $(REGION))"
	kubectl get ns $(NAMESPACE) >/dev/null 2>&1 || kubectl apply -f k8s/ollama/namespace.yaml
	kubectl apply -f k8s/ollama/ollama.yaml
	@echo "Waiting for Ollama rollout (Karpenter may provision g5g — up to 20m)..."
	@if ! kubectl -n $(NAMESPACE) rollout status deploy/ollama --timeout=20m; then \
		echo ""; \
		echo "ERROR: Ollama rollout failed. Diagnostics:"; \
		$(MAKE) --no-print-directory diagnose-llm; \
		exit 1; \
	fi
	@echo "Pulling model $(OLLAMA_MODEL)..."
	kubectl -n $(NAMESPACE) exec deploy/ollama -- ollama pull "$(OLLAMA_MODEL)"
	@$(MAKE) --no-print-directory status-llm
	@echo "Ollama ready: http://ollama.$(NAMESPACE).svc.cluster.local:11434/v1  model=$(OLLAMA_MODEL)"

.PHONY: status-llm
status-llm:
	kubectl -n $(NAMESPACE) get pods,svc,pvc -l app=ollama -o wide
	@kubectl -n $(NAMESPACE) exec deploy/ollama -- ollama list 2>/dev/null || true

.PHONY: destroy-llm destroy-ollama
destroy-llm destroy-ollama:
	kubectl -n $(NAMESPACE) delete deploy,svc,pvc -l app=ollama --ignore-not-found
	@echo "Removed Ollama workloads (GPU NodeClaims can consolidate away)."

.PHONY: values
values: check
	@mkdir -p $(CACHE_DIR)
	@if [ -n "$(ACM_CERTIFICATE_ARN)" ]; then \
		ACM_CERT_ANNOTATION="    alb.ingress.kubernetes.io/certificate-arn: $(ACM_CERTIFICATE_ARN)"; \
	else \
		ACM_CERT_ANNOTATION="    # alb.ingress.kubernetes.io/certificate-arn: (set ACM_CERTIFICATE_ARN in ../ingress/.env)"; \
	fi; \
	export DOMAIN="$(DOMAIN)" DOMAIN_CLIENT="$(DOMAIN_CLIENT)" DOMAIN_SERVER="$(DOMAIN_SERVER)" \
		MONGO_URI="$(MONGO_URI)" REDIS_URI="$(REDIS_URI)" \
		AWS_REGION="$(AWS_REGION)" AWS_BUCKET_NAME="$(AWS_BUCKET_NAME)" \
		POSTGRES_HOST="$(POSTGRES_HOST)" POSTGRES_PORT="$(POSTGRES_PORT)" \
		POSTGRES_DB="$(POSTGRES_DB)" POSTGRES_USER="$(POSTGRES_USER)" \
		GROQ_MODEL="$(GROQ_MODEL)" OLLAMA_MODEL="$(OLLAMA_MODEL)" \
		ALLOW_REGISTRATION="$(ALLOW_REGISTRATION)" ALLOW_EMAIL_LOGIN="$(ALLOW_EMAIL_LOGIN)" \
		OTEL_TRACING_ENABLED="$(OTEL_TRACING_ENABLED)" OTEL_SERVICE_NAME="$(OTEL_SERVICE_NAME)" \
		OTEL_EXPORTER_OTLP_ENDPOINT="$(OTEL_EXPORTER_OTLP_ENDPOINT)" \
		OTEL_EXPORTER_OTLP_PROTOCOL="$(OTEL_EXPORTER_OTLP_PROTOCOL)" \
		OTEL_TRACES_EXPORTER="$(OTEL_TRACES_EXPORTER)" \
		ACM_CERT_ANNOTATION="$$ACM_CERT_ANNOTATION"; \
	envsubst '$${DOMAIN} $${DOMAIN_CLIENT} $${DOMAIN_SERVER} $${MONGO_URI} $${REDIS_URI} $${AWS_REGION} $${AWS_BUCKET_NAME} $${POSTGRES_HOST} $${POSTGRES_PORT} $${POSTGRES_DB} $${POSTGRES_USER} $${GROQ_MODEL} $${OLLAMA_MODEL} $${ALLOW_REGISTRATION} $${ALLOW_EMAIL_LOGIN} $${OTEL_TRACING_ENABLED} $${OTEL_SERVICE_NAME} $${OTEL_EXPORTER_OTLP_ENDPOINT} $${OTEL_EXPORTER_OTLP_PROTOCOL} $${OTEL_TRACES_EXPORTER} $${ACM_CERT_ANNOTATION}' \
		< values.yaml.tpl > "$(VALUES_OUT)"
	@echo "Wrote $(VALUES_OUT)"
	@grep -F 'apiKey: "$${GROQ_API_KEY}"' "$(VALUES_OUT)" >/dev/null \
		|| (echo "ERROR: GROQ_API_KEY placeholder missing from rendered values" && exit 1)
	@grep -F 'baseURL: "http://ollama.librechat.svc.cluster.local:11434/v1/"' "$(VALUES_OUT)" >/dev/null \
		|| (echo "ERROR: Self-host Ollama endpoint missing from rendered values" && exit 1)

.PHONY: deploy
deploy: secrets values
	@echo "Helm upgrade --install $(RELEASE)..."
	@if [ -n "$(CHART_VERSION)" ]; then \
		helm upgrade --install $(RELEASE) $(CHART) \
			--version $(CHART_VERSION) \
			--namespace $(NAMESPACE) --create-namespace \
			-f "$(VALUES_OUT)" \
			--wait --timeout 15m; \
	else \
		helm upgrade --install $(RELEASE) $(CHART) \
			--namespace $(NAMESPACE) --create-namespace \
			-f "$(VALUES_OUT)" \
			--wait --timeout 15m; \
	fi
	@$(MAKE) --no-print-directory status
	@echo ""
	@echo "App: https://$(DOMAIN)"
	@echo "Next: make endpoints  |  DNS → ALB  |  ACM must cover $(DOMAIN)"

.PHONY: status
status:
	@echo "==== Helm ===="
	helm -n $(NAMESPACE) status $(RELEASE) 2>/dev/null || true
	@echo ""
	@echo "==== Workloads ===="
	kubectl -n $(NAMESPACE) get pods,svc,ingress,pvc -o wide 2>/dev/null || true

.PHONY: endpoints
endpoints:
	@echo "LibreChat ALB (after make deploy):"
	@HOST=$$(kubectl -n $(NAMESPACE) get ingress $(RELEASE) -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null); \
	if [ -z "$$HOST" ]; then \
		HOST=$$(kubectl -n $(NAMESPACE) get ingress -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}' 2>/dev/null); \
	fi; \
	if [ -n "$$HOST" ]; then \
		echo "  ALB hostname: $$HOST"; \
		echo "  Point DNS for $(DOMAIN) → $$HOST (Alias A / CNAME)"; \
	else \
		echo "  (Ingress not ready yet — re-run after ALB provisions)"; \
	fi
	@if [ -n "$(ACM_CERTIFICATE_ARN)" ]; then \
		echo "  ACM: $(ACM_CERTIFICATE_ARN)"; \
	else \
		echo "  Tip: set ACM_CERTIFICATE_ARN in ../ingress/.env (SAN must include $(DOMAIN))"; \
	fi

.PHONY: destroy
destroy:
	helm -n $(NAMESPACE) uninstall $(RELEASE) --wait 2>/dev/null || true
	kubectl delete namespace $(NAMESPACE) --ignore-not-found
	rm -f "$(VALUES_OUT)" "$(SECRET_ENV)"
	@echo "Removed Helm release $(RELEASE) and namespace $(NAMESPACE)."

.PHONY: destroy-unpod
destroy-unpod:
	@echo "Deleting legacy namespace unpod (ALB for Unpod Ingress will go away)..."
	kubectl delete namespace unpod --ignore-not-found
	@echo "Optional: delete ECR repos unpod-* manually if unused."
