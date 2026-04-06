import boto3
import json
import logging
import time
import signal
import sys
from datetime import datetime
from sqlalchemy.orm import Session
from app.config import settings
from app.database import SessionLocal, BiomassReading

logging.basicConfig(
    level=logging.INFO,
    format='{"time": "%(asctime)s", "level": "%(levelname)s", "message": "%(message)s"}'
)
logger = logging.getLogger(__name__)

# Graceful shutdown handling
# When Kubernetes stops a pod it sends SIGTERM first
# giving the worker time to finish its current message
# before dying. Teams call this "graceful shutdown."
shutdown_requested = False

def handle_shutdown(signum, frame):
    global shutdown_requested
    logger.info("Shutdown signal received — finishing current batch then stopping")
    shutdown_requested = True

signal.signal(signal.SIGTERM, handle_shutdown)
signal.signal(signal.SIGINT, handle_shutdown)


def process_message(message: dict, db: Session) -> bool:
    """
    Process a single SQS message containing a biomass sensor reading.
    Returns True if successful, False if the message should be retried.
    """
    try:
        # SQS message body is a JSON string — parse it
        body = json.loads(message["Body"])

        # Validate required fields are present
        required = ["sensor_id", "plant_id", "sensor_timestamp"]
        missing = [f for f in required if f not in body]
        if missing:
            logger.error(f"Message missing required fields: {missing} — discarding")
            # Return True here — we don't want to retry a malformed message
            # Teams call permanently bad messages "poison pills"
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

        logger.info(
            f"Processed reading — sensor: {body['sensor_id']} "
            f"plant: {body['plant_id']} "
            f"output: {body.get('output_kwh')} kWh"
        )
        return True

    except json.JSONDecodeError as e:
        logger.error(f"Invalid JSON in message body: {e} — discarding")
        return True  # poison pill — don't retry

    except Exception as e:
        logger.error(f"Failed to process message: {e} — will retry")
        db.rollback()
        return False  # tell the caller to NOT delete this message from SQS


def poll_queue(sqs_client):
    """
    Main polling loop. Continuously asks SQS for messages,
    processes them, and deletes them on success.
    """
    logger.info(f"Starting biomass-ingestion worker — queue: {settings.sqs_queue_url}")

    while not shutdown_requested:
        try:
            # Ask SQS for up to batch_size messages
            # WaitTimeSeconds=20 means SQS holds the connection open
            # for up to 20 seconds if the queue is empty before
            # returning an empty response.
            # Teams call this "long polling" — more efficient than
            # repeatedly hammering SQS with empty responses
            response = sqs_client.receive_message(
                QueueUrl=settings.sqs_queue_url,
                MaxNumberOfMessages=settings.batch_size,
                WaitTimeSeconds=20,
                VisibilityTimeout=settings.visibility_timeout
            )

            messages = response.get("Messages", [])

            if not messages:
                # Queue is empty — long poll returned nothing
                logger.info("Queue empty — waiting")
                continue

            logger.info(f"Received {len(messages)} messages")

            # Process each message with its own database session
            for message in messages:
                db = SessionLocal()
                try:
                    success = process_message(message, db)

                    if success:
                        # Delete from SQS — tells SQS "I handled this,
                        # don't redeliver it." Teams call this
                        # "acknowledging" or "acking" the message.
                        sqs_client.delete_message(
                            QueueUrl=settings.sqs_queue_url,
                            ReceiptHandle=message["ReceiptHandle"]
                        )
                    # If success is False we do NOT delete the message
                    # SQS will redeliver it after the visibility timeout
                finally:
                    db.close()

        except Exception as e:
            logger.error(f"Polling error: {e} — retrying in 5 seconds")
            time.sleep(5)

    logger.info("Worker shutdown complete")


def main():
    sqs_client = boto3.client(
        "sqs",
        region_name=settings.aws_region
    )
    poll_queue(sqs_client)


if __name__ == "__main__":
    main()
    