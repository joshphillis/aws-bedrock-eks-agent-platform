output "alerts_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarms"
  value       = aws_sns_topic.alerts.arn
}

output "agents_log_group_name" {
  description = "CloudWatch Log Group name for agent application logs"
  value       = aws_cloudwatch_log_group.agents.name
}

output "dashboard_name" {
  description = "CloudWatch dashboard name"
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}
