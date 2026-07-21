NAMESPACE ?= postgres
STORAGE_CLASS ?= gp3
STORAGE_SIZE ?= 10Gi
IMAGE ?= postgres:16-alpine

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Self-hosted PostgreSQL (PoC) on EKS"
	@echo ""
	@echo "Targets:"
	@echo "  secrets   Create/update Secret from .env"
	@echo "  deploy    Apply namespace + StatefulSet + Service"
	@echo "  status    Show pods / pvc / svc"
	@echo "  diagnose  Show why pod is not Ready"
	@echo "  logs      Tail postgres logs"
	@echo "  destroy   Delete namespace (wipes PVC data)"
	@echo "  conninfo  Print in-cluster connection details"
	@echo ""
	@echo "Prereq: make -C ../eks install-ebs-csi"
	@echo "Usage:"
	@echo "  cp .env.example .env && edit passwords"
	@echo "  make secrets && make deploy"

.PHONY: secrets
secrets:
	@test -f .env || (echo "Missing .env — copy from .env.example" && exit 1)
	kubectl get ns $(NAMESPACE) >/dev/null 2>&1 || kubectl create namespace $(NAMESPACE)
	kubectl -n $(NAMESPACE) create secret generic postgres-credentials \
		--from-env-file=.env \
		--dry-run=client -o yaml | kubectl apply -f -

.PHONY: deploy
deploy: secrets
	STORAGE_CLASS=$(STORAGE_CLASS) STORAGE_SIZE=$(STORAGE_SIZE) IMAGE=$(IMAGE) \
		envsubst '$${STORAGE_CLASS} $${STORAGE_SIZE} $${IMAGE}' \
		< k8s/statefulset.yaml.tpl > /tmp/postgres-statefulset.yaml
	kubectl apply -f k8s/namespace.yaml
	kubectl apply -f /tmp/postgres-statefulset.yaml
	kubectl apply -f k8s/service.yaml
	@kubectl -n $(NAMESPACE) rollout status statefulset/postgres --timeout=300s \
		|| ($(MAKE) --no-print-directory diagnose && exit 1)
	@$(MAKE) --no-print-directory conninfo

.PHONY: diagnose
diagnose:
	@echo "==== pods / pvc ===="
	kubectl -n $(NAMESPACE) get pods,pvc,sts -o wide || true
	@echo ""
	@echo "==== pod describe (events) ===="
	kubectl -n $(NAMESPACE) describe pod -l app=postgres 2>/dev/null | sed -n '/Events:/,$$p' || true
	@echo ""
	@echo "==== pvc describe ===="
	kubectl -n $(NAMESPACE) describe pvc 2>/dev/null | sed -n '/Name:/,/Events:/p;/Events:/,$$p' | head -80 || true
	@echo ""
	@echo "==== storage classes ===="
	kubectl get sc || true
	@echo ""
	@echo "==== recent events ===="
	kubectl -n $(NAMESPACE) get events --sort-by=.lastTimestamp | tail -20 || true
	@echo ""
	@echo "Common fixes:"
	@echo "  1) No volume:  make -C ../eks install-ebs-csi"
	@echo "  2) No NodePool: make -C ../eks install-karpenter-config"
	@echo "  3) Retry:      make destroy && make deploy"

.PHONY: status
status:
	kubectl -n $(NAMESPACE) get pods,svc,pvc,statefulset

.PHONY: logs
logs:
	kubectl -n $(NAMESPACE) logs -f statefulset/postgres

.PHONY: destroy
destroy:
	kubectl delete namespace $(NAMESPACE) --ignore-not-found
	@echo "Namespace $(NAMESPACE) deleted (data wiped)."

.PHONY: conninfo
conninfo:
	@echo ""
	@echo "In-cluster DSN (for Unpod .env.prod):"
	@echo "  POSTGRES_HOST=postgres.$(NAMESPACE).svc.cluster.local"
	@echo "  POSTGRES_PORT=5432"
	@echo "  POSTGRES_DB=$$(grep ^POSTGRES_DB= .env 2>/dev/null | cut -d= -f2- || echo unpod_db)"
	@echo "  POSTGRES_USER=$$(grep ^POSTGRES_USER= .env 2>/dev/null | cut -d= -f2- || echo unpod)"
