# LibreChat + Ollama on EKS (`core-cluster`)

Self-hosted [LibreChat](https://www.librechat.ai/) with in-cluster **Ollama**, wired to the PoC stores already in this repo (Mongo, Redis, Postgres/pgvector, S3). Public URL: **`https://librechat.ntwtech.com`**.

## Prerequisites

- EKS up (`make -C ../eks setup` / Karpenter NodePools applied)
- `kubectl` context on `core-cluster`
- Helm 3, `envsubst` (gettext), openssl
- AWS Load Balancer Controller: `make -C ../ingress deploy`
- Data stores:
  - `make -C ../postgres deploy` — use **pgvector** image (see `postgres/makefile`)
  - `make -C ../redis deploy`
  - `make -C ../mongo deploy`
  - `make -C ../s3 create && make -C ../s3 create-user`
- ACM certificate whose SANs include **`librechat.ntwtech.com`**
  - Set `ACM_CERTIFICATE_ARN` in [`../ingress/.env`](../ingress/.env)
- GPU for Ollama: `make -C ../eks install-karpenter-config` (gpu-pool) + `make install-gpu-plugin`
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
#   make -C ../postgres conninfo
# S3 keys are written by: make -C ../s3 create-user
# Ensure POSTGRES_USER / POSTGRES_PASSWORD match ../postgres/.env

make install-gpu-plugin
make deploy-ollama
make secrets
make init-postgres
make deploy
make endpoints
```

Point DNS (Route53 Alias/CNAME) for **`librechat.ntwtech.com`** at the ALB hostname from `make endpoints`.

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
| RAG API | Chart subchart | Uses **external** Postgres + pgvector |
| Ollama | `k8s/ollama/` | `gpu-pool`, models on PVC |
| Ingress | Helm → ALB (`ingressClassName: alb`) | Host `librechat.ntwtech.com` |

External (not installed by this folder): Mongo, Redis, Postgres, S3, Grafana Alloy.

## Self-hosted LLM (Ollama)

- Service: `http://ollama.librechat.svc.cluster.local:11434`
- LibreChat custom endpoint + RAG embeddings both use Ollama
- Defaults: chat `llama3.2`, embeddings `nomic-embed-text` (override via `.env` / `make deploy-ollama OLLAMA_MODEL=...`)

Smoke test:

```bash
kubectl -n librechat exec deploy/ollama -- ollama list
kubectl -n librechat exec deploy/ollama -- curl -s http://127.0.0.1:11434/api/tags
```

## Makefile targets

| Target | Purpose |
|--------|---------|
| `gen-secrets` | Fill empty `CREDS_*` / `JWT_*` / `MEILI_*` in `.env` |
| `secrets` | Apply `librechat-credentials-env` + `librechat-vectordb` |
| `init-postgres` | `CREATE DATABASE` + `CREATE EXTENSION vector` |
| `install-gpu-plugin` | NVIDIA device plugin |
| `deploy-ollama` | Ollama Deployment + model pull |
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
  k8s/ollama/
eks/ ingress/ grafana/
postgres/ redis/ mongo/ s3/
```

## Notes

- Do not commit `.env`.
- Optional ECR cleanup after migration: delete unused `unpod-*` repositories in ECR.
- If a leftover local `unpod/.cache` directory remains (nested git clone), delete it with `rm -rf unpod`.
- Grafana Cloud already scrapes the cluster; filter Loki/Prometheus by `namespace="librechat"`.
- If `init-postgres` fails on `CREATE EXTENSION vector`, recreate Postgres with the pgvector image (`make -C ../postgres destroy && make -C ../postgres deploy`) — **wipes DB data**.
