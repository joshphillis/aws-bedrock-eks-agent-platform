variable "name" {
  description = "Platform name prefix"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "queue_names" {
  description = "Names of the SQS queues to create (mirrors Azure Service Bus topics)"
  type        = list(string)
  default     = ["research-tasks", "analysis-tasks", "writer-tasks", "agent-results"]
}

variable "message_retention_seconds" {
  description = "How long SQS retains a message (default 1 hour)"
  type        = number
  default     = 3600
}

variable "visibility_timeout_seconds" {
  description = "Message visibility timeout — set longer than the slowest Bedrock invocation"
  type        = number
  default     = 120
}

variable "max_receive_count" {
  description = "Number of receive attempts before a message goes to the DLQ"
  type        = number
  default     = 5
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
