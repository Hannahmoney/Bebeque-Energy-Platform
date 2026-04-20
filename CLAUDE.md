# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bebeque Energy Platform is a microservices architecture for energy consumption analytics and IoT data ingestion. It is migrating from a monolith (EC2) to Kubernetes (EKS) using the strangler fig pattern — routing traffic to new services while keeping the old monolith running. **120 live B2B clients must not be disrupted during migration.**

## Local Development

Start the full stack (PostgreSQL, Redis, LocalStack, all 4 services):
```bash
docker compose up --build -d
docker compose ps
docker compose logs -f <service-name>
docker compose down -v   # clean slate: removes volumes
```

Run a single service locally (example: analytics-api):
```bash
cd services/analytics-api/
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
DATABASE_URL="postgresql://postgres:postgres@localhost:5432/bebeque" \
REDIS_URL="redis://localhost:6379" \
ENVIRONMENT="development" \
uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

SQS workers start via `python -m app.worker` in their service directory.

## Testing

Health checks:
```bash
curl http://localhost:8000/health   # analytics-api
curl http://localhost:8001/health   # notification-service
```

Analytics query:
```bash
curl "http://localhost:8000/api/v1/analytics/clients/client-001/usage?days=30"
```

Send a message to LocalStack SQS (bash):
```bash
aws sqs send-message \
  --endpoint-url http://localhost:4566 \
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/biomass-queue \
  --message-body '{"sensor_id":"sensor-001","plant_id":"plant-ny","temperature_celsius":82.4,"moisture_percent":23.1,"output_kwh":145.7,"sensor_timestamp":"2024-04-06T10:00:00"}' \
  --region us-east-1
```

Verify database rows:
```bash
docker exec -it $(docker compose ps -q postgres) psql -U postgres -d bebeque -c "SELECT * FROM biomass_readings LIMIT 5;"
```

## Architecture

### Four Microservices

| Service | Type | Scale | Key Tech |
|---------|------|-------|----------|
| `analytics-api` | FastAPI REST API | HPA (CPU) | FastAPI, SQLAlchemy, Redis |
| `biomass-ingestion` | SQS worker | KEDA (queue depth) | boto3, SQLAlchemy |
| `data-ingestion` | SQS worker | KEDA (scales to zero) | boto3, SQLAlchemy, CSV |
| `notification-service` | FastAPI + SQS daemon thread | HPA | FastAPI, boto3, threading |

### Data Flows
- **CSV ingestion**: Client CSV → S3 → SQS → `data-ingestion` → PostgreSQL
- **IoT ingestion**: IoT sensor → SQS → `biomass-ingestion` → PostgreSQL
- **Analytics query**: HTTP → `analytics-api` → Redis (5-min TTL) → PostgreSQL fallback
- **Notifications**: Event → SQS → `notification-service` → email/webhook

### Helm Chart Design
One reusable chart (`helm/bebeque-service/`) serves all four services. New services only need a new values file. Key conditionals in templates:
- `service.yaml` — skipped for SQS workers (no HTTP)
- `hpa.yaml` — only for API services
- `keda-scaledobject.yaml` — only for SQS workers

`terminationGracePeriodSeconds` is intentionally matched to each worker's `VISIBILITY_TIMEOUT` so SQS messages aren't reprocessed on pod shutdown (30s biomass, 120s data-ingestion).

### CI/CD Pattern
GitHub Actions reusable workflow in `.github/workflows/deploy-service.yml` (owned by platform team). Each service has a thin caller workflow. Pipeline: Docker build → ECR push (Git SHA tag, never `latest`) → Helm deploy staging → manual approval gate → Helm deploy production. Authentication is OIDC only — no static AWS keys.

## Key Configuration

All services use Pydantic `BaseSettings` reading from environment variables or a `.env` file. The `ENVIRONMENT` variable controls behavior (development enables LocalStack endpoints).

LocalStack queue URL format (note: not `localhost:4566`):
```
http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/<queue-name>
```

Database and queues are initialized automatically on first `docker compose up`:
- `scripts/seed-database.sql` — creates tables, indexes, sample data
- `scripts/init-localstack.sh` — creates SQS queues and S3 bucket

## Helm & Kubernetes Commands

```bash
helm lint helm/bebeque-service/
helm template analytics-api helm/bebeque-service/ -f helm/bebeque-service/values/analytics-api.staging.yaml
helm upgrade --install analytics-api helm/bebeque-service/ \
  --namespace staging --create-namespace \
  --values helm/bebeque-service/values/analytics-api.staging.yaml \
  --set image.tag=<git-sha>

kubectl logs -n staging -l app=analytics-api --tail=50 -f
kubectl rollout restart deployment/analytics-api -n staging
```

## PowerShell Gotchas

When working on Windows and writing files that will be sent to AWS or LocalStack:

- **Never** use `Out-File -Encoding utf8` — it adds a BOM that corrupts JSON/CSV payloads.
- **Always** use: `[System.IO.File]::WriteAllText(path, content, [System.Text.UTF8Encoding]::new($false))`
- Fix CRLF on shell scripts before running in containers: `(Get-Content script.sh -Raw).Replace("`r`n", "`n") | Set-Content script.sh -NoNewline`
- PowerShell line continuation uses backtick `` ` ``, not backslash.

## Terraform

Infrastructure lives in `terraform/infra/` (EKS, VPC, ALB, RDS, OIDC provider). `terraform/bootstrap/` is one-time AWS account setup. The GitHub Actions IAM role is `bebeque-github-actions-role`; trust policy is scoped to `main` branch plus named environments (`staging`, `production`).

## Documentation

- `docs/BEBEQUE-NARRATIVE.md` — full migration strategy and architectural decisions
- `README.md` — working test commands, folder structure, PowerShell rules
- `docs/bebeque-step8-cicd-summary.md` — CI/CD pipeline detail
