# Unpod on EKS (`core-cluster`)

Scaffold to build images into ECR and deploy Unpod onto your Karpenter-backed cluster.
Optional: self-hosted LLM via vLLM on `gpu-pool`.

## Prerequisites

- EKS cluster up (`make -C eks setup` / Karpenter NodePools applied)
- `kubectl` context pointing at `core-cluster`
- Docker + AWS CLI
- AWS Load Balancer Controller installed (for ALB Ingress)
- Managed data stores in the same VPC:
  - RDS PostgreSQL 16
  - ElastiCache Redis
  - DocumentDB or MongoDB Atlas
  - S3 bucket for media
- **PoC alternative:** self-host DBs on EKS:
  - `make -C postgres deploy`
  - `make -C redis deploy`
  - `make -C mongo deploy`
  Then copy connection strings from each `make conninfo` into `unpod/.env.prod`
- LiveKit Cloud (or self-hosted) + STT/TTS API keys
- For self-hosted LLM: GPU NodeClass + NVIDIA device plugin (see below)

## Quick path

```bash
cd unpod

# 1. Fill secrets
cp .env.prod.example .env.prod
# edit .env.prod — DB/LiveKit/AI keys + PUBLIC_* URLs

# 2. Build & push images (clones unpod into .cache/unpod)
make build-push

# 3. Deploy platform + voice
make deploy DOMAIN=yourdomain.com

# 4. (Optional) Self-hosted LLM on GPU nodes
make -C ../eks install-karpenter-config   # applies nodeclass-gpu + gpu-pool
make install-gpu-plugin
make deploy-llm                           # default: Qwen/Qwen2.5-7B-Instruct
# or: make deploy-llm VLLM_MODEL=meta-llama/Llama-3.1-8B-Instruct

# 5. Watch
make status
```

Point DNS (or Route53 alias) at the ALB hostname from `kubectl -n unpod get ingress`.

Add your ACM cert ARN to `k8s/base/ingress.yaml.tpl` before deploy:

```yaml
alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:ACCOUNT:certificate/ID
```

## What gets deployed

| Component | Image / chart | Node pool |
|-----------|---------------|-----------|
| `web` | ECR `unpod-web` | Karpenter `core-pool` |
| `backend-core` | ECR `unpod-backend-core` | `core-pool` |
| `api-services` | ECR `unpod-api-services` | `core-pool` |
| `centrifugo` | `centrifugo/centrifugo:v5` | `core-pool` |
| `voice-executor` | ECR `unpod-voice-executor` (8 CPU / 16Gi) | `core-pool` |
| `vllm` (optional) | `vllm/vllm-openai` + 1× GPU | `gpu-pool` (`g5.*` preferred) |
| migrate Job | same as backend-core | once |

## Self-hosted LLM (vLLM)

1. **GPU NodeClass** (`eks/karpenter/nodeclass-gpu.yaml`) uses `al2023@latest` so Karpenter selects the **NVIDIA accelerated AMI** when pods request `nvidia.com/gpu`.
2. **`gpu-pool`** is tainted with `nvidia.com/gpu=true:NoSchedule` (on-demand only).
3. **NVIDIA device plugin** exposes GPUs to the scheduler (`make install-gpu-plugin`).
4. **vLLM** serves OpenAI-compatible API at `http://vllm.unpod.svc.cluster.local:8000/v1`.

Wire Unpod / clients via `.env.prod`:

```bash
OPENAI_BASE_URL=http://vllm.unpod.svc.cluster.local:8000/v1
OPENAI_API_KEY=local-vllm
LLM_MODEL=local-llm
```

Smoke test from any pod in the cluster:

```bash
kubectl -n unpod exec deploy/backend-core -- \
  curl -s http://vllm:8000/v1/models
```

Default model `Qwen/Qwen2.5-7B-Instruct` fits **g5.xlarge** (A10G 24GB). First start downloads weights to a 50Gi PVC (can take several minutes).

## Makefile targets

| Target | Purpose |
|--------|---------|
| `clone-unpod` | Fetch upstream source |
| `ecr-create` | Create 4 ECR repos |
| `build-push` | Build amd64 images + push |
| `secrets` | Apply `.env.prod` as K8s secrets |
| `deploy-platform` | web / APIs / centrifugo / ingress |
| `deploy-voice` | voice-executor + HPA |
| `install-gpu-plugin` | NVIDIA device plugin DaemonSet |
| `deploy-llm` | vLLM on gpu-pool |
| `migrate` | Django migrate Job |
| `deploy` | secrets + platform + voice + migrate |
| `deploy-all` | deploy + GPU plugin + vLLM |
| `status` | Pods / ingress / HPA / PVC |
| `destroy-app` | Delete `unpod` namespace only |

## Layout

```
unpod/                    # app deploy (this folder)
  makefile
  .env.prod.example
  docker/
  k8s/base/
  k8s/overlays/prod/
  k8s/voice/
  k8s/llm/
eks/                      # cluster bootstrap
  makefile
  cluster.yaml
  karpenter/
    nodeclass-gpu.yaml
    nodepool-gpu.yaml
postgres/ redis/ mongo/   # PoC self-hosted DBs
```

## Notes

- Images are forced to `linux/amd64` to match Karpenter pools (system nodes are ARM `t4g`).
- Voice pods request **8 CPU / 16Gi** each. Expect Karpenter to launch larger `c`/`m`/`r` instances.
- GPU nodes are expensive — deploy LLM only when needed; Karpenter consolidates after idle (`consolidateAfter: 5m` on gpu-pool).
- Do not commit `.env.prod`.
- Prefect (optional) is not wired here; use upstream `apps/super/deployment/k8s` Prefect overlays if needed.
