from sqlalchemy import create_engine, Column, Integer, String, Float, DateTime
from sqlalchemy.orm import sessionmaker, DeclarativeBase
from sqlalchemy.sql import func
from app.config import settings

engine = create_engine(
    settings.database_url,
    pool_pre_ping=True,
    pool_size=3,      # workers need fewer connections than APIs
    max_overflow=5
)

SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)

class Base(DeclarativeBase):
    pass

class BiomassReading(Base):
    __tablename__ = "biomass_readings"

    id = Column(Integer, primary_key=True, index=True)
    sensor_id = Column(String, nullable=False, index=True)
    plant_id = Column(String, nullable=False, index=True)
    temperature_celsius = Column(Float, nullable=True)
    moisture_percent = Column(Float, nullable=True)
    output_kwh = Column(Float, nullable=True)
    # sensor_timestamp is when the IoT sensor recorded the reading
    # created_at is when we wrote it to the database
    # these can differ if the queue backed up
    sensor_timestamp = Column(DateTime, nullable=False)
    created_at = Column(DateTime, server_default=func.now())

def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()