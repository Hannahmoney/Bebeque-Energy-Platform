output "alb_dns_name" {
  description = "ALB DNS name — used to reach the platform before a custom domain is configured"
  value       = aws_lb.main.dns_name
}

output "alb_arn" {
  description = "ALB ARN"
  value       = aws_lb.main.arn
}

output "https_listener_arn" {
  description = "HTTPS listener ARN — referenced when adding listener rules outside this module"
  value       = aws_lb_listener.https.arn
}

output "target_group_arns" {
  description = "Map of service name to target group ARN"
  value       = { for k, tg in aws_lb_target_group.services : k => tg.arn }
}

output "alb_zone_id" {
  description = "ALB hosted zone ID — used for Route53 alias records"
  value       = aws_lb.main.zone_id
}