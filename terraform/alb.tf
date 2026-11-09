# Block a specific abusive client at the load balancer. source_ip matches the real TCP source address (not
# X-Forwarded-For), which is what we want for a direct client. Priority 1 so it is evaluated before every other
# rule. Blocked requests get a fixed response and never reach the target group, so they drop out of the stats.
resource "aws_lb_listener_rule" "aggregator_block_ip" {
  listener_arn = data.aws_lb_listener.main_443.arn
  priority     = 1

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      status_code  = "403"
      message_body = "Your client has been blocked for excessive load on this volunteer-run server. A daily export of everything is at https://cdn.aws.bmlt.app/aggregator/manifest.json (see https://cdn.aws.bmlt.app/aggregator/responsible-use.html). If that does not fit your needs, email admin@bmlt.app and we will help you get the data more efficiently, and unblock you."
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
    source_ip {
      values = ["76.138.131.237/32"]
    }
  }
}

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
# No message body on purpose: pointing the job at the JSON endpoint would just move the polling somewhere harder to block.
# Priority 3 so it is evaluated before the host rules below; 5 condition values is the ALB's per-rule limit.
resource "aws_lb_listener_rule" "aggregator_xml_gone" {
  listener_arn = data.aws_lb_listener.main_443.arn
  priority     = 3

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      status_code  = "404"
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

# meeting-registry/0.1 downloads the whole dataset in 60 slices, 8 times a day: 22% of all bytes and 19% of all
# backend time from one client (TOP_CLIENTS_FINDINGS.md, HARVESTERS.md). Its user agent says "contact in repo
# README" but the repo is not public and the address is a bare VPS, so the response to its own requests is the
# only way to reach the operator. Remove this rule once they have been in touch and have a more efficient export.
resource "aws_lb_listener_rule" "aggregator_meeting_registry" {
  listener_arn = data.aws_lb_listener.main_443.arn
  priority     = 2

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      status_code  = "403"
      message_body = "meeting-registry: your client downloads the full BMLT aggregator dataset 8 times a day, which is about a fifth of this volunteer-run server's capacity. A daily export of everything is at https://cdn.aws.bmlt.app/aggregator/manifest.json (see https://cdn.aws.bmlt.app/aggregator/responsible-use.html). If it does not fit your needs, email admin@bmlt.app and we will help you get the data more efficiently, and unblock you."
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
    http_header {
      http_header_name = "User-Agent"
      values           = ["meeting-registry/*"]
    }
  }
}

# MeetingBoard: a third-party app querying the live API directly. The terms of use reserve the live API for NA
# service bodies; everyone else takes their data from the daily export. Blocked at the ALB with a 403 pointing to
# the terms and the export. Remove this rule once they have been in touch and moved to the export.
resource "aws_lb_listener_rule" "aggregator_meeting_board" {
  listener_arn = data.aws_lb_listener.main_443.arn
  priority     = 11

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      status_code  = "403"
      message_body = "MeetingBoard: the live API of this volunteer-run aggregator is for NA service bodies; third-party apps take their data from the daily export instead. See the terms of use at https://cdn.aws.bmlt.app/aggregator/tos.html. The export of everything is at https://cdn.aws.bmlt.app/aggregator/manifest.json (guide: https://cdn.aws.bmlt.app/aggregator/responsible-use.html). Email admin@bmlt.app and we will help you move to the export, and unblock you."
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
    http_header {
      http_header_name = "User-Agent"
      values           = ["*MeetingBoard*"]
    }
  }
}

# The host-only forward rules must be evaluated AFTER every client-block rule above, otherwise a blocked client's
# request matches the host forward first and is proxied to the app before its block is ever reached. Priorities 4,
# 6 and 7 on this shared listener belong to other stacks (fortyseven/unstable/latest.aws.bmlt.app), so these are
# pinned high (20+) to stay clear of them and to sit below nothing but the listener default.
resource "aws_lb_listener_rule" "aggregator" {
  listener_arn = data.aws_lb_listener.main_443.arn
  priority     = 20

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
  priority     = 21

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
  priority     = 22

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
  priority     = 23

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
