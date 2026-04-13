variable "project" { type = string }
variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "public_subnet_ids" { type = list(string) }
variable "eks_cluster_name" { type = string }

variable "certificate_arn" {
  description = "ACM certificate ARN for the HTTPS listener"
  type        = string
}