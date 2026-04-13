output "bucket_arn" {
  description = "S3 bucket ARN — passed to IAM module to scope permissions"
  value       = aws_s3_bucket.main.arn
}

output "bucket_name" {
  description = "S3 bucket name — used by services to upload and download objects"
  value       = aws_s3_bucket.main.id
}