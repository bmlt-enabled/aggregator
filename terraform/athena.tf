# Traffic analytics over the ALB access logs the shared "bmlt" ALB already writes to S3.
# Nothing here runs continuously: cost is S3 storage for query results (expired after 7 days)
# plus Athena's $5/TB scanned (the ALB writes ~4MB/day, so a full year is ~1.5GB).

data "aws_s3_bucket" "alb_logs" {
  bucket = "bmlt-logs-20221208032620283700000001"
}

locals {
  alb_logs_location = "s3://${data.aws_s3_bucket.alb_logs.id}/AWSLogs/${data.aws_caller_identity.current.account_id}/elasticloadbalancing/us-east-1"
}

resource "aws_s3_bucket" "athena_results" {
  bucket_prefix = "aggregator-athena-results-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "athena_results" {
  bucket                  = aws_s3_bucket.athena_results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "athena_results" {
  bucket = aws_s3_bucket.athena_results.id

  rule {
    id     = "expire-results"
    status = "Enabled"

    filter {}

    expiration {
      days = 7
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

resource "aws_athena_workgroup" "aggregator" {
  name          = "aggregator"
  force_destroy = true

  configuration {
    # Not enforced: the stats lambda's geoip CTAS has to choose its own external_location (the results
    # bucket expires everything after 7 days). The output location below is still the default, and
    # the scan cutoff applies either way.
    enforce_workgroup_configuration = false
    # Hard stop for any single query at 10GB (~$0.05) so a bad query can't cost real money.
    bytes_scanned_cutoff_per_query = 10737418240

    result_configuration {
      output_location = "s3://${aws_s3_bucket.athena_results.id}/"
    }
  }
}

resource "aws_glue_catalog_database" "aggregator_logs" {
  name = "aggregator_logs"
}

# Partition projection means no crawler and no MSCK REPAIR: always filter on `day`
# (e.g. WHERE day >= '2026/09/01') so Athena only reads those prefixes.
resource "aws_glue_catalog_table" "alb_access_logs" {
  name          = "alb_access_logs"
  database_name = aws_glue_catalog_database.aggregator_logs.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "EXTERNAL"                  = "TRUE"
    "projection.enabled"        = "true"
    "projection.day.type"       = "date"
    "projection.day.range"      = "2022/12/08,NOW"
    "projection.day.format"     = "yyyy/MM/dd"
    "projection.day.interval"   = "1"
    "projection.day.unit"       = "DAYS"
    "storage.location.template" = "${local.alb_logs_location}/$${day}"
  }

  partition_keys {
    name = "day"
    type = "string"
  }

  storage_descriptor {
    location      = "${local.alb_logs_location}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.RegexSerDe"
      parameters = {
        "serialization.format" = "1"
        "input.regex"          = "([^ ]*) ([^ ]*) ([^ ]*) ([^ ]*):([0-9]*) ([^ ]*)[:-]([0-9]*) ([-.0-9]*) ([-.0-9]*) ([-.0-9]*) (|[-0-9]*) (-|[-0-9]*) ([-0-9]*) ([-0-9]*) \"([^ ]*) (.*) (- |[^ ]*)\" \"([^\"]*)\" ([A-Z0-9-_]+) ([A-Za-z0-9.-]*) ([^ ]*) \"([^\"]*)\" \"([^\"]*)\" \"([^\"]*)\" ([-.0-9]*) ([^ ]*) \"([^\"]*)\" \"([^\"]*)\" \"([^ ]*)\" \"([^\\s]+?)\" \"([^\\s]+)\" \"([^ ]*)\" \"([^ ]*)\" ?([^ ]*)? ?( .*)?"
      }
    }

    dynamic "columns" {
      for_each = [
        ["type", "string"],
        ["time", "string"],
        ["elb", "string"],
        ["client_ip", "string"],
        ["client_port", "int"],
        ["target_ip", "string"],
        ["target_port", "int"],
        ["request_processing_time", "double"],
        ["target_processing_time", "double"],
        ["response_processing_time", "double"],
        ["elb_status_code", "int"],
        ["target_status_code", "string"],
        ["received_bytes", "bigint"],
        ["sent_bytes", "bigint"],
        ["request_verb", "string"],
        ["request_url", "string"],
        ["request_proto", "string"],
        ["user_agent", "string"],
        ["ssl_cipher", "string"],
        ["ssl_protocol", "string"],
        ["target_group_arn", "string"],
        ["trace_id", "string"],
        ["domain_name", "string"],
        ["chosen_cert_arn", "string"],
        ["matched_rule_priority", "string"],
        ["request_creation_time", "string"],
        ["actions_executed", "string"],
        ["redirect_url", "string"],
        ["lambda_error_reason", "string"],
        ["target_port_list", "string"],
        ["target_status_code_list", "string"],
        ["classification", "string"],
        ["classification_reason", "string"],
        ["conn_trace_id", "string"],
      ]
      content {
        name = columns.value[0]
        type = columns.value[1]
      }
    }
  }
}

# Everything else queries this view. The stats lambda re-runs this saved query on every run, so
# edits here take effect on the next rollup (or run it by hand in the Athena console).
resource "aws_athena_named_query" "create_requests_view" {
  name      = "00 create aggregator_requests view"
  workgroup = aws_athena_workgroup.aggregator.name
  database  = aws_glue_catalog_database.aggregator_logs.name
  query     = <<-EOT
    CREATE OR REPLACE VIEW aggregator_requests AS
    SELECT
      day,
      CAST(from_iso8601_timestamp(time) AS timestamp)                     AS ts,
      client_ip,
      domain_name,
      user_agent,
      elb_status_code,
      target_processing_time,
      sent_bytes,
      url_extract_path(request_url)                                       AS path,
      -- some clients double-encode the query, leaving "GetSearchResults&meeting_key=..." as the value
      split_part(COALESCE(TRY(url_decode(url_extract_parameter(request_url, 'switcher'))), url_extract_parameter(request_url, 'switcher')), '&', 1) AS switcher,
      url_extract_parameter(request_url, 'callingApp')                    AS calling_app,
      TRY_CAST(url_extract_parameter(request_url, 'lat_val') AS double)   AS lat,
      TRY_CAST(url_extract_parameter(request_url, 'long_val') AS double)  AS lng,
      TRY_CAST(url_extract_parameter(request_url, 'geo_width_km') AS double) AS geo_width_km,
      TRY_CAST(url_extract_parameter(request_url, 'geo_width') AS double) AS geo_width_mi,
      -- Our apps send "<app>/<version> (iOS|Android)"; NULL for everything else. The lambda's APPS lists the same names.
      regexp_extract(user_agent, '^(NAMeetingsNearMe|BMLTSearch)/([^ ]+) \((\w+)\)', 1) AS app,
      regexp_extract(user_agent, '^(NAMeetingsNearMe|BMLTSearch)/([^ ]+) \((\w+)\)', 2) AS app_version,
      regexp_extract(user_agent, '^(NAMeetingsNearMe|BMLTSearch)/([^ ]+) \((\w+)\)', 3) AS app_os,
      CASE
        WHEN split_part(COALESCE(TRY(url_decode(url_extract_parameter(request_url, 'switcher'))), url_extract_parameter(request_url, 'switcher')), '&', 1) <> 'GetSearchResults'
          THEN split_part(COALESCE(TRY(url_decode(url_extract_parameter(request_url, 'switcher'))), url_extract_parameter(request_url, 'switcher')), '&', 1)
        WHEN request_url LIKE '%meeting_ids%'                THEN 'meeting detail'
        WHEN request_url LIKE '%sort_results_by_next_start%' THEN 'virtual list'
        -- a negative width means "the nearest N", never a map view, whether or not the fields are trimmed
        -- (NA Meetings Near Me sends data_field_key on its nearest-200 search)
        WHEN regexp_like(request_url, 'geo_width(_km)?=-')      THEN 'nearby search'
        -- data_field_key only means "trimmed response": without coordinates it is a lookup (e.g. BMLTSearch checking
        -- whether a service body has meetings of its own), not a map
        WHEN request_url LIKE '%data_field_key%' AND request_url NOT LIKE '%lat_val%' THEN 'trimmed list'
        WHEN request_url LIKE '%data_field_key%'             THEN 'map'
        WHEN request_url LIKE '%lat_val%'                    THEN 'nearby search'
        ELSE 'other search'
      END                                                                 AS request_kind,
      request_url
    FROM alb_access_logs
    WHERE target_group_arn LIKE '%:targetgroup/aggregator/%'
  EOT
}

resource "aws_athena_named_query" "app_daily_usage" {
  name      = "app: daily usage by OS and version"
  workgroup = aws_athena_workgroup.aggregator.name
  database  = aws_glue_catalog_database.aggregator_logs.name
  query     = <<-EOT
    SELECT day, app, app_os, app_version, count(*) AS requests, count(DISTINCT client_ip) AS unique_ips,
           count_if(elb_status_code >= 500) AS errors_5xx,
           round(approx_percentile(target_processing_time, 0.95), 3) AS p95_seconds
    FROM aggregator_requests
    WHERE day >= date_format(current_date - interval '30' day, '%Y/%m/%d')
      AND app IS NOT NULL
    GROUP BY 1, 2, 3, 4
    ORDER BY day DESC, requests DESC
  EOT
}

resource "aws_athena_named_query" "app_feature_usage" {
  name      = "app: feature usage (last 30 days)"
  workgroup = aws_athena_workgroup.aggregator.name
  database  = aws_glue_catalog_database.aggregator_logs.name
  query     = <<-EOT
    SELECT app, request_kind, app_os, count(*) AS requests, count(DISTINCT client_ip) AS unique_ips,
           round(approx_percentile(target_processing_time, 0.5), 3)  AS p50_seconds,
           round(approx_percentile(target_processing_time, 0.95), 3) AS p95_seconds
    FROM aggregator_requests
    WHERE day >= date_format(current_date - interval '30' day, '%Y/%m/%d')
      AND app IS NOT NULL
    GROUP BY 1, 2, 3
    ORDER BY requests DESC
  EOT
}

resource "aws_athena_named_query" "app_search_locations" {
  name      = "app: where people search from (last 30 days)"
  workgroup = aws_athena_workgroup.aggregator.name
  database  = aws_glue_catalog_database.aggregator_logs.name
  query     = <<-EOT
    SELECT app, round(lat, 1) AS lat, round(lng, 1) AS lng, count(*) AS searches, count(DISTINCT client_ip) AS unique_ips
    FROM aggregator_requests
    WHERE day >= date_format(current_date - interval '30' day, '%Y/%m/%d')
      AND app IS NOT NULL
      AND lat IS NOT NULL AND lng IS NOT NULL
    GROUP BY 1, 2, 3
    ORDER BY searches DESC
    LIMIT 1000
  EOT
}

resource "aws_athena_named_query" "requests_by_client" {
  name      = "requests by client (last 7 days)"
  workgroup = aws_athena_workgroup.aggregator.name
  database  = aws_glue_catalog_database.aggregator_logs.name
  query     = <<-EOT
    SELECT calling_app, user_agent, count(*) AS requests, count(DISTINCT client_ip) AS unique_ips
    FROM aggregator_requests
    WHERE day >= date_format(current_date - interval '7' day, '%Y/%m/%d')
    GROUP BY 1, 2
    ORDER BY requests DESC
    LIMIT 100
  EOT
}

# Searches carry the user's coordinates, which beats GeoIP. Rounded to 1 decimal (~11km)
# so this is a heatmap of areas, not of people.
resource "aws_athena_named_query" "search_locations" {
  name      = "search locations heatmap (last 30 days)"
  workgroup = aws_athena_workgroup.aggregator.name
  database  = aws_glue_catalog_database.aggregator_logs.name
  query     = <<-EOT
    SELECT round(lat, 1) AS lat, round(lng, 1) AS lng, count(*) AS searches, count(DISTINCT client_ip) AS unique_ips
    FROM aggregator_requests
    WHERE day >= date_format(current_date - interval '30' day, '%Y/%m/%d')
      AND switcher = 'GetSearchResults'
      AND lat IS NOT NULL AND lng IS NOT NULL
    GROUP BY 1, 2
    ORDER BY searches DESC
    LIMIT 1000
  EOT
}

resource "aws_athena_named_query" "daily_traffic" {
  name      = "daily traffic by switcher (last 30 days)"
  workgroup = aws_athena_workgroup.aggregator.name
  database  = aws_glue_catalog_database.aggregator_logs.name
  query     = <<-EOT
    SELECT day, switcher, count(*) AS requests, count(DISTINCT client_ip) AS unique_ips,
           round(approx_percentile(target_processing_time, 0.95), 3) AS p95_seconds
    FROM aggregator_requests
    WHERE day >= date_format(current_date - interval '30' day, '%Y/%m/%d')
    GROUP BY 1, 2
    ORDER BY day DESC, requests DESC
  EOT
}
