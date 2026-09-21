resource "aws_lb_target_group" "aggregator" {
  name                 = "aggregator"
  port                 = 8000
  protocol             = "HTTP"
  vpc_id               = data.aws_vpc.main.id
  deregistration_delay = 5

  # defaults (30s x 3) keep routing to a dead Spot host for up to 90s
  health_check {
    path                = "/"
    matcher             = "200"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

# bmlt-server dropped the XML format, so every /client_interface/xml/ request already fails with a 422 from the
# app: ~246k a year, nearly all one legacy job polling GetChanges for ~1,800 service bodies. Answer them at the load
# balancer instead. JSON GetChanges is left alone: sites call it and get a valid (empty) list.
# Priority 3 so it is evaluated before the host rules below; 5 condition values is the ALB's per-rule limit.
resource "aws_lb_listener_rule" "aggregator_xml_gone" {
  listener_arn = data.aws_lb_listener.main_443.arn
  priority     = 3

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      status_code  = "404"
      message_body = "The XML format is no longer supported. Use /client_interface/json/ instead."
    }
  }

  condition {
    host_header {
      values = [
        data.aws_route53_zone.aggregator_bmltenabled_org.name,
        "aggregator.na-bmlt.org",
        data.aws_route53_zone.tomato_bmltenabled_org.name,
        "tomato.na-bmlt.org",
      ]
    }
  }

  condition {
    path_pattern {
      values = ["*/client_interface/xml/*"]
    }
  }
}

resource "aws_lb_listener_rule" "aggregator" {
  listener_arn = data.aws_lb_listener.main_443.arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.aggregator.arn
  }

  condition {
    host_header {
      values = [data.aws_route53_zone.aggregator_bmltenabled_org.name]
    }
  }
}

resource "aws_lb_listener_rule" "aggregator_na-bmlt_org" {
  listener_arn = data.aws_lb_listener.main_443.arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.aggregator.arn
  }

  condition {
    host_header {
      values = ["aggregator.na-bmlt.org"]
    }
  }
}

resource "aws_lb_listener_rule" "tomato" {
  listener_arn = data.aws_lb_listener.main_443.arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.aggregator.arn
  }

  condition {
    host_header {
      values = [data.aws_route53_zone.tomato_bmltenabled_org.name]
    }
  }
}

resource "aws_lb_listener_rule" "tomato_na-bmlt_org" {
  listener_arn = data.aws_lb_listener.main_443.arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.aggregator.arn
  }

  condition {
    host_header {
      values = ["tomato.na-bmlt.org"]
    }
  }
}
