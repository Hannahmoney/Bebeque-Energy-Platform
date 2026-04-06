from fastapi import FastAPI
from contextlib import asynccontextmanager
import threading
import logging
from app.schemas import HealthResponse
from app.consumer import run_consumer, shutdown_requested
from app.config import settings

logging.basicConfig(
    level=logging.INFO,
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "message": "%(message)s"}'
)
logger = logging.getLogger(__name__)

# consumer_thread holds a reference to the background thread
# so we can check its health in the health endpoint
consumer_thread = None


# lifespan is FastAPI's way of running code at startup and shutdown
# Teams call this a "lifespan event" or "startup hook"
@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup — runs before the API starts accepting requests
    global consumer_thread
    consumer_thread = threading.Thread(
        target=run_consumer,
        daemon=True,  # thread dies automatically when main process dies
        name="sqs-consumer"
    )
    consumer_thread.start()
    logger.info("SQS consumer thread started")

    yield  # API runs here — handling requests

    # Shutdown — runs when the API is stopping
    logger.info("Shutting down notification service")


app = FastAPI(
    title="Bebeque Notification Service",
    version="1.0.0",
    lifespan=lifespan
)


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