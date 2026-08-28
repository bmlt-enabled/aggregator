data "aws_caller_identity" "current" {}

# Capture EC2 Spot interruption warnings and rebalance recommendations into
# CloudWatch Logs, then turn them into countable metrics + a dashboard so we can
# see how often the all-Spot fleet is being rotated (without inbox noise).

resource "aws_cloudwatch_log_group" "spot_interruption" {
  name              = "/aws/events/aggregator-spot-interruption"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "spot_rebalance" {
  name              = "/aws/events/aggregator-spot-rebalance"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_resource_policy" "events_to_logs" {
  policy_name = "aggregator-events-to-logs"
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = ["events.amazonaws.com", "delivery.logs.amazonaws.com"]
        }
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:log-group:/aws/events/aggregator-spot-*:*"
      }
    ]
  })
}

# --- Spot interruption warnings (the 2-minute reclaim notice) ---

resource "aws_cloudwatch_event_rule" "spot_interruption" {
  name        = "aggregator-spot-interruption"
  description = "EC2 Spot interruption warnings (2-minute reclaim notice)"

  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Spot Instance Interruption Warning"]
  })
}

resource "aws_cloudwatch_event_target" "spot_interruption" {
  rule      = aws_cloudwatch_event_rule.spot_interruption.name
  target_id = "spot-interruption-logs"
  arn       = aws_cloudwatch_log_group.spot_interruption.arn
}

resource "aws_cloudwatch_log_metric_filter" "spot_interruption" {
  name           = "aggregator-spot-interruptions"
  log_group_name = aws_cloudwatch_log_group.spot_interruption.name
  pattern        = ""

  metric_transformation {
    name          = "SpotInterruptionWarnings"
    namespace     = "Aggregator/Spot"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# --- Rebalance recommendations (early "this instance is at risk" signal) ---

resource "aws_cloudwatch_event_rule" "spot_rebalance" {
  name        = "aggregator-spot-rebalance"
  description = "EC2 rebalance recommendations (early Spot-at-risk signal)"

  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Instance Rebalance Recommendation"]
  })
}

resource "aws_cloudwatch_event_target" "spot_rebalance" {
  rule      = aws_cloudwatch_event_rule.spot_rebalance.name
  target_id = "spot-rebalance-logs"
  arn       = aws_cloudwatch_log_group.spot_rebalance.arn
}

resource "aws_cloudwatch_log_metric_filter" "spot_rebalance" {
  name           = "aggregator-spot-rebalance"
  log_group_name = aws_cloudwatch_log_group.spot_rebalance.name
  pattern        = ""

  metric_transformation {
    name          = "SpotRebalanceRecommendations"
    namespace     = "Aggregator/Spot"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# --- Dashboard: interruptions & rebalance recommendations over time ---

resource "aws_cloudwatch_dashboard" "spot" {
  dashboard_name = "aggregator-spot"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 24
        height = 6
        properties = {
          title  = "Spot interruptions & rebalance recommendations (daily)"
          region = "us-east-1"
          view   = "timeSeries"
          stat   = "Sum"
          period = 86400
          metrics = [
            ["Aggregator/Spot", "SpotInterruptionWarnings"],
            ["Aggregator/Spot", "SpotRebalanceRecommendations"]
          ]
        }
      }
    ]
  })
}
