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

variable "oidc_provider_arn" {
  description = "OIDC provider ARN for the EKS cluster (from eks module)"
  type        = string
}

variable "oidc_provider_url" {
  description = "OIDC provider URL without https:// (from eks module)"
  type        = string
}

variable "k8s_namespace" {
  description = "Kubernetes namespace where agent ServiceAccounts live"
  type        = string
  default     = "agents"
}

variable "agent_names" {
  description = "List of agent names — one IAM role is created per agent"
  type        = list(string)
  default     = ["orchestrator", "research-agent", "analysis-agent", "writer-agent"]
}

variable "bedrock_model_id" {
  description = "Amazon Bedrock model ID used by the agents"
  type        = string
  default     = "anthropic.claude-3-5-sonnet-20241022-v2:0"
}

variable "sqs_queue_urls" {
  description = "Map of queue name → SQS URL (from sqs-sns module)"
  type        = map(string)
}

variable "sqs_queue_arns" {
  description = "Map of queue name → SQS ARN (from sqs-sns module)"
  type        = map(string)
}

variable "sqs_kms_key_arn" {
  description = "KMS key ARN used to encrypt SQS queues (from sqs-sns module)"
  type        = string
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
