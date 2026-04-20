# Bebeque Energy Platform

Microservices platform for energy analytics and IoT data ingestion. Migrating from EC2 monolith to EKS using the strangler fig pattern.

---

## Quick Start

```powershell
docker compose up --build -d
docker compose ps
```

Services start in dependency order: Postgres → Redis → LocalStack → application services.

First startup auto-initialises:
- **`scripts/seed-database.sql`** — creates tables + sample data
- **`scripts/init-localstack.sh`** — creates SQS queues + S3 bucket

---

## Services

| Service | Port | Type | Scales on |
|---------|------|------|-----------|
| `analytics-api` | 8000 | FastAPI REST | HPA (CPU) |
| `notification-service` | 8001 | FastAPI + SQS daemon thread | HPA |
| `biomass-ingestion` | — | SQS worker | KEDA (queue depth, scales to zero) |
| `data-ingestion` | — | SQS worker | KEDA (scales to zero) |

**Data flows:**
- IoT sensor → SQS `biomass-queue` → `biomass-ingestion` → `biomass_readings`
- Client CSV → S3 → SQS `data-ingestion-queue` → `data-ingestion` → `meter_readings`
- HTTP query → `analytics-api` → Redis (5 min TTL) → Postgres fallback
- Event → SQS `notifications-queue` → `notification-service` → email / webhook

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

Verify rows + data lineage (`source_file` column):
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
docker stats --no-stream                  # memory usage

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

## Incidents and Fixes

| Problem | Cause | Fix |
|---|---|---|
| `NonExistentQueue` on startup | Worker started before LocalStack init script finished | Healthcheck verifies queue with `get-queue-url`, not just port open |
| Queue URL not found | Newer LocalStack uses subdomain URL format | Use `http://sqs.us-east-1.localhost.localstack.cloud:4566/...` |
| `Expecting value: line 1 column 1` on JSON messages | PowerShell `Out-File -Encoding utf8` adds BOM | `[System.IO.File]::WriteAllText` with `UTF8Encoding::new($false)` |
| `Skipping row — missing columns: ['client_id']` | BOM on CSV corrupts first column header | Same fix. Worker also uses `decode("utf-8-sig")` as defence |
| Message stuck redelivering | Worker returning False causes SQS to redeliver indefinitely | `purge-queue` to clear during development |
| `NoSuchBucket` on S3 upload | Init script didn't create bucket | Manually run `aws s3 mb` |
