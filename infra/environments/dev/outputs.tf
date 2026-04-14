output "vpc_id" {
  description = "VPC ID"
  value       = module.networking.vpc_id
}

output "eks_cluster_name" {
  description = "EKS cluster name"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API server endpoint"
  value       = module.eks.cluster_endpoint
}

output "oidc_provider_arn" {
  description = "OIDC provider ARN (for debugging IRSA issues)"
  value       = module.eks.oidc_provider_arn
}

output "ecr_repository_urls" {
  description = "Map of agent name → ECR URL — use in kustomization image patches"
  value       = module.ecr.repository_urls
}

output "agent_role_arns" {
  description = "Map of agent name → IAM role ARN — paste into k8s/overlays/dev/kustomization.yaml"
  value       = module.secrets.agent_role_arns
}

output "sqs_queue_urls" {
  description = "Map of queue name → SQS URL"
  value       = module.sqs_sns.queue_urls
  sensitive   = true
}

output "config_secret_arn" {
  description = "ARN of the shared config Secrets Manager secret"
  value       = module.secrets.config_secret_arn
}

output "cloudwatch_dashboard" {
  description = "CloudWatch dashboard name"
  value       = module.monitoring.dashboard_name
}
