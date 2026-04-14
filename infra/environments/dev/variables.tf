variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "name" {
  description = "Platform name prefix — used in all resource names"
  type        = string
  default     = "aiplatform"
}

variable "environment" {
  description = "Deployment environment"
  type        = string
  default     = "dev"
}

variable "owner_tag" {
  description = "Owner tag applied to all resources"
  type        = string
  default     = "joshua"
}

variable "alert_email" {
  description = "Email address for CloudWatch alarm and budget notifications"
  type        = string
}

variable "admin_principal_arn" {
  description = "IAM principal ARN (user or role) granted admin access to Secrets Manager and KMS keys"
  type        = string
}

variable "bedrock_model_id" {
  description = "Amazon Bedrock model ID"
  type        = string
  default     = "anthropic.claude-3-5-sonnet-20241022-v2:0"
}

variable "monthly_budget_usd" {
  description = "Monthly AWS spend budget in USD"
  type        = number
  default     = 100
}
