output "agent_role_arns" {
  description = "Map of agent name → IAM role ARN — use these to annotate K8s ServiceAccounts"
  value       = { for k, v in aws_iam_role.agent : k => v.arn }
}

output "agent_role_names" {
  description = "Map of agent name → IAM role name"
  value       = { for k, v in aws_iam_role.agent : k => v.name }
}

output "config_secret_arn" {
  description = "ARN of the shared platform config Secrets Manager secret"
  value       = aws_secretsmanager_secret.config.arn
}

output "openai_secret_arn" {
  description = "ARN of the OpenAI API key Secrets Manager secret"
  value       = aws_secretsmanager_secret.openai.arn
}
