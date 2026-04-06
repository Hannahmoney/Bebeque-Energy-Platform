import redis
from app.config import settings

# redis.from_url parses the full connection string
# decode_responses=True means Redis returns Python strings
# instead of raw bytes
redis_client = redis.from_url(
    settings.redis_url,
    decode_responses=True
)

def get_cache():
    return redis_client