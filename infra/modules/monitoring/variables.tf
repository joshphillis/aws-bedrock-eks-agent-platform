variable "name" {
  description = "Platform name prefix"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "aws_region" {
  description = "AWS region"
  type        = string
}

variable "eks_cluster_name" {
  description = "EKS cluster name — used in CloudWatch Container Insights alarms"
  type        = string
}

variable "sqs_queue_names" {
  description = "Map of logical name → SQS queue name (used to build metric alarm dimensions)"
  type        = map(string)
}

variable "dlq_arns" {
  description = "Map of logical name → DLQ ARN"
  type        = map(string)
  default     = {}
}

variable "alert_email_addresses" {
  description = "Email addresses to notify for CloudWatch alarms and budget alerts"
  type        = list(string)
}

variable "dlq_alert_threshold" {
  description = "Number of DLQ messages that triggers a critical alarm"
  type        = number
  default     = 5
}

variable "node_cpu_threshold" {
  description = "EKS node CPU utilisation percent that triggers a warning alarm"
  type        = number
  default     = 80
}

variable "monthly_budget_usd" {
  description = "Monthly spend budget in USD"
  type        = number
  default     = 100
}

variable "log_retention_days" {
  description = "CloudWatch log group retention in days"
  type        = number
  default     = 30
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
