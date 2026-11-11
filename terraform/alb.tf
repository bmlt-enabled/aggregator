# Shared values for the client-block rules below. One 403 body and one host list, edited in one place.
locals {
  blocked_message = "Your client has been blocked for excessive load on this volunteer-run aggregator. The live API is reserved for NA service bodies; third-party apps and bulk consumers take their data from the daily export instead (terms: https://cdn.aws.bmlt.app/aggregator/tos.html). A daily export of everything is at https://cdn.aws.bmlt.app/aggregator/manifest.json (guide: https://cdn.aws.bmlt.app/aggregator/responsible-use.html). Email admin@bmlt.app and we will help you move to the export, and unblock you."

  aggregator_hosts = [
    data.aws_route53_zone.aggregator_bmltenabled_org.name,
    "aggregator.na-bmlt.org",
    data.aws_route53_zone.tomato_bmltenabled_org.name,
    "tomato.na-bmlt.org",
  ]

  # One entry per client blocked by User-Agent; for_each below turns each into its own listener rule. They can't be
  # folded into a single rule's values list: the ALB caps a rule at 5 condition values, and the 4 host_header values
  # plus the UA pattern already use all 5. Priorities must stay distinct and clear of 4/6/7 (other stacks) and the
  # 20+ forward rules. Remove an entry once that client has been in touch and moved to the export.
  blocked_user_agents = {
    # MeetingBoard: a third-party app querying the live API directly, which the terms reserve for NA service bodies.
    meeting_board = { priority = 11, user_agent = "*MeetingBoard*" }

    # sobriety-tools (sobriety.tools): pre-warms six hard-coded US metros at geo_width=800 km hourly with no caching
    # (HARVESTERS.md, EXPENSIVE_QUERIES.md) — heaviest live-API client by bytes. No contact in its UA. Matched by UA,
    # not IP: its addresses are Cloudflare egress.
    sobriety_tools = { priority = 12, user_agent = "*sobriety-tools*" }

    # narecovery-* (narecovery.org): an independent NA meeting directory ingesting under several narecovery- user
    # agents (meeting-directory, feasibility-study, research, ingest). Also reachable at admin@narecovery.org.
    narecovery = { priority = 13, user_agent = "*narecovery-*" }

    # Navira: a third-party recovery app pulling large trimmed meeting lists (~286 MB/mo over ~694 requests — bulk
    # regional pulls, not per-user searches). No contact in its UA.
    navira = { priority = 14, user_agent = "*Navira*" }

    # 12steps-meeting-ingest: a server-side ingest copying meeting data from the live API (~130 MB/mo from 3 IPs).
    # Exact name so the sibling 12steps-meeting-research / 12steps-research / 12steps.life clients are left alone.
    "12steps_ingest" = { priority = 15, user_agent = "*12steps-meeting-ingest*" }

    # meeting-registry/0.1: downloads the whole dataset in 60 slices, 8x/day — 22% of all bytes and 19% of backend
    # time (TOP_CLIENTS_FINDINGS.md, HARVESTERS.md). Its UA says "contact in repo README" but the repo is not public
    # and the address is a bare VPS, so the response to its own requests is the only way to reach the operator.
    meeting_registry = { priority = 16, user_agent = "meeting-registry/*" }

    # MyMeetings: a server-side map-search harvester. Trivial at first (19 MB in Oct), it exploded to ~36k map
    # requests / 447 MB / 11.6 backend-hours from just 10 IPs over Nov 8-10 — the heaviest named client by backend
    # time, and almost entirely GetSearchResults map crawls. No contact in its UA.
    mymeetings = { priority = 17, user_agent = "*MyMeetings*" }

  }
}

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
      message_body = local.blocked_message
    }
  }

  condition {
    host_header {
      values = local.aggregator_hosts
    }
  }

  condition {
    source_ip {
      values = ["76.138.131.237/32"]
    }
  }
}

# A second IP block, separate rule because the ALB caps a rule at 5 condition values and the 4 host_header
# values plus one source_ip already fill rule above. 93.123.109.165: Bulgarian host spraying Laravel/admin
# recon paths (/horizon, /telescope, /filament, /login, /install...), ~150 req in 6h, no BMLT API calls.
resource "aws_lb_listener_rule" "aggregator_block_ip_2" {
  listener_arn = data.aws_lb_listener.main_443.arn
  priority     = 2

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      status_code  = "403"
      message_body = local.blocked_message
    }
  }

  condition {
    host_header {
      values = local.aggregator_hosts
    }
  }

  condition {
    source_ip {
      values = ["93.123.109.165/32"]
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
      values = local.aggregator_hosts
    }
  }

  condition {
    path_pattern {
      values = ["*/client_interface/xml/*"]
    }
  }
}

# One fixed-response 403 per blocked User-Agent in local.blocked_user_agents. Blocked requests never reach the
# target group, so they drop out of the stats. See that map for why each client is blocked.
resource "aws_lb_listener_rule" "aggregator_ua_block" {
  for_each = local.blocked_user_agents

  listener_arn = data.aws_lb_listener.main_443.arn
  priority     = each.value.priority

  action {
    type = "fixed-response"

    fixed_response {
      content_type = "text/plain"
      status_code  = "403"
      message_body = local.blocked_message
    }
  }

  condition {
    host_header {
      values = local.aggregator_hosts
    }
  }

  condition {
    http_header {
      http_header_name = "User-Agent"
      values           = [each.value.user_agent]
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
