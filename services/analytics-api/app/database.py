from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker, DeclarativeBase
from app.config import settings

# create_engine opens the connection pool to PostgreSQL
# pool_pre_ping=True means SQLAlchemy checks the connection
# is alive before using it — handles dropped connections
engine = create_engine(
    settings.database_url,
    pool_pre_ping=True,
    pool_size=5,        # keep 5 connections open permanently
    max_overflow=10     # allow up to 10 extra under heavy load
)

# SessionLocal is a factory — calling it gives you one
# database session (one unit of work)
SessionLocal = sessionmaker(
    autocommit=False,
    autoflush=False,
    bind=engine
)

# Base is the parent class all database models inherit from
class Base(DeclarativeBase):
    pass

# get_db is a FastAPI dependency — it opens a session,
# hands it to the endpoint function, then closes it cleanly
# whether the request succeeded or failed
def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()