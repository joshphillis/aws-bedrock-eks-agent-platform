data "aws_caller_identity" "current" {}

# ── KMS key for ECR image encryption ─────────────────────────────────────────
resource "aws_kms_key" "ecr" {
  description             = "ECR image encryption key — ${var.name}-${var.environment}"
  deletion_window_in_days = 14
  enable_key_rotation     = true
  tags                    = var.tags
}

# ── ECR Repositories ──────────────────────────────────────────────────────────
resource "aws_ecr_repository" "agents" {
  for_each = toset(var.agent_names)

  name                 = "${var.name}-${each.key}"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr.arn
  }

  tags = merge(var.tags, {
    Name = "${var.name}-${each.key}"
  })
}

# ── Lifecycle Policies ────────────────────────────────────────────────────────
resource "aws_ecr_lifecycle_policy" "agents" {
  for_each   = aws_ecr_repository.agents
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep the last ${var.image_retention_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.image_retention_count
        }
        action = { type = "expire" }
      }
    ]
  })
}

# ── Repository Policies (allow EKS node role to pull) ────────────────────────
data "aws_iam_policy_document" "ecr_pull" {
  statement {
    sid    = "AllowEKSNodePull"
    effect = "Allow"
    principals {
      type        = "AWS"
      identifiers = [var.node_role_arn]
    }
    actions = [
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "ecr:BatchCheckLayerAvailability",
    ]
  }
}

resource "aws_ecr_repository_policy" "agents" {
  for_each   = aws_ecr_repository.agents
  repository = each.value.name
  policy     = data.aws_iam_policy_document.ecr_pull.json
}
