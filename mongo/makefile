NAMESPACE ?= mongo
STORAGE_CLASS ?= gp3
STORAGE_SIZE ?= 10Gi
IMAGE ?= mongo:7

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Self-hosted MongoDB (PoC) on EKS"
	@echo ""
	@echo "Targets:"
	@echo "  secrets   Create/update Secret from .env"
	@echo "  deploy    Apply namespace + StatefulSet + Service"
	@echo "  status    Show pods / pvc / svc"
	@echo "  logs      Tail mongo logs"
	@echo "  destroy   Delete namespace (wipes PVC data)"
	@echo "  conninfo  Print in-cluster connection details"
	@echo ""
	@echo "Usage:"
	@echo "  cp .env.example .env && edit passwords"
	@echo "  make secrets && make deploy"

.PHONY: secrets
secrets:
	@test -f .env || (echo "Missing .env — copy from .env.example" && exit 1)
	kubectl get ns $(NAMESPACE) >/dev/null 2>&1 || kubectl create namespace $(NAMESPACE)
	kubectl -n $(NAMESPACE) create secret generic mongo-credentials \
		--from-env-file=.env \
		--dry-run=client -o yaml | kubectl apply -f -

.PHONY: deploy
deploy: secrets
	STORAGE_CLASS=$(STORAGE_CLASS) STORAGE_SIZE=$(STORAGE_SIZE) IMAGE=$(IMAGE) \
		envsubst '$${STORAGE_CLASS} $${STORAGE_SIZE} $${IMAGE}' \
		< k8s/statefulset.yaml.tpl > /tmp/mongo-statefulset.yaml
	kubectl apply -f k8s/namespace.yaml
	kubectl apply -f /tmp/mongo-statefulset.yaml
	kubectl apply -f k8s/service.yaml
	kubectl -n $(NAMESPACE) rollout status statefulset/mongo --timeout=300s
	@$(MAKE) --no-print-directory conninfo

.PHONY: status
status:
	kubectl -n $(NAMESPACE) get pods,svc,pvc,statefulset

.PHONY: logs
logs:
	kubectl -n $(NAMESPACE) logs -f statefulset/mongo

.PHONY: destroy
destroy:
	kubectl delete namespace $(NAMESPACE) --ignore-not-found
	@echo "Namespace $(NAMESPACE) deleted (data wiped)."

.PHONY: conninfo
conninfo:
	@USER=$$(grep ^MONGO_USER= .env 2>/dev/null | cut -d= -f2-); \
	PASS=$$(grep ^MONGO_PASSWORD= .env 2>/dev/null | cut -d= -f2-); \
	DB=$$(grep ^MONGO_DB= .env 2>/dev/null | cut -d= -f2-); \
	echo ""; \
	echo "In-cluster DSN (for librechat/.env):"; \
	echo "  MONGO_URI=mongodb://$${USER}:$${PASS}@mongo.$(NAMESPACE).svc.cluster.local:27017/LibreChat?authSource=admin"
