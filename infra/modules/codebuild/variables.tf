variable "name" {
  description = "Platform name prefix — used in all resource names"
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

variable "github_repo" {
  description = "GitHub repository in owner/repo format (e.g. acme/my-platform)"
  type        = string
}

variable "agent_names" {
  description = "Agent names — one CodeBuild project is created per entry"
  type        = list(string)
  default     = ["orchestrator", "research-agent", "analysis-agent", "writer-agent"]
}

variable "ecr_repository_urls" {
  description = "Map of agent name → ECR repository URL"
  type        = map(string)
}

variable "ecr_repository_arns" {
  description = "Map of agent name → ECR repository ARN (used to scope push permissions)"
  type        = map(string)
}

variable "github_actions_role_name" {
  description = "Name of the IAM role used by GitHub Actions. When set, a policy granting StartBuild/BatchGetBuilds is attached so the workflow can trigger builds."
  type        = string
  default     = null
}

variable "build_timeout_minutes" {
  description = "Maximum build duration in minutes"
  type        = number
  default     = 30
}

variable "tags" {
  description = "Additional tags applied to all resources"
  type        = map(string)
  default     = {}
}
