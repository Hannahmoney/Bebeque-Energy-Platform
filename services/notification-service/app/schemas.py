from pydantic import BaseModel
from typing import Optional

class NotificationEvent(BaseModel):
    event_type: str        # e.g. "usage_threshold_exceeded"
    client_id: str
    recipient_email: str
    subject: str
    body: str
    webhook_url: Optional[str] = None

class HealthResponse(BaseModel):
    status: str
    consumer: str
    environment: str