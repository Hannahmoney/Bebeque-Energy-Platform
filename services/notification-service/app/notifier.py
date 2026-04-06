import logging

logger = logging.getLogger(__name__)

def send_email(recipient: str, subject: str, body: str) -> bool:
    """
    In production this would call AWS SES or SendGrid.
    We mock it here — log the notification and return True.
    Teams call this "stubbing" or "mocking" an external dependency.
    """
    logger.info(
        f"[MOCK EMAIL] "
        f"to: {recipient} | "
        f"subject: {subject} | "
        f"body: {body[:100]}..."
    )
    return True


def send_webhook(url: str, payload: dict) -> bool:
    """
    In production this would make an HTTP POST to the client's
    webhook URL. Mocked here.
    """
    logger.info(
        f"[MOCK WEBHOOK] "
        f"url: {url} | "
        f"payload: {payload}"
    )
    return True