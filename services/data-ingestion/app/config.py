from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    database_url: str
    sqs_queue_url: str
    s3_bucket_name: str
    aws_region: str = "eu-west-1"
    environment: str = "development"
    batch_size: int = 5
    visibility_timeout: int = 120  # CSVs take longer to process

    class Config:
        env_file = ".env"

settings = Settings()