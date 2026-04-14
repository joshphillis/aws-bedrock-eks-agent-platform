output "repository_urls" {
  description = "Map of agent name → ECR repository URL"
  value       = { for k, v in aws_ecr_repository.agents : k => v.repository_url }
}

output "repository_arns" {
  description = "Map of agent name → ECR repository ARN"
  value       = { for k, v in aws_ecr_repository.agents : k => v.arn }
}

output "registry_id" {
  description = "ECR registry ID (AWS account ID)"
  value       = data.aws_caller_identity.current.account_id
}
