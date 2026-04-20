# Bebeque Energy Platform

Microservices platform for energy analytics and IoT data ingestion. Migrating from EC2 monolith to EKS using the strangler fig pattern — the ALB routes traffic to EKS for migrated services and to the EC2 monolith for everything else. **120 live B2B clients must not be disrupted.**

---

## Services

| Service | Port | Type | Scales on |
|---------|------|------|-----------|
| `analytics-api` | 8000 | FastAPI REST API | HPA (CPU) |
| `notification-service` | 8001 | FastAPI + SQS daemon thread | HPA |
| `biomass-ingestion` | — | SQS worker | KEDA (queue depth, scales to zero) |
| `data-ingestion` | — | SQS worker | KEDA (scales to zero) |

**Data flows:**
- IoT sensor → SQS `biomass-queue` → `biomass-ingestion` → `biomass_readings`
- Client CSV → S3 → SQS `data-ingestion-queue` → `data-ingestion` → `meter_readings`
- HTTP query → `analytics-api` → Redis (5 min TTL cache) → PostgreSQL fallback
- Event → SQS `notifications-queue` → `notification-service` → email / webhook

**Stateful services run outside Kubernetes** (managed AWS):
- PostgreSQL → RDS (shared by EKS services and EC2 monolith during migration)
- Redis → ElastiCache
- Queues → SQS (3 queues)
- Files → S3 (`bebeque-uploads`)

---

## Local Development

Start the full stack (PostgreSQL, Redis, LocalStack, all 4 services):
```powershell
docker compose up --build -d
docker compose ps
```

First startup auto-initialises:
- `scripts/seed-database.sql` — creates tables + indexes + sample data
- `scripts/init-localstack.sh` — creates SQS queues + S3 bucket

Run a single service locally:
```powershell
cd services/analytics-api
python -m venv .venv && .venv\Scripts\activate
pip install -r requirements.txt
$env:DATABASE_URL="postgresql://postgres:postgres@localhost:5432/bebeque"
$env:REDIS_URL="redis://localhost:6379"
$env:ENVIRONMENT="development"
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

SQS workers: `python -m app.worker` from the service directory.

---

## PowerShell Rules

**Never use `Out-File -Encoding utf8`** — it adds a BOM that corrupts JSON and CSV payloads.

Always write files like this:
```powershell
[System.IO.File]::WriteAllText("$env:TEMP\filename.json", $content, [System.Text.UTF8Encoding]::new($false))
```

**LocalStack queue URLs must use the subdomain format:**
```
http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/queue-name
```
`http://localhost:4566/...` does not work with LocalStack 3.x.

**Line continuation is backtick**, not backslash.

**Fix CRLF on shell scripts after every edit:**
```powershell
(Get-Content scripts/init-localstack.sh -Raw).Replace("`r`n", "`n") | Set-Content scripts/init-localstack.sh -NoNewline
```

---

## Test Commands

### Health checks
```powershell
curl http://localhost:8000/health   # analytics-api
curl http://localhost:8001/health   # notification-service
```

### Analytics endpoint (call twice to verify Redis caching)
```powershell
curl "http://localhost:8000/api/v1/analytics/clients/client-001/usage?days=30"
docker compose logs analytics-api | Select-String "cache"
```

### Biomass worker
```powershell
$biomass = '{"sensor_id":"sensor-001","plant_id":"plant-new-york","temperature_celsius":82.4,"moisture_percent":23.1,"output_kwh":145.7,"sensor_timestamp":"2024-04-06T10:00:00"}'
[System.IO.File]::WriteAllText("$env:TEMP\biomass.json", $biomass, [System.Text.UTF8Encoding]::new($false))

aws sqs send-message `
  --endpoint-url http://localhost:4566 `
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/biomass-queue `
  --message-body file://$env:TEMP/biomass.json `
  --region us-east-1

docker compose logs -f biomass-ingestion
```

Verify in Postgres:
```powershell
$pg = docker compose ps -q postgres
docker exec -it $pg psql -U postgres -d bebeque -c "SELECT * FROM biomass_readings ORDER BY created_at DESC LIMIT 5;"
```

### Data ingestion (CSV via S3)
```powershell
$csv = "client_id,meter_id,reading_kwh,recorded_at`nclient-003,meter-X,234.5,2024-04-01T09:00:00`nclient-003,meter-X,241.2,2024-04-02T09:00:00`n"
[System.IO.File]::WriteAllText("$env:TEMP\readings.csv", $csv, [System.Text.UTF8Encoding]::new($false))

aws s3 cp "$env:TEMP\readings.csv" s3://bebeque-uploads/uploads/client-003/april-2024.csv `
  --endpoint-url http://localhost:4566 --region us-east-1

$s3event = '{"Records":[{"s3":{"bucket":{"name":"bebeque-uploads"},"object":{"key":"uploads/client-003/april-2024.csv"}}}]}'
[System.IO.File]::WriteAllText("$env:TEMP\s3event.json", $s3event, [System.Text.UTF8Encoding]::new($false))

aws sqs send-message `
  --endpoint-url http://localhost:4566 `
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/data-ingestion-queue `
  --message-body file://$env:TEMP/s3event.json `
  --region us-east-1

docker compose logs -f data-ingestion
```

Verify rows + data lineage (`source_file` column traces every row back to its source CSV):
```powershell
docker exec -it $pg psql -U postgres -d bebeque -c "SELECT client_id, meter_id, reading_kwh, source_file FROM meter_readings LIMIT 10;"
curl "http://localhost:8000/api/v1/analytics/clients/client-003/usage?days=30"
```

### Notification service
```powershell
$n = '{"event_type":"usage_threshold_exceeded","client_id":"client-001","recipient_email":"admin@client001.com","subject":"Energy usage alert","body":"Your usage has exceeded the monthly threshold.","webhook_url":"https://client001.com/webhooks/bebeque"}'
[System.IO.File]::WriteAllText("$env:TEMP\notification.json", $n, [System.Text.UTF8Encoding]::new($false))

aws sqs send-message `
  --endpoint-url http://localhost:4566 `
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/notifications-queue `
  --message-body file://$env:TEMP/notification.json `
  --region us-east-1

docker compose logs -f notification-service
```

### Poison pill (invalid JSON — should be discarded, not retried)
```powershell
aws sqs send-message `
  --endpoint-url http://localhost:4566 `
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/biomass-queue `
  --message-body "this is not valid json" `
  --region us-east-1
```

---

## Stack Management

```powershell
docker compose ps
docker compose logs -f <service>
docker compose restart <service>
docker compose up --build -d <service>   # rebuild one service
docker compose stop                       # stop, keep volumes
docker compose down -v                    # full teardown

# Purge a stuck queue
aws sqs purge-queue `
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/biomass-queue `
  --endpoint-url http://localhost:4566 --region us-east-1

# Manually create LocalStack resources if init script didn't run
aws sqs create-queue --queue-name biomass-queue --endpoint-url http://localhost:4566 --region us-east-1
aws sqs create-queue --queue-name data-ingestion-queue --endpoint-url http://localhost:4566 --region us-east-1
aws sqs create-queue --queue-name notifications-queue --endpoint-url http://localhost:4566 --region us-east-1
aws s3 mb s3://bebeque-uploads --endpoint-url http://localhost:4566 --region us-east-1

# Inspect
aws sqs list-queues --endpoint-url http://localhost:4566 --region us-east-1
aws s3 ls --endpoint-url http://localhost:4566
```

---

## Terraform — Infrastructure

State stored remotely in S3 (`bebeque-terraform-state-us-east-1`).

### Modules

| Module | What it creates |
|--------|----------------|
| `vpc` | VPC, public/private subnets, NAT gateway |
| `eks` | EKS cluster, node groups, OIDC provider |
| `rds` | PostgreSQL 16, private subnet, SG scoped to EKS nodes |
| `elasticache` | Redis cluster, private subnet, SG scoped to EKS nodes |
| `sqs` | biomass-queue, data-ingestion-queue, notifications-queue |
| `ecr` | ECR repos for all four services (`bebeque/*`) |
| `s3` | `bebeque-uploads` bucket |
| `iam` | IRSA roles per service + GitHub Actions OIDC role |
| `alb` | Application Load Balancer, ACM cert, listener rules (strangler fig routing) |

### Commands
```bash
cd terraform/infra/
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

One-time bootstrap (creates S3 state bucket):
```bash
cd terraform/bootstrap/
terraform init && terraform apply
```

### Connect kubectl after apply
```bash
aws eks update-kubeconfig --region us-east-1 --name bebeque-eks-cluster
kubectl get nodes
```

If `kubectl get nodes` returns a credentials error, your IAM user needs an EKS access entry:
```bash
aws eks create-access-entry \
  --cluster-name bebeque-eks-cluster \
  --principal-arn arn:aws:iam::<account-id>:user/<your-user> \
  --type STANDARD

aws eks associate-access-policy \
  --cluster-name bebeque-eks-cluster \
  --principal-arn arn:aws:iam::<account-id>:user/<your-user> \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster
```

---

## Helm — Self-Service Chart

**One chart, not four.** `helm/bebeque-service/` deploys all services via per-service values files. Adding a fifth service = one new values file.

```
helm/bebeque-service/
├── Chart.yaml
├── values.yaml                        ← schema + defaults (never deployed directly)
├── templates/
│   ├── deployment.yaml                ← all services
│   ├── service.yaml                   ← API services only (conditional)
│   ├── hpa.yaml                       ← API services only (conditional)
│   ├── keda-scaledobject.yaml         ← SQS workers only (conditional)
│   ├── serviceaccount.yaml            ← IRSA annotation lives here
│   ├── role.yaml                      ← rules: [] — explicit zero Kubernetes API permissions
│   ├── rolebinding.yaml
│   ├── networkpolicy.yaml             ← default deny, explicit allow rules
│   └── _helpers.tpl
└── values/
    ├── analytics-api.staging.yaml
    ├── analytics-api.production.yaml
    ├── biomass-ingestion.staging.yaml
    ├── biomass-ingestion.production.yaml
    ├── data-ingestion.staging.yaml
    ├── data-ingestion.production.yaml
    ├── notification-service.staging.yaml
    └── notification-service.production.yaml
```

### Key template behaviours
| Template | Key behaviour |
|----------|--------------|
| `deployment.yaml` | `checksum/values` annotation forces rolling restart on any config change |
| `deployment.yaml` | `terminationGracePeriodSeconds` matches SQS visibility timeout per service (biomass=30s, data-ingestion=120s) |
| `service.yaml` | Skipped when `service.enabled: false` (SQS workers have no HTTP port) |
| `hpa.yaml` | CPU-based, only for API services |
| `keda-scaledobject.yaml` | Queue-depth scaling, `minReplicas: 0` — scales to zero when queue empty |
| `serviceaccount.yaml` | Carries IRSA annotation — pods get temporary AWS creds, no access keys |
| `role.yaml` | `rules: []` — least privilege, auditable |
| `networkpolicy.yaml` | Default deny ingress/egress with explicit allow rules |

### To onboard a new service
1. Create `helm/bebeque-service/values/<service>.staging.yaml`
2. Create `helm/bebeque-service/values/<service>.production.yaml`
3. Copy any caller workflow and update the paths
4. Done — the chart handles everything else

### Helm commands
```bash
helm lint helm/bebeque-service/
helm template analytics-api helm/bebeque-service/ \
  -f helm/bebeque-service/values/analytics-api.staging.yaml

helm upgrade --install analytics-api helm/bebeque-service/ \
  --namespace staging --create-namespace \
  --values helm/bebeque-service/values/analytics-api.staging.yaml \
  --set image.tag=<git-sha>
```

---

## Secrets Management

Secrets are **never in values files or environment variables**. They live in AWS Secrets Manager and are pulled into the cluster by External Secrets Operator (ESO).

### How it works
```
AWS Secrets Manager
  └── bebeque/production/database  { "url": "postgresql://..." }
  └── bebeque/production/redis     { "url": "redis://..." }
        ↓
ClusterSecretStore (k8s/secrets/cluster-secret-store.yaml)
  — authenticates to Secrets Manager via IRSA (ESO's own service account)
        ↓
ExternalSecret per service (k8s/secrets/external-secrets.yaml)
  — pulls specific keys, creates a native Kubernetes Secret
        ↓
deployment.yaml envFrom: — mounts the secret as environment variables
```

### Files
- `k8s/secrets/cluster-secret-store.yaml` — one cluster-wide store pointing at Secrets Manager
- `k8s/secrets/external-secrets.yaml` — one ExternalSecret per service, refreshes every 1 hour

### Secret paths in Secrets Manager
| Secret | Key | Used by |
|--------|-----|---------|
| `bebeque/production/database` | `url` | analytics-api, biomass-ingestion, data-ingestion |
| `bebeque/production/redis` | `url` | analytics-api |

### Apply secrets config
```bash
# Install External Secrets Operator (one-time)
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets --create-namespace

# Apply store + secrets
kubectl apply -f k8s/secrets/cluster-secret-store.yaml
kubectl apply -f k8s/secrets/external-secrets.yaml

# Verify
kubectl get externalsecret -n production
kubectl get secret analytics-api-secrets -n production
```

---

## CI/CD Pipeline

### Architecture
```
Push to main (paths filter — only if relevant files changed)
  → build-and-push job
      OIDC auth → ECR login → Docker build → push with Git SHA tag
  → deploy-staging job
      OIDC auth → helm upgrade --install → namespace: staging
  → APPROVAL GATE (manual, nnnennaorjiugo-source must approve)
  → deploy-production job
      OIDC auth → helm upgrade --install → namespace: production
```

### Reusable workflow pattern
`.github/workflows/deploy-service.yml` is the core pipeline (platform team owns it). The four caller workflows are ~25 lines each and just pass inputs:

```
.github/workflows/
├── deploy-service.yml              ← reusable (do not edit per-service)
├── deploy-analytics-api.yml        ← caller
├── deploy-biomass-ingestion.yml    ← caller
├── deploy-data-ingestion.yml       ← caller
└── deply-notification-service.yml  ← caller
```

A new service gets CI/CD by adding one caller file — not copying the full pipeline.

### OIDC authentication (no static AWS keys)
GitHub Actions proves its identity using a short-lived cryptographic token. AWS verifies the token and issues temporary credentials (~15 min). The IAM role trust policy only allows:
- `repo:Hannahmoney/Bebeque-Energy-Platform:ref:refs/heads/main`
- `repo:Hannahmoney/Bebeque-Energy-Platform:environment:staging`
- `repo:Hannahmoney/Bebeque-Energy-Platform:environment:production`

A fork, a feature branch, or any other account cannot assume the role.

GitHub secret required: `AWS_ACCOUNT_ID`

### Git SHA image tags (never `latest`)
Every image is tagged with the first 7 chars of `GITHUB_SHA`:
```
478544567935.dkr.ecr.us-east-1.amazonaws.com/bebeque/analytics-api:a335454
```
ECR has immutable tags enabled — a tag cannot be overwritten once pushed. In incident response, `latest` tells you nothing. A SHA traces directly to a commit.

### Path filters
Each caller only triggers when its own files change:
```yaml
paths:
  - 'services/analytics-api/**'
  - 'helm/bebeque-service/**'          # chart change triggers all 4 services
  - '.github/workflows/deploy-analytics-api.yml'
  - '.github/workflows/deploy-service.yml'
```
A Terraform change or README edit triggers nothing.

### GitHub Environments
- `staging` — no protection rules, deploys automatically
- `production` — requires manual approval, prevent-self-review enabled (the pusher cannot approve their own deploy)

---

## Rollback

### Method 1 — Helm rollback (fastest, surgical)
```bash
helm history analytics-api -n staging
helm rollback analytics-api <revision> -n staging
```

### Method 2 — Kubernetes rollout undo (emergency only)
```bash
kubectl rollout undo deployment/analytics-api -n staging
```
Swaps back to the previous ReplicaSet in seconds. Helm state is not updated — use only when production is down and you need pods back immediately.

### Method 3 — Pipeline rollback (preferred, full audit trail)
Re-run a previous successful pipeline run in the GitHub Actions UI. Redeploys a known-good SHA through OIDC + Helm + approval gate. This is what you say in incident retrospectives.

---

## Observability

### Metrics — kube-prometheus-stack
Installed in the `monitoring` namespace. Includes: Prometheus, Grafana, Alertmanager, kube-state-metrics, node-exporter.

```bash
# Install
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --values helm/kube-prometheus-stack/values.yaml

# Apply custom alert rules
kubectl apply -f k8s/monitoring/bebeque-alerts.yaml
```

**Grafana:** port-forward to access locally:
```bash
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
# Open http://localhost:3000 — admin / bebeque-grafana-2024
```

### Alerts (`k8s/monitoring/bebeque-alerts.yaml`)
| Alert | Condition | Severity |
|-------|-----------|----------|
| `PodCrashLooping` | >1 restart in 5 min | critical |
| `PodNotReady` | not ready for 5 min | warning |
| `HighCPUUsage` | >85% CPU limit for 10 min | warning |
| `HighMemoryUsage` | >85% memory limit for 10 min | warning |

Alertmanager routes to email via AWS SES (`alerts@inspireherinitiative.xyz` → `nnennaorjiugo@gmail.com`). Critical alerts suppress matching warning alerts.

### Logging — Fluent Bit → CloudWatch
Fluent Bit runs as a DaemonSet, tailing `/var/log/containers/*.log` on every node. Ships to CloudWatch log group `/bebeque/eks/containers`.

```bash
helm repo add fluent https://fluent.github.io/helm-charts
helm install fluent-bit fluent/fluent-bit \
  --namespace logging --create-namespace \
  --values helm/fluent-bit/values.yaml
```

Fluent Bit uses IRSA (`bebeque-fluent-bit-role`) — no static AWS keys.

### EKS control plane logging
All five control plane log types enabled (API, audit, authenticator, controller-manager, scheduler). Config in `k8s/monitoring/eks-logging.json`.

```bash
aws eks update-cluster-config \
  --name bebeque-eks-cluster \
  --logging '{"clusterLogging":[{"types":["api","audit","authenticator","controllerManager","scheduler"],"enabled":true}]}'
```

---

## Kubernetes — Day-to-Day

```bash
# Status
kubectl get pods -n staging
kubectl get all -n staging
kubectl describe pod <pod-name> -n staging

# Logs
kubectl logs -n staging -l app=analytics-api --tail=50 -f

# Restart + rollout
kubectl rollout restart deployment/analytics-api -n staging
kubectl rollout status deployment/analytics-api -n staging

# Scaling
kubectl get hpa -n staging                  # API services
kubectl get scaledobject -n staging         # SQS workers (KEDA)

# Security resources
kubectl get networkpolicy -n staging
kubectl get rolebinding -n staging
kubectl get serviceaccount -n staging
kubectl get externalsecret -n production

# Exec into a pod
kubectl exec -it <pod-name> -n staging -- /bin/bash

# Trace image back to commit
kubectl get pod <pod-name> -n staging -o jsonpath='{.spec.containers[0].image}'
```

---

## Incidents and Fixes

| Problem | Cause | Fix |
|---|---|---|
| `NonExistentQueue` on startup | Worker started before LocalStack init script finished | Healthcheck verifies queue with `get-queue-url`, not just port open |
| Queue URL not found | Newer LocalStack uses subdomain URL format | Use `http://sqs.us-east-1.localhost.localstack.cloud:4566/...` |
| `Expecting value: line 1 column 1` on JSON messages | PowerShell `Out-File -Encoding utf8` adds BOM | `[System.IO.File]::WriteAllText` with `UTF8Encoding::new($false)` |
| `Skipping row — missing columns: ['client_id']` | BOM on CSV corrupts first column header | Same fix. Worker also uses `decode("utf-8-sig")` as defence |
| Message stuck redelivering | Worker returning False causes SQS to redeliver indefinitely | `purge-queue` to clear during development |
| `NoSuchBucket` on S3 upload | Init script didn't create bucket | Manually run `aws s3 mb` |
| `kubectl` credentials error after `update-kubeconfig` | IAM user not in EKS access entries | Add access entry + associate `AmazonEKSClusterAdminPolicy` |
| `CrashLoopBackOff` on analytics-api pod | Pydantic Settings requires `DATABASE_URL` and `REDIS_URL` at startup | Wired via External Secrets Operator in Step 11 |
| OIDC role assumption rejected for staging/production jobs | Sub claim format changes to `environment:staging` when job uses GitHub Environment | Update IAM trust policy to allow all three sub claim formats |
| ECR rejected `latest` tag push | ECR immutable tags — tag already exists from manual push | Remove `latest` from pipeline, push Git SHA only |
| KEDA ScaledObject CRD not found | KEDA not installed before Helm deploy | Install KEDA 2.13.0 via Helm in `keda` namespace first |
| Bash comments inside YAML `run:` block cause pipeline failure | Comments in multiline shell blocks are executed as commands | Remove comments from `run:` blocks entirely |

---

## Documentation

| File | Content |
|------|---------|
| `docs/BEBEQUE-NARRATIVE.md` | Full project story — every architectural decision explained for interviews |
| `docs/BEBEQUE-STEP-7-HELM` | Helm chart design decisions, template breakdown, issues encountered |
| `docs/bebeque-step8-cicd-summary.md` | CI/CD pipeline deep-dive — OIDC, SHA tags, path filters, approval gate |
| `docs/BEBEQUE-SERVICE-READMES.md` | Per-service documentation |
| `docs/interview-prep.md` | Interview Q&A for this project |
| `docs/bebeque-q0-observability` | Observability step notes |
| `Bebeque_Technical_Reference.docx` | Full technical reference document |
