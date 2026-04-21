output "project_names" {
  description = "Map of agent name → CodeBuild project name"
  value       = { for k, v in aws_codebuild_project.agents : k => v.name }
}

output "project_arns" {
  description = "Map of agent name → CodeBuild project ARN"
  value       = { for k, v in aws_codebuild_project.agents : k => v.arn }
}

output "codebuild_role_arn" {
  description = "ARN of the IAM role assumed by CodeBuild"
  value       = aws_iam_role.codebuild.arn
}

output "github_connection_arn" {
  description = "ARN of the CodeStar connection to GitHub (must be activated in the AWS console before builds will succeed)"
  value       = aws_codestarconnections_connection.github.arn
}

output "github_connection_status" {
  description = "Activation status of the GitHub CodeStar connection"
  value       = aws_codestarconnections_connection.github.connection_status
}

output "cache_bucket" {
  description = "S3 bucket used for Docker layer caching"
  value       = aws_s3_bucket.build_cache.bucket
}
