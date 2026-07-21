CLUSTER_NAME ?= core-cluster
REGION ?= us-east-1
K8S_VERSION ?= 1.30
KARPENTER_VERSION ?= 1.14.0
KARPENTER_NAMESPACE ?= kube-system
AWS_PARTITION ?= aws
AWS_ACCOUNT_ID := $(shell aws sts get-caller-identity --query Account --output text)

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "EKS / Karpenter makefile"
	@echo ""
	@echo "Targets:"
	@echo "  help                     Show this help"
	@echo "  check                    Verify AWS identity and print cluster context"
	@echo "  create-roles             Create cluster and node IAM roles"
	@echo "  create-cluster           Deploy Karpenter CFN stack and create EKS cluster"
	@echo "  update-cluster-version   Upgrade EKS control plane to K8S_VERSION"
	@echo "  wire-karpenter-iam       Configure pod identity and node IAM mapping"
	@echo "  install-karpenter        Install/upgrade Karpenter via Helm"
	@echo "  install-karpenter-config Apply NodeClass and NodePool manifests"
	@echo "  setup                    Full bootstrap: roles, cluster, Karpenter"
	@echo "  destroy                  Delete EKS cluster and Karpenter CFN stack"
	@echo ""
	@echo "Variables (override with VAR=value):"
	@echo "  CLUSTER_NAME=$(CLUSTER_NAME)"
	@echo "  REGION=$(REGION)"
	@echo "  K8S_VERSION=$(K8S_VERSION)"
	@echo "  KARPENTER_VERSION=$(KARPENTER_VERSION)"
	@echo "  KARPENTER_NAMESPACE=$(KARPENTER_NAMESPACE)"
	@echo ""
	@echo "Example:"
	@echo "  make update-cluster-version K8S_VERSION=1.31"

.PHONY: check
check:
	@aws sts get-caller-identity | cat
	@echo "Cluster: $(CLUSTER_NAME) | Region: $(REGION) | Account: $(AWS_ACCOUNT_ID)"

.PHONY: create-roles
create-roles:
	@echo "Creating IAM Roles..."
	aws iam create-role --role-name $(CLUSTER_NAME)-ClusterRole \
		--assume-role-policy-document file://policies/cluster-trust-policy.json || true
	aws iam attach-role-policy --role-name $(CLUSTER_NAME)-ClusterRole \
		--policy-arn arn:aws:iam::aws:policy/AmazonEKSClusterPolicy
	aws iam create-role --role-name $(CLUSTER_NAME)-NodeRole \
		--assume-role-policy-document file://policies/node-trust-policy.json || true
	aws iam attach-role-policy --role-name $(CLUSTER_NAME)-NodeRole \
		--policy-arn arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy
	aws iam attach-role-policy --role-name $(CLUSTER_NAME)-NodeRole \
		--policy-arn arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy
	aws iam attach-role-policy --role-name $(CLUSTER_NAME)-NodeRole \
		--policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly

.PHONY: create-cluster
create-cluster: check
	@echo "Deploying Karpenter CloudFormation..."
	curl -fsSL https://raw.githubusercontent.com/aws/karpenter-provider-aws/v$(KARPENTER_VERSION)/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml > /tmp/karpenter-cf.yaml
	aws cloudformation deploy \
		--stack-name Karpenter-$(CLUSTER_NAME) \
		--template-file /tmp/karpenter-cf.yaml \
		--parameter-overrides ClusterName=$(CLUSTER_NAME) \
		--capabilities CAPABILITY_NAMED_IAM
	@echo "Creating EKS Cluster with eksctl..."
	AWS_ACCOUNT_ID=$(AWS_ACCOUNT_ID) envsubst '$${AWS_ACCOUNT_ID}' < cluster.yaml | eksctl create cluster -f -

.PHONY: update-cluster-version
update-cluster-version: check
	@echo "Updating EKS control plane to $(K8S_VERSION)..."
	aws eks update-cluster-version \
		--name $(CLUSTER_NAME) \
		--region $(REGION) \
		--kubernetes-version $(K8S_VERSION)
	@echo "Upgrade started. Check status with:"
	@echo "  aws eks describe-cluster --name $(CLUSTER_NAME) --region $(REGION) --query 'cluster.{status:status,version:version}'"

.PHONY: wire-karpenter-iam
wire-karpenter-iam: check
	@echo "Ensuring eks-pod-identity-agent addon..."
	eksctl create addon --name eks-pod-identity-agent --cluster $(CLUSTER_NAME) --region $(REGION) || true
	@echo "Creating Karpenter Pod Identity association..."
	eksctl create podidentityassociation \
		--cluster $(CLUSTER_NAME) \
		--region $(REGION) \
		--namespace $(KARPENTER_NAMESPACE) \
		--service-account-name karpenter \
		--role-name $(CLUSTER_NAME)-karpenter \
		--permission-policy-arns \
			arn:$(AWS_PARTITION):iam::$(AWS_ACCOUNT_ID):policy/KarpenterControllerNodeLifecyclePolicy-$(CLUSTER_NAME),arn:$(AWS_PARTITION):iam::$(AWS_ACCOUNT_ID):policy/KarpenterControllerIAMIntegrationPolicy-$(CLUSTER_NAME),arn:$(AWS_PARTITION):iam::$(AWS_ACCOUNT_ID):policy/KarpenterControllerEKSIntegrationPolicy-$(CLUSTER_NAME),arn:$(AWS_PARTITION):iam::$(AWS_ACCOUNT_ID):policy/KarpenterControllerInterruptionPolicy-$(CLUSTER_NAME),arn:$(AWS_PARTITION):iam::$(AWS_ACCOUNT_ID):policy/KarpenterControllerResourceDiscoveryPolicy-$(CLUSTER_NAME),arn:$(AWS_PARTITION):iam::$(AWS_ACCOUNT_ID):policy/KarpenterControllerZonalShiftPolicy-$(CLUSTER_NAME) \
		|| true
	@echo "Mapping Karpenter node role..."
	eksctl create iamidentitymapping \
		--cluster $(CLUSTER_NAME) \
		--region $(REGION) \
		--arn arn:$(AWS_PARTITION):iam::$(AWS_ACCOUNT_ID):role/KarpenterNodeRole-$(CLUSTER_NAME) \
		--username 'system:node:{{EC2PrivateDNSName}}' \
		--group system:bootstrappers \
		--group system:nodes \
		|| true

.PHONY: install-karpenter
install-karpenter: wire-karpenter-iam
	aws iam create-service-linked-role --aws-service-name spot.amazonaws.com || true
	helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
		--version $(KARPENTER_VERSION) \
		--namespace $(KARPENTER_NAMESPACE) --create-namespace \
		--set settings.clusterName=$(CLUSTER_NAME) \
		--set settings.interruptionQueue=$(CLUSTER_NAME) \
		--wait
	kubectl rollout restart deployment/karpenter -n $(KARPENTER_NAMESPACE)
	kubectl rollout status deployment/karpenter -n $(KARPENTER_NAMESPACE) --timeout=180s

.PHONY: install-karpenter-config
install-karpenter-config:
	kubectl apply -f karpenter/nodeclass.yaml
	kubectl apply -f karpenter/nodepool-core.yaml
	kubectl apply -f karpenter/nodepool-gpu.yaml

.PHONY: setup
setup: create-roles create-cluster install-karpenter install-karpenter-config
	@echo "Setup complete"
	@echo "Run: aws eks update-kubeconfig --name $(CLUSTER_NAME) --region $(REGION)"

.PHONY: destroy
destroy:
	eksctl delete cluster --name $(CLUSTER_NAME) --region $(REGION) --force || true
	aws cloudformation delete-stack --stack-name Karpenter-$(CLUSTER_NAME)
