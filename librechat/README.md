# LibreChat + Groq on EKS (`core-cluster`)

Self-hosted [LibreChat](https://www.librechat.ai/) with **Groq** (OpenAI-compatible API), wired to the PoC stores already in this repo (Mongo, Redis, S3). Public URL: **`https://librechat.ntwtech.com`**.

## Prerequisites

- EKS up (`make -C ../eks setup` / Karpenter NodePools applied)
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

make secrets
make deploy
make endpoints

# If a previous Ollama GPU deploy is still pending:
make destroy-ollama
```

Point DNS (Route53 / Cloudflare CNAME) for **`librechat.ntwtech.com`** at the ALB hostname from `make endpoints`.

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
| RAG API | Disabled | Groq has no embeddings; re-enable when wiring another embed provider |
| Ingress | Helm → ALB (`ingressClassName: alb`) | Host `librechat.ntwtech.com` |

External (not installed by this folder): Mongo, Redis, Postgres, S3, Grafana Alloy.

## Groq models

Default chat model: `llama-3.3-70b-versatile` (`GROQ_MODEL` in `.env`).

Also listed in config: `llama-3.1-8b-instant`, `gemma2-9b-it`.

LibreChat keeps `apiKey: "${GROQ_API_KEY}"` in config and expands it from the pod Secret at runtime.

## Makefile targets

| Target | Purpose |
|--------|---------|
| `gen-secrets` | Fill empty `CREDS_*` / `JWT_*` / `MEILI_*` in `.env` |
| `secrets` | Apply `librechat-credentials-env` (+ vectordb secret for future RAG) |
| `init-postgres` | Optional `CREATE DATABASE` + `CREATE EXTENSION vector` |
| `destroy-ollama` | Remove leftover in-cluster Ollama / GPU pending pods |
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
  k8s/ollama/          # optional / legacy GPU path
eks/ ingress/ grafana/
postgres/ redis/ mongo/ s3/
```

## Notes

- Do not commit `.env`.
- Optional ECR cleanup after migration: delete unused `unpod-*` repositories in ECR.
- Grafana Cloud already scrapes the cluster; filter Loki/Prometheus by `namespace="librechat"`.
- To bring RAG back later: enable `librechat-rag-api` in `values.yaml.tpl` with a real embeddings provider (not Groq).
