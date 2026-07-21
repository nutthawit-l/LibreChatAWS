CLUSTER_NAME ?= core-cluster
REGION ?= us-east-1
NAMESPACE ?= librechat
RELEASE ?= librechat
CHART ?= oci://ghcr.io/danny-avila/librechat-chart/librechat
# Pin when known; empty = latest chart from OCI
CHART_VERSION ?=
NVIDIA_DEVICE_PLUGIN_VERSION ?= v0.17.1
OLLAMA_MODEL ?= llama3.2
OLLAMA_EMBED_MODEL ?= nomic-embed-text
OPENAI_API_KEY ?= ollama

DOMAIN ?= librechat.ntwtech.com
ACM_CERTIFICATE_ARN ?= $(shell sed -n 's/^ACM_CERTIFICATE_ARN=//p' ../ingress/.env 2>/dev/null)

CACHE_DIR := $(CURDIR)/.cache
VALUES_OUT := $(CACHE_DIR)/values.yaml
SECRET_ENV := $(CACHE_DIR)/credentials.env

-include .env
export

DOMAIN := $(or $(DOMAIN),librechat.ntwtech.com)
DOMAIN_CLIENT := $(or $(DOMAIN_CLIENT),https://$(DOMAIN))
DOMAIN_SERVER := $(or $(DOMAIN_SERVER),https://$(DOMAIN))
OLLAMA_URL := $(or $(OLLAMA_URL),http://ollama.$(NAMESPACE).svc.cluster.local:11434)
OLLAMA_MODEL := $(or $(OLLAMA_MODEL),llama3.2)
OLLAMA_EMBED_MODEL := $(or $(OLLAMA_EMBED_MODEL),nomic-embed-text)
ALLOW_REGISTRATION := $(or $(ALLOW_REGISTRATION),true)
ALLOW_EMAIL_LOGIN := $(or $(ALLOW_EMAIL_LOGIN),true)
AWS_REGION := $(or $(AWS_REGION),$(REGION))
POSTGRES_HOST := $(or $(POSTGRES_HOST),postgres.postgres.svc.cluster.local)
POSTGRES_PORT := $(or $(POSTGRES_PORT),5432)
POSTGRES_DB := $(or $(POSTGRES_DB),librechat_vectordb)
POSTGRES_USER := $(or $(POSTGRES_USER),librechat)

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "LibreChat + Ollama on EKS ($(CLUSTER_NAME))"
	@echo ""
	@echo "Targets:"
	@echo "  check              Verify tools / kube context / .env"
	@echo "  gen-secrets        Fill empty CREDS_* / JWT_* / MEILI_* in .env"
	@echo "  secrets            Apply K8s secrets from .env"
	@echo "  init-postgres      Create RAG DB + pgvector extension on shared Postgres"
	@echo "  install-gpu-plugin NVIDIA device plugin DaemonSet"
	@echo "  deploy-ollama      Namespace + Ollama (gpu-pool) + pull models"
	@echo "  values             Render values.yaml.tpl → .cache/values.yaml"
	@echo "  deploy             Helm install/upgrade LibreChat"
	@echo "  status             Pods / svc / ingress"
	@echo "  endpoints          ALB hostname + DNS hint"
	@echo "  destroy            Uninstall Helm + delete namespace librechat"
	@echo "  destroy-unpod      Delete legacy unpod namespace (migration)"
	@echo ""
	@echo "Prereq: ingress, mongo, redis, postgres (pgvector image), s3"
	@echo "Usage:"
	@echo "  cp .env.example .env && make gen-secrets"
	@echo "  # copy MONGO_URI / REDIS_URI / POSTGRES_* / AWS_* from conninfo"
	@echo "  make deploy-ollama && make secrets && make init-postgres && make deploy"
	@echo ""
	@echo "Variables:"
	@echo "  DOMAIN=$(DOMAIN)  NAMESPACE=$(NAMESPACE)  RELEASE=$(RELEASE)"
	@echo "  ACM_CERTIFICATE_ARN=$(ACM_CERTIFICATE_ARN)"
	@echo "  OLLAMA_MODEL=$(OLLAMA_MODEL)  OLLAMA_EMBED_MODEL=$(OLLAMA_EMBED_MODEL)"

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
	@echo "Domain: $(DOMAIN) | Namespace: $(NAMESPACE)"

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
		echo "AWS_ACCESS_KEY_ID=$(AWS_ACCESS_KEY_ID)"; \
		echo "AWS_SECRET_ACCESS_KEY=$(AWS_SECRET_ACCESS_KEY)"; \
		echo "AWS_REGION=$(AWS_REGION)"; \
		echo "AWS_BUCKET_NAME=$(AWS_BUCKET_NAME)"; \
		echo "OPENAI_API_KEY=$(OPENAI_API_KEY)"; \
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
	@echo "Installing NVIDIA device plugin $(NVIDIA_DEVICE_PLUGIN_VERSION)..."
	kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/$(NVIDIA_DEVICE_PLUGIN_VERSION)/deployments/static/nvidia-device-plugin.yml
	@echo "Ensure gpu NodeClass/NodePool: make -C ../eks install-karpenter-config"

.PHONY: deploy-ollama
deploy-ollama:
	kubectl apply -f k8s/ollama/namespace.yaml
	kubectl apply -f k8s/ollama/ollama.yaml
	@echo "Waiting for Ollama (GPU node may take several minutes)..."
	kubectl -n $(NAMESPACE) rollout status deploy/ollama --timeout=20m
	@echo "Pulling chat model $(OLLAMA_MODEL)..."
	kubectl -n $(NAMESPACE) exec deploy/ollama -- ollama pull $(OLLAMA_MODEL)
	@echo "Pulling embed model $(OLLAMA_EMBED_MODEL)..."
	kubectl -n $(NAMESPACE) exec deploy/ollama -- ollama pull $(OLLAMA_EMBED_MODEL)
	@echo "Ollama ready at $(OLLAMA_URL)"

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
		OLLAMA_URL="$(OLLAMA_URL)" OLLAMA_MODEL="$(OLLAMA_MODEL)" OLLAMA_EMBED_MODEL="$(OLLAMA_EMBED_MODEL)" \
		ALLOW_REGISTRATION="$(ALLOW_REGISTRATION)" ALLOW_EMAIL_LOGIN="$(ALLOW_EMAIL_LOGIN)" \
		ACM_CERT_ANNOTATION="$$ACM_CERT_ANNOTATION"; \
	envsubst '$${DOMAIN} $${DOMAIN_CLIENT} $${DOMAIN_SERVER} $${MONGO_URI} $${REDIS_URI} $${AWS_REGION} $${AWS_BUCKET_NAME} $${POSTGRES_HOST} $${POSTGRES_PORT} $${POSTGRES_DB} $${POSTGRES_USER} $${OLLAMA_URL} $${OLLAMA_MODEL} $${OLLAMA_EMBED_MODEL} $${ALLOW_REGISTRATION} $${ALLOW_EMAIL_LOGIN} $${ACM_CERT_ANNOTATION}' \
		< values.yaml.tpl > "$(VALUES_OUT)"
	@echo "Wrote $(VALUES_OUT)"

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
