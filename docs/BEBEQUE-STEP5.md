# Bebeque Energy Platform — Steps 1–5 Summary

## What We Built

A Python microservices platform running locally in Docker. Four services extracted from a monolith, all verified working end-to-end.

---

## The Four Services

### 1. analytics-api
A REST API that B2B clients call to get their energy usage data.
Reads from PostgreSQL. Caches results in Redis for 5 minutes.

### 2. biomass-ingestion
A background worker that reads IoT sensor data from a queue and writes it to the database.
No HTTP endpoints — it just polls SQS and processes messages.

### 3. data-ingestion
A background worker that processes bulk CSV uploads from B2B clients.
A client uploads a CSV to S3, an SQS message tells the worker to go process it, the worker validates each row and inserts them into the database.

### 4. notification-service
A service that sends email and webhook notifications.
Polls a queue for notification events and dispatches them.

---

## The Local Infrastructure

Because we can't run real AWS services locally, Docker Compose includes three stand-ins:

| Local container | What it replaces in production |
|---|---|
| PostgreSQL | AWS RDS |
| Redis | AWS ElastiCache |
| LocalStack | AWS SQS + S3 |

---

## The Tests — and Why They Matter

### Test 1 — Analytics API cache-aside
**What we did:** Called the same endpoint twice.
**What we checked:** First call said `Cache miss — querying database`. Second call said `Cache hit`.
**Why it matters:** Proves Redis is working as a cache layer. In production this means fewer database queries under load, faster response times for B2B clients.

---

### Test 2 — Biomass ingestion end-to-end
**What we did:** Sent a JSON message onto the biomass SQS queue simulating an IoT sensor reading.
**What we checked:** Worker logged `Processed reading — sensor: sensor-001 plant: plant-001`. Row appeared in the `biomass_readings` table in PostgreSQL.
**Why it matters:** Proves the full SQS → worker → database flow works. In production, biomass plant sensors send readings this way continuously.

---

### Test 3 — Data ingestion CSV pipeline
**What we did:** Created a CSV file with meter readings, uploaded it to LocalStack S3, sent an S3 event notification to the SQS queue.
**What we checked:** Worker logged `Processed test-readings.csv — written: 3, skipped: 0`. Three rows appeared in the `meter_readings` table with `source_file = test-readings.csv`.
**Why it matters:** Proves the full S3 + SQS → worker → database flow works. The `source_file` column on every row is data lineage — you can always trace which file a reading came from.

---

### Test 4 — Notification service mock email
**What we did:** Sent a correctly structured notification event onto the notifications SQS queue.
**What we checked:** Worker logged `[MOCK EMAIL] to: client@example.com | subject: Usage Alert`.
**Why it matters:** Proves the notification consumer thread is alive, picking up messages, and dispatching them. In production this sends real emails and webhook calls to clients.

---

### Test 5 — Poison pill handling
**What we did:** Sent a malformed JSON message onto the biomass queue.
**What we checked:** Worker logged `Invalid JSON in message body — discarding` and continued polling. It did not crash.
**Why it matters:** In production, bad messages will arrive. A worker that crashes on a bad message takes down the whole service. A worker that discards bad messages and keeps going is resilient. This is called poison pill handling.

---

## What Was Also Discovered

During verification we found the Terraform folder already had significant work from a previous session:

- **VPC and EKS modules** — written, with a few bugs to fix
- **RDS, ElastiCache, SQS, S3, ECR, IAM, ALB modules** — variable files exist but `main.tf` files are empty
- **Remote state** — S3 backend correctly configured, state file exists but is empty (no real AWS infrastructure created yet)

This means Step 6 is not starting from scratch — it is completing and correcting existing work.

---

## Current Status

| Step | Status |
|---|---|
| Step 1 — Architecture and system design | ✅ Complete |
| Step 2 — Migration strategy | ✅ Complete |
| Step 3 — Application code | ✅ Complete |
| Step 4 — Dockerfiles | ✅ Complete |
| Step 5 — Docker Compose local stack | ✅ Complete and re-verified |
| Step 6 — Terraform AWS infrastructure | 🔄 In progress |

Step 7 — Helm charts
Step 8 — GitHub Actions CI/CD
Step 9 — ArgoCD GitOps
Step 10 — Observability
Step 11 — Security hardening
Step 12 — Incident simulations and interview prep how to speak for long for a question