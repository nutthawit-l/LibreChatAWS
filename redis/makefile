NAMESPACE ?= redis
STORAGE_CLASS ?= gp3
STORAGE_SIZE ?= 5Gi
IMAGE ?= redis:7-alpine

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Self-hosted Redis (PoC) on EKS"
	@echo ""
	@echo "Targets:"
	@echo "  secrets   Create/update Secret from .env"
	@echo "  deploy    Apply namespace + StatefulSet + Service"
	@echo "  status    Show pods / pvc / svc"
	@echo "  diagnose  Show why pod is not Ready"
	@echo "  logs      Tail redis logs"
	@echo "  destroy   Delete namespace (wipes PVC data)"
	@echo "  conninfo  Print in-cluster connection details"
	@echo ""
	@echo "Prereq: make -C ../eks install-ebs-csi"
	@echo "        make -C ../eks install-karpenter-config  # if nodes are full"
	@echo "Usage:"
	@echo "  cp .env.example .env && edit password"
	@echo "  make secrets && make deploy"

.PHONY: secrets
secrets:
	@test -f .env || (echo "Missing .env — copy from .env.example" && exit 1)
	kubectl get ns $(NAMESPACE) >/dev/null 2>&1 || kubectl create namespace $(NAMESPACE)
	kubectl -n $(NAMESPACE) create secret generic redis-credentials \
		--from-env-file=.env \
		--dry-run=client -o yaml | kubectl apply -f -

.PHONY: deploy
deploy: secrets
	STORAGE_CLASS=$(STORAGE_CLASS) STORAGE_SIZE=$(STORAGE_SIZE) IMAGE=$(IMAGE) \
		envsubst '$${STORAGE_CLASS} $${STORAGE_SIZE} $${IMAGE}' \
		< k8s/statefulset.yaml.tpl > /tmp/redis-statefulset.yaml
	kubectl apply -f k8s/namespace.yaml
	kubectl apply -f /tmp/redis-statefulset.yaml
	kubectl apply -f k8s/service.yaml
	@kubectl -n $(NAMESPACE) rollout status statefulset/redis --timeout=300s \
		|| ($(MAKE) --no-print-directory diagnose && exit 1)
	@$(MAKE) --no-print-directory conninfo

.PHONY: diagnose
diagnose:
	@echo "==== pods / pvc ===="
	kubectl -n $(NAMESPACE) get pods,pvc,sts -o wide || true
	@echo ""
	@echo "==== pod describe (events) ===="
	kubectl -n $(NAMESPACE) describe pod -l app=redis 2>/dev/null | sed -n '/Events:/,$$p' || true
	@echo ""
	@echo "==== node memory pressure ===="
	kubectl top nodes 2>/dev/null || kubectl describe nodes | grep -E 'Name:|Allocatable:|Allocated resources:|memory' | head -40 || true
	@echo ""
	@echo "==== storage classes ===="
	kubectl get sc || true
	@echo ""
	@echo "Common fixes:"
	@echo "  1) Insufficient memory on t4g.small: make -C ../eks install-karpenter-config"
	@echo "  2) No volume: make -C ../eks install-ebs-csi"
	@echo "  3) Retry: make destroy && make deploy"

.PHONY: status
status:
	kubectl -n $(NAMESPACE) get pods,svc,pvc,statefulset

.PHONY: logs
logs:
	kubectl -n $(NAMESPACE) logs -f statefulset/redis

.PHONY: destroy
destroy:
	kubectl delete namespace $(NAMESPACE) --ignore-not-found
	@echo "Namespace $(NAMESPACE) deleted (data wiped)."

.PHONY: conninfo
conninfo:
	@PASS=$$(grep ^REDIS_PASSWORD= .env 2>/dev/null | cut -d= -f2-); \
	echo ""; \
	echo "In-cluster URL (for librechat/.env):"; \
	echo "  REDIS_URI=redis://:$${PASS}@redis.$(NAMESPACE).svc.cluster.local:6379/0"
