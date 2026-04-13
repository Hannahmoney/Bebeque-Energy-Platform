output "repository_urls" {
  description = "Map of service name to ECR repository URL — used by CI/CD to push images"
  value       = { for k, r in aws_ecr_repository.services : k => r.repository_url }
}

output "repository_arns" {
  description = "Map of service name to ECR repository ARN — used by IAM to scope pull permissions"
  value       = { for k, r in aws_ecr_repository.services : k => r.arn }
}