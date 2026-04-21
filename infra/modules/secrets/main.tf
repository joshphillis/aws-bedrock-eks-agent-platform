data "aws_caller_identity" "current" {}

# ── Secrets Manager: shared platform config ───────────────────────────────────
resource "aws_secretsmanager_secret" "config" {
  name                    = "${var.name}/${var.environment}/config"
  description             = "Shared configuration for all AI platform agents"
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "config" {
  secret_id = aws_secretsmanager_secret.config.id
  secret_string = jsonencode({
    aws_region             = var.aws_region
    bedrock_model_id       = var.bedrock_model_id
    sqs_research_queue_url = lookup(var.sqs_queue_urls, "research-tasks", "")
    sqs_analysis_queue_url = lookup(var.sqs_queue_urls, "analysis-tasks", "")
    sqs_writer_queue_url   = lookup(var.sqs_queue_urls, "writer-tasks", "")
    sqs_results_queue_url  = lookup(var.sqs_queue_urls, "agent-results", "")
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ── Secrets Manager: OpenAI fallback key ─────────────────────────────────────
resource "aws_secretsmanager_secret" "openai" {
  name                    = "${var.name}/${var.environment}/openai"
  description             = "OpenAI API key (fallback when Bedrock is unavailable)"
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "openai" {
  secret_id     = aws_secretsmanager_secret.openai.id
  secret_string = jsonencode({ api_key = "REPLACE_WITH_OPENAI_API_KEY" })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ── IAM IRSA roles — one per agent ───────────────────────────────────────────
data "aws_iam_policy_document" "irsa_trust" {
  for_each = toset(var.agent_names)

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:${var.k8s_namespace}:sa-${each.key}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${var.oidc_provider_url}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "agent" {
  for_each = toset(var.agent_names)

  name               = "role-${each.key}-${var.environment}"
  assume_role_policy = data.aws_iam_policy_document.irsa_trust[each.key].json

  tags = merge(var.tags, {
    Name  = "role-${each.key}-${var.environment}"
    Agent = each.key
  })
}

# ── IAM Policy: Bedrock invocation ───────────────────────────────────────────
data "aws_iam_policy_document" "bedrock" {
  statement {
    sid    = "InvokeBedrock"
    effect = "Allow"
    actions = [
      "bedrock:InvokeModel",
      "bedrock:InvokeModelWithResponseStream",
    ]
    resources = ["arn:aws:bedrock:${var.aws_region}::foundation-model/*"]
  }
}

resource "aws_iam_policy" "bedrock" {
  name        = "policy-bedrock-${var.name}-${var.environment}"
  description = "Allow agents to invoke Bedrock foundation models"
  policy      = data.aws_iam_policy_document.bedrock.json
  tags        = var.tags
}

# ── IAM Policy: Secrets Manager read ─────────────────────────────────────────
data "aws_iam_policy_document" "secrets" {
  statement {
    sid    = "ReadSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      aws_secretsmanager_secret.config.arn,
      aws_secretsmanager_secret.openai.arn,
    ]
  }
}

resource "aws_iam_policy" "secrets" {
  name        = "policy-secrets-${var.name}-${var.environment}"
  description = "Allow agents to read Secrets Manager secrets"
  policy      = data.aws_iam_policy_document.secrets.json
  tags        = var.tags
}

# ── IAM Policy: SQS per-agent access ─────────────────────────────────────────
# Orchestrator: send to task queues, receive from results queue
data "aws_iam_policy_document" "sqs_orchestrator" {
  statement {
    sid    = "SendToTaskQueues"
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [
      lookup(var.sqs_queue_arns, "research-tasks", "*"),
      lookup(var.sqs_queue_arns, "analysis-tasks", "*"),
      lookup(var.sqs_queue_arns, "writer-tasks", "*"),
    ]
  }
  statement {
    sid    = "ReceiveFromResultsQueue"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [lookup(var.sqs_queue_arns, "agent-results", "*")]
  }
}

# Worker agents: receive from own queue, send to results queue
locals {
  worker_queue_map = {
    "research-agent"  = "research-tasks"
    "analysis-agent"  = "analysis-tasks"
    "writer-agent"    = "writer-tasks"
  }
}

data "aws_iam_policy_document" "sqs_worker" {
  for_each = local.worker_queue_map

  statement {
    sid    = "ReceiveFromOwnQueue"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [lookup(var.sqs_queue_arns, each.value, "*")]
  }
  statement {
    sid    = "SendToResultsQueue"
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [lookup(var.sqs_queue_arns, "agent-results", "*")]
  }
}

resource "aws_iam_policy" "sqs_orchestrator" {
  name        = "policy-sqs-orchestrator-${var.environment}"
  description = "SQS access for the orchestrator agent"
  policy      = data.aws_iam_policy_document.sqs_orchestrator.json
  tags        = var.tags
}

resource "aws_iam_policy" "sqs_worker" {
  for_each    = local.worker_queue_map
  name        = "policy-sqs-${each.key}-${var.environment}"
  description = "SQS access for ${each.key}"
  policy      = data.aws_iam_policy_document.sqs_worker[each.key].json
  tags        = var.tags
}

# ── IAM Policy: SQS KMS key access ──────────────────────────────────────────
data "aws_iam_policy_document" "sqs_kms" {
  statement {
    sid    = "UseSQSKMSKey"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey",
      "kms:Decrypt",
      "kms:DescribeKey",
    ]
    resources = [var.sqs_kms_key_arn]
  }
}

resource "aws_iam_policy" "sqs_kms" {
  name        = "policy-sqs-kms-${var.name}-${var.environment}"
  description = "Allow agents to use the SQS KMS key for encrypt/decrypt"
  policy      = data.aws_iam_policy_document.sqs_kms.json
  tags        = var.tags
}

# ── CloudWatch Logs policy (shared) ──────────────────────────────────────────
data "aws_iam_policy_document" "cloudwatch_logs" {
  statement {
    sid    = "WriteLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/agents/*"]
  }
}

resource "aws_iam_policy" "cloudwatch_logs" {
  name        = "policy-cloudwatch-agents-${var.environment}"
  description = "Allow agents to write CloudWatch Logs"
  policy      = data.aws_iam_policy_document.cloudwatch_logs.json
  tags        = var.tags
}

# ── Attach policies to each agent role ───────────────────────────────────────
resource "aws_iam_role_policy_attachment" "bedrock" {
  for_each   = toset(var.agent_names)
  role       = aws_iam_role.agent[each.key].name
  policy_arn = aws_iam_policy.bedrock.arn
}

resource "aws_iam_role_policy_attachment" "secrets" {
  for_each   = toset(var.agent_names)
  role       = aws_iam_role.agent[each.key].name
  policy_arn = aws_iam_policy.secrets.arn
}

resource "aws_iam_role_policy_attachment" "cloudwatch_logs" {
  for_each   = toset(var.agent_names)
  role       = aws_iam_role.agent[each.key].name
  policy_arn = aws_iam_policy.cloudwatch_logs.arn
}

resource "aws_iam_role_policy_attachment" "sqs_orchestrator" {
  role       = aws_iam_role.agent["orchestrator"].name
  policy_arn = aws_iam_policy.sqs_orchestrator.arn
}

resource "aws_iam_role_policy_attachment" "sqs_worker" {
  for_each   = local.worker_queue_map
  role       = aws_iam_role.agent[each.key].name
  policy_arn = aws_iam_policy.sqs_worker[each.key].arn
}

resource "aws_iam_role_policy_attachment" "sqs_kms" {
  for_each   = toset(var.agent_names)
  role       = aws_iam_role.agent[each.key].name
  policy_arn = aws_iam_policy.sqs_kms.arn
}
