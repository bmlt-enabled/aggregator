# Daily rollup of the ALB logs into small JSON files for the stats frontend, plus a monthly
# GeoIP refresh. See stats_lambda.py. Cost is a few Lambda seconds and ~150MB of Athena scans
# per day (well under a cent a month).

resource "aws_s3_bucket" "stats" {
  bucket_prefix = "aggregator-stats-"
}

resource "aws_s3_bucket_public_access_block" "stats" {
  bucket                  = aws_s3_bucket.stats.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# DB-IP "IP to City Lite" CSV, downloaded by the lambda. The queryable `geoip` table is built
# from this by CTAS (also in the lambda), so it is not managed here.
resource "aws_glue_catalog_table" "geoip_raw" {
  name          = "geoip_raw"
  database_name = aws_glue_catalog_database.aggregator_logs.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "EXTERNAL" = "TRUE"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.stats.id}/geoip/raw/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.serde2.OpenCSVSerde"
      parameters = {
        "separatorChar" = ","
        "quoteChar"     = "\""
      }
    }

    dynamic "columns" {
      for_each = ["ip_start", "ip_end", "continent", "country", "region", "city", "lat", "lng"]
      content {
        name = columns.value
        type = "string"
      }
    }
  }
}

# One raw Parquet row per request, UNLOADed daily by the lambda under s3://stats/facts/day=YYYY-MM-DD/, for
# ad-hoc querying with DuckDB or Athena. Private analytics layer: keeps client IPs and exact coordinates
# (CloudFront serves only app/ and stats/, so facts/ is S3-only), unlike the redacted JSON stats.
# Partition projection means no crawler: always filter on `day` (e.g. WHERE day >= DATE '2026-09-01').
#   DuckDB:  SELECT * FROM read_parquet('s3://<bucket>/facts/*/*.parquet', hive_partitioning = true)
resource "aws_glue_catalog_table" "aggregator_facts" {
  name          = "aggregator_facts"
  database_name = aws_glue_catalog_database.aggregator_logs.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "EXTERNAL"                  = "TRUE"
    "classification"            = "parquet"
    "projection.enabled"        = "true"
    "projection.day.type"       = "date"
    "projection.day.range"      = "2022-12-08,NOW"
    "projection.day.format"     = "yyyy-MM-dd"
    "projection.day.interval"   = "1"
    "projection.day.unit"       = "DAYS"
    "storage.location.template" = "s3://${aws_s3_bucket.stats.id}/facts/day=$${day}"
  }

  partition_keys {
    name = "day"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${aws_s3_bucket.stats.id}/facts/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
      parameters            = { "serialization.format" = "1" }
    }

    dynamic "columns" {
      for_each = [
        ["client_ip", "string"],
        ["ts", "timestamp"],
        ["hour", "int"],
        ["domain_name", "string"],
        ["user_agent", "string"],
        ["elb_status_code", "int"],
        ["target_processing_time", "double"],
        ["sent_bytes", "bigint"],
        ["path", "string"],
        ["switcher", "string"],
        ["calling_app", "string"],
        ["search_lat", "double"],
        ["search_lng", "double"],
        ["geo_width_km", "double"],
        ["geo_width_mi", "double"],
        ["app", "string"],
        ["app_version", "string"],
        ["app_os", "string"],
        ["request_kind", "string"],
        ["geo_country", "string"],
        ["geo_region", "string"],
        ["geo_city", "string"],
        ["geo_lat", "double"],
        ["geo_lng", "double"],
      ]
      content {
        name = columns.value[0]
        type = columns.value[1]
      }
    }
  }
}

data "archive_file" "stats_lambda" {
  type        = "zip"
  source_file = "stats_lambda.py"
  output_path = "stats_lambda.zip"
}

resource "aws_lambda_function" "stats" {
  filename                       = "stats_lambda.zip"
  function_name                  = "AggregatorStats"
  role                           = aws_iam_role.stats_lambda.arn
  handler                        = "stats_lambda.lambda_handler"
  source_code_hash               = data.archive_file.stats_lambda.output_base64sha256
  runtime                        = "python3.13"
  architectures                  = ["arm64"]
  memory_size                    = 256
  timeout                        = 900
  reserved_concurrent_executions = 1

  environment {
    variables = {
      WORKGROUP     = aws_athena_workgroup.aggregator.name
      DATABASE      = aws_glue_catalog_database.aggregator_logs.name
      VIEW_QUERY_ID = aws_athena_named_query.create_requests_view.id
      STATS_BUCKET  = aws_s3_bucket.stats.id
    }
  }
}

resource "aws_cloudwatch_log_group" "stats_lambda" {
  name              = "/aws/lambda/AggregatorStats"
  retention_in_days = 14
}

# 03:00 UTC: the ALB delivers the last logs for a day within minutes of midnight UTC.
resource "aws_cloudwatch_event_rule" "stats_daily" {
  name                = "aggregator-stats-daily"
  schedule_expression = "cron(0 3 * * ? *)"
}

resource "aws_cloudwatch_event_target" "stats_daily" {
  rule = aws_cloudwatch_event_rule.stats_daily.name
  arn  = aws_lambda_function.stats.arn
}

resource "aws_lambda_permission" "stats_daily" {
  statement_id  = "AggregatorStatsDaily"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.stats.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.stats_daily.arn
}

# 03:30 UTC: write yesterday's Parquet facts, after the 03:00 JSON rollup. Decoupled so a JSON
# backfill stays fast; facts are backfilled with {"facts": true, "start": "...", "end": "..."}.
resource "aws_cloudwatch_event_rule" "stats_facts" {
  name                = "aggregator-stats-facts"
  schedule_expression = "cron(30 3 * * ? *)"
}

resource "aws_cloudwatch_event_target" "stats_facts" {
  rule  = aws_cloudwatch_event_rule.stats_facts.name
  arn   = aws_lambda_function.stats.arn
  input = jsonencode({ facts = true })
}

resource "aws_lambda_permission" "stats_facts" {
  statement_id  = "AggregatorStatsFacts"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.stats.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.stats_facts.arn
}

# DB-IP publishes a new file at the start of each month.
resource "aws_cloudwatch_event_rule" "stats_geoip" {
  name                = "aggregator-stats-geoip"
  schedule_expression = "cron(0 1 3 * ? *)"
}

resource "aws_cloudwatch_event_target" "stats_geoip" {
  rule  = aws_cloudwatch_event_rule.stats_geoip.name
  arn   = aws_lambda_function.stats.arn
  input = jsonencode({ geoip = true })
}

resource "aws_lambda_permission" "stats_geoip" {
  statement_id  = "AggregatorStatsGeoip"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.stats.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.stats_geoip.arn
}

resource "aws_iam_role" "stats_lambda" {
  name = "aggregator_stats_lambda"
  assume_role_policy = jsonencode(
    {
      Version = "2012-10-17"
      Statement = [
        {
          Action = "sts:AssumeRole"
          Principal = {
            Service = "lambda.amazonaws.com"
          }
          Effect = "Allow"
        }
      ]
  })
}

resource "aws_iam_role_policy" "stats_lambda" {
  name = "aggregator_stats_lambda"
  role = aws_iam_role.stats_lambda.id
  policy = jsonencode(
    {
      Version = "2012-10-17"
      Statement = [
        {
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "${aws_cloudwatch_log_group.stats_lambda.arn}:*"
        },
        {
          Effect = "Allow"
          Action = [
            "athena:StartQueryExecution",
            "athena:GetQueryExecution",
            "athena:GetQueryResults",
            "athena:GetNamedQuery"
          ]
          Resource = aws_athena_workgroup.aggregator.arn
        },
        {
          # Table create/delete is for the view and the geoip CTAS.
          Effect = "Allow"
          Action = [
            "glue:GetDatabase",
            "glue:GetTable",
            "glue:GetTables",
            "glue:GetPartitions",
            "glue:CreateTable",
            "glue:UpdateTable",
            "glue:DeleteTable"
          ]
          Resource = [
            "arn:aws:glue:us-east-1:${data.aws_caller_identity.current.account_id}:catalog",
            aws_glue_catalog_database.aggregator_logs.arn,
            "arn:aws:glue:us-east-1:${data.aws_caller_identity.current.account_id}:table/${aws_glue_catalog_database.aggregator_logs.name}/*"
          ]
        },
        {
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
          Resource = [data.aws_s3_bucket.alb_logs.arn, "${data.aws_s3_bucket.alb_logs.arn}/AWSLogs/*"]
        },
        {
          Effect = "Allow"
          Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation", "s3:AbortMultipartUpload"]
          Resource = [
            aws_s3_bucket.athena_results.arn, "${aws_s3_bucket.athena_results.arn}/*",
            aws_s3_bucket.stats.arn, "${aws_s3_bucket.stats.arn}/*"
          ]
        }
      ]
  })
}
