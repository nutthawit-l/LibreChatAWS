# LibreChat on AWS EKS (PoC)

Self-hosted [LibreChat](https://www.librechat.ai/) บน **Amazon EKS** พร้อม LLM ผ่าน **Groq** (OpenAI-compatible API)  
Public URL: **`https://librechat.ntwtech.com`**

โปรเจกต์นี้เป็น PoC ฝั่ง infrastructure / platform: bootstrap cluster, data stores, ingress, observability และ deploy แอปด้วย Makefile แยกตามคอมโพเนนต์

---

## สิ่งที่ระบบทำ

ผู้ใช้เข้าเว็บ LibreChat ผ่าน HTTPS → ALB → Pod บน EKS  
แชทไปที่ **Groq API** (เช่น `llama-3.3-70b-versatile`)  
ข้อมูล session / user เก็บใน **MongoDB**, cache ใน **Redis**, ไฟล์ media ใน **S3**  
เมตริก / ล็อก / เทรซ ส่งไป **Grafana Cloud** ผ่าน Grafana Alloy ในคลัสเตอร์

```
Browser
   │  HTTPS (ACM)
   ▼
ALB (AWS Load Balancer Controller)
   │  target-type: ip
   ▼
LibreChat Pod (ns: librechat)
   ├──► Groq API          (chat / completions)
   ├──► MongoDB           (users, conversations)
   ├──► Redis             (cache / sessions)
   ├──► S3                (uploads / media)
   └──► Alloy OTLP        → Grafana Cloud (Tempo / Loki / Prometheus)
```

---

## Tech stack

| Layer | Choice |
|-------|--------|
| Orchestration | Amazon EKS 1.30 (`core-cluster`, `us-east-1`) |
| Autoscaling | Karpenter (Spot + On-Demand, consolidate เมื่อ idle) |
| App | LibreChat (Helm OCI chart) |
| LLM | Groq (`llama-3.3-70b-versatile` เป็น default) |
| Datastores | MongoDB 7, Redis 7, S3; Postgres/pgvector พร้อมไว้ (RAG ปิดอยู่) |
| Ingress | AWS Load Balancer Controller → internet-facing ALB |
| TLS | ACM + DNS (`librechat.ntwtech.com`) |
| Observability | Grafana Cloud + `k8s-monitoring` (Alloy) |
| IaC style | `eksctl` + Helm + `kubectl` + Makefile (`envsubst`) |

---

## โครงสร้าง repo

```
.
├── eks/          # EKS cluster, IAM roles, Karpenter NodeClass/NodePool, EBS CSI
├── ingress/      # AWS Load Balancer Controller + IngressClass alb
├── mongo/        # MongoDB StatefulSet (LibreChat primary DB)
├── redis/        # Redis StatefulSet (cache)
├── postgres/     # Postgres + pgvector (optional; สำหรับ RAG ในอนาคต)
├── s3/           # S3 bucket + IAM user สำหรับ media
├── grafana/      # Alloy collectors → Grafana Cloud
└── librechat/    # Helm values, secrets, deploy LibreChat
```

แต่ละโฟลเดอร์มี `makefile` และ `.env.example` ของตัวเอง — ไม่ commit `.env`

รายละเอียดลึกต่อโมดูล: [librechat/README.md](librechat/README.md) · [ingress/README.md](ingress/README.md) · [grafana/README.md](grafana/README.md)

---

## Prerequisites

ติดตั้งบนเครื่องที่ใช้ deploy:

- AWS CLI (configured, สิทธิ์สร้าง EKS / IAM / EC2 / S3 / ELB)
- `eksctl`, `kubectl`, Helm 3
- `envsubst` (gettext), `openssl`, `make`
- บัญชี [Groq](https://console.groq.com/keys) สำหรับ API key
- (แนะนำ) บัญชี [Grafana Cloud](https://grafana.com) สำหรับ observability
- ACM certificate ที่ SAN รวม `librechat.ntwtech.com` (region เดียวกับคลัสเตอร์)

---

## Setup ทีละขั้น (ลำดับสำคัญ)

รันจาก root ของ repo นี้ ลำดับด้านล่างสะท้อน dependency จริงของระบบ

### 1) Bootstrap EKS + Karpenter

```bash
make -C eks setup
aws eks update-kubeconfig --name core-cluster --region us-east-1
```

ได้: control plane, system node group (`t4g.small`), Karpenter, EBS CSI, StorageClass `gp3`  
Workload แอปจะขึ้นบน node ที่ Karpenter provision (ไม่ใช้ system node เป็นหลัก)

### 2) AWS Load Balancer Controller

```bash
cd ingress
cp .env.example .env
# ใส่ ACM_CERTIFICATE_ARN=arn:aws:acm:us-east-1:...:certificate/...
make deploy
```

### 3) Data stores + S3

```bash
# Mongo
cp mongo/.env.example mongo/.env   # แก้ password
make -C mongo deploy
make -C mongo conninfo             # ได้ MONGO_URI

# Redis
cp redis/.env.example redis/.env
make -C redis deploy
make -C redis conninfo             # ได้ REDIS_URI

# S3 media
cp s3/.env.example s3/.env         # optional
make -C s3 create
make -C s3 create-user             # เขียน access key ไป librechat/.env

# Postgres (optional — RAG ปิดตอนใช้ Groq)
# make -C postgres deploy
```

### 4) Observability (optional แต่แนะนำ)

```bash
cd grafana
cp .env.example .env
# กรอก GRAFANA_CLOUD_* จาก Grafana Cloud portal (ดู grafana/README.md)
make deploy
make endpoints                     # OTLP URL ในคลัสเตอร์สำหรับ LibreChat
```

### 5) Deploy LibreChat

```bash
cd librechat
cp .env.example .env
make gen-secrets

# ใส่ใน .env:
#   MONGO_URI / REDIS_URI จากขั้นตอน 3
#   AWS_* จาก s3 create-user
#   GROQ_API_KEY=... และ OPENAI_API_KEY=ค่าเดียวกัน
#   ACM ถูกอ่านจาก ../ingress/.env อัตโนมัติ

make secrets
make deploy
make endpoints
```

ชี้ DNS (Route53 / Cloudflare) **`librechat.ntwtech.com`** → ALB hostname จาก `make endpoints`

เปิด `https://librechat.ntwtech.com` แล้ว register / login ได้ตาม `ALLOW_REGISTRATION`

---

## การทำงานของแต่ละส่วน (อธิบายสัมภาษณ์)

### EKS + Karpenter

- **System NodeGroup** คงที่เล็ก ๆ สำหรับ add-on / system pods
- **Karpenter `core-pool`** สเกล worker ตาม pending pods — ใช้ Spot เป็นหลัก, ตัดขนาด `nano`–`medium` ทิ้งเพราะ DaemonSet (Alloy, node-exporter) เต็ม maxPods ง่าย
- มี **GPU NodePool** ไว้สำหรับ path เก่า (Ollama) — ตอนนี้ LLM ไป Groq แล้ว ไม่จำเป็นต้องมี GPU ในคลัสเตอร์
- Disruption: `WhenEmptyOrUnderutilized` เพื่อ consolidate ประหยัดค่าใช้จ่าย

### LibreChat + Groq

- Chart ปิด embedded Mongo/Redis — ชี้ไป datastore ที่ deploy เอง
- Endpoint แบบ custom OpenAI-compatible ไปที่ `https://api.groq.com/openai/v1/`
- Secrets (JWT, Groq key, S3 keys) อยู่ใน K8s Secret `librechat-credentials-env`
- **RAG API ปิด** เพราะ Groq ไม่มี embeddings API — Postgres/pgvector พร้อมเปิดเมื่อต่อ embed provider อื่น

### Ingress / TLS

- Ingress `ingressClassName: alb` → controller สร้าง internet-facing ALB
- HTTP→HTTPS redirect, health check `/health`, idle timeout ยาวสำหรับ chat stream
- ใบรับรองมาจาก ACM annotation (ต้อง match hostname)

### Observability

- Alloy เก็บ metrics / pod logs / events ส่ง Grafana Cloud
- LibreChat ส่ง OTLP traces ไป Alloy receiver ใน namespace `grafana`
- ใน Grafana: กรองด้วย `cluster="core-cluster"`, `namespace="librechat"`

---

## Makefile cheat sheet

| โฟลเดอร์ | คำสั่งหลัก | หน้าที่ |
|---------|------------|---------|
| `eks` | `make setup` / `make destroy` | สร้าง / ลบคลัสเตอร์ |
| `ingress` | `make deploy` / `make endpoints` | ALB controller + ดู ALB DNS |
| `mongo` / `redis` / `postgres` | `make deploy` / `make conninfo` | StatefulSet + connection string |
| `s3` | `make create` / `make create-user` | Bucket + IAM keys |
| `grafana` | `make deploy` / `make endpoints` | Alloy → Grafana Cloud |
| `librechat` | `make deploy` / `make status` / `make destroy` | แอปหลัก |

ทุกโฟลเดอร์รองรับ `make help`

---

## Design decisions ที่มักถูกถาม

1. **ทำไม self-host LibreChat บน EKS?**  
   ควบคุม data residency, ผูก LLM provider ได้ยืดหยุ่น, ฝึก pattern เดียวกับ production K8s (Ingress, Secrets, StatefulSets, autoscaling)

2. **ทำไม Groq แทน Ollama ในคลัสเตอร์?**  
   ลดความซับซ้อนและค่า GPU node; latency/throughput ของ hosted inference ดีพอสำหรับ PoC; ยังคง OpenAI-compatible อยู่แล้วสลับ provider ได้

3. **ทำไม datastore เป็น StatefulSet ในคลัสเตอร์?**  
   PoC เร็ว ไม่ต้อง provision RDS/ElastiCache; ใช้ EBS gp3 + EBS CSI; production จริงอาจย้ายไป managed service

4. **ทำไมแยกโฟลเดอร์ + Makefile แทน monorepo Helm เดียว?**  
   deploy / destroy / debug ทีละชั้นได้, ชัดว่า IAM/ALB คนละ concern กับแอป, สะดวกอธิบาย dependency ในสัมภาษณ์

5. **ทำไม Spot + consolidation?**  
   PoC คุมงบ; system node คงที่, workload ขึ้น-ลงตาม Karpenter

---

## Tear down (ระวังข้อมูลหาย)

ลำดับแนะนำ (แอปก่อน แล้ว datastore แล้ว observability แล้วคลัสเตอร์):

```bash
make -C librechat destroy
make -C mongo destroy      # ลบ PVC ด้วย
make -C redis destroy
make -C postgres destroy   # ถ้าเคย deploy
make -C grafana destroy
make -C ingress destroy    # ไม่ลบ ALB ที่ยังค้างจาก Ingress — ลบแอปก่อน
# S3: make -C s3 destroy   # ลบ object + bucket (destructive)
make -C eks destroy
```

---

## หมายเหตุความปลอดภัย

- อย่า commit `.env`, `.values.generated.yaml`, หรือ secret ที่ generate แล้ว
- S3 access key ใน `librechat/.env` ถูก unexport ตอนรัน make เพื่อไม่ทับ AWS CLI credential ของโฮสต์ (สำคัญกับ `aws-iam-authenticator`)
- ACM + DNS ต้องตรงกับ `DOMAIN` ไม่เช่นนั้น HTTPS บน ALB จะล้มแม้แอปขึ้นปกติ

---

## Quick verify หลัง deploy

```bash
kubectl get nodes
kubectl -n librechat get pods,svc,ingress
make -C librechat endpoints
make -C librechat status

# ล็อก / เทรซ (ถ้า deploy grafana แล้ว)
# Grafana Cloud → Explore → Loki/Tempo กรอง namespace="librechat"
```

เปิดเบราว์เซอร์ที่ `https://librechat.ntwtech.com` แล้วลองแชทกับโมเดล Groq ได้ถือว่า end-to-end สำเร็จ
