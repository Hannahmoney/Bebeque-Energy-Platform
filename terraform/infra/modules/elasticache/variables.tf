variable "project" { type = string }
variable "environment" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "eks_node_sg_id" { type = string }

variable "redis_auth_token" {
  description = "AUTH token for Redis — required when transit encryption is enabled"
  type        = string
  sensitive   = true
}