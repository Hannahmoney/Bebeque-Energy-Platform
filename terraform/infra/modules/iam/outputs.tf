output "service_role_arns" {
  description = "Map of service name to IAM role ARN — annotated onto Kubernetes service accounts"
  value = {
    analytics-api        = aws_iam_role.analytics_api.arn
    biomass-ingestion    = aws_iam_role.biomass_ingestion.arn
    data-ingestion       = aws_iam_role.data_ingestion.arn
    notification-service = aws_iam_role.notification_service.arn
  }
}