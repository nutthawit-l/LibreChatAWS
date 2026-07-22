# LibreChat + Groq + self-host Ollama on EKS (`core-cluster`)

Self-hosted [LibreChat](https://www.librechat.ai/) with **Groq** (hosted API) and optional **Ollama** on Karpenter `gpu-pool` (`g5g` ARM + T4G). Public URL: **`https://librechat.ntwtech.com`**.

## Prerequisites

- EKS up (`make -C ../eks setup` / Karpenter NodePools applied — `gpu-pool` is arm64/`g5g`)
- `kubectl` context on `core-cluster`
- Helm 3, `envsubst` (gettext), openssl
- AWS Load Balancer Controller: `make -C ../ingress deploy`
- Data stores:
  - `make -C ../redis deploy`
  - `make -C ../mongo deploy`
  - `make -C ../s3 create && make -C ../s3 create-user`
  - Postgres optional (RAG API is **disabled** while using Groq — no embeddings API)
- ACM certificate whose SANs include **`librechat.ntwtech.com`**
  - Set `ACM_CERTIFICATE_ARN` in [`../ingress/.env`](../ingress/.env)
- Groq API key from https://console.groq.com/keys
- Optional observability: `make -C ../grafana deploy`

## Quick path

```bash
# If Unpod is still on the cluster
make destroy-unpod

make -C ../ingress deploy

cd librechat
cp .env.example .env
make gen-secrets

# Copy connection strings from:
#   make -C ../mongo conninfo
#   make -C ../redis conninfo
# S3 keys are written by: make -C ../s3 create-user
# Set GROQ_API_KEY=... and OPENAI_API_KEY=... (same value) in .env
# Optional: OLLAMA_MODEL=qwen2.5:0.5b (default)

make install-gpu-plugin
make deploy-llm          # g5g + pull OLLAMA_MODEL
make secrets
make deploy
make endpoints
```

Point DNS (Route53 / Cloudflare CNAME) for **`librechat.ntwtech.com`** at the ALB hostname from `make endpoints`.

In the UI: use endpoint **Groq** or **Self-host** (`qwen2.5:0.5b`).

## DNS / ACM

1. In ACM (same region as the cluster, usually `us-east-1`), issue or update a certificate that includes `librechat.ntwtech.com`.
2. Put the ARN in `../ingress/.env` as `ACM_CERTIFICATE_ARN=arn:aws:acm:...`.
3. Re-run `make deploy` (or `make values && helm upgrade ...`) so the Ingress annotation picks up the cert.
4. Create DNS: `librechat.ntwtech.com` → ALB hostname from `make endpoints`.

Without a matching ACM cert, HTTPS on the ALB will fail even if HTTP redirect annotations are set.

## What gets deployed

| Component | How | Notes |
|-----------|-----|--------|
| LibreChat | Helm `oci://ghcr.io/danny-avila/librechat-chart/librechat` | Namespace `librechat`, port 3080 |
| Meilisearch | Chart subchart | Search index |
| Ollama | `k8s/ollama/` + `make deploy-llm` | ClusterIP only; `g5g` via `gpu-pool` |
| RAG API | Disabled | Groq has no embeddings; re-enable when wiring another embed provider |
| Ingress | Helm → ALB (`ingressClassName: alb`) | Host `librechat.ntwtech.com` |

External (not installed by this folder): Mongo, Redis, Postgres, S3, Grafana Alloy.

## LLM endpoints

### Groq

Default chat model: `llama-3.3-70b-versatile` (`GROQ_MODEL` in `.env`).

Also listed: `llama-3.1-8b-instant`, `gemma2-9b-it`.

LibreChat expands `${GROQ_API_KEY}` from Secret `librechat-credentials-env`.

### Self-host (Ollama on g5g)

- Base URL: `http://ollama.librechat.svc.cluster.local:11434/v1/`
- Default model: `qwen2.5:0.5b` (`OLLAMA_MODEL`) on `gpu-pool` (`g5g.2xlarge` / `g5g.xlarge`, arm64 + T4G)
- Requires **Running On-Demand G and VT instances** quota &gt; 0 (recommend ≥ 8 vCPUs) in `us-east-1`

```bash
# After quota is approved:
aws service-quotas get-service-quota --service-code ec2 --quota-code L-DB2E81BA --region us-east-1 --query 'Quota.Value'
make deploy-llm   # apply-gpu-pool + device plugin + Ollama + pull model
make secrets && make deploy
```

GPU NodeClass (`gpu`) pins AL2023 **arm64 NVIDIA** AMI via SSM  
`/aws/service/eks/optimized-ami/1.31/amazon-linux-2023/arm64/nvidia/recommended/image_id`  
(update `1.31` if the cluster Kubernetes version changes).

## Makefile targets

| Target | Purpose |
|--------|---------|
| `gen-secrets` | Fill empty `CREDS_*` / `JWT_*` / `MEILI_*` in `.env` |
| `secrets` | Apply `librechat-credentials-env` (+ vectordb secret for future RAG) |
| `init-postgres` | Optional `CREATE DATABASE` + `CREATE EXTENSION vector` |
| `install-gpu-plugin` | NVIDIA device plugin DaemonSet |
| `deploy-llm` | Deploy Ollama on g5g + `ollama pull $(OLLAMA_MODEL)` |
| `status-llm` | Ollama pods / listed models |
| `destroy-llm` / `destroy-ollama` | Remove Ollama Deployment/Service/PVC |
| `deploy` | Helm install/upgrade LibreChat |
| `status` / `endpoints` | Ops helpers |
| `destroy` | Remove LibreChat namespace |
| `destroy-unpod` | Delete legacy `unpod` namespace |

## Layout

```
librechat/
  makefile
  .env.example
  values.yaml.tpl
  README.md
  k8s/ollama/          # Ollama on gpu-pool (g5g / ARM)
eks/ ingress/ grafana/
postgres/ redis/ mongo/ s3/
```

## Notes

- Do not commit `.env`.
- Optional ECR cleanup after migration: delete unused `unpod-*` repositories in ECR.
- Grafana Cloud already scrapes the cluster; filter Loki/Prometheus by `namespace="librechat"`.
- Backend tracing: `OTEL_*` in `.env` points at Alloy (`make -C ../grafana endpoints`). In Grafana: **Drilldown → Traces** or **Explore → Tempo**, service `librechat`.
- To bring RAG back later: enable `librechat-rag-api` in `values.yaml.tpl` with a real embeddings provider (not Groq).
- Ollama is ClusterIP only — not exposed on the ALB.
