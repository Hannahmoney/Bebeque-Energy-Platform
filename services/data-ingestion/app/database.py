from sqlalchemy import create_engine, Column, Integer, String, Float, DateTime
from sqlalchemy.orm import sessionmaker, DeclarativeBase
from sqlalchemy.sql import func
from app.config import settings

engine = create_engine(
    settings.database_url,
    pool_pre_ping=True,
    pool_size=3,
    max_overflow=5
)

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
    source_file = Column(String, nullable=True)  # which S3 key this came from
    created_at = Column(DateTime, server_default=func.now())