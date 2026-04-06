# Bebeque Energy Platform — Narrative Walkthrough

> Read this out loud. It is written the way you would explain this project to an interviewer,
> a new team member, or a technical lead who wants to understand every decision you made.

---

## The Story — Where We Started

When I joined Bebeque Energy, the entire platform was a single Python application running on one EC2 virtual machine in AWS. One application doing eight jobs simultaneously — handling user logins, serving energy analytics, generating PDF reports, processing IoT sensor data from biomass plants, sending emails and webhooks, running an admin tool, and ingesting CSV files uploaded by B2B clients.

This is called a monolith. It works until it does not. The problems are predictable: one bug in the report generator can take down the login system. One traffic spike on the analytics dashboard slows down everything else. You cannot update the notification logic without redeploying the entire application and risking every other feature.

The engineering team had already decided to break it apart into microservices — separate, independent applications each doing one job. My role as the lead DevOps contractor was to design and build the platform those microservices would run on, establish the deployment standards, and migrate services across one by one while the monolith kept serving 120 live B2B clients without interruption.

That last constraint — migrate without disrupting live clients — is what shapes every decision in this architecture.

---

## The Pattern — Strangler Fig

The approach we used is called the strangler fig pattern, named after a tree that grows around another tree, gradually takes over, and eventually replaces it entirely. At no point does the forest go dark.

In practice it works like this. You build the new platform alongside the old one. You shift traffic piece by piece. The old monolith handles anything not yet migrated. When everything is migrated, you decommission the monolith. The clients never notice the transition.

The mechanism that makes this possible is the AWS Application Load Balancer. It sits in front of both environments and reads the URL of every incoming request. Based on routing rules you configure, it decides: does this request go to the new EKS platform or to the old EC2 monolith?

Right now those rules look like this. Requests to `/api/v1/analytics` go to EKS — that service has been migrated. Requests to `/api/v1/ingest` go to EKS — that one too. Everything else — report generation, the consumer dashboard, authentication, the admin tool — still goes to the EC2 monolith, because those services have not been migrated yet.

This means a B2B client hitting the platform at any given moment might be served by the new EKS platform for their analytics data and by the old monolith for their PDF report, in the same session, without knowing or caring about either. To them it is one product. To us it is a controlled migration in progress.

---

## The Platform — Why EKS

The new platform runs on AWS EKS, which is Elastic Kubernetes Service. Kubernetes is an open-source system for running containerised applications at scale. EKS is AWS's managed version of it — AWS handles the control plane so we do not have to.

The alternative would have been ECS, AWS's own container platform. ECS is simpler and cheaper to operate. But we chose EKS for three reasons.

First, portability. Kubernetes is an industry standard. The skills, the tooling, the configuration — all of it transfers if Bebeque ever moves to a different cloud provider or if any engineer on the team moves to a different company. ECS is AWS-proprietary. Everything you build for it stays there.

Second, ecosystem. The tools we need — KEDA for queue-based autoscaling, ArgoCD for GitOps deployments, OPA Gatekeeper for policy enforcement, kube-prometheus-stack for observability — all run natively on Kubernetes. Replicating this on ECS requires significantly more bespoke work.

Third, it is what hiring managers and technical leads expect to see when a senior DevOps engineer says they built a production microservices platform. EKS is the credible choice.

---

## The Four Services — What They Are and Why They Are Shaped That Way

Four services have been migrated from the monolith to EKS so far. Each one has a different shape, and each shape exists for a specific reason.

### analytics-api — The synchronous REST API

The analytics-api is the most important service in the platform. It is what 120 B2B clients talk to when they want to see their energy usage data. A client's system sends an HTTP GET request — give me this client's energy consumption for the last 30 days — and expects an immediate response.

This is called a synchronous service. The client is waiting. The service must respond. It is built with FastAPI, a Python web framework chosen for its speed, its automatic request validation, and its auto-generated API documentation.

When a request arrives, the first thing the service does is check Redis. Redis is an in-memory cache — think of it as a very fast notepad that forgets everything after a set time. If the answer to this exact question was already computed in the last five minutes and stored there, the service returns it immediately without touching the database. This is called the cache-aside pattern.

If the answer is not in Redis — a cache miss — the service queries the PostgreSQL database, calculates the aggregated energy usage, stores the result in Redis with a five-minute expiry, and returns it to the client. The next time anyone asks the same question within five minutes, Redis answers instantly.

Why does this matter? The analytics-api serves 120 B2B clients. Many of them check their dashboards at similar times — first thing in the morning, at the end of the month. Without caching, a hundred simultaneous requests for the same client's data means a hundred database queries. With caching, it means one database query and ninety-nine Redis reads. The database stays fast for everyone.

This service scales using HPA — the Horizontal Pod Autoscaler. When CPU usage rises because many requests are coming in simultaneously, Kubernetes automatically adds more pods. When traffic drops, it scales back down. CPU is the right signal here because high CPU means the API is actively processing many requests.

### biomass-ingestion — The queue consumer worker

The biomass-ingestion service looks completely different from the analytics-api because it has a completely different job. Bebeque recently launched a biomass energy product. IoT sensors at biomass plants continuously measure temperature, moisture levels, and energy output. Those readings need to get into the database.

This service has no HTTP endpoints. Nothing calls it. It drives itself. It runs a continuous loop — ask an SQS queue if there are any messages, process them, loop again. IoT sensors publish their readings to that queue. This worker picks them up, parses the JSON payload, validates the required fields, writes a row to the biomass_readings table in PostgreSQL, and tells SQS the message was handled by deleting it.

The key behaviours that make this reliable in production are three things.

Long polling — instead of hammering SQS with rapid-fire empty requests when the queue is quiet, the worker asks SQS to hold the connection open for up to twenty seconds before returning an empty response. This is far more efficient and costs less money.

Visibility timeout — when the worker picks up a message, SQS hides it from all other workers for thirty seconds. This prevents two pods from processing the same sensor reading simultaneously. If the worker crashes before finishing, the message becomes visible again after thirty seconds and gets redelivered automatically.

Graceful shutdown — when Kubernetes needs to stop a pod, it sends a SIGTERM signal first. The worker catches this signal, finishes processing its current message, and then exits cleanly. Without this, Kubernetes could kill a pod mid-processing, leaving a message partially written and redelivered unnecessarily.

This service scales using KEDA — the Kubernetes Event-Driven Autoscaler. KEDA watches the SQS queue depth. If five hundred messages are waiting, KEDA scales up to ten pods to drain the queue fast. When the queue is empty, KEDA scales all the way back to zero pods. Zero pods means zero compute cost during quiet periods. The standard Kubernetes autoscaler, HPA, cannot scale to zero — that is the key reason we use KEDA for workers.

### data-ingestion — The CSV pipeline worker

The data-ingestion service handles a different kind of data inflow. B2B clients do not always send data in real time via IoT sensors. Some clients upload bulk CSV files containing historical meter readings. A client uploads a file, and this service processes it.

The flow has more steps than biomass-ingestion. The CSV file lands in an S3 bucket. S3 fires an event notification to an SQS queue. This worker reads that SQS message, extracts the S3 file path from it, downloads the CSV, parses every row, validates each one for required columns and correct data types, and bulk-inserts all valid rows into PostgreSQL in a single database transaction.

A few details worth explaining. The visibility timeout on this worker is one hundred and twenty seconds instead of thirty. Downloading a large CSV and parsing hundreds of rows takes longer than writing a single sensor reading. If the timeout was too short, SQS would redeliver the message while the worker was still processing it, causing duplicate inserts.

Bulk insert means all valid rows from a CSV are added to the database in one transaction with one commit. This is dramatically faster than committing after each row. A five-hundred-row CSV with per-row commits makes five hundred database round trips. With bulk insert it makes one.

Every row written to the database includes the S3 file path it came from, stored in a column called source_file. This is called data lineage. If a B2B client ever says their data for a particular month looks wrong, you can query the database and trace every single row back to the exact file it came from. That is the kind of operational detail that matters in production but is easy to skip when you are moving fast.

Like biomass-ingestion, this service scales with KEDA based on queue depth.

### notification-service — The event-driven notifier

The notification-service is architecturally interesting because it is a hybrid. It runs two things simultaneously in the same process — a FastAPI HTTP server for its health endpoint, and a background thread that consumes messages from an SQS queue.

Its job is to send notifications to B2B clients. When something notable happens — a client's energy usage crosses a threshold, a monthly report is ready — the analytics-api publishes an event to a notifications SQS queue. The notification-service picks that event up and sends the client an email and, if they have one configured, a webhook to their own systems.

The actual email and webhook sending is mocked in this implementation — we log what would be sent rather than integrating a real email service like AWS SES. This keeps the local testing environment simple while the core pattern — event consumed, notification dispatched — is fully functional and testable.

The reason the two services communicate through SQS rather than directly over HTTP is decoupling. If the analytics-api called the notification-service directly over HTTP, the analytics-api would need to know the notification-service's address. If the notification-service was down during a deployment, the analytics-api's call would fail. If you wanted to add a second consumer — a logging service, an audit trail — you would have to change the analytics-api code to call it too.

With SQS, the analytics-api publishes one message and immediately moves on. It does not know or care who reads it. The notification-service subscribes to the queue and processes messages at its own pace. If it is down, messages wait safely in the queue for up to fourteen days and are processed when it comes back up. Adding a new consumer requires zero changes to the analytics-api. This is the event-driven architecture pattern and it is one of the most important architectural decisions in this project.

The service uses HPA for scaling because it has an HTTP endpoint that Kubernetes uses for health checks, and CPU is a reasonable proxy for load on a notification service.

---

## The Infrastructure — What Lives Where and Why

### The database is outside Kubernetes

PostgreSQL runs on AWS RDS — a managed database service — not inside the Kubernetes cluster. This is deliberate.

Pods in Kubernetes are ephemeral. Kubernetes can kill and reschedule a pod at any time. You do not want your database to disappear because Kubernetes decided to move a pod to a different node. Running a database inside Kubernetes is possible but requires significant additional work — persistent volumes, careful scheduling, your own backup and failover management.

RDS gives you all of that for free. AWS handles automated backups, point-in-time recovery, multi-AZ failover, patching, and monitoring. The managed service costs a bit more than running PostgreSQL yourself, but it eliminates an entire category of operational risk.

There is also a migration-specific reason. During the strangler fig migration, both the EC2 monolith and the EKS services connect to the same database. That database must exist independently of either environment. If it lived inside EKS, the monolith could not reach it cleanly.

### The cache is outside Kubernetes for the same reason

Redis runs on AWS ElastiCache. Same logic as the database. Stateless applications — APIs, workers — go inside Kubernetes. Stateful systems — databases, caches — go on managed AWS services.

### SQS connects the services

Three SQS queues carry the asynchronous communication between services and from the outside world into the platform. The biomass queue receives IoT sensor readings. The data-ingestion queue receives S3 upload notifications. The notifications queue receives internal events from the analytics-api.

SQS is managed by AWS, which means message durability, delivery guarantees, and scaling are all handled. You do not run a message broker yourself.

### S3 stores files

S3 holds two types of files. CSV uploads from B2B clients land here and trigger the data-ingestion pipeline. Generated PDF reports will be stored here too, served through CloudFront so the application servers never have to handle file downloads directly.

### IRSA scopes permissions per service

Each service has its own AWS identity through IRSA — IAM Roles for Service Accounts. The analytics-api can reach RDS and Redis. The biomass-ingestion worker can reach its SQS queue and write to RDS. The data-ingestion worker can reach its SQS queue, read from S3, and write to RDS. No service can touch another service's resources.

This is the principle of least privilege applied at the pod level. If a service is compromised, the blast radius is limited to exactly the resources that service legitimately needs.

---

## The Local Testing Environment — What We Built and Why

Before touching AWS, we ran the entire platform on a laptop using Docker Compose. Seven containers: PostgreSQL, Redis, LocalStack, and the four application services.

LocalStack is a tool that runs fake versions of AWS services inside a Docker container. It emulates SQS and S3 so your application code can use the real AWS SDK — boto3 — without connecting to real AWS. The application code is identical between local and production. Only environment variables change. Locally, the SQS endpoint points at LocalStack. In production, it points at real AWS. The code does not know the difference.

This is important because it means every bug you find locally is a real bug, not a local-only quirk. The data flows that work in Docker Compose will work in EKS.

### What each test proved

Test one proved the analytics-api starts correctly, connects to PostgreSQL, connects to Redis, and returns a healthy status on its health endpoint. The health endpoint is not a nice-to-have — Kubernetes calls it continuously to decide whether to keep a pod running or restart it.

Test two proved the cache-aside pattern works. The first call to the usage endpoint hit the database — we could see the cache miss in the logs. The second call returned immediately from Redis — we could see the cache hit. The database received one query for two client requests.

Test three proved the biomass-ingestion pipeline end to end. We published a JSON message to the SQS queue simulating an IoT sensor reading. The worker picked it up within twenty seconds, parsed it, wrote it to the biomass_readings table, and deleted the message from the queue. We verified the row in the database.

Test four proved the data-ingestion pipeline end to end. We created a CSV file with five meter readings, uploaded it to the LocalStack S3 bucket, published an S3 event notification to the SQS queue, and watched the worker download the CSV, parse all five rows, and bulk-insert them into the meter_readings table. We then verified the data was queryable through the analytics-api — proving the full chain from file upload to API response.

Test five proved the notification-service receives events and dispatches notifications. We published a notification event to the notifications queue and watched the service log a mock email and webhook, confirming the consumer thread was running and processing messages correctly.

Test six proved the poison pill handling. We sent a deliberately malformed message — plain text, not JSON — to the biomass queue. The worker logged the error, deleted the message, and continued running normally. It did not crash. It did not loop. The next valid message would be processed correctly.

---

## The Problems We Hit and What They Taught Us

### The race condition

When we first started the stack, the biomass-ingestion worker immediately began throwing NonExistentQueue errors. It was starting and trying to connect to the SQS queue before LocalStack had finished running the init script that creates the queues.

The containers were healthy by Docker's definition — LocalStack was responding to API calls. But healthy does not mean ready. The healthcheck was too loose. It verified that LocalStack was alive, not that the queues actually existed.

The fix was to tighten the healthcheck to use `get-queue-url` for a specific queue rather than `list-queues`. `get-queue-url` fails if the queue does not exist. So the healthcheck now only passes once the init script has created the queues. This is the difference between a container being started and a dependency being ready — the same concept that `depends_on: condition: service_healthy` exists to solve.

### The URL format change

After fixing the healthcheck, the workers were still failing with NonExistentQueue. The init script was creating the queues successfully, but the workers could not find them.

The issue was the queue URL format. Newer versions of LocalStack use a subdomain-style URL: `http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/queue-name`. The workers were configured with the old simple format: `http://localstack:4566/000000000000/queue-name`. These are different addresses. The SDK was looking in the wrong place.

The fix was to update the queue URLs in the Compose file to match what LocalStack actually creates, which you can see by running `aws sqs list-queues`. This is a good reminder that infrastructure dependencies have versions and their behaviour can change between releases.

### The BOM problem

Once the queue URL was correct, test messages were arriving at the workers but being discarded with a JSON parse error — "Expecting value: line 1 column 1 char 0." The message body appeared empty.

The cause was the BOM — Byte Order Mark. PowerShell 5's `Out-File -Encoding utf8` writes an invisible three-byte sequence at the start of every file. The AWS CLI reads the file and sends those three bytes as the start of the message body. The worker receives what looks like empty or corrupt content and cannot parse it.

The fix is to write files using the .NET method directly: `[System.IO.File]::WriteAllText` with `UTF8Encoding::new($false)`. The `$false` means do not emit a BOM. This works on all PowerShell versions.

The same issue affected CSV files uploaded to S3. The fix there is defensive — the data-ingestion worker uses `decode("utf-8-sig")` when reading the CSV content. The `-sig` variant automatically strips a BOM if one is present, making the worker resilient to files written by different tools on different operating systems.

These three incidents — a race condition, a version mismatch, and an encoding bug — are exactly the kinds of problems you encounter when building real infrastructure. They are not embarrassing. They are the job. Being able to describe what went wrong, why it went wrong, and how you fixed it is what demonstrates operational competence in an interview.

---

## How to Tell This Story in an Interview

Start with the problem, not the solution. "Bebeque had a monolith. It was serving live clients. The team decided to migrate to microservices but needed to do it without downtime." That immediately establishes context and stakes.

Then explain your role. "I was brought in as the lead DevOps contractor to design the target platform and manage the migration." This establishes ownership.

Then explain the pattern. "We used the strangler fig approach — new platform alongside the old one, traffic shifted service by service through ALB routing rules." One sentence that shows you understand the strategy.

Then walk through the services. For each one, say what it does, what shape it takes, why it takes that shape, and how it scales. Mention the specific tools — FastAPI, SQS, KEDA, Redis — but always explain why you chose them, not just that you used them.

For the infrastructure decisions, always have a reason. Database outside the cluster — because pods are ephemeral and RDS handles backups. SQS between services — because decoupling means failures in one service do not cascade to others. KEDA for workers — because CPU is the wrong signal when the real metric is queue depth.

Finish with the migration story. Shadow mode to validate before touching traffic. Canary release to limit blast radius. One-line ALB rule change to roll back if something goes wrong. Keep the monolith running as a safety net through the stabilisation period.

And if they ask about problems you encountered, tell the BOM story. An interviewer who hears you describe a debugging process — symptom, hypothesis, investigation, root cause, fix, verification — learns far more about your operational capability than one who hears a list of tools you have used.
