# Bebeque Energy — Per-Service README Collection

> One section per service. What it does, why it exists, how it works,
> how to run and test it, and what an interviewer will ask about it.

---

# Service 1 — analytics-api

## What it is

A REST API that returns energy usage data for B2B clients. This is the highest-traffic, highest-priority service in the platform. It was the first service migrated from the monolith because it had clear boundaries, was read-only against the database, and had the most to gain from independent scaling.

## What it does

- Accepts HTTP GET requests from B2B client systems
- Checks Redis for a cached response before touching the database
- Queries PostgreSQL for aggregated energy readings if no cache hit
- Stores the result in Redis with a 5-minute TTL
- Returns JSON — total kWh, reading count, time period

## Why it is shaped this way

It is a synchronous API because clients call it and wait for a response. They need an answer now. This is fundamentally different from the workers, which process data in the background with no caller waiting.

FastAPI is chosen over Flask because it is faster for I/O-heavy workloads, validates request inputs automatically, and generates interactive API documentation at `/docs` without extra work.

The cache-aside pattern exists because the same client's usage data gets requested many times — every time they load their dashboard. Without caching, each request hits PostgreSQL. With caching, the database gets asked once per 5-minute window per client, no matter how many requests come in.

## Files and what each one does

| File | Purpose |
|---|---|
| `app/config.py` | Reads environment variables into a typed object. Crashes at startup if required config is missing. |
| `app/database.py` | Creates the PostgreSQL connection pool. Provides `get_db()` dependency that opens and closes sessions per request. |
| `app/cache.py` | Creates the Redis client. Shared across all requests. |
| `app/models.py` | Defines the `energy_readings` table as a Python class. SQLAlchemy uses this to generate SQL queries. |
| `app/schemas.py` | Defines what the API returns. FastAPI uses this to serialise responses to JSON and prevent leaking internal fields. |
| `app/main.py` | The actual API. Health check endpoint and two business endpoints. |

## Endpoints

| Method | Path | What it does |
|---|---|---|
| GET | `/health` | Returns status of the service, database, and Redis. Kubernetes calls this every few seconds. |
| GET | `/api/v1/analytics/clients/{client_id}/usage` | Returns aggregated kWh total for a client over N days. Cache-aside. |
| GET | `/api/v1/analytics/clients/{client_id}/readings` | Returns raw individual readings for a client. No cache — for detailed chart views. |

## How to run locally

```powershell
# Full stack
docker compose up --build -d

# Health check
curl http://localhost:8000/health

# Usage query
curl "http://localhost:8000/api/v1/analytics/clients/client-001/usage?days=30"

# Call twice and verify cache hit
docker compose logs analytics-api | Select-String "cache"
```

## How it scales

HPA — Horizontal Pod Autoscaler — watches CPU usage. When CPU rises above the threshold (typically 70%), Kubernetes adds pods. When it drops, pods are removed. CPU is the right signal because high CPU directly correlates with many simultaneous requests being processed.

Minimum: 2 pods (so there is always a pod ready while another is being replaced during a deployment)
Maximum: depends on load testing results, typically 10 for this traffic level

## What an interviewer will ask

**Why Redis and not just PostgreSQL with a good index?**
PostgreSQL with an index is fast but still requires a network round trip, query parsing, and disk I/O. Redis is in-memory — the response is microseconds, not milliseconds. At 120 B2B clients all checking dashboards at 9am, the difference is meaningful. Also, caching reduces database connection pressure, which matters when the connection pool is shared with the monolith during migration.

**What happens if Redis goes down?**
The health endpoint reports degraded. The API continues to function — every request falls through to PostgreSQL. Performance degrades but nothing breaks. This is called graceful degradation. We could make Redis optional by wrapping the cache calls in try/except and falling back to database on any Redis error.

**Why a 5-minute TTL specifically?**
Energy readings are written hourly at most. A 5-minute cache means a client always sees data that is at most 5 minutes stale, which is acceptable for an analytics dashboard. For a real-time monitoring use case you would lower it. For a daily summary report you could raise it to hours.

**What does `pool_pre_ping=True` do?**
It tells SQLAlchemy to test a connection before using it. Database connections can go stale — the connection appears open but the database has closed it. Without pre-ping, a stale connection causes a request to fail with a confusing error. With pre-ping, SQLAlchemy detects the stale connection and opens a fresh one transparently.

**What is a FastAPI dependency?**
`Depends(get_db)` is FastAPI's dependency injection system. Instead of calling `get_db()` manually in every endpoint function, FastAPI calls it and passes the result in. The key benefit is cleanup — FastAPI runs the code after the `yield` in `get_db()` whether the request succeeded or raised an exception. The database session always gets closed, always.

---

# Service 2 — biomass-ingestion

## What it is

A queue consumer worker that reads IoT sensor readings from an SQS queue and writes them to PostgreSQL. This was the second service migrated because the biomass product was new — there was no legacy code to untangle, no existing clients depending on the old implementation.

## What it does

- Continuously polls an SQS queue for sensor reading messages
- Parses each message as JSON
- Validates that required fields are present
- Writes a row to the `biomass_readings` table in PostgreSQL
- Deletes the message from SQS on success
- Leaves the message in the queue on failure so it gets redelivered

## Why it is shaped this way

There is no client waiting for a response. IoT sensors fire readings into a queue and do not care when they get processed. This asynchronous pattern — produce now, consume when ready — is the right shape for data ingest.

A worker, not an API, because nothing needs to call it. It calls out — to SQS, to PostgreSQL — but nothing calls in. No HTTP endpoints. No Ingress. No Service in Kubernetes. Just a Deployment running a Python loop.

## Files and what each one does

| File | Purpose |
|---|---|
| `app/config.py` | Environment variable config. Includes `visibility_timeout` and `batch_size` settings. |
| `app/database.py` | PostgreSQL connection. Also defines the `BiomassReading` model — the table schema. |
| `app/worker.py` | The entire worker — signal handlers, message processing, polling loop. |

## The message format it expects

```json
{
  "sensor_id": "sensor-001",
  "plant_id": "plant-new-york",
  "temperature_celsius": 82.4,
  "moisture_percent": 23.1,
  "output_kwh": 145.7,
  "sensor_timestamp": "2024-04-06T10:00:00"
}
```

`sensor_id`, `plant_id`, and `sensor_timestamp` are required. Temperature, moisture, and output_kwh are optional — some sensors only report a subset of measurements.

## How to run and test locally

```powershell
# Start the full stack
docker compose up --build -d

# Send a test sensor reading
$biomass = '{"sensor_id":"sensor-001","plant_id":"plant-new-york","temperature_celsius":82.4,"moisture_percent":23.1,"output_kwh":145.7,"sensor_timestamp":"2024-04-06T10:00:00"}'
[System.IO.File]::WriteAllText("$env:TEMP\biomass-message.json", $biomass, [System.Text.UTF8Encoding]::new($false))

aws sqs send-message `
  --endpoint-url http://localhost:4566 `
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/biomass-queue `
  --message-body file://$env:TEMP/biomass-message.json `
  --region us-east-1

# Watch the worker process it
docker compose logs -f biomass-ingestion

# Verify the row in the database
$postgresContainer = docker compose ps -q postgres
docker exec -it $postgresContainer psql -U postgres -d bebeque -c "SELECT * FROM biomass_readings ORDER BY created_at DESC LIMIT 5;"

# Test poison pill handling
aws sqs send-message `
  --endpoint-url http://localhost:4566 `
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/biomass-queue `
  --message-body "this is not valid json" `
  --region us-east-1
```

## How it scales

KEDA — Kubernetes Event-Driven Autoscaler — watches the SQS queue depth. If messages are backing up, KEDA adds pods to drain the queue faster. When the queue is empty, KEDA scales to zero pods. Zero pods means zero compute cost when there is no IoT data coming in.

HPA cannot scale to zero. This is the primary reason workers use KEDA.

## What an interviewer will ask

**What is long polling and why does it matter?**
`WaitTimeSeconds=20` tells SQS to hold the connection open for up to 20 seconds if the queue is empty before returning. Without this, the worker fires off a request to SQS every second or two, receives an empty response, and does it again. With long polling, an idle worker makes approximately three requests per minute instead of hundreds. This reduces SQS API call costs and reduces the chance of hitting SQS rate limits at scale.

**What is the visibility timeout?**
When a worker receives a message, SQS hides it from all other consumers for the visibility timeout period (30 seconds for biomass). This prevents two worker pods from processing the same message simultaneously. If the worker crashes or takes longer than 30 seconds to process the message, SQS makes the message visible again and it gets picked up by another worker. This guarantees at-least-once delivery.

**What does at-least-once delivery mean?**
Every message will be processed at least once, but possibly more than once if a worker crashes after writing to the database but before deleting the message from SQS. The message gets redelivered and processed again — a duplicate write. For sensor readings this is acceptable — a duplicate reading with the same timestamp can be detected and deduplicated later. For financial transactions you would need additional deduplication logic.

**What is a poison pill?**
A message that can never be successfully processed — malformed JSON, missing required fields, an impossible data value. If the worker returned False for every failure, a poison pill would loop forever, being redelivered every 30 seconds indefinitely. The worker detects unrecoverable messages and returns True — treating them as successfully handled — so they get deleted. In production you would also send them to a dead letter queue first so you can inspect them later.

**Why does the worker use `signal.signal(signal.SIGTERM, handle_shutdown)`?**
Kubernetes sends SIGTERM before killing a pod — during a deployment, a scale-down, or a node drain. The signal handler sets a flag. The polling loop checks the flag at the top of every iteration. The worker finishes its current message and exits cleanly. Without this, Kubernetes forcibly kills the process mid-message after a 30-second grace period. The message stays invisible in SQS until the visibility timeout expires, then gets redelivered and processed twice.

---

# Service 3 — data-ingestion

## What it is

A queue consumer worker that processes CSV files uploaded by B2B clients. Files land in S3. S3 fires an event to SQS. This worker reads the event, downloads the CSV, parses it, and bulk-inserts the meter readings into PostgreSQL.

## What it does

- Polls an SQS queue for S3 event notifications
- Extracts the S3 file path from the event
- Downloads the CSV file from S3 into memory
- Parses every row, validates required columns and data types
- Skips invalid rows with a warning log, does not fail the whole file
- Bulk-inserts all valid rows in a single database transaction
- Stores the S3 file path on every row for data lineage
- Deletes the SQS message on success

## Why it is shaped this way

The same reasons as biomass-ingestion — asynchronous, queue-driven, no HTTP endpoints — but with an extra step in the middle. S3 is the entry point, not SQS directly. S3 event notifications are the bridge.

This is a common AWS pattern for file processing pipelines. File lands in S3 → S3 fires event to SQS → worker processes file. It decouples the upload from the processing. A client can upload a CSV and get a response immediately from S3. The actual processing happens in the background without the client waiting.

## Files and what each one does

| File | Purpose |
|---|---|
| `app/config.py` | Config including `s3_bucket_name` and a longer `visibility_timeout` of 120 seconds. |
| `app/database.py` | PostgreSQL connection. Defines `MeterReading` model with `source_file` column for data lineage. |
| `app/worker.py` | Full pipeline — polling, S3 download, CSV parsing, bulk insert. |

## The SQS message format it expects

```json
{
  "Records": [{
    "s3": {
      "bucket": { "name": "bebeque-uploads" },
      "object": { "key": "uploads/client-003/april-2024.csv" }
    }
  }]
}
```

This is the format AWS S3 uses for event notifications. The worker extracts the bucket name and object key, then calls `s3_client.get_object()` to download the file.

## The CSV format it expects

```csv
client_id,meter_id,reading_kwh,recorded_at
client-003,meter-X,234.5,2024-04-01T09:00:00
client-003,meter-X,241.2,2024-04-02T09:00:00
```

Required columns: `client_id`, `meter_id`, `reading_kwh`, `recorded_at`. Rows missing any of these are skipped with a warning. The file continues processing. A bad row does not abort the entire file.

## How to run and test locally

```powershell
# Create CSV without BOM
$csv = "client_id,meter_id,reading_kwh,recorded_at`nclient-003,meter-X,234.5,2024-04-01T09:00:00`nclient-003,meter-X,241.2,2024-04-02T09:00:00`nclient-003,meter-X,228.9,2024-04-03T09:00:00`nclient-004,meter-Y,178.3,2024-04-01T09:00:00`nclient-004,meter-Y,182.1,2024-04-02T09:00:00`n"
[System.IO.File]::WriteAllText("$env:TEMP\test-readings.csv", $csv, [System.Text.UTF8Encoding]::new($false))

# Upload to LocalStack S3
aws s3 cp "$env:TEMP\test-readings.csv" `
  s3://bebeque-uploads/uploads/client-003/april-2024.csv `
  --endpoint-url http://localhost:4566 `
  --region us-east-1

# Send the S3 event to SQS
$s3event = '{"Records":[{"s3":{"bucket":{"name":"bebeque-uploads"},"object":{"key":"uploads/client-003/april-2024.csv"}}}]}'
[System.IO.File]::WriteAllText("$env:TEMP\s3-event.json", $s3event, [System.Text.UTF8Encoding]::new($false))

aws sqs send-message `
  --endpoint-url http://localhost:4566 `
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/data-ingestion-queue `
  --message-body file://$env:TEMP/s3-event.json `
  --region us-east-1

# Watch the worker
docker compose logs -f data-ingestion

# Verify in database
$postgresContainer = docker compose ps -q postgres
docker exec -it $postgresContainer psql -U postgres -d bebeque -c "SELECT client_id, meter_id, reading_kwh, source_file FROM meter_readings LIMIT 10;"

# Verify queryable via analytics-api
curl "http://localhost:8000/api/v1/analytics/clients/client-003/usage?days=30"
```

## How it scales

KEDA based on data-ingestion-queue depth. Same rationale as biomass-ingestion. Scales to zero when no files are being uploaded.

The visibility timeout is set to 120 seconds (vs 30 for biomass) because downloading and parsing a large CSV takes significantly longer than writing a single sensor reading. If the timeout was 30 seconds, SQS would redeliver the message while the worker was still processing it, causing duplicate inserts.

## What an interviewer will ask

**Why does the visibility timeout matter more here than for biomass-ingestion?**
Biomass processes one JSON object — fast. Data-ingestion downloads a file from S3 over the network, reads potentially thousands of rows, and writes them all to the database. If a CSV has 10,000 rows and the worker processes 1,000 rows per second, that is 10 seconds minimum just for database writes, plus download time. A 30-second visibility timeout could easily expire before the processing finishes, causing SQS to redeliver the message and the worker to process the file twice. 120 seconds gives comfortable headroom.

**What is data lineage and why does it matter?**
The `source_file` column stores the S3 key of the CSV that produced each row — for example `uploads/client-003/april-2024.csv`. If a B2B client reports their energy data for March looks incorrect, you can query: `SELECT * FROM meter_readings WHERE source_file = 'uploads/client-003/march-2024.csv'`. You can see every row that came from that file. You can reprocess it if needed. Without data lineage, you cannot trace data back to its source — debugging data quality issues becomes extremely difficult.

**Why bulk insert instead of row by row?**
`db.add_all(readings)` followed by one `db.commit()` sends all rows to PostgreSQL in a single network round trip and a single transaction. Inserting row by row means one round trip per row — for a 500-row CSV that is 500 network round trips. At 1ms per round trip, that is 500ms of network time alone. Bulk insert collapses that to one round trip. The difference is especially significant when the database is not localhost but an RDS instance across a network.

**What happens if the CSV has 1000 rows and row 500 fails?**
In the current implementation, invalid rows are skipped individually during parsing — they are logged as warnings and excluded from the `readings` list. The valid rows are still bulk-inserted. So a CSV with 999 valid rows and 1 invalid row writes 999 rows successfully. The `db.rollback()` in the outer exception handler only fires if something unexpected fails — not for individual row validation failures.

**Why `decode("utf-8-sig")` instead of `decode("utf-8")`?**
The `-sig` variant is defensive. It automatically strips a BOM if one is present at the start of the file. BOM is an invisible marker that some tools — including older PowerShell — add to UTF-8 files. Without `-sig`, a BOM causes the first column header to be read as `<invisible bytes>client_id` instead of `client_id`, and all rows fail validation with "missing columns: client_id". The `-sig` fix makes the worker resilient to files created by different tools on different platforms.

---

# Service 4 — notification-service

## What it is

A hybrid service that runs a FastAPI health endpoint and a background SQS consumer thread simultaneously. It receives internal notification events from other services and sends email and webhook notifications to B2B clients.

## What it does

- Runs a background thread that polls the notifications SQS queue
- Parses each message as a notification event
- Sends a mock email to the client's configured address
- Sends a mock webhook to the client's configured endpoint if one exists
- Exposes a `/health` endpoint that Kubernetes uses to check whether the service is alive — including whether the background consumer thread is still running

## Why it is shaped this way

The notification-service needs two things at once — an HTTP interface for health checks and a queue consumer for its actual work. Rather than running two separate processes, it runs both in one process using Python threading. The FastAPI server runs in the main thread. The SQS consumer runs in a background daemon thread started at application startup via FastAPI's lifespan event.

The health endpoint actively monitors the consumer thread. If the thread dies, the health endpoint reports degraded. Kubernetes detects this and restarts the pod. Without this monitoring, the pod could appear healthy while the consumer thread had silently crashed — notifications would stop being sent with no alert.

## Why events come through SQS and not direct HTTP

If the analytics-api called the notification-service directly over HTTP:

- The analytics-api would need to know the notification-service's address
- If the notification-service was down during a deployment, the call would fail and the notification would be lost
- Adding a second consumer (a logging service, an audit trail) would require changing the analytics-api
- The analytics-api would be coupled to the availability of the notification-service

With SQS:

- The analytics-api publishes one message and moves on — it does not know or care who reads it
- Messages wait in the queue for up to 14 days if the consumer is down — nothing is lost
- Adding new consumers requires zero changes to the analytics-api
- The services are decoupled — they can be deployed, scaled, and restarted independently

## Files and what each one does

| File | Purpose |
|---|---|
| `app/config.py` | Environment variable config. No database URL — this service does not write to the database directly. |
| `app/schemas.py` | Defines `NotificationEvent` — the expected message structure — and `HealthResponse`. |
| `app/notifier.py` | Mock email and webhook sending. Logs what would be sent. Replace with real SES/SendGrid integration. |
| `app/consumer.py` | SQS polling loop. Runs in a background thread. Signal handlers for graceful shutdown. |
| `app/main.py` | FastAPI app. Lifespan starts the consumer thread. Health endpoint checks thread is alive. |

## The event format it expects

```json
{
  "event_type": "usage_threshold_exceeded",
  "client_id": "client-001",
  "recipient_email": "admin@client001.com",
  "subject": "Energy usage alert",
  "body": "Your energy usage has exceeded your monthly threshold.",
  "webhook_url": "https://client001.com/webhooks/bebeque"
}
```

`webhook_url` is optional — not all clients have webhooks configured.

## How to run and test locally

```powershell
# Health check
curl http://localhost:8001/health

# Send a notification event
$notification = '{"event_type":"usage_threshold_exceeded","client_id":"client-001","recipient_email":"admin@client001.com","subject":"Energy usage alert","body":"Your energy usage has exceeded your monthly threshold.","webhook_url":"https://client001.com/webhooks/bebeque"}'
[System.IO.File]::WriteAllText("$env:TEMP\notification.json", $notification, [System.Text.UTF8Encoding]::new($false))

aws sqs send-message `
  --endpoint-url http://localhost:4566 `
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/notifications-queue `
  --message-body file://$env:TEMP/notification.json `
  --region us-east-1

# Watch the service process it
docker compose logs -f notification-service
```

Expected in logs:
```
[MOCK EMAIL] to: admin@client001.com | subject: Energy usage alert | body: Your energy usage...
[MOCK WEBHOOK] url: https://client001.com/webhooks/bebeque | payload: {...}
```

## How it scales

HPA based on CPU. The notification-service handles HTTP health check requests and processes notification events. CPU is a reasonable proxy for load on this service.

## What an interviewer will ask

**Why does the health endpoint check the consumer thread?**
A pod can be running and passing HTTP health checks while the consumer thread has silently crashed. Kubernetes would never know — the pod looks healthy. Notifications would stop being sent. No alert would fire. By checking `consumer_thread.is_alive()` in the health endpoint, we make the internal thread state visible to Kubernetes. A dead thread returns degraded status. Kubernetes restarts the pod. The thread comes back up. This is called surfacing internal health to the orchestrator.

**What is FastAPI lifespan?**
The `@asynccontextmanager async def lifespan(app)` function runs code at startup (before the API accepts requests) and at shutdown (after it stops). We use startup to launch the consumer thread — so it is always running alongside the HTTP server. The `yield` in the middle is where the API runs. Everything before `yield` is startup, everything after is shutdown.

**What does `daemon=True` mean on the thread?**
A daemon thread is killed automatically when the main process exits. Without `daemon=True`, the Python process would stay alive after the main thread stopped, waiting for the consumer thread to finish. With `daemon=True`, if the main process exits for any reason, the consumer thread is killed too. The pod exits cleanly. Kubernetes restarts it.

**How would you replace the mock email sending with real sending?**
Replace the body of `send_email()` in `notifier.py` with a call to AWS SES: `ses_client.send_email(Source=..., Destination=..., Message=...)`. The rest of the service stays identical. Because the notification logic is isolated in `notifier.py`, the change is minimal and testable in isolation. This is the single responsibility principle applied at the function level.

**Why test the notification-service by publishing directly to SQS instead of through the analytics-api?**
Because the services are decoupled. The notification-service does not know and does not care who publishes to its queue. Publishing directly proves the service works without involving any other service — pure isolation. If the test failed, you would know the problem was in the notification-service itself, not in the analytics-api or the queue wiring. This is the testing benefit of loose coupling.

---

# Cross-Service Topics

## Why all four services use the same Dockerfile pattern

Two-stage build, non-root user, requirements before code, exec-form CMD. This is called a golden path template. Any engineer on the team can read any Dockerfile and understand it immediately because they all follow the same structure. Consistency reduces cognitive overhead and reduces the chance of one service having a misconfigured container that only shows up in production.

## Why configuration always comes from environment variables

The same Docker image runs in development, staging, and production. Only the environment variables change. This is the twelve-factor app configuration principle. It means you never need to rebuild an image to deploy to a different environment — you just change the variables. Database URL, queue URL, Redis URL, environment name — all injected at runtime, never hardcoded.

## Why the default environment is development not production

The `environment: str = "development"` in every config is a default — what the setting falls back to if no environment variable is provided. In production, the Helm chart explicitly sets `ENVIRONMENT: production` in the ConfigMap and that value overrides the default. The development default is a safety net: if a production pod somehow loses its environment variables, it fails toward the less dangerous state rather than behaving as production unexpectedly.

## Why every service has structured JSON logging

Log lines formatted as JSON objects are queryable in CloudWatch. Instead of grepping raw text, you can filter: show me all cache misses for client-001 in the last hour. In an incident, structured logs are the difference between finding the root cause in 5 minutes and spending 45 minutes reading raw text. Every service uses the same log format so you can correlate events across services by timestamp.

## The PowerShell-specific lessons learned

On Windows PowerShell 5, `Out-File -Encoding utf8` adds a BOM — three invisible bytes — to every file. The AWS CLI sends those bytes as part of the message body. Workers receive what looks like empty or corrupt content.

The fix for every file write: `[System.IO.File]::WriteAllText("path", content, [System.Text.UTF8Encoding]::new($false))`. The `$false` means no BOM.

For CSV files read by the data-ingestion worker: `decode("utf-8-sig")` strips a BOM if present, making the worker resilient regardless of what tool created the file.

Shell scripts for Linux containers must use LF line endings, not CRLF. Fix after every edit: `(Get-Content file -Raw).Replace("`r`n", "`n") | Set-Content file -NoNewline`.

These are not obscure edge cases. They are common friction points when building Linux-based infrastructure from a Windows development machine. Knowing them and being able to explain them demonstrates real operational experience.
