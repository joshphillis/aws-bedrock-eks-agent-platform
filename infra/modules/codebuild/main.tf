data "aws_caller_identity" "current" {}

locals {
  agents      = toset(var.agent_names)
  # ECR registry hostname is the first path segment of any repo URL
  ecr_registry = split("/", values(var.ecr_repository_urls)[0])[0]
}

# ── GitHub connection (CodeStar) ───────────────────────────────────────────────
# After `terraform apply`, activate this connection in the AWS console:
#   Developer Tools → Connections → select the connection → Update pending connection
resource "aws_codestarconnections_connection" "github" {
  name          = "${var.name}-github-${var.environment}"
  provider_type = "GitHub"
  tags          = var.tags
}

# ── IAM role for CodeBuild ────────────────────────────────────────────────────
data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codebuild" {
  name               = "${var.name}-codebuild-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "codebuild" {
  # ECR registry authentication — must target *
  statement {
    sid       = "ECRAuth"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # ECR push scoped to the four agent repositories
  statement {
    sid    = "ECRPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = values(var.ecr_repository_arns)
  }

  # CloudWatch Logs for build output
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.name}-*",
      "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.name}-*:*",
    ]
  }

  # S3 for Docker layer cache
  statement {
    sid    = "S3Cache"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
      "s3:PutObject",
    ]
    resources = ["${aws_s3_bucket.build_cache.arn}/*"]
  }

  # CodeStar connection — allows CodeBuild to clone from GitHub
  statement {
    sid       = "CodeStarConnection"
    effect    = "Allow"
    actions   = ["codestar-connections:UseConnection"]
    resources = [aws_codestarconnections_connection.github.arn]
  }
}

resource "aws_iam_role_policy" "codebuild" {
  name   = "${var.name}-codebuild-${var.environment}"
  role   = aws_iam_role.codebuild.id
  policy = data.aws_iam_policy_document.codebuild.json
}

# ── S3 build cache ────────────────────────────────────────────────────────────
resource "aws_s3_bucket" "build_cache" {
  bucket        = "${var.name}-codebuild-cache-${var.environment}-${data.aws_caller_identity.current.account_id}"
  force_destroy = true
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "build_cache" {
  bucket                  = aws_s3_bucket.build_cache.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "build_cache" {
  bucket = aws_s3_bucket.build_cache.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "build_cache" {
  bucket = aws_s3_bucket.build_cache.id
  rule {
    id     = "expire-cache"
    status = "Enabled"
    filter { prefix = "" }
    expiration { days = 30 }
  }
}

# ── CodeBuild projects (one per agent) ───────────────────────────────────────
resource "aws_codebuild_project" "agents" {
  for_each = local.agents

  name          = "${var.name}-${each.key}-${var.environment}"
  description   = "Build and push ${each.key} Docker image to ECR"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = var.build_timeout_minutes

  source {
    type      = "GITHUB"
    location  = "https://github.com/${var.github_repo}.git"
    buildspec = <<-BUILDSPEC
      version: 0.2
      phases:
        pre_build:
          commands:
            - aws ecr get-login-password --region $AWS_DEFAULT_REGION | docker login --username AWS --password-stdin $ECR_REGISTRY
        build:
          commands:
            - docker build -t $ECR_REPO_URL:$CODEBUILD_RESOLVED_SOURCE_VERSION agents/$AGENT_NAME/
            - docker tag $ECR_REPO_URL:$CODEBUILD_RESOLVED_SOURCE_VERSION $ECR_REPO_URL:latest
        post_build:
          commands:
            - docker push $ECR_REPO_URL:$CODEBUILD_RESOLVED_SOURCE_VERSION
            - docker push $ECR_REPO_URL:latest
    BUILDSPEC

    git_clone_depth = 1

    git_submodules_config {
      fetch_submodules = false
    }
  }

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    # LINUX_CONTAINER + privileged_mode is required for Docker-in-Docker builds
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    privileged_mode             = true
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "AGENT_NAME"
      value = each.key
    }

    environment_variable {
      name  = "ECR_REGISTRY"
      value = local.ecr_registry
    }

    environment_variable {
      name  = "ECR_REPO_URL"
      value = var.ecr_repository_urls[each.key]
    }
  }

  cache {
    type     = "S3"
    location = aws_s3_bucket.build_cache.bucket
  }

  logs_config {
    cloudwatch_logs {
      group_name  = "/aws/codebuild/${var.name}-${each.key}-${var.environment}"
      stream_name = "build"
    }
  }

  tags = merge(var.tags, { Agent = each.key })
}

# ── Grant GitHub Actions role permission to trigger builds ────────────────────
data "aws_iam_policy_document" "gha_codebuild" {
  count = var.github_actions_role_name != null ? 1 : 0

  statement {
    sid    = "StartAndMonitorBuilds"
    effect = "Allow"
    actions = [
      "codebuild:StartBuild",
      "codebuild:BatchGetBuilds",
      "codebuild:StopBuild",
    ]
    resources = [for p in aws_codebuild_project.agents : p.arn]
  }
}

resource "aws_iam_role_policy" "gha_codebuild" {
  count = var.github_actions_role_name != null ? 1 : 0

  name   = "${var.name}-gha-codebuild-${var.environment}"
  role   = var.github_actions_role_name
  policy = data.aws_iam_policy_document.gha_codebuild[0].json
}
