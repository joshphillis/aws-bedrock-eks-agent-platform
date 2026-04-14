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

variable "kubernetes_version" {
  description = "Kubernetes version for the EKS cluster"
  type        = string
  default     = "1.32"
}

variable "vpc_id" {
  description = "VPC ID"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnet IDs for node groups"
  type        = list(string)
}

variable "sg_nodes_id" {
  description = "Security group ID for EKS worker nodes"
  type        = string
}

variable "public_access_cidrs" {
  description = "CIDR blocks allowed to reach the EKS public API endpoint"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "system_vm_size" {
  description = "Instance type for the system node group"
  type        = string
  default     = "t3.medium"
}

variable "system_node_count" {
  description = "Desired number of system nodes"
  type        = number
  default     = 2
}

variable "agent_vm_size" {
  description = "Instance type for the AI-agents node group"
  type        = string
  default     = "t3.large"
}

variable "agent_min_count" {
  description = "Minimum nodes in the AI-agents autoscaling group"
  type        = number
  default     = 1
}

variable "agent_max_count" {
  description = "Maximum nodes in the AI-agents autoscaling group"
  type        = number
  default     = 3
}

variable "log_retention_days" {
  description = "CloudWatch log retention in days for EKS control-plane logs"
  type        = number
  default     = 30
}

variable "tags" {
  description = "Additional tags"
  type        = map(string)
  default     = {}
}
