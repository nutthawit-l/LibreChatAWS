# Grafana Cloud + EKS (`core-cluster`)

Ship cluster metrics, pod logs, events, and optional app OTLP telemetry from this
EKS stack to **Grafana Cloud** via the official [`k8s-monitoring`](https://github.com/grafana/k8s-monitoring-helm)
Helm chart (Grafana Alloy collectors).

Integrates with namespaces already used by this repo: `unpod`, `postgres`, `redis`, `mongo`.

## Prerequisites

- EKS up (`make -C ../eks setup`), `kubectl` context on `core-cluster`
- Helm 3
- A **Grafana Cloud** account (free tier is enough for PoC) — see below

## Grafana Cloud: what you need to create

You do **not** create separate AWS IAM users for this. Everything is on [grafana.com](https://grafana.com).

| Thing | Do you create it? | Used for |
|-------|-------------------|----------|
| Grafana.com account | Yes (once) | Login |
| Cloud **stack** (e.g. `myorg`) | Yes (usually auto-created on signup) | Hosted Prometheus + Loki + Tempo + Grafana UI |
| **Access Policy** + **token** | Yes (required) | Alloy auth to push data (`GRAFANA_CLOUD_TOKEN`) |
| Extra “Tempo user” / “Loki user” | No | Instance IDs come from the stack; password = the token |

One token with write scopes covers metrics, logs, and traces. Usernames in `.env` are numeric **instance IDs**, not email logins.

### 1. Sign up / open your stack

1. Go to [https://grafana.com/auth/sign-up/create-user](https://grafana.com/auth/sign-up/create-user) (or sign in).
2. Open the **Cloud Portal** → select your organization → open your **stack**.
3. Note the stack name and region (e.g. `prod-us-east-0`). Endpoints below depend on that region.

### 2. Create an Access Policy + token

1. In the stack: **Administration** → **Users and access** → **Cloud access policies**  
   (or Cloud Portal → **Security** → **Access Policies**).
2. **Create access policy** — display name e.g. `eks-core-cluster-write`.
3. Scopes (minimum for this repo):

   | Scope | Why |
   |-------|-----|
   | `metrics:write` | Alloy → Cloud Prometheus |
   | `logs:write` | Alloy → Cloud Loki |
   | `traces:write` | Alloy receiver → Cloud Tempo (via OTLP) |

4. **Add token** on that policy → copy the secret once (`glc_...`).  
   Put it in `.env` as `GRAFANA_CLOUD_TOKEN`.

Optional later: `metrics:read` / `logs:read` if something in-cluster must query Cloud back (OpenCost). Not needed for the current PoC values.

### 3. Copy endpoints + instance IDs into `.env`

From the stack home (or **Connections** / each product’s **Details** page):

**Metrics (Prometheus)**

1. Open **Prometheus** (or **Metrics**) → **Details** / **Sending metrics**.
2. Copy:
   - **Remote Write Endpoint** → `GRAFANA_CLOUD_METRICS_URL`  
     (ends with `/api/prom/push`)
   - **Username** / Instance ID → `GRAFANA_CLOUD_METRICS_USER`  
     (number, e.g. `123456`)

**Logs (Loki)**

1. Open **Loki** (or **Logs**) → **Details** / **Sending logs**.
2. Copy:
   - **URL** → `GRAFANA_CLOUD_LOGS_URL`  
     (add `/loki/api/v1/push` if the portal shows only the base host)
   - **Username** / Instance ID → `GRAFANA_CLOUD_LOGS_USER`

**Traces (Tempo via OTLP)**

1. Open **OpenTelemetry** or **Tempo** → **OTLP** / **Sending traces**.
2. Copy:
   - **OTLP Endpoint** → `GRAFANA_CLOUD_OTLP_URL`  
     (usually `https://otlp-gateway-….grafana.net/otlp`)
   - **Instance ID** / stack user → `GRAFANA_CLOUD_OTLP_INSTANCE_ID`  
     (often the same number as the metrics/logs user for a single stack)

Password for all three destinations is the **same** `GRAFANA_CLOUD_TOKEN`.

### 4. (Recommended) Activate Kubernetes Monitoring

1. In Grafana: **Infrastructure** → **Kubernetes** (or **Observability** → **Kubernetes Monitoring**).
2. Follow the in-app prompt to enable the app / install recording rules if asked.  
   Dashboards work best after this step; Alloy can still push data without it.

You can also use the portal’s “configure Kubernetes” wizard to verify endpoints, but this repo’s `make deploy` already installs the collectors — you only need the `.env` values from steps 2–3.

### Map to `.env`

```bash
cp .env.example .env
```

| `.env` key | From Grafana Cloud |
|------------|--------------------|
| `CLUSTER_NAME` | Must match EKS (`core-cluster`) — label in Cloud UI |
| `GRAFANA_CLOUD_METRICS_URL` | Prometheus remote write URL |
| `GRAFANA_CLOUD_METRICS_USER` | Prometheus instance ID |
| `GRAFANA_CLOUD_LOGS_URL` | Loki push URL |
| `GRAFANA_CLOUD_LOGS_USER` | Loki instance ID |
| `GRAFANA_CLOUD_OTLP_URL` | OTLP gateway URL |
| `GRAFANA_CLOUD_OTLP_INSTANCE_ID` | OTLP / stack instance ID |
| `GRAFANA_CLOUD_TOKEN` | Access Policy token (`glc_…`) |

## Quick path

```bash
cd grafana

cp .env.example .env
# Fill GRAFANA_CLOUD_* from the Cloud steps above

make deploy
make endpoints
```

In Grafana Cloud:

1. Open **Kubernetes Monitoring** → select cluster `core-cluster`
2. Or **Explore** → Prometheus / Loki with label `cluster="core-cluster"`
3. Traces: **Explore** → Tempo / Traces (after apps send OTLP)
## What gets deployed

| Component | Role |
|-----------|------|
| Alloy metrics (StatefulSet) | kubelet / cAdvisor / kube-state-metrics / node-exporter + annotation scrapes → Prometheus |
| Alloy logs (DaemonSet) | Pod stdout/stderr → Loki |
| Alloy singleton | Kubernetes events → Loki |
| Alloy receiver (Deployment) | In-cluster OTLP gRPC `:4317` / HTTP `:4318` → Grafana Cloud OTLP |
| kube-state-metrics | Cluster object metrics |
| node-exporter | Host CPU / mem / disk |

Cost (OpenCost) and energy (Kepler) collectors stay **off** for PoC.

## Integrate with Unpod

### Logs & cluster metrics (automatic)

After `make deploy`, Alloy scrapes the whole cluster. Unpod / DB pod logs appear in Loki under `cluster="core-cluster"` and `namespace="unpod"` (etc.).

### App metrics via annotations (optional)

If a service exposes Prometheus metrics, annotate the Pod or Service:

```yaml
metadata:
  annotations:
    prometheus.io/scrape: "true"
    prometheus.io/port: "9116"
    prometheus.io/path: "/metrics"
```

`annotationAutodiscovery` will pick them up without chart changes.

### Traces / OTLP from Unpod

Point apps at the in-cluster receiver (from `make endpoints`):

```bash
# Example — add to unpod/.env after deploy
OTEL_EXPORTER_OTLP_ENDPOINT=http://grafana-k8s-monitoring-alloy-receiver.grafana.svc.cluster.local:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
OTEL_SERVICE_NAME=unpod
```

Exact Service name can differ slightly by chart version; always prefer `make endpoints`.

## Makefile targets

| Target | Purpose |
|--------|---------|
| `check` | Validate `.env`, helm, kubectl |
| `repo` | Add/update `grafana` Helm repo |
| `secrets` | Apply `grafana-cloud` Secret |
| `values` | Render `values.yaml.tpl` |
| `deploy` | Helm upgrade `--install` |
| `status` | Pods / services / release |
| `endpoints` | Print OTLP URLs for Unpod |
| `logs` | Tail Alloy metrics logs |
| `destroy` | Uninstall release + delete namespace |

## Layout

```
grafana/
  makefile
  .env.example
  values.yaml.tpl      # k8s-monitoring chart v4+
  README.md
```

## Notes

- Do not commit `.env` or `.values.generated.yaml` (gitignored).
- Token is also written into the rendered values file under `/tmp`-style path in-repo (`.values.generated.yaml`); keep it local.
- Chart pin: `CHART_VERSION` in the makefile (default `4.3.0`). Override with `make deploy CHART_VERSION=4.2.2`.
- To tear down only observability: `make destroy` (does not touch Unpod / DBs).
