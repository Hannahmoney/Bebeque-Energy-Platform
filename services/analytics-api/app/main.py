from fastapi import FastAPI, Depends, HTTPException, Query
from sqlalchemy.orm import Session
from sqlalchemy import func
from sqlalchemy import text
from datetime import datetime, timedelta
from typing import Optional
import json
import logging

from app.database import get_db
from app.cache import get_cache
from app.models import EnergyReading
from app.schemas import EnergyReadingResponse, EnergyUsageSummary, HealthResponse
from app.config import settings

# Configure structured logging — teams call this JSON logging
# because log lines are JSON objects, easy to query in CloudWatch
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Create the FastAPI application
app = FastAPI(
    title="Bebeque Analytics API",
    version="1.0.0"
)


# ── Health check endpoint ─────────────────────────────────────
# Every service must have one. Kubernetes calls this to decide
# if the pod is healthy. ALB calls it to decide if the target
# is healthy. Teams call it the "health endpoint" or "ping."
@app.get("/health", response_model=HealthResponse)
def health_check(
    db: Session = Depends(get_db),
    cache = Depends(get_cache)
):
    # Check database connectivity
    db_status = "ok"
    try:
        db.execute(text("SELECT 1"))
    except Exception as e:
        logger.error(f"Database health check failed: {e}")
        db_status = "error"

    # Check Redis connectivity
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


# ── Energy usage summary endpoint ────────────────────────────
# The main business endpoint. Returns aggregated energy usage
# for a specific client over a time period.
# Path: GET /api/v1/analytics/clients/{client_id}/usage
@app.get(
    "/api/v1/analytics/clients/{client_id}/usage",
    response_model=EnergyUsageSummary
)
def get_client_usage(
    client_id: str,
    days: int = Query(default=30, ge=1, le=365),
    db: Session = Depends(get_db),
    cache = Depends(get_cache)
):
    # Build a cache key specific to this client and time window
    # Teams call this the "cache key strategy"
    cache_key = f"usage:{client_id}:{days}"

    # Try the cache first — teams call this "cache-aside pattern"
    # or "look-aside caching"
    cached = cache.get(cache_key)
    if cached:
        logger.info(f"Cache hit for {cache_key}")
        return EnergyUsageSummary(**json.loads(cached))

    logger.info(f"Cache miss for {cache_key} — querying database")

    # Cache miss — query PostgreSQL
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

    # If no readings exist for this client, return 404
    # Teams call this a "not found" or "404 guard"
    if not result or result.reading_count == 0:
        raise HTTPException(
            status_code=404,
            detail=f"No energy readings found for client {client_id}"
        )

    summary = EnergyUsageSummary(
        client_id=client_id,
        total_kwh=round(result.total_kwh, 2),
        reading_count=result.reading_count,
        period_start=period_start,
        period_end=period_end
    )

    # Store in cache — expire after 5 minutes (300 seconds)
    # Teams call this "TTL" — time to live
    cache.setex(
        cache_key,
        300,
        json.dumps(summary.model_dump(), default=str)
    )

    return summary


# ── Individual readings endpoint ──────────────────────────────
# Returns the raw readings for a client — useful for the
# detailed chart view in the B2B dashboard
@app.get(
    "/api/v1/analytics/clients/{client_id}/readings",
    response_model=list[EnergyReadingResponse]
)
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
    ).order_by(
        EnergyReading.recorded_at.desc()
    ).limit(limit).all()

    if not readings:
        raise HTTPException(
            status_code=404,
            detail=f"No readings found for client {client_id}"
        )

    return readings