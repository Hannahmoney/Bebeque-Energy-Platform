output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "node_security_group_id" {
  description = "Security group ID attached to worker nodes — used by RDS and ElastiCache to allow inbound from nodes"
  value       = aws_security_group.node.id
}

output "oidc_provider" {
  description = "OIDC provider URL without https:// — used to build IRSA trust policies"
  value       = replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN"
  value       = aws_iam_openid_connect_provider.cluster.arn
}

output "cluster_autoscaler_role_arn" {
  description = "IAM role ARN for the Cluster Autoscaler service account"
  value       = aws_iam_role.cluster_autoscaler.arn
}




# output "cluster_name" {
#   description = "EKS cluster name"
#   value       = aws_eks_cluster.main.name
# }

# output "cluster_endpoint" {
#   description = "EKS cluster API endpoint"
#   value       = aws_eks_cluster.main.endpoint
# }

# output "node_security_group_id" {
#   description = "Security group ID attached to the node group"
#   value = aws_eks_node_group.main.resources[0].remote_access_security_group_id

# }

# output "oidc_provider" {
#   description = "OIDC provider URL without https://"
#   value       = replace(aws_iam_openid_connect_provider.cluster.url, "https://", "")
# }

# output "oidc_provider_arn" {
#   description = "OIDC provider ARN"
#   value       = aws_iam_openid_connect_provider.cluster.arn
# }