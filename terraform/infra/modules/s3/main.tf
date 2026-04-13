# --- S3 Bucket ---
# One bucket for two purposes: CSV uploads from B2B clients and
# PDF reports served via CloudFront.
# Versioning is enabled so we have a history of every uploaded file.
# This matters for data lineage — we can always retrieve the exact
# CSV that produced a set of meter_readings rows.

resource "aws_s3_bucket" "main" {
  bucket = "${var.project}-uploads-${var.environment}"

  tags = {
    Name        = "${var.project}-uploads-${var.environment}"
    Project     = var.project
    Environment = var.environment
  }
}

# --- Block all public access ---
# No object in this bucket should ever be publicly accessible directly.
# PDF reports are served via CloudFront, not via S3 public URLs.
# CSV uploads are internal only.

resource "aws_s3_bucket_public_access_block" "main" {
  bucket = aws_s3_bucket.main.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- Versioning ---
# Keeps every version of every object.
# Required for data lineage on CSV uploads.
# Also means accidental overwrites are recoverable.

resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id

  versioning_configuration {
    status = "Enabled"
  }
}

# --- Encryption at rest ---
# AES256 server-side encryption on every object.
# No extra cost, no reason not to.

resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# --- Lifecycle rules ---
# CSV uploads: move to cheaper storage after 90 days, delete after 365.
# PDF reports: move to cheaper storage after 90 days, keep indefinitely.
# This keeps costs down as the bucket grows without manual cleanup.

resource "aws_s3_bucket_lifecycle_configuration" "main" {
  bucket = aws_s3_bucket.main.id

  rule {
    id     = "csv-uploads-lifecycle"
    status = "Enabled"

    filter {
      prefix = "uploads/"
    }

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 365
    }
  }

  rule {
    id     = "pdf-reports-lifecycle"
    status = "Enabled"

    filter {
      prefix = "reports/"
    }

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
  }
}