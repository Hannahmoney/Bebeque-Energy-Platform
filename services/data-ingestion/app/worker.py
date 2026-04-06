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
    logger.info("Shutdown signal received — finishing current message then stopping")
    shutdown_requested = True

signal.signal(signal.SIGTERM, handle_shutdown)
signal.signal(signal.SIGINT, handle_shutdown)


def parse_and_validate_row(row: dict, s3_key: str) -> MeterReading | None:
    """
    Validates a single CSV row and returns a MeterReading object.
    Returns None if the row is invalid — we skip bad rows but
    continue processing the rest of the file.
    """
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
        logger.warning(f"Skipping row — invalid data: {e} — row: {row}")
        return None


def process_csv(s3_key: str, s3_client, db) -> tuple[int, int]:
    """
    Downloads a CSV from S3, parses it, and bulk-inserts
    meter readings into PostgreSQL.
    Returns (rows_written, rows_skipped).
    """
    logger.info(f"Downloading CSV from S3: {s3_key}")

    # Download the file from S3 into memory
    # For very large files you would stream this —
    # for B2B meter data CSV files are typically small
    response = s3_client.get_object(
        Bucket=settings.s3_bucket_name,
        Key=s3_key
    )
    csv_content = response["Body"].read().decode("utf-8")

    # Parse CSV — csv.DictReader maps each row to a dict
    # using the header row as keys
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

    # Bulk insert — add all readings in one database transaction
    # much faster than inserting one row at a time
    # Teams call this "bulk insert" or "batch insert"
    db.add_all(readings)
    db.commit()

    logger.info(
        f"Processed {s3_key} — "
        f"written: {len(readings)}, skipped: {rows_skipped}"
    )
    return len(readings), rows_skipped


def process_message(message: dict, s3_client, db) -> bool:
    """
    An S3 event notification looks like this:
    {
      "Records": [{
        "s3": {
          "bucket": { "name": "bebeque-uploads" },
          "object": { "key": "uploads/client-123/march-2024.csv" }
        }
      }]
    }
    """
    try:
        body = json.loads(message["Body"])

        # S3 event notifications wrap the actual event in Records
        records = body.get("Records", [])
        if not records:
            logger.warning("Message has no S3 Records — discarding")
            return True  # poison pill

        for record in records:
            s3_key = record["s3"]["object"]["key"]
            process_csv(s3_key, s3_client, db)

        return True

    except KeyError as e:
        logger.error(f"Unexpected message structure — missing key: {e} — discarding")
        return True  # poison pill

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