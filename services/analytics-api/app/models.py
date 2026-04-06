from sqlalchemy import Column, Integer, String, Float, DateTime
from sqlalchemy.sql import func
from app.database import Base

class EnergyReading(Base):
    # __tablename__ must match the actual table name in PostgreSQL
    # this is the existing table the monolith also uses
    __tablename__ = "energy_readings"

    id = Column(Integer, primary_key=True, index=True)
    client_id = Column(String, nullable=False, index=True)
    meter_id = Column(String, nullable=False)
    reading_kwh = Column(Float, nullable=False)
    recorded_at = Column(DateTime, nullable=False)
    created_at = Column(DateTime, server_default=func.now())