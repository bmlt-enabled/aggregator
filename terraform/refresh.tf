resource "aws_ssm_document" "aggregator_refresh_asg" {
  name          = "aggregator-refresh-asg"
  document_type = "Automation"

  content = jsonencode({
    schemaVersion = "0.3"
    assumeRole    = aws_iam_role.eventbridge.arn
    mainSteps = [{
      action = "aws:executeScript"
      name   = "RefreshASG"
      inputs = {
        Runtime = "python3.11"
        Handler = "main"
        Script  = <<-EOT
                      def main(events, context):
                          import boto3
                          client = boto3.client('autoscaling')
                          response = client.start_instance_refresh(AutoScalingGroupName = '${aws_autoscaling_group.aggregator_cluster.name}')
                          return response
                      EOT
      }
    }]
  })
}

resource "aws_iam_role" "eventbridge" {
  name = "aggregator-eventbridge-instance-refresh"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = ["ssm.amazonaws.com", "events.amazonaws.com"]
      }
    }]
  })
}

resource "aws_iam_role_policy" "eventbridge" {
  role = aws_iam_role.eventbridge.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = ["autoscaling:StartInstanceRefresh", "ssm:StartAutomationExecution", "sts:AssumeRole"]
        Effect   = "Allow"
        Resource = "*"
      },
      {
        Action   = ["iam:PassRole"]
        Effect   = "Allow"
        Resource = aws_iam_role.eventbridge.arn
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "bi_monthly" {
  name                = "every-two-months"
  schedule_expression = "cron(0 12 1 */2 ? *)"
}

resource "aws_cloudwatch_event_target" "start_asg_refresh" {
  rule      = aws_cloudwatch_event_rule.bi_monthly.name
  target_id = "startAggregatorASGRefresh"
  # See https://github.com/hashicorp/terraform-provider-aws/issues/6461#issuecomment-510845647
  arn      = replace(aws_ssm_document.aggregator_refresh_asg.arn, "document/", "automation-definition/")
  role_arn = aws_iam_role.eventbridge.arn
}
