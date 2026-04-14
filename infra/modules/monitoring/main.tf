data "aws_caller_identity" "current" {}

# ── SNS Topic for alerts ──────────────────────────────────────────────────────
resource "aws_sns_topic" "alerts" {
  name = "alerts-${var.name}-${var.environment}"
  tags = var.tags
}

resource "aws_sns_topic_subscription" "email" {
  for_each  = toset(var.alert_email_addresses)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.key
}

# ── CloudWatch Log Groups ─────────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "agents" {
  name              = "/agents/${var.name}-${var.environment}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_log_group" "eks_application" {
  name              = "/aws/containerinsights/${var.eks_cluster_name}/application"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# ── CloudWatch Metric Alarms ──────────────────────────────────────────────────

# EKS node CPU usage
resource "aws_cloudwatch_metric_alarm" "node_cpu" {
  alarm_name          = "${var.name}-${var.environment}-node-cpu-high"
  alarm_description   = "EKS node CPU utilisation exceeded ${var.node_cpu_threshold}%"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "node_cpu_utilization"
  namespace           = "ContainerInsights"
  period              = 300
  statistic           = "Average"
  threshold           = var.node_cpu_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    ClusterName = var.eks_cluster_name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

# SQS DLQ message depth — one alarm per DLQ
resource "aws_cloudwatch_metric_alarm" "dlq_messages" {
  for_each = var.sqs_queue_names

  alarm_name          = "${var.name}-${var.environment}-dlq-${each.key}"
  alarm_description   = "Dead-letter queue ${each.key} has more than ${var.dlq_alert_threshold} messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = var.dlq_alert_threshold
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = "${var.name}-${each.key}-dlq-${var.environment}"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

# SQS message age — detect stalled consumers
resource "aws_cloudwatch_metric_alarm" "queue_age" {
  for_each = var.sqs_queue_names

  alarm_name          = "${var.name}-${var.environment}-queue-age-${each.key}"
  alarm_description   = "Messages in ${each.key} queue are older than 5 minutes — consumer may be down"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 300
  statistic           = "Maximum"
  threshold           = 300
  treat_missing_data  = "notBreaching"

  dimensions = {
    QueueName = "${var.name}-${each.value}-${var.environment}"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = var.tags
}

# ── CloudWatch Dashboard ──────────────────────────────────────────────────────
resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name}-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "SQS Queue Depth"
          period = 60
          stat   = "Average"
          metrics = [
            for name in keys(var.sqs_queue_names) : [
              "AWS/SQS", "ApproximateNumberOfMessagesVisible",
              "QueueName", "${var.name}-${name}-${var.environment}"
            ]
          ]
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "DLQ Message Count"
          period = 60
          stat   = "Maximum"
          metrics = [
            for name in keys(var.sqs_queue_names) : [
              "AWS/SQS", "ApproximateNumberOfMessagesVisible",
              "QueueName", "${var.name}-${name}-dlq-${var.environment}"
            ]
          ]
        }
      },
      {
        type   = "metric"
        width  = 12
        height = 6
        properties = {
          title  = "EKS Node CPU"
          period = 300
          stat   = "Average"
          metrics = [
            ["ContainerInsights", "node_cpu_utilization", "ClusterName", var.eks_cluster_name]
          ]
        }
      },
      {
        type   = "log"
        width  = 24
        height = 8
        properties = {
          title   = "Agent Errors"
          region  = var.aws_region
          query   = "SOURCE '/agents/${var.name}-${var.environment}' | fields @timestamp, @message | filter @message like /ERROR|Exception/ | sort @timestamp desc | limit 50"
        }
      }
    ]
  })
}

# ── CloudWatch Logs Insights Saved Queries ────────────────────────────────────
resource "aws_cloudwatch_query_definition" "agent_errors" {
  name = "${var.name}/${var.environment}/AgentErrors"

  log_group_names = [aws_cloudwatch_log_group.agents.name]

  query_string = <<-EOT
    fields @timestamp, @logStream, @message
    | filter @message like /ERROR|Exception/
    | sort @timestamp desc
    | limit 100
  EOT
}

resource "aws_cloudwatch_query_definition" "bedrock_latency" {
  name = "${var.name}/${var.environment}/BedrockLatency"

  log_group_names = [aws_cloudwatch_log_group.agents.name]

  query_string = <<-EOT
    fields @timestamp, @message
    | filter @message like /bedrock/i
    | stats avg(latency_ms) as avg_ms,
            pct(latency_ms, 95) as p95_ms,
            count(*) as requests
            by bin(5m)
  EOT
}

resource "aws_cloudwatch_query_definition" "dlq_events" {
  name = "${var.name}/${var.environment}/DLQEvents"

  log_group_names = [aws_cloudwatch_log_group.agents.name]

  query_string = <<-EOT
    fields @timestamp, @message
    | filter @message like /dead.letter|dlq|maxReceiveCount/i
    | sort @timestamp desc
    | limit 50
  EOT
}

# ── AWS Budgets ───────────────────────────────────────────────────────────────
resource "aws_budgets_budget" "monthly" {
  name         = "${var.name}-${var.environment}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.alert_email_addresses
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.alert_email_addresses
  }

  tags = var.tags
}
