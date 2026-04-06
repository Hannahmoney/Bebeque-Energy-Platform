import boto3
import json
import logging
import time
import signal
import threading
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

        logger.info(
            f"Processing notification — "
            f"type: {event.event_type} "
            f"client: {event.client_id}"
        )

        # Send email notification
        email_sent = send_email(
            recipient=event.recipient_email,
            subject=event.subject,
            body=event.body
        )

        # Send webhook if the client has one configured
        if event.webhook_url:
            send_webhook(
                url=event.webhook_url,
                payload={
                    "event_type": event.event_type,
                    "client_id": event.client_id,
                    "message": event.body
                }
            )

        return email_sent

    except json.JSONDecodeError as e:
        logger.error(f"Invalid JSON in message: {e} — discarding")
        return True

    except Exception as e:
        logger.error(f"Failed to process notification: {e} — will retry")
        return False


def run_consumer():
    """
    This function runs in a background thread.
    The FastAPI app runs in the main thread.
    Both run simultaneously in the same process.
    """
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