CLUSTER_NAME ?= core-cluster
REGION ?= us-east-1
NAMESPACE ?= kube-system
RELEASE ?= aws-load-balancer-controller
SERVICE_ACCOUNT ?= aws-load-balancer-controller
CHART_REPO ?= https://aws.github.io/eks-charts
CHART ?= aws-load-balancer-controller
# Chart 1.14.x → controller v2.14.x (matches vendored IAM policy)
CHART_VERSION ?= 1.14.0
CONTROLLER_IAM_VERSION ?= v2.14.1
POLICY_NAME ?= AWSLoadBalancerControllerIAMPolicy
ROLE_NAME ?= $(CLUSTER_NAME)-aws-load-balancer-controller
AWS_PARTITION ?= aws
AWS_ACCOUNT_ID := $(shell aws sts get-caller-identity --query Account --output text 2>/dev/null)
DOMAIN ?= unpod.ntwtech.com

-include .env
export

CLUSTER_NAME := $(or $(CLUSTER_NAME),core-cluster)
REGION := $(or $(REGION),us-east-1)
NAMESPACE := $(or $(NAMESPACE),kube-system)
DOMAIN := $(or $(DOMAIN),unpod.ntwtech.com)

POLICY_ARN := arn:$(AWS_PARTITION):iam::$(AWS_ACCOUNT_ID):policy/$(POLICY_NAME)
ROLE_ARN := arn:$(AWS_PARTITION):iam::$(AWS_ACCOUNT_ID):role/$(ROLE_NAME)

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "AWS Load Balancer Controller (ALB) on EKS ($(CLUSTER_NAME))"
	@echo ""
	@echo "Targets:"
	@echo "  check          Verify AWS + kubectl + helm + .env"
	@echo "  create-iam     IAM policy + role + Pod Identity association"
	@echo "  tag-subnets    Ensure public subnets have kubernetes.io/role/elb=1"
	@echo "  repo           Add/update eks Helm repo"
	@echo "  crds           Apply TargetGroupBinding CRDs (needed on helm upgrade)"
	@echo "  ingressclass   Apply IngressClass named alb"
	@echo "  deploy         Install/upgrade controller + IngressClass"
	@echo "  status         Controller pods + cluster Ingresses"
	@echo "  endpoints      Print Unpod ALB hostname (after unpod deploy)"
	@echo "  logs           Tail controller logs"
	@echo "  destroy        Uninstall Helm release (keeps IAM; does not delete ALBs)"
	@echo ""
	@echo "Prereq: EKS up (make -C ../eks setup), kubectl context set"
	@echo "Usage:"
	@echo "  cp .env.example .env   # optional ACM_CERTIFICATE_ARN"
	@echo "  make deploy"
	@echo "  make -C ../unpod deploy"
	@echo ""
	@echo "Variables:"
	@echo "  CLUSTER_NAME=$(CLUSTER_NAME)  REGION=$(REGION)  NAMESPACE=$(NAMESPACE)"
	@echo "  RELEASE=$(RELEASE)  CHART_VERSION=$(CHART_VERSION)"
	@echo "  ROLE_NAME=$(ROLE_NAME)"

.PHONY: check
check:
	@test -f .env || cp .env.example .env
	@command -v helm >/dev/null || (echo "Missing helm. Install: https://helm.sh/docs/intro/install/" && exit 1)
	@command -v kubectl >/dev/null || (echo "Missing kubectl" && exit 1)
	@command -v aws >/dev/null || (echo "Missing aws CLI" && exit 1)
	@command -v eksctl >/dev/null || (echo "Missing eksctl" && exit 1)
	@test -n "$(AWS_ACCOUNT_ID)" || (echo "AWS_ACCOUNT_ID empty — aws sts get-caller-identity failed" && exit 1)
	@aws sts get-caller-identity | cat
	@kubectl config current-context
	@kubectl get --raw=/readyz >/dev/null 2>&1 \
		|| (echo "Cannot reach EKS API."; \
		    echo "Try: aws eks update-kubeconfig --name $(CLUSTER_NAME) --region $(REGION)"; exit 1)
	@echo "Cluster: $(CLUSTER_NAME) | Region: $(REGION) | Account: $(AWS_ACCOUNT_ID)"

.PHONY: create-iam
create-iam: check
	@echo "Ensuring IAM policy $(POLICY_NAME)..."
	@aws iam get-policy --policy-arn "$(POLICY_ARN)" >/dev/null 2>&1 \
		|| aws iam create-policy \
			--policy-name "$(POLICY_NAME)" \
			--policy-document file://policies/iam-policy.json
	@echo "Ensuring IAM role $(ROLE_NAME)..."
	@aws iam get-role --role-name "$(ROLE_NAME)" >/dev/null 2>&1 \
		|| aws iam create-role \
			--role-name "$(ROLE_NAME)" \
			--assume-role-policy-document file://policies/pod-identity-trust-policy.json
	@aws iam attach-role-policy \
		--role-name "$(ROLE_NAME)" \
		--policy-arn "$(POLICY_ARN)" 2>/dev/null || true
	@echo "Ensuring eks-pod-identity-agent addon..."
	eksctl create addon --name eks-pod-identity-agent \
		--cluster $(CLUSTER_NAME) --region $(REGION) || true
	@echo "Creating Pod Identity association..."
	eksctl create podidentityassociation \
		--cluster $(CLUSTER_NAME) \
		--region $(REGION) \
		--namespace $(NAMESPACE) \
		--service-account-name $(SERVICE_ACCOUNT) \
		--role-arn "$(ROLE_ARN)" \
		|| true
	@echo "IAM ready: $(ROLE_ARN)"

.PHONY: _vpc-id
_vpc-id:
	@if [ -n "$(VPC_ID)" ]; then echo "$(VPC_ID)"; \
	else aws eks describe-cluster --name $(CLUSTER_NAME) --region $(REGION) \
		--query 'cluster.resourcesVpcConfig.vpcId' --output text; fi

.PHONY: tag-subnets
tag-subnets: check
	@echo "Tagging public subnets in cluster VPC for internet-facing ALB..."
	@VPC=$$($(MAKE) --no-print-directory _vpc-id); \
	SUBNETS=$$(aws ec2 describe-subnets --region $(REGION) \
		--filters "Name=vpc-id,Values=$$VPC" \
		--query 'Subnets[?MapPublicIpOnLaunch==`true`].SubnetId' --output text); \
	if [ -z "$$SUBNETS" ]; then \
		echo "No MapPublicIpOnLaunch=true subnets found in $$VPC — tag manually:"; \
		echo "  kubernetes.io/role/elb=1 on public subnets"; \
		exit 1; \
	fi; \
	for s in $$SUBNETS; do \
		echo "  $$s → kubernetes.io/role/elb=1"; \
		aws ec2 create-tags --region $(REGION) --resources $$s \
			--tags Key=kubernetes.io/role/elb,Value=1; \
	done; \
	echo "Also ensure cluster discovery tag exists (karpenter.sh/discovery=$(CLUSTER_NAME))."

.PHONY: repo
repo:
	helm repo add eks $(CHART_REPO) 2>/dev/null || true
	helm repo update eks

.PHONY: crds
crds:
	kubectl apply -f https://raw.githubusercontent.com/aws/eks-charts/master/stable/aws-load-balancer-controller/crds/crds.yaml

.PHONY: ingressclass
ingressclass:
	kubectl apply -f k8s/ingressclass-alb.yaml
	@echo "IngressClass alb applied (matches unpod ingressClassName)"

.PHONY: deploy
deploy: create-iam tag-subnets repo ingressclass
	@VPC=$$($(MAKE) --no-print-directory _vpc-id); \
	echo "Installing $(RELEASE) (chart $(CHART_VERSION)) vpc=$$VPC ..."; \
	helm upgrade --install $(RELEASE) eks/$(CHART) \
		--version $(CHART_VERSION) \
		--namespace $(NAMESPACE) --create-namespace \
		--set clusterName=$(CLUSTER_NAME) \
		--set region=$(REGION) \
		--set vpcId=$$VPC \
		--set serviceAccount.create=true \
		--set serviceAccount.name=$(SERVICE_ACCOUNT) \
		--wait --timeout 5m
	@$(MAKE) --no-print-directory status
	@echo ""
	@echo "Next: make -C ../unpod deploy"
	@echo "Optional ACM: set ACM_CERTIFICATE_ARN in .env then re-deploy Unpod"

.PHONY: status
status:
	@echo "==== Helm release ===="
	helm -n $(NAMESPACE) status $(RELEASE) 2>/dev/null || true
	@echo ""
	@echo "==== Controller pods ===="
	kubectl -n $(NAMESPACE) get deploy,pods -l app.kubernetes.io/name=aws-load-balancer-controller -o wide 2>/dev/null || true
	@echo ""
	@echo "==== IngressClass ===="
	kubectl get ingressclass alb 2>/dev/null || true
	@echo ""
	@echo "==== Ingresses (all namespaces) ===="
	kubectl get ingress -A -o wide 2>/dev/null || true

.PHONY: endpoints
endpoints:
	@echo "Unpod ALB (after make -C ../unpod deploy):"
	@HOST=$$(kubectl -n unpod get ingress unpod -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null); \
	if [ -n "$$HOST" ]; then \
		echo "  ALB hostname: $$HOST"; \
		echo "  Point DNS for app/api/chat/realtime.$(DOMAIN) → $$HOST (Alias A / CNAME)"; \
	else \
		echo "  (Ingress not ready yet — deploy Unpod, then re-run make endpoints)"; \
	fi
	@if [ -n "$(ACM_CERTIFICATE_ARN)" ]; then \
		echo "  ACM: $(ACM_CERTIFICATE_ARN)"; \
	else \
		echo "  Tip: set ACM_CERTIFICATE_ARN in .env for HTTPS on Unpod Ingress"; \
	fi

.PHONY: logs
logs:
	kubectl -n $(NAMESPACE) logs -f deploy/$(RELEASE) --all-containers=true

.PHONY: destroy
destroy:
	@echo "Uninstalling Helm release $(RELEASE) (ALBs created by Ingress may remain until Ingress is deleted)..."
	helm -n $(NAMESPACE) uninstall $(RELEASE) --wait 2>/dev/null || true
	kubectl delete ingressclass alb --ignore-not-found
	@echo "Kept IAM role/policy and Pod Identity association."
	@echo "To remove Unpod Ingress/ALB: make -C ../unpod destroy-app"
