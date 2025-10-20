resource "aws_cloudwatch_log_group" "aggregator" {
  name              = "aggregator"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "aggregator_import" {
  name              = "aggregator-import"
  retention_in_days = 7
}

resource "aws_cloudwatch_log_group" "aggregator_init" {
  name              = "aggregator-init"
  retention_in_days = 7
}

resource "aws_cloudwatch_event_rule" "aggregator_import" {
  name                = "aggregator-import"
  description         = "Kicks off aggregator import every 4 hours"
  schedule_expression = "rate(4 hours)"
}

# resource "aws_cloudwatch_event_target" "aggregator_import" {
#   target_id = "aggregator-import"
#   arn       = aws_ecs_cluster.aggregator.arn
#   rule      = aws_cloudwatch_event_rule.aggregator_import.name
#   role_arn  = aws_iam_role.ecs_events.arn
#
#   ecs_target {
#     task_count          = 1
#     task_definition_arn = aws_ecs_task_definition.aggregator_import.arn
#     launch_type         = "EC2"
#     propagate_tags      = "TASK_DEFINITION"
#   }
# }

data "aws_iam_policy_document" "ecs_events" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ecs_events_run_task_with_any_role" {
  statement {
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ecs:RunTask"]
    resources = [aws_ecs_task_definition.aggregator_import.arn]
  }
}

resource "aws_iam_role" "ecs_events" {
  name               = "ecs-events-aggregator"
  assume_role_policy = data.aws_iam_policy_document.ecs_events.json
}

resource "aws_iam_role_policy" "ecs_events_run_task_with_any_role" {
  name   = "ecs-events-run-task-with-any-role-aggregator"
  role   = aws_iam_role.ecs_events.id
  policy = data.aws_iam_policy_document.ecs_events_run_task_with_any_role.json
}

resource "aws_cloudwatch_metric_alarm" "lb_hosts_lt_2" {
  alarm_name          = "aggregator-lb-unhealthy-hosts-lt-2"
  alarm_description   = "healthy hosts less than 2 for an 20 minutes"
  actions_enabled     = true
  comparison_operator = "LessThanThreshold"
  datapoints_to_alarm = 1
  evaluation_periods  = 1
  period              = 1200
  threshold           = 2
  statistic           = "Maximum"
  treat_missing_data  = "missing"
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"

  dimensions = {
    "LoadBalancer" = data.aws_lb.main.arn_suffix
    "TargetGroup"  = aws_lb_target_group.aggregator.arn_suffix
  }

  alarm_actions             = [aws_sns_topic.lb_hosts.arn]
  ok_actions                = [aws_sns_topic.lb_hosts.arn]
  insufficient_data_actions = []

  tags = {
    Name = "aggregator"
  }
}

resource "aws_cloudwatch_metric_alarm" "lb_hosts_lt_1" {
  alarm_name          = "aggregator-lb-unhealthy-hosts-lt-1"
  alarm_description   = "healthy hosts less than 1 for an 5 minutes"
  actions_enabled     = true
  comparison_operator = "LessThanThreshold"
  datapoints_to_alarm = 1
  evaluation_periods  = 1
  period              = 300
  threshold           = 1
  statistic           = "Maximum"
  treat_missing_data  = "missing"
  metric_name         = "HealthyHostCount"
  namespace           = "AWS/ApplicationELB"

  dimensions = {
    "LoadBalancer" = data.aws_lb.main.arn_suffix
    "TargetGroup"  = aws_lb_target_group.aggregator.arn_suffix
  }

  alarm_actions             = [aws_sns_topic.lb_hosts.arn]
  ok_actions                = [aws_sns_topic.lb_hosts.arn]
  insufficient_data_actions = []

  tags = {
    Name = "aggregator"
  }
}

resource "aws_sns_topic" "lb_hosts" {
  name = "aggregator-lb-healthy-host"

  tags = {
    Name = "aggregator"
  }
}

resource "aws_cloudwatch_event_rule" "aggregator_ecs_state" {
  name        = "aggregator-ecs-state-stop"
  description = "Get each time a aggregator task stops"

  event_pattern = jsonencode(
    {
      source = [
        "aws.ecs"
      ]
      detail-type = [
        "ECS Task State Change"
      ]
      detail = {
        clusterArn = [
          aws_ecs_cluster.aggregator.arn
        ]
        containers = {
          lastStatus = [
            "STOPPED"
          ]
        }
        group = [
          "service:${aws_ecs_task_definition.aggregator.family}"
        ]
      }
  })
}

resource "aws_cloudwatch_event_target" "aggregator" {
  target_id = "SendToLambdaAggregator"
  rule      = aws_cloudwatch_event_rule.aggregator_ecs_state.name
  arn       = aws_lambda_function.aggregator_lambda.arn
}

resource "aws_cloudwatch_log_group" "aggregator_lambda_logs" {
  name              = "/aws/lambda/${aws_lambda_function.aggregator_lambda.function_name}"
  retention_in_days = 7
}
