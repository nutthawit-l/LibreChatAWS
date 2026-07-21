CLUSTER_NAME ?= core-cluster
REGION ?= us-east-1
NAMESPACE ?= unpod
AWS_ACCOUNT_ID = $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
ECR = $(AWS_ACCOUNT_ID).dkr.ecr.$(REGION).amazonaws.com
IMAGE_TAG ?= latest

# Self-hosted LLM
VLLM_MODEL ?= Qwen/Qwen2.5-7B-Instruct
VLLM_SERVED_MODEL_NAME ?= local-llm
NVIDIA_DEVICE_PLUGIN_VERSION ?= v0.17.1

# Path to a local clone of https://github.com/unpod-ai/unpod
UNPOD_SRC ?= $(CURDIR)/.cache/unpod
UNPOD_REPO ?= https://github.com/unpod-ai/unpod.git
UNPOD_REF ?= main

# Public hostnames (override for your DNS)
DOMAIN ?= unpod.ntwtech.com
WEB_HOST ?= app.$(DOMAIN)
API_HOST ?= api.$(DOMAIN)
CHAT_HOST ?= chat.$(DOMAIN)
CENTRIFUGO_HOST ?= realtime.$(DOMAIN)

IMAGES := unpod-web unpod-backend-core unpod-api-services unpod-voice-executor
BUILD_DIR := $(CURDIR)/.cache/build

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Unpod on EKS (core-cluster)"
	@echo ""
	@echo "Targets:"
	@echo "  check              Verify AWS identity / kube context"
	@echo "  clone-unpod        Clone/update unpod source into UNPOD_SRC"
	@echo "  ecr-create         Create ECR repositories"
	@echo "  ecr-login          Authenticate Docker to ECR"
	@echo "  build              Build all images (amd64)"
	@echo "  push               Push all images to ECR"
	@echo "  build-push         Build + push"
	@echo "  secrets            Create/update K8s secrets from .env"
	@echo "  deploy-platform    Apply platform manifests (web/api/centrifugo)"
	@echo "  deploy-voice       Apply voice-executor + HPA"
	@echo "  install-gpu-plugin Install NVIDIA device plugin (DaemonSet)"
	@echo "  deploy-llm         Deploy vLLM on Karpenter gpu-pool"
	@echo "  migrate            Run Django migrate Job"
	@echo "  deploy             secrets + platform + voice + migrate"
	@echo "  deploy-all         deploy + gpu plugin + vLLM"
	@echo "  status             Show unpod resources"
	@echo "  destroy-app        Delete namespace $(NAMESPACE) (keeps ECR/RDS)"
	@echo ""
	@echo "Variables:"
	@echo "  CLUSTER_NAME=$(CLUSTER_NAME)  REGION=$(REGION)  NAMESPACE=$(NAMESPACE)"
	@echo "  UNPOD_SRC=$(UNPOD_SRC)"
	@echo "  IMAGE_TAG=$(IMAGE_TAG)"
	@echo "  WEB_HOST=$(WEB_HOST)  API_HOST=$(API_HOST)"
	@echo "  VLLM_MODEL=$(VLLM_MODEL)  VLLM_SERVED_MODEL_NAME=$(VLLM_SERVED_MODEL_NAME)"

.PHONY: check
check:
	@aws sts get-caller-identity | cat
	@echo "Account: $(AWS_ACCOUNT_ID) | ECR: $(ECR)"
	@kubectl config current-context
	@kubectl get nodepools 2>/dev/null || true

.PHONY: clone-unpod
clone-unpod:
	@mkdir -p "$(dir $(UNPOD_SRC))"
	@if [ -d "$(UNPOD_SRC)/.git" ]; then \
		git -C "$(UNPOD_SRC)" fetch --depth 1 origin "$(UNPOD_REF)"; \
		git -C "$(UNPOD_SRC)" checkout -q FETCH_HEAD; \
	else \
		git clone --depth 1 --branch "$(UNPOD_REF)" "$(UNPOD_REPO)" "$(UNPOD_SRC)"; \
	fi
	@echo "Unpod source: $(UNPOD_SRC) @ $$(git -C "$(UNPOD_SRC)" rev-parse --short HEAD)"

.PHONY: ecr-create
ecr-create: check
	@for r in $(IMAGES); do \
		echo "ECR repo: $$r"; \
		aws ecr describe-repositories --repository-names $$r --region $(REGION) >/dev/null 2>&1 || \
		aws ecr create-repository \
			--repository-name $$r \
			--region $(REGION) \
			--image-scanning-configuration scanOnPush=true \
			--encryption-configuration encryptionType=AES256 >/dev/null; \
	done

.PHONY: ecr-login
ecr-login:
	aws ecr get-login-password --region $(REGION) | \
		docker login --username AWS --password-stdin $(ECR)

.PHONY: build
build: clone-unpod
	docker build --platform linux/amd64 \
		-f docker/Dockerfile.backend-core \
		-t $(ECR)/unpod-backend-core:$(IMAGE_TAG) \
		"$(UNPOD_SRC)"
	docker build --platform linux/amd64 \
		-f docker/Dockerfile.api-services \
		-t $(ECR)/unpod-api-services:$(IMAGE_TAG) \
		"$(UNPOD_SRC)"
	docker build --platform linux/amd64 \
		-f "$(UNPOD_SRC)/infrastructure/docker/frontend/Dockerfile.dev" \
		-t $(ECR)/unpod-web:$(IMAGE_TAG) \
		"$(UNPOD_SRC)"
	docker build --platform linux/amd64 \
		-f "$(UNPOD_SRC)/apps/super/Dockerfile" \
		-t $(ECR)/unpod-voice-executor:$(IMAGE_TAG) \
		"$(UNPOD_SRC)/apps/super"

.PHONY: push
push: ecr-login
	@for r in $(IMAGES); do \
		docker push $(ECR)/$$r:$(IMAGE_TAG); \
	done

.PHONY: build-push
build-push: ecr-create build push

.PHONY: secrets
secrets:
	@test -f .env || (echo "Missing .env — copy from .env.prod.example" && exit 1)
	kubectl get ns $(NAMESPACE) >/dev/null 2>&1 || kubectl create namespace $(NAMESPACE)
	kubectl -n $(NAMESPACE) create secret generic unpod-secrets \
		--from-env-file=.env \
		--dry-run=client -o yaml | kubectl apply -f -
	kubectl -n $(NAMESPACE) create secret generic voice-executor-secrets \
		--from-env-file=.env \
		--dry-run=client -o yaml | kubectl apply -f -

.PHONY: _render
_render:
	@test -n "$(AWS_ACCOUNT_ID)" || (echo "AWS_ACCOUNT_ID empty — run aws configure / check identity" && exit 1)
	@mkdir -p "$(BUILD_DIR)/platform" "$(BUILD_DIR)/voice"
	@cp -a k8s/base/namespace.yaml k8s/base/configmap.yaml \
		k8s/base/backend-core.yaml k8s/base/api-services.yaml \
		k8s/base/web.yaml k8s/base/centrifugo.yaml \
		"$(BUILD_DIR)/platform/"
	@WEB_HOST=$(WEB_HOST) API_HOST=$(API_HOST) CHAT_HOST=$(CHAT_HOST) CENTRIFUGO_HOST=$(CENTRIFUGO_HOST) \
		envsubst '$${WEB_HOST} $${API_HOST} $${CHAT_HOST} $${CENTRIFUGO_HOST}' \
		< k8s/base/ingress.yaml.tpl > "$(BUILD_DIR)/platform/ingress.yaml"
	@printf '%s\n' \
		'apiVersion: kustomize.config.k8s.io/v1beta1' \
		'kind: Kustomization' \
		'namespace: $(NAMESPACE)' \
		'resources:' \
		'  - namespace.yaml' \
		'  - configmap.yaml' \
		'  - backend-core.yaml' \
		'  - api-services.yaml' \
		'  - web.yaml' \
		'  - centrifugo.yaml' \
		'  - ingress.yaml' \
		'images:' \
		'  - name: unpod-web' \
		'    newName: $(ECR)/unpod-web' \
		'    newTag: $(IMAGE_TAG)' \
		'  - name: unpod-backend-core' \
		'    newName: $(ECR)/unpod-backend-core' \
		'    newTag: $(IMAGE_TAG)' \
		'  - name: unpod-api-services' \
		'    newName: $(ECR)/unpod-api-services' \
		'    newTag: $(IMAGE_TAG)' \
		> "$(BUILD_DIR)/platform/kustomization.yaml"
	@cp -a k8s/voice/voice-executor.yaml "$(BUILD_DIR)/voice/"
	@printf '%s\n' \
		'apiVersion: kustomize.config.k8s.io/v1beta1' \
		'kind: Kustomization' \
		'namespace: $(NAMESPACE)' \
		'resources:' \
		'  - voice-executor.yaml' \
		'images:' \
		'  - name: unpod-voice-executor' \
		'    newName: $(ECR)/unpod-voice-executor' \
		'    newTag: $(IMAGE_TAG)' \
		> "$(BUILD_DIR)/voice/kustomization.yaml"
	@sed 's|image: unpod-backend-core:latest|image: $(ECR)/unpod-backend-core:$(IMAGE_TAG)|' \
		k8s/base/migrate-job.yaml > "$(BUILD_DIR)/migrate-job.yaml"

.PHONY: deploy-platform
deploy-platform: _render
	kubectl apply -k "$(BUILD_DIR)/platform"

.PHONY: deploy-voice
deploy-voice: _render
	kubectl apply -k "$(BUILD_DIR)/voice"

.PHONY: install-gpu-plugin
install-gpu-plugin:
	@echo "Installing NVIDIA device plugin $(NVIDIA_DEVICE_PLUGIN_VERSION)..."
	kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/$(NVIDIA_DEVICE_PLUGIN_VERSION)/deployments/static/nvidia-device-plugin.yml
	@echo "Ensure gpu NodeClass/NodePool are applied: make -C ../eks install-karpenter-config"

.PHONY: deploy-llm
deploy-llm:
	kubectl get ns $(NAMESPACE) >/dev/null 2>&1 || kubectl create namespace $(NAMESPACE)
	@mkdir -p "$(BUILD_DIR)/llm"
	@cp -a k8s/llm/vllm.yaml k8s/llm/kustomization.yaml "$(BUILD_DIR)/llm/"
	@# Patch model id in the rendered ConfigMap
	@sed -i.bak \
		-e 's|VLLM_MODEL: ".*"|VLLM_MODEL: "$(VLLM_MODEL)"|' \
		-e 's|VLLM_SERVED_MODEL_NAME: ".*"|VLLM_SERVED_MODEL_NAME: "$(VLLM_SERVED_MODEL_NAME)"|' \
		"$(BUILD_DIR)/llm/vllm.yaml" && rm -f "$(BUILD_DIR)/llm/vllm.yaml.bak"
	kubectl apply -k "$(BUILD_DIR)/llm"
	@echo "vLLM deploying — Karpenter will launch a GPU node (g5.* preferred)."
	@echo "Endpoint: http://vllm.$(NAMESPACE).svc.cluster.local:8000/v1"
	@echo "Wait: kubectl -n $(NAMESPACE) rollout status deploy/vllm --timeout=15m"

.PHONY: migrate
migrate: _render
	kubectl -n $(NAMESPACE) delete job unpod-migrate --ignore-not-found
	kubectl apply -f "$(BUILD_DIR)/migrate-job.yaml"
	kubectl -n $(NAMESPACE) wait --for=condition=complete job/unpod-migrate --timeout=300s

.PHONY: deploy
deploy: secrets deploy-platform deploy-voice migrate
	@echo "Deployed."
	@echo "Hosts: https://$(WEB_HOST)  https://$(API_HOST)"
	@echo "Next: make status"
	@echo "Optional LLM: make install-gpu-plugin && make deploy-llm"

.PHONY: deploy-all
deploy-all: deploy install-gpu-plugin deploy-llm
	@echo "Platform + voice + vLLM requested."

.PHONY: status
status:
	kubectl -n $(NAMESPACE) get pods,svc,ingress,hpa,job,pvc
	@echo ""
	@kubectl -n $(NAMESPACE) get ingress -o wide 2>/dev/null || true
	@echo ""
	@kubectl get nodes -l nvidia.com/gpu.present=true -o wide 2>/dev/null || \
		kubectl get nodes -o custom-columns=NAME:.metadata.name,INSTANCE:.metadata.labels.node\\.kubernetes\\.io/instance-type,TAINTS:.spec.taints 2>/dev/null || true

.PHONY: destroy-app
destroy-app:
	kubectl delete namespace $(NAMESPACE) --ignore-not-found
	@echo "Namespace $(NAMESPACE) deleted. ECR images and managed DBs retained."
