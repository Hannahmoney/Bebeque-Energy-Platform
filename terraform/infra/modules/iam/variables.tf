variable "project" { type = string }
variable "environment" { type = string }
variable "aws_region" { type = string }
variable "account_id" { type = string }
variable "oidc_provider" { type = string }
variable "oidc_provider_arn" { type = string }
variable "sqs_queue_arns" { type = map(string) }
variable "s3_bucket_arn" { type = string }
