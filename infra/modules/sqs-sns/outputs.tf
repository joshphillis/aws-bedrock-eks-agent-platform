output "queue_urls" {
  description = "Map of queue name → SQS queue URL"
  value       = { for k, v in aws_sqs_queue.main : k => v.id }
}

output "queue_arns" {
  description = "Map of queue name → SQS queue ARN"
  value       = { for k, v in aws_sqs_queue.main : k => v.arn }
}

output "dlq_arns" {
  description = "Map of queue name → dead-letter queue ARN"
  value       = { for k, v in aws_sqs_queue.dlq : k => v.arn }
}

output "topic_arns" {
  description = "Map of topic name → SNS topic ARN"
  value       = { for k, v in aws_sns_topic.agents : k => v.arn }
}

output "kms_key_arn" {
  description = "KMS key ARN used for SQS/SNS encryption"
  value       = aws_kms_key.sqs.arn
}
