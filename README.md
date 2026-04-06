# Bebeque Energy Platform — Project Reference

> Steps 3–5 complete. All code that worked, folder structure, and PowerShell-specific notes.

---

## Folder Structure

```
bebeque/
├── docker-compose.yml
├── scripts/
│   ├── init-localstack.sh
│   └── seed-database.sql
└── services/
    ├── analytics-api/
    │   ├── Dockerfile
    │   ├── requirements.txt
    │   └── app/
    │       ├── config.py
    │       ├── database.py
    │       ├── cache.py
    │       ├── models.py
    │       ├── schemas.py
    │       └── main.py
    ├── biomass-ingestion/
    │   ├── Dockerfile
    │   ├── requirements.txt
    │   └── app/
    │       ├── config.py
    │       ├── database.py
    │       └── worker.py
    ├── data-ingestion/
    │   ├── Dockerfile
    │   ├── requirements.txt
    │   └── app/
    │       ├── config.py
    │       ├── database.py
    │       └── worker.py
    └── notification-service/
        ├── Dockerfile
        ├── requirements.txt
        └── app/
            ├── config.py
            ├── schemas.py
            ├── notifier.py
            ├── consumer.py
            └── main.py
```

---

## PowerShell Rules (learned the hard way)

These apply to every step from here forward.

**Never use `Out-File -Encoding utf8`** — it adds a BOM (invisible bytes) that corrupts JSON and CSV files.

**Always use this pattern for writing files:**
```powershell
$content = 'your content here'
[System.IO.File]::WriteAllText("$env:TEMP\filename.json", $content, [System.Text.UTF8Encoding]::new($false))
```

**Always use the full LocalStack queue URL format:**
```
http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/queue-name
```
Not `http://localhost:4566/000000000000/queue-name` — that format does not work with newer LocalStack.

**Line continuation in PowerShell is backtick**, not backslash:
```powershell
aws sqs send-message `
  --region us-east-1
```

**Fix CRLF line endings on shell scripts every time you edit them:**
```powershell
(Get-Content scripts/init-localstack.sh -Raw).Replace("`r`n", "`n") | Set-Content scripts/init-localstack.sh -NoNewline
```

---

## Step 3 — Application Code

### analytics-api

#### `services/analytics-api/requirements.txt`
```txt
fastapi==0.111.0
uvicorn==0.29.0
sqlalchemy==2.0.30
psycopg2-binary==2.9.9
redis==5.0.4
boto3==1.34.0
pydantic==2.7.0
pydantic-settings==2.2.1
alembic==1.13.1
```

#### `services/analytics-api/app/config.py`
```python
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    database_url: str
    redis_url: str
    environment: str = "development"

    class Config:
        env_file = ".env"

settings = Settings()
```

#### `services/analytics-api/app/database.py`
```python
from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, DeclarativeBase
from app.config import settings

engine = create_engine(
    settings.database_url,
    pool_pre_ping=True,
    pool_size=5,
    max_overflow=10
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

class Base(DeclarativeBase):
    pass

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()
```

#### `services/analytics-api/app/cache.py`
```python
import redis
from app.config import settings

redis_client = redis.from_url(
    settings.redis_url,
    decode_responses=True
)

def get_cache():
    return redis_client
```

#### `services/analytics-api/app/models.py`
```python
from sqlalchemy import Column, Integer, String, Float, DateTime
from sqlalchemy.sql import func
from app.database import Base

class EnergyReading(Base):
    __tablename__ = "energy_readings"

    id = Column(Integer, primary_key=True, index=True)
    client_id = Column(String, nullable=False, index=True)
    meter_id = Column(String, nullable=False)
    reading_kwh = Column(Float, nullable=False)
    recorded_at = Column(DateTime, nullable=False)
    created_at = Column(DateTime, server_default=func.now())
```

#### `services/analytics-api/app/schemas.py`
```python
from pydantic import BaseModel
from datetime import datetime

class EnergyReadingResponse(BaseModel):
    id: int
    client_id: str
    meter_id: str
    reading_kwh: float
    recorded_at: datetime

    model_config = {"from_attributes": True}

class EnergyUsageSummary(BaseModel):
    client_id: str
    total_kwh: float
    reading_count: int
    period_start: datetime
    period_end: datetime

class HealthResponse(BaseModel):
    status: str
    database: str
    cache: str
    environment: str
```

#### `services/analytics-api/app/main.py`
```python
from fastapi import FastAPI, Depends, HTTPException, Query
from sqlalchemy.orm import Session
from sqlalchemy import func
from datetime import datetime, timedelta
import json
import logging

from app.database import get_db
from app.cache import get_cache
from app.models import EnergyReading
from app.schemas import EnergyReadingResponse, EnergyUsageSummary, HealthResponse
from app.config import settings

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="Bebeque Analytics API", version="1.0.0")


@app.get("/health", response_model=HealthResponse)
def health_check(db: Session = Depends(get_db), cache=Depends(get_cache)):
    db_status = "ok"
    try:
        db.execute("SELECT 1")
    except Exception as e:
        logger.error(f"Database health check failed: {e}")
        db_status = "error"

    cache_status = "ok"
    try:
        cache.ping()
    except Exception as e:
        logger.error(f"Cache health check failed: {e}")
        cache_status = "error"

    return HealthResponse(
        status="ok" if db_status == "ok" and cache_status == "ok" else "degraded",
        database=db_status,
        cache=cache_status,
        environment=settings.environment
    )


@app.get("/api/v1/analytics/clients/{client_id}/usage", response_model=EnergyUsageSummary)
def get_client_usage(
    client_id: str,
    days: int = Query(default=30, ge=1, le=365),
    db: Session = Depends(get_db),
    cache=Depends(get_cache)
):
    cache_key = f"usage:{client_id}:{days}"

    cached = cache.get(cache_key)
    if cached:
        logger.info(f"Cache hit for {cache_key}")
        return EnergyUsageSummary(**json.loads(cached))

    logger.info(f"Cache miss for {cache_key} — querying database")

    period_start = datetime.utcnow() - timedelta(days=days)
    period_end = datetime.utcnow()

    result = db.query(
        func.sum(EnergyReading.reading_kwh).label("total_kwh"),
        func.count(EnergyReading.id).label("reading_count")
    ).filter(
        EnergyReading.client_id == client_id,
        EnergyReading.recorded_at >= period_start,
        EnergyReading.recorded_at <= period_end
    ).first()

    if not result or result.reading_count == 0:
        raise HTTPException(status_code=404, detail=f"No energy readings found for client {client_id}")

    summary = EnergyUsageSummary(
        client_id=client_id,
        total_kwh=round(result.total_kwh, 2),
        reading_count=result.reading_count,
        period_start=period_start,
        period_end=period_end
    )

    cache.setex(cache_key, 300, json.dumps(summary.model_dump(), default=str))
    return summary


@app.get("/api/v1/analytics/clients/{client_id}/readings", response_model=list[EnergyReadingResponse])
def get_client_readings(
    client_id: str,
    days: int = Query(default=7, ge=1, le=90),
    limit: int = Query(default=100, ge=1, le=1000),
    db: Session = Depends(get_db)
):
    period_start = datetime.utcnow() - timedelta(days=days)

    readings = db.query(EnergyReading).filter(
        EnergyReading.client_id == client_id,
        EnergyReading.recorded_at >= period_start
    ).order_by(EnergyReading.recorded_at.desc()).limit(limit).all()

    if not readings:
        raise HTTPException(status_code=404, detail=f"No readings found for client {client_id}")

    return readings
```

---

### biomass-ingestion

#### `services/biomass-ingestion/requirements.txt`
```txt
boto3==1.34.0
sqlalchemy==2.0.30
psycopg2-binary==2.9.9
pydantic-settings==2.2.1
```

#### `services/biomass-ingestion/app/config.py`
```python
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    database_url: str
    sqs_queue_url: str
    aws_region: str = "us-east-1"
    environment: str = "development"
    batch_size: int = 10
    visibility_timeout: int = 30

    class Config:
        env_file = ".env"

settings = Settings()
```

#### `services/biomass-ingestion/app/database.py`
```python
from sqlalchemy import create_engine, Column, Integer, String, Float, DateTime
from sqlalchemy.orm import sessionmaker, DeclarativeBase
from sqlalchemy.sql import func
from app.config import settings

engine = create_engine(settings.database_url, pool_pre_ping=True, pool_size=3, max_overflow=5)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

class Base(DeclarativeBase):
    pass

class BiomassReading(Base):
    __tablename__ = "biomass_readings"

    id = Column(Integer, primary_key=True, index=True)
    sensor_id = Column(String, nullable=False, index=True)
    plant_id = Column(String, nullable=False, index=True)
    temperature_celsius = Column(Float, nullable=True)
    moisture_percent = Column(Float, nullable=True)
    output_kwh = Column(Float, nullable=True)
    sensor_timestamp = Column(DateTime, nullable=False)
    created_at = Column(DateTime, server_default=func.now())
```

#### `services/biomass-ingestion/app/worker.py`
```python
import boto3
import json
import logging
import time
import signal
from datetime import datetime
from app.config import settings
from app.database import SessionLocal, BiomassReading

logging.basicConfig(
    level=logging.INFO,
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "message": "%(message)s"}'
)
logger = logging.getLogger(__name__)

shutdown_requested = False

def handle_shutdown(signum, frame):
    global shutdown_requested
    logger.info("Shutdown signal received — finishing current batch then stopping")
    shutdown_requested = True

signal.signal(signal.SIGTERM, handle_shutdown)
signal.signal(signal.SIGINT, handle_shutdown)


def process_message(message: dict, db) -> bool:
    try:
        body = json.loads(message["Body"])

        required = ["sensor_id", "plant_id", "sensor_timestamp"]
        missing = [f for f in required if f not in body]
        if missing:
            logger.error(f"Message missing required fields: {missing} — discarding")
            return True

        reading = BiomassReading(
            sensor_id=body["sensor_id"],
            plant_id=body["plant_id"],
            temperature_celsius=body.get("temperature_celsius"),
            moisture_percent=body.get("moisture_percent"),
            output_kwh=body.get("output_kwh"),
            sensor_timestamp=datetime.fromisoformat(body["sensor_timestamp"])
        )

        db.add(reading)
        db.commit()

        logger.info(f"Processed reading — sensor: {body['sensor_id']} plant: {body['plant_id']} output: {body.get('output_kwh')} kWh")
        return True

    except json.JSONDecodeError as e:
        logger.error(f"Invalid JSON in message body: {e} — discarding")
        return True

    except Exception as e:
        logger.error(f"Failed to process message: {e} — will retry")
        db.rollback()
        return False


def poll_queue(sqs_client):
    logger.info(f"Starting biomass-ingestion worker — queue: {settings.sqs_queue_url}")

    while not shutdown_requested:
        try:
            response = sqs_client.receive_message(
                QueueUrl=settings.sqs_queue_url,
                MaxNumberOfMessages=settings.batch_size,
                WaitTimeSeconds=20,
                VisibilityTimeout=settings.visibility_timeout
            )

            messages = response.get("Messages", [])

            if not messages:
                logger.info("Queue empty — waiting")
                continue

            logger.info(f"Received {len(messages)} messages")

            for message in messages:
                db = SessionLocal()
                try:
                    success = process_message(message, db)
                    if success:
                        sqs_client.delete_message(
                            QueueUrl=settings.sqs_queue_url,
                            ReceiptHandle=message["ReceiptHandle"]
                        )
                finally:
                    db.close()

        except Exception as e:
            logger.error(f"Polling error: {e} — retrying in 5 seconds")
            time.sleep(5)

    logger.info("Worker shutdown complete")


def main():
    sqs_client = boto3.client("sqs", region_name=settings.aws_region)
    poll_queue(sqs_client)


if __name__ == "__main__":
    main()
```

---

### data-ingestion

#### `services/data-ingestion/requirements.txt`
```txt
boto3==1.34.0
sqlalchemy==2.0.30
psycopg2-binary==2.9.9
pydantic-settings==2.2.1
```

#### `services/data-ingestion/app/config.py`
```python
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    database_url: str
    sqs_queue_url: str
    s3_bucket_name: str
    aws_region: str = "us-east-1"
    environment: str = "development"
    batch_size: int = 5
    visibility_timeout: int = 120

    class Config:
        env_file = ".env"

settings = Settings()
```

#### `services/data-ingestion/app/database.py`
```python
from sqlalchemy import create_engine, Column, Integer, String, Float, DateTime
from sqlalchemy.orm import sessionmaker, DeclarativeBase
from sqlalchemy.sql import func
from app.config import settings

engine = create_engine(settings.database_url, pool_pre_ping=True, pool_size=3, max_overflow=5)
SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

class Base(DeclarativeBase):
    pass

class MeterReading(Base):
    __tablename__ = "meter_readings"

    id = Column(Integer, primary_key=True, index=True)
    client_id = Column(String, nullable=False, index=True)
    meter_id = Column(String, nullable=False, index=True)
    reading_kwh = Column(Float, nullable=False)
    recorded_at = Column(DateTime, nullable=False)
    source_file = Column(String, nullable=True)
    created_at = Column(DateTime, server_default=func.now())
```

#### `services/data-ingestion/app/worker.py`
```python
import boto3
import json
import csv
import io
import logging
import time
import signal
from datetime import datetime
from app.config import settings
from app.database import SessionLocal, MeterReading

logging.basicConfig(
    level=logging.INFO,
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "message": "%(message)s"}'
)
logger = logging.getLogger(__name__)

shutdown_requested = False

def handle_shutdown(signum, frame):
    global shutdown_requested
    shutdown_requested = True

signal.signal(signal.SIGTERM, handle_shutdown)
signal.signal(signal.SIGINT, handle_shutdown)


def parse_and_validate_row(row: dict, s3_key: str):
    required_columns = ["client_id", "meter_id", "reading_kwh", "recorded_at"]
    missing = [c for c in required_columns if not row.get(c)]
    if missing:
        logger.warning(f"Skipping row — missing columns: {missing}")
        return None

    try:
        return MeterReading(
            client_id=row["client_id"].strip(),
            meter_id=row["meter_id"].strip(),
            reading_kwh=float(row["reading_kwh"]),
            recorded_at=datetime.fromisoformat(row["recorded_at"].strip()),
            source_file=s3_key
        )
    except (ValueError, TypeError) as e:
        logger.warning(f"Skipping row — invalid data: {e}")
        return None


def process_csv(s3_key: str, s3_client, db):
    logger.info(f"Downloading CSV from S3: {s3_key}")

    response = s3_client.get_object(Bucket=settings.s3_bucket_name, Key=s3_key)
    csv_content = response["Body"].read().decode("utf-8-sig")  # utf-8-sig strips BOM if present

    reader = csv.DictReader(io.StringIO(csv_content))
    readings = []
    rows_skipped = 0

    for row in reader:
        reading = parse_and_validate_row(row, s3_key)
        if reading:
            readings.append(reading)
        else:
            rows_skipped += 1

    if not readings:
        logger.warning(f"No valid rows found in {s3_key}")
        return 0, rows_skipped

    db.add_all(readings)
    db.commit()

    logger.info(f"Processed {s3_key} — written: {len(readings)}, skipped: {rows_skipped}")
    return len(readings), rows_skipped


def process_message(message: dict, s3_client, db) -> bool:
    try:
        body = json.loads(message["Body"])
        records = body.get("Records", [])

        if not records:
            logger.warning("Message has no S3 Records — discarding")
            return True

        for record in records:
            s3_key = record["s3"]["object"]["key"]
            process_csv(s3_key, s3_client, db)

        return True

    except KeyError as e:
        logger.error(f"Unexpected message structure — missing key: {e} — discarding")
        return True

    except Exception as e:
        logger.error(f"Failed to process message: {e} — will retry")
        db.rollback()
        return False


def poll_queue(sqs_client, s3_client):
    logger.info(f"Starting data-ingestion worker — queue: {settings.sqs_queue_url}")

    while not shutdown_requested:
        try:
            response = sqs_client.receive_message(
                QueueUrl=settings.sqs_queue_url,
                MaxNumberOfMessages=settings.batch_size,
                WaitTimeSeconds=20,
                VisibilityTimeout=settings.visibility_timeout
            )

            messages = response.get("Messages", [])

            if not messages:
                continue

            logger.info(f"Received {len(messages)} messages")

            for message in messages:
                db = SessionLocal()
                try:
                    success = process_message(message, s3_client, db)
                    if success:
                        sqs_client.delete_message(
                            QueueUrl=settings.sqs_queue_url,
                            ReceiptHandle=message["ReceiptHandle"]
                        )
                finally:
                    db.close()

        except Exception as e:
            logger.error(f"Polling error: {e} — retrying in 5 seconds")
            time.sleep(5)

    logger.info("Worker shutdown complete")


def main():
    sqs_client = boto3.client("sqs", region_name=settings.aws_region)
    s3_client = boto3.client("s3", region_name=settings.aws_region)
    poll_queue(sqs_client, s3_client)


if __name__ == "__main__":
    main()
```

> Note: `decode("utf-8-sig")` is used instead of `decode("utf-8")`. The `-sig` variant automatically strips a BOM if one is present in the CSV file. This is the defensive fix for the PowerShell BOM problem on uploaded CSVs.

---

### notification-service

#### `services/notification-service/requirements.txt`
```txt
fastapi==0.111.0
uvicorn==0.29.0
boto3==1.34.0
pydantic==2.7.0
pydantic-settings==2.2.1
```

#### `services/notification-service/app/config.py`
```python
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    sqs_queue_url: str
    aws_region: str = "us-east-1"
    environment: str = "development"
    batch_size: int = 10
    visibility_timeout: int = 30

    class Config:
        env_file = ".env"

settings = Settings()
```

#### `services/notification-service/app/schemas.py`
```python
from pydantic import BaseModel
from typing import Optional

class NotificationEvent(BaseModel):
    event_type: str
    client_id: str
    recipient_email: str
    subject: str
    body: str
    webhook_url: Optional[str] = None

class HealthResponse(BaseModel):
    status: str
    consumer: str
    environment: str
```

#### `services/notification-service/app/notifier.py`
```python
import logging

logger = logging.getLogger(__name__)

def send_email(recipient: str, subject: str, body: str) -> bool:
    logger.info(f"[MOCK EMAIL] to: {recipient} | subject: {subject} | body: {body[:100]}...")
    return True

def send_webhook(url: str, payload: dict) -> bool:
    logger.info(f"[MOCK WEBHOOK] url: {url} | payload: {payload}")
    return True
```

#### `services/notification-service/app/consumer.py`
```python
import boto3
import json
import logging
import time
import signal
from app.config import settings
from app.schemas import NotificationEvent
from app.notifier import send_email, send_webhook

logger = logging.getLogger(__name__)

shutdown_requested = False

def handle_shutdown(signum, frame):
    global shutdown_requested
    shutdown_requested = True
    logger.info("Shutdown signal received")

signal.signal(signal.SIGTERM, handle_shutdown)
signal.signal(signal.SIGINT, handle_shutdown)


def process_message(message: dict) -> bool:
    try:
        body = json.loads(message["Body"])
        event = NotificationEvent(**body)

        logger.info(f"Processing notification — type: {event.event_type} client: {event.client_id}")

        send_email(recipient=event.recipient_email, subject=event.subject, body=event.body)

        if event.webhook_url:
            send_webhook(url=event.webhook_url, payload={
                "event_type": event.event_type,
                "client_id": event.client_id,
                "message": event.body
            })

        return True

    except json.JSONDecodeError as e:
        logger.error(f"Invalid JSON in message: {e} — discarding")
        return True

    except Exception as e:
        logger.error(f"Failed to process notification: {e} — will retry")
        return False


def run_consumer():
    sqs_client = boto3.client("sqs", region_name=settings.aws_region)
    logger.info(f"Notification consumer started — queue: {settings.sqs_queue_url}")

    while not shutdown_requested:
        try:
            response = sqs_client.receive_message(
                QueueUrl=settings.sqs_queue_url,
                MaxNumberOfMessages=settings.batch_size,
                WaitTimeSeconds=20,
                VisibilityTimeout=settings.visibility_timeout
            )

            messages = response.get("Messages", [])

            for message in messages:
                success = process_message(message)
                if success:
                    sqs_client.delete_message(
                        QueueUrl=settings.sqs_queue_url,
                        ReceiptHandle=message["ReceiptHandle"]
                    )

        except Exception as e:
            logger.error(f"Consumer error: {e} — retrying in 5 seconds")
            time.sleep(5)
```

#### `services/notification-service/app/main.py`
```python
from fastapi import FastAPI
from contextlib import asynccontextmanager
import threading
import logging
from app.schemas import HealthResponse
from app.consumer import run_consumer
from app.config import settings

logging.basicConfig(
    level=logging.INFO,
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "message": "%(message)s"}'
)
logger = logging.getLogger(__name__)

consumer_thread = None

@asynccontextmanager
async def lifespan(app: FastAPI):
    global consumer_thread
    consumer_thread = threading.Thread(target=run_consumer, daemon=True, name="sqs-consumer")
    consumer_thread.start()
    logger.info("SQS consumer thread started")
    yield
    logger.info("Shutting down notification service")


app = FastAPI(title="Bebeque Notification Service", version="1.0.0", lifespan=lifespan)


@app.get("/health", response_model=HealthResponse)
def health_check():
    consumer_status = "ok"
    if consumer_thread is None or not consumer_thread.is_alive():
        consumer_status = "error"
        logger.error("SQS consumer thread is not running")

    return HealthResponse(
        status="ok" if consumer_status == "ok" else "degraded",
        consumer=consumer_status,
        environment=settings.environment
    )
```

---

## Step 4 — Dockerfiles

All four Dockerfiles follow the same pattern: two-stage build, non-root user, requirements before code.

### `services/analytics-api/Dockerfile`
```dockerfile
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim AS runtime
RUN useradd --create-home --shell /bin/bash appuser
WORKDIR /app
COPY --from=builder /install /usr/local
COPY app/ ./app/
USER appuser
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
```

### `services/biomass-ingestion/Dockerfile`
```dockerfile
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim AS runtime
RUN useradd --create-home --shell /bin/bash appuser
WORKDIR /app
COPY --from=builder /install /usr/local
COPY app/ ./app/
USER appuser
CMD ["python", "-m", "app.worker"]
```

### `services/data-ingestion/Dockerfile`
```dockerfile
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim AS runtime
RUN useradd --create-home --shell /bin/bash appuser
WORKDIR /app
COPY --from=builder /install /usr/local
COPY app/ ./app/
USER appuser
CMD ["python", "-m", "app.worker"]
```

### `services/notification-service/Dockerfile`
```dockerfile
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim AS runtime
RUN useradd --create-home --shell /bin/bash appuser
WORKDIR /app
COPY --from=builder /install /usr/local
COPY app/ ./app/
USER appuser
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
```

### `.dockerignore` (place in each service folder)
```
__pycache__/
*.pyc
*.pyo
.env
.env.*
.git
.gitignore
*.md
tests/
.pytest_cache/
```

---

## Step 5 — Docker Compose and Local Testing

### `scripts/seed-database.sql`
```sql
CREATE TABLE IF NOT EXISTS energy_readings (
    id SERIAL PRIMARY KEY,
    client_id VARCHAR(255) NOT NULL,
    meter_id VARCHAR(255) NOT NULL,
    reading_kwh FLOAT NOT NULL,
    recorded_at TIMESTAMP NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_energy_readings_client_id ON energy_readings(client_id);

CREATE TABLE IF NOT EXISTS biomass_readings (
    id SERIAL PRIMARY KEY,
    sensor_id VARCHAR(255) NOT NULL,
    plant_id VARCHAR(255) NOT NULL,
    temperature_celsius FLOAT,
    moisture_percent FLOAT,
    output_kwh FLOAT,
    sensor_timestamp TIMESTAMP NOT NULL,
    created_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_biomass_readings_sensor_id ON biomass_readings(sensor_id);

CREATE TABLE IF NOT EXISTS meter_readings (
    id SERIAL PRIMARY KEY,
    client_id VARCHAR(255) NOT NULL,
    meter_id VARCHAR(255) NOT NULL,
    reading_kwh FLOAT NOT NULL,
    recorded_at TIMESTAMP NOT NULL,
    source_file VARCHAR(500),
    created_at TIMESTAMP DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS idx_meter_readings_client_id ON meter_readings(client_id);

INSERT INTO energy_readings (client_id, meter_id, reading_kwh, recorded_at) VALUES
    ('client-001', 'meter-A', 142.3, NOW() - INTERVAL '1 day'),
    ('client-001', 'meter-A', 138.7, NOW() - INTERVAL '2 days'),
    ('client-001', 'meter-A', 155.1, NOW() - INTERVAL '3 days'),
    ('client-001', 'meter-B', 89.4,  NOW() - INTERVAL '1 day'),
    ('client-001', 'meter-B', 92.1,  NOW() - INTERVAL '2 days'),
    ('client-002', 'meter-C', 201.8, NOW() - INTERVAL '1 day'),
    ('client-002', 'meter-C', 198.3, NOW() - INTERVAL '2 days');
```

### `scripts/init-localstack.sh`
> Always fix line endings after saving: `(Get-Content scripts/init-localstack.sh -Raw).Replace("`r`n", "`n") | Set-Content scripts/init-localstack.sh -NoNewline`

```bash
#!/bin/bash
echo "Initialising LocalStack resources..."

awslocal sqs create-queue --queue-name biomass-queue --region us-east-1
awslocal sqs create-queue --queue-name data-ingestion-queue --region us-east-1
awslocal sqs create-queue --queue-name notifications-queue --region us-east-1
awslocal s3 mb s3://bebeque-uploads --region us-east-1

echo "Verifying resources:"
awslocal sqs list-queues --region us-east-1
echo "Init complete."
```

### `docker-compose.yml`
```yaml
services:

  postgres:
    image: postgres:16-alpine
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: postgres
      POSTGRES_DB: bebeque
    ports:
      - "5432:5432"
    volumes:
      - ./scripts/seed-database.sql:/docker-entrypoint-initdb.d/seed.sql
      - postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U postgres"]
      interval: 5s
      timeout: 5s
      retries: 5

  redis:
    image: redis:7-alpine
    ports:
      - "6379:6379"
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 5s
      timeout: 5s
      retries: 5

  localstack:
    image: localstack/localstack:3.4
    ports:
      - "4566:4566"
    environment:
      SERVICES: sqs,s3
      AWS_DEFAULT_REGION: us-east-1
      PERSISTENCE: 1
    volumes:
      - ./scripts/init-localstack.sh:/etc/localstack/init/ready.d/init.sh
      - localstack_data:/var/lib/localstack
    healthcheck:
      test: ["CMD-SHELL", "awslocal sqs get-queue-url --queue-name biomass-queue --region us-east-1"]
      interval: 10s
      timeout: 10s
      retries: 15
      start_period: 20s

  analytics-api:
    build:
      context: ./services/analytics-api
      dockerfile: Dockerfile
    ports:
      - "8000:8000"
    environment:
      DATABASE_URL: postgresql://postgres:postgres@postgres:5432/bebeque
      REDIS_URL: redis://redis:6379
      ENVIRONMENT: development
    depends_on:
      postgres:
        condition: service_healthy
      redis:
        condition: service_healthy
    restart: on-failure
    volumes:
      - ./services/analytics-api/app:/app/app

  biomass-ingestion:
    build:
      context: ./services/biomass-ingestion
      dockerfile: Dockerfile
    environment:
      DATABASE_URL: postgresql://postgres:postgres@postgres:5432/bebeque
      SQS_QUEUE_URL: http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/biomass-queue
      AWS_DEFAULT_REGION: us-east-1
      AWS_ACCESS_KEY_ID: test
      AWS_SECRET_ACCESS_KEY: test
      AWS_ENDPOINT_URL: http://localstack:4566
      ENVIRONMENT: development
    depends_on:
      postgres:
        condition: service_healthy
      localstack:
        condition: service_healthy
    restart: on-failure
    volumes:
      - ./services/biomass-ingestion/app:/app/app

  data-ingestion:
    build:
      context: ./services/data-ingestion
      dockerfile: Dockerfile
    environment:
      DATABASE_URL: postgresql://postgres:postgres@postgres:5432/bebeque
      SQS_QUEUE_URL: http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/data-ingestion-queue
      S3_BUCKET_NAME: bebeque-uploads
      AWS_DEFAULT_REGION: us-east-1
      AWS_ACCESS_KEY_ID: test
      AWS_SECRET_ACCESS_KEY: test
      AWS_ENDPOINT_URL: http://localstack:4566
      ENVIRONMENT: development
    depends_on:
      postgres:
        condition: service_healthy
      localstack:
        condition: service_healthy
    restart: on-failure
    volumes:
      - ./services/data-ingestion/app:/app/app

  notification-service:
    build:
      context: ./services/notification-service
      dockerfile: Dockerfile
    ports:
      - "8001:8000"
    environment:
      SQS_QUEUE_URL: http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/notifications-queue
      AWS_DEFAULT_REGION: us-east-1
      AWS_ACCESS_KEY_ID: test
      AWS_SECRET_ACCESS_KEY: test
      AWS_ENDPOINT_URL: http://localstack:4566
      ENVIRONMENT: development
    depends_on:
      localstack:
        condition: service_healthy
    restart: on-failure
    volumes:
      - ./services/notification-service/app:/app/app

volumes:
  postgres_data:
  localstack_data:
```

---

## Test Commands (PowerShell, working versions)

### Start the stack
```powershell
docker compose up --build -d
docker compose ps
```

### Test 1 — health check
```powershell
curl http://localhost:8000/health
```

### Test 2 — analytics usage endpoint
```powershell
curl "http://localhost:8000/api/v1/analytics/clients/client-001/usage?days=30"
```

Call it twice — second call should show cache hit in logs:
```powershell
docker compose logs analytics-api | Select-String "cache"
```

### Test 3 — biomass-ingestion worker
```powershell
$biomass = '{"sensor_id":"sensor-001","plant_id":"plant-new-york","temperature_celsius":82.4,"moisture_percent":23.1,"output_kwh":145.7,"sensor_timestamp":"2024-04-06T10:00:00"}'
[System.IO.File]::WriteAllText("$env:TEMP\biomass-message.json", $biomass, [System.Text.UTF8Encoding]::new($false))

aws sqs send-message `
  --endpoint-url http://localhost:4566 `
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/biomass-queue `
  --message-body file://$env:TEMP/biomass-message.json `
  --region us-east-1

docker compose logs -f biomass-ingestion
```

Verify in database:
```powershell
$postgresContainer = docker compose ps -q postgres
docker exec -it $postgresContainer psql -U postgres -d bebeque -c "SELECT * FROM biomass_readings ORDER BY created_at DESC LIMIT 5;"
```

### Test 4 — data-ingestion worker with CSV
```powershell
# Create CSV without BOM
$csv = "client_id,meter_id,reading_kwh,recorded_at`nclient-003,meter-X,234.5,2024-04-01T09:00:00`nclient-003,meter-X,241.2,2024-04-02T09:00:00`nclient-003,meter-X,228.9,2024-04-03T09:00:00`nclient-004,meter-Y,178.3,2024-04-01T09:00:00`nclient-004,meter-Y,182.1,2024-04-02T09:00:00`n"
[System.IO.File]::WriteAllText("$env:TEMP\test-readings.csv", $csv, [System.Text.UTF8Encoding]::new($false))

# Upload to LocalStack S3
aws s3 cp "$env:TEMP\test-readings.csv" `
  s3://bebeque-uploads/uploads/client-003/april-2024.csv `
  --endpoint-url http://localhost:4566 `
  --region us-east-1

# Send SQS event
$s3event = '{"Records":[{"s3":{"bucket":{"name":"bebeque-uploads"},"object":{"key":"uploads/client-003/april-2024.csv"}}}]}'
[System.IO.File]::WriteAllText("$env:TEMP\s3-event.json", $s3event, [System.Text.UTF8Encoding]::new($false))

aws sqs send-message `
  --endpoint-url http://localhost:4566 `
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/data-ingestion-queue `
  --message-body file://$env:TEMP/s3-event.json `
  --region us-east-1

docker compose logs -f data-ingestion
```

Verify in database:
```powershell
docker exec -it $postgresContainer psql -U postgres -d bebeque -c "SELECT client_id, meter_id, reading_kwh, source_file FROM meter_readings LIMIT 10;"
```

Verify via API:
```powershell
curl "http://localhost:8000/api/v1/analytics/clients/client-003/usage?days=30"
```

### Test 5 — notification-service
```powershell
curl http://localhost:8001/health

$notification = '{"event_type":"usage_threshold_exceeded","client_id":"client-001","recipient_email":"admin@client001.com","subject":"Energy usage alert","body":"Your energy usage has exceeded your monthly threshold.","webhook_url":"https://client001.com/webhooks/bebeque"}'
[System.IO.File]::WriteAllText("$env:TEMP\notification.json", $notification, [System.Text.UTF8Encoding]::new($false))

aws sqs send-message `
  --endpoint-url http://localhost:4566 `
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/notifications-queue `
  --message-body file://$env:TEMP/notification.json `
  --region us-east-1

docker compose logs -f notification-service
```

### Test 6 — poison pill
```powershell
aws sqs send-message `
  --endpoint-url http://localhost:4566 `
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/biomass-queue `
  --message-body "this is not valid json" `
  --region us-east-1

docker compose logs -f biomass-ingestion
```

---

## Useful Stack Management Commands

```powershell
# Status of all containers
docker compose ps

# Logs for one service
docker compose logs -f analytics-api

# Logs for all services
docker compose logs -f

# Restart one service
docker compose restart analytics-api

# Rebuild and restart one service
docker compose up --build -d analytics-api

# Stop everything, keep data
docker compose stop

# Full teardown including volumes (clean slate)
docker compose down -v

# Memory usage
docker stats --no-stream

# Purge a queue (clear all stuck messages)
aws sqs purge-queue `
  --queue-url http://sqs.us-east-1.localhost.localstack.cloud:4566/000000000000/biomass-queue `
  --endpoint-url http://localhost:4566 `
  --region us-east-1

# List all LocalStack queues
aws sqs list-queues --endpoint-url http://localhost:4566 --region us-east-1

# List LocalStack S3 buckets
aws s3 ls --endpoint-url http://localhost:4566

# Manually create resources if init script did not run
aws sqs create-queue --queue-name biomass-queue --endpoint-url http://localhost:4566 --region us-east-1
aws sqs create-queue --queue-name data-ingestion-queue --endpoint-url http://localhost:4566 --region us-east-1
aws sqs create-queue --queue-name notifications-queue --endpoint-url http://localhost:4566 --region us-east-1
aws s3 mb s3://bebeque-uploads --endpoint-url http://localhost:4566 --region us-east-1
```

---

## Incidents and Fixes (real problems encountered)

| Problem | Cause | Fix |
|---|---|---|
| `NonExistentQueue` on startup | Race condition — worker started before LocalStack init script finished | Tighten LocalStack healthcheck to verify queue existence with `get-queue-url` |
| Queue URL not found | Newer LocalStack uses subdomain URL format | Use `http://sqs.us-east-1.localhost.localstack.cloud:4566/...` not `http://localhost:4566/...` |
| `Expecting value: line 1 column 1` on JSON messages | PowerShell `Out-File -Encoding utf8` adds BOM | Use `[System.IO.File]::WriteAllText` with `UTF8Encoding::new($false)` |
| `Skipping row — missing columns: ['client_id']` on CSV | BOM on CSV corrupts first column header | Same fix — write CSV with `WriteAllText`. Worker also uses `decode("utf-8-sig")` as defence |
| Message stuck redelivering | Worker returns False on failure, SQS keeps redelivering | Use `purge-queue` to clear stuck messages during development |
| `NoSuchBucket` on S3 upload | Init script did not create bucket | Manually run `aws s3 mb` command |