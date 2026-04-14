variable "name" {
  description = "Platform name prefix"
  type        = string
}

variable "environment" {
  description = "Deployment environment"
  type        = string
}

variable "agent_names" {
  description = "List of agent names — one ECR repository will be created per agent"
  type        = list(string)
  default     = ["orchestrator", "research-agent", "analysis-agent", "writer-agent"]
}

variable "node_role_arn" {
  description = "IAM role ARN of the EKS worker nodes, granted pull access to all repositories"
  type        = string
}

variable "image_retention_count" {
  description = "Maximum number of images to retain per repository"
  type        = number
  default     = 30
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
