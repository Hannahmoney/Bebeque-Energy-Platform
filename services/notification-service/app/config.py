from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    sqs_queue_url: str
    aws_region: str = "eu-west-1"
    environment: str = "development"
    batch_size: int = 10
    visibility_timeout: int = 30

    class Config:
        env_file = ".env"

settings = Settings()