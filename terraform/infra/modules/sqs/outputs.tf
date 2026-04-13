output "queue_arns" {
  description = "Map of queue name to ARN — passed to IAM module to scope permissions"
  value       = { for k, q in aws_sqs_queue.main : k => q.arn }
}

output "queue_urls" {
  description = "Map of queue name to URL — used by services to send and receive messages"
  value       = { for k, q in aws_sqs_queue.main : k => q.url }
}

output "dlq_arns" {
  description = "Map of DLQ name to ARN"
  value       = { for k, q in aws_sqs_queue.dlq : k => q.arn }
}