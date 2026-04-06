from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    database_url: str
    sqs_queue_url: str
    aws_region: str = "eu-west-1"
    environment: str = "development"
    
    # How many messages to fetch per poll cycle
    # Maximum SQS allows is 10
    batch_size: int = 10
    
    # How long SQS hides a message from other consumers
    # while this worker is processing it (seconds)
    # Teams call this the "visibility timeout"
    visibility_timeout: int = 30

    class Config:
        env_file = ".env"

settings = Settings()
