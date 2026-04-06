from pydantic import BaseModel
from datetime import datetime
from typing import List

class EnergyReadingResponse(BaseModel):
    id: int
    client_id: str
    meter_id: str
    reading_kwh: float
    recorded_at: datetime

    # This tells Pydantic to read values from SQLAlchemy
    # model attributes, not just plain dictionaries
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