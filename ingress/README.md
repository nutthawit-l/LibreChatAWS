# AWS Load Balancer Controller (ALB) on EKS (`core-cluster`)

Installs the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
so Kubernetes `Ingress` resources with `ingressClassName: alb` provision internet-facing ALBs.

Unpod already defines host rules in `unpod/k8s/base/ingress.yaml.tpl` — this folder owns the **controller + IAM + IngressClass**, not the app routes.

## Prerequisites

- EKS up (`make -C ../eks setup`), `kubectl` context on `core-cluster`
- Helm 3, AWS CLI, eksctl
- ACM certificate covering Unpod hosts (recommended for HTTPS):
  - `app.unpod.ntwtech.com`
  - `api.unpod.ntwtech.com`
  - `chat.unpod.ntwtech.com`
  - `realtime.unpod.ntwtech.com`

## Quick path

```bash
cd ingress

cp .env.example .env
# optional: set ACM_CERTIFICATE_ARN=arn:aws:acm:us-east-1:...:certificate/...

make deploy
make status

# Then deploy Unpod (reads ACM from ../ingress/.env when set)
make -C ../unpod deploy
make endpoints
```

Point Route53 (or your DNS) Alias/CNAME records at the ALB hostname from `make endpoints`.

## What gets installed

| Piece | Purpose |
|-------|---------|
| IAM policy `AWSLoadBalancerControllerIAMPolicy` | ELB/EC2/ACM permissions (vendored under `policies/`) |
| IAM role `core-cluster-aws-load-balancer-controller` | Pod Identity trust (`pods.eks.amazonaws.com`) |
| Pod Identity association | Binds role → `kube-system/aws-load-balancer-controller` SA |
| Helm `aws-load-balancer-controller` | Provisions ALB/NLB from Ingress/Service |
| `IngressClass` `alb` | Matches Unpod `ingressClassName: alb` |
| Subnet tags `kubernetes.io/role/elb=1` | Public subnets discoverable for internet-facing ALB |

## Integrate with Unpod

1. `make deploy` here (controller must be Ready before Ingress reconciles).
2. Set `ACM_CERTIFICATE_ARN` in `ingress/.env` (optional but needed for HTTPS listeners with an explicit cert).
3. `make -C ../unpod deploy` — Unpod renders Ingress hosts and, when present, injects the ACM annotation from `../ingress/.env`.
4. `make endpoints` — prints the ALB DNS name for DNS cutover.

App Ingress stays in Unpod; do not put postgres/redis/mongo/grafana behind this ALB.

## Makefile targets

| Target | Purpose |
|--------|---------|
| `check` | AWS + kubectl + helm |
| `create-iam` | Policy, role, Pod Identity |
| `tag-subnets` | Tag public subnets for ALB |
| `repo` | Add/update `eks` Helm repo |
| `crds` | Apply CRDs (needed on chart upgrade) |
| `ingressclass` | Apply `alb` IngressClass |
| `deploy` | Full install/upgrade |
| `status` | Controller + Ingresses |
| `endpoints` | Unpod ALB hostname |
| `logs` | Tail controller |
| `destroy` | Uninstall Helm + IngressClass (keeps IAM) |

## Layout

```
ingress/
  makefile
  .env.example
  README.md
  policies/
    iam-policy.json                 # LBC v2.14.1
    pod-identity-trust-policy.json
  k8s/
    ingressclass-alb.yaml
```

## Notes

- Do not commit `.env`.
- Chart pin: `CHART_VERSION` (default `1.14.0`). Bump `CONTROLLER_IAM_VERSION` / refresh `policies/iam-policy.json` together when upgrading.
- `make destroy` does **not** delete live ALBs; delete the Unpod Ingress (or `make -C ../unpod destroy-app`) first.
- After Karpenter bootstrap: `make -C ../eks setup` → `make -C ../ingress deploy` → app deploys.
