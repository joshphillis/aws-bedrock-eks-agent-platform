# ── KMS key for SQS encryption ────────────────────────────────────────────────
resource "aws_kms_key" "sqs" {
  description             = "SQS message encryption key — ${var.name}-${var.environment}"
  deletion_window_in_days = 14
  enable_key_rotation     = true
  tags                    = var.tags
}

resource "aws_kms_alias" "sqs" {
  name          = "alias/sqs-${var.name}-${var.environment}"
  target_key_id = aws_kms_key.sqs.key_id
}

# ── Dead-Letter Queues ────────────────────────────────────────────────────────
resource "aws_sqs_queue" "dlq" {
  for_each = toset(var.queue_names)

  name                       = "${var.name}-${each.key}-dlq-${var.environment}"
  message_retention_seconds  = 1209600 # 14 days
  kms_master_key_id          = aws_kms_key.sqs.id
  sqs_managed_sse_enabled    = false

  tags = merge(var.tags, {
    Name = "${var.name}-${each.key}-dlq-${var.environment}"
    Role = "dead-letter-queue"
  })
}

# ── Primary Queues ────────────────────────────────────────────────────────────
resource "aws_sqs_queue" "main" {
  for_each = toset(var.queue_names)

  name                       = "${var.name}-${each.key}-${var.environment}"
  message_retention_seconds  = var.message_retention_seconds
  visibility_timeout_seconds = var.visibility_timeout_seconds
  receive_wait_time_seconds  = 20  # long polling
  kms_master_key_id          = aws_kms_key.sqs.id
  sqs_managed_sse_enabled    = false

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = var.max_receive_count
  })

  tags = merge(var.tags, {
    Name = "${var.name}-${each.key}-${var.environment}"
  })
}

# ── Queue Policies (restrict to account; agents access via IRSA IAM roles) ───
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "aws_iam_policy_document" "queue_policy" {
  for_each = toset(var.queue_names)

  statement {
    sid    = "DenyNonSSL"
    effect = "Deny"
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    actions   = ["sqs:*"]
    resources = [aws_sqs_queue.main[each.key].arn]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_sqs_queue_policy" "main" {
  for_each  = toset(var.queue_names)
  queue_url = aws_sqs_queue.main[each.key].id
  policy    = data.aws_iam_policy_document.queue_policy[each.key].json
}

# ── SNS Topics (future fan-out; currently 1:1 with SQS) ──────────────────────
resource "aws_sns_topic" "agents" {
  for_each          = toset(var.queue_names)
  name              = "${var.name}-${each.key}-${var.environment}"
  kms_master_key_id = aws_kms_key.sqs.id

  tags = merge(var.tags, {
    Name = "${var.name}-${each.key}-${var.environment}"
  })
}

# ── SNS → SQS Subscriptions ───────────────────────────────────────────────────
resource "aws_sns_topic_subscription" "sqs" {
  for_each  = toset(var.queue_names)
  topic_arn = aws_sns_topic.agents[each.key].arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.main[each.key].arn

  # Deliver the raw message body (not the SNS envelope) so agents parse plain JSON
  raw_message_delivery = true
}

# Allow SNS to write to SQS
resource "aws_sqs_queue_policy" "allow_sns" {
  for_each  = toset(var.queue_names)
  queue_url = aws_sqs_queue.main[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowSNSPublish"
        Effect = "Allow"
        Principal = { Service = "sns.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.main[each.key].arn
        Condition = {
          ArnEquals = { "aws:SourceArn" = aws_sns_topic.agents[each.key].arn }
        }
      },
      {
        Sid    = "DenyNonSSL"
        Effect = "Deny"
        Principal = { AWS = "*" }
        Action    = "sqs:*"
        Resource  = aws_sqs_queue.main[each.key].arn
        Condition = {
          Bool = { "aws:SecureTransport" = "false" }
        }
      }
    ]
  })
}
