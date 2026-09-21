# Password-protected stats dashboard: CloudFront in front of the private stats bucket.
#   /          -> s3://stats/app/    (the built UI from bmlt-enabled/aggregator-stats, uploaded with its `npm run deploy`)
#   /stats/*   -> s3://stats/stats/  (JSON written by the stats lambda)
# geoip/ is not reachable through CloudFront. Everything fits in CloudFront's always-free tier.

locals {
  stats_domain = "stats.${trimsuffix(data.aws_route53_zone.aggregator_bmltenabled_org.name, ".")}"
}

resource "aws_acm_certificate" "stats" {
  domain_name       = local.stats_domain
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "stats_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.stats.domain_validation_options : dvo.domain_name => dvo
  }

  zone_id         = data.aws_route53_zone.aggregator_bmltenabled_org.id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "stats" {
  certificate_arn         = aws_acm_certificate.stats.arn
  validation_record_fqdns = [for r in aws_route53_record.stats_cert_validation : r.fqdn]
}

resource "aws_cloudfront_origin_access_control" "stats" {
  name                              = "aggregator-stats"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# Basic auth at the edge. The credential ends up in the function source (and tfstate), which
# is fine for keeping a dashboard of aggregate counts away from crawlers and passers-by.
resource "aws_cloudfront_function" "stats_auth" {
  name    = "aggregator-stats-auth"
  runtime = "cloudfront-js-2.0"
  publish = true
  code    = <<-EOT
    function handler(event) {
      var request = event.request;
      var auth = request.headers.authorization;
      if (!auth || auth.value !== 'Basic ${base64encode("${var.stats_username}:${var.stats_password}")}') {
        return {
          statusCode: 401,
          statusDescription: 'Unauthorized',
          headers: { 'www-authenticate': { value: 'Basic realm="aggregator stats"' } }
        };
      }
      return request;
    }
  EOT
}

data "aws_cloudfront_cache_policy" "caching_optimized" {
  name = "Managed-CachingOptimized"
}

resource "aws_cloudfront_distribution" "stats" {
  enabled             = true
  comment             = "aggregator stats dashboard"
  aliases             = [local.stats_domain]
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  http_version        = "http2and3"

  origin {
    origin_id                = "app"
    domain_name              = aws_s3_bucket.stats.bucket_regional_domain_name
    origin_path              = "/app"
    origin_access_control_id = aws_cloudfront_origin_access_control.stats.id
  }

  origin {
    origin_id                = "data"
    domain_name              = aws_s3_bucket.stats.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.stats.id
  }

  default_cache_behavior {
    target_origin_id       = "app"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.stats_auth.arn
    }
  }

  ordered_cache_behavior {
    path_pattern           = "/stats/*"
    target_origin_id       = "data"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.caching_optimized.id

    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.stats_auth.arn
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.stats.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

resource "aws_s3_bucket_policy" "stats" {
  bucket = aws_s3_bucket.stats.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "CloudFrontRead"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = ["${aws_s3_bucket.stats.arn}/app/*", "${aws_s3_bucket.stats.arn}/stats/*"]
        Condition = {
          StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.stats.arn }
        }
      }
    ]
  })
}

resource "aws_route53_record" "stats" {
  for_each = toset(["A", "AAAA"])

  zone_id = data.aws_route53_zone.aggregator_bmltenabled_org.id
  name    = local.stats_domain
  type    = each.key

  alias {
    name                   = aws_cloudfront_distribution.stats.domain_name
    zone_id                = aws_cloudfront_distribution.stats.hosted_zone_id
    evaluate_target_health = false
  }
}

output "stats_url" {
  value = "https://${local.stats_domain}"
}

output "stats_bucket" {
  value = aws_s3_bucket.stats.id
}

output "stats_distribution_id" {
  value = aws_cloudfront_distribution.stats.id
}
