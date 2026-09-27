"""
Daily traffic rollup: runs a handful of Athena queries over one day of ALB logs and
writes the aggregates to S3 as JSON for the stats frontend.

  stats/daily/YYYY-MM-DD.json   everything for that day
  stats/index.json              one summary row per day, for trend charts
  stats/monthly/YYYY-MM.json    the month's daily files merged (no Athena), for long ranges;
                                rebuilt for every month a run touches, or all of them with {"monthly": true}
  facts/day=YYYY-MM-DD/*.parquet  one raw row per request (Glue table aggregator_facts) for ad-hoc DuckDB/Athena

The JSON stats write no client IPs, only counts, with coordinates rounded to 1 decimal. The facts/ Parquet is
the private analytics layer: it keeps client IPs and exact coordinates. CloudFront serves only app/ and
stats/, so facts/ is reachable only with S3 credentials.

The headline counts in index.json exclude EXCLUDED_CITIES (Google's Mountain View, which spikes after every
Android release); the geo/clients/user-agent breakdowns keep them, and the frontend filters the same list.

Invoke with no payload for yesterday's JSON rollup (UTC), or backfill with
  {"day": "2026-09-18"}  or  {"start": "2026-09-06", "end": "2026-09-18"}

{"facts": true} (scheduled daily, after the rollup) writes the Parquet facts for yesterday; back it
fill the same way, {"facts": true, "start": "...", "end": "..."}. It is decoupled from the JSON rollup
so a JSON backfill stays fast and facts can go as far back as the ALB logs, independent of the dashboard.

{"geoip": true} (scheduled monthly) refreshes the GeoIP table from DB-IP's free
"IP to City Lite" CSV (CC BY 4.0: the frontend must credit "IP Geolocation by DB-IP").

Ranges are capped at MAX_BACKFILL_DAYS per invocation; loop for longer spans.
"""
import json
import os
import time
import urllib.error
import urllib.request
from datetime import date, datetime, timedelta, timezone

import boto3

athena = boto3.client("athena")
s3 = boto3.client("s3")
glue = boto3.client("glue")

WORKGROUP = os.environ["WORKGROUP"]
DATABASE = os.environ["DATABASE"]
VIEW_QUERY_ID = os.environ["VIEW_QUERY_ID"]
STATS_BUCKET = os.environ["STATS_BUCKET"]
MAX_BACKFILL_DAYS = 45
GEOIP_URL = "https://download.db-ip.com/free/dbip-city-lite-{month}.csv.gz"
GEOIP_USER_AGENT = "aggregator-stats/1.0 (+https://github.com/bmlt-enabled/aggregator)"
GEOIP_RAW_KEY = "geoip/raw/dbip-city-lite.csv.gz"
GEOIP_TABLE_PREFIX = "geoip/table/"
# Queries allowed to fail without failing the day (geo needs the monthly GeoIP load to have run once).
OPTIONAL = {"geo"}
# Our apps, as the view's `app` column names them (athena.tf): field prefix -> (app, first day with traffic).
# Every per-app number is written as <prefix>_<field>; files from before an app was added just lack its fields.
APPS = {
    "app": ("NAMeetingsNearMe", date(2026, 9, 6)),
    "bmlt_search": ("BMLTSearch", date(2026, 9, 20)),
}
# Queries that only look at app traffic. Before the first launch they can only return zeros, and
# app_active's 30-day window is most of a day's scan, so backfills skip them.
APP_LAUNCH = min(launch for _, launch in APPS.values())
APP_ONLY = {"app_active", "app_versions"}
# (country, region, city) whose client IPs are dropped from the summary/index counts: office or cloud
# locations that are bots, not users. Google's Mountain View spikes after every Android release (Play
# pre-launch testing and review). Only the headline numbers (index.json) exclude these; the geo/clients/
# user-agent breakdowns keep them, and the frontend drops the same list from its place lists and map
# (src/lib/data.ts EXCLUDED_PLACES in aggregator-stats — keep the two in sync). Needs the GeoIP table:
# when it is absent the exclusion is silently skipped, like the geo query.
EXCLUDED_CITIES = [("US", "California", "Mountain View")]
# Per-request facts UNLOADed to Parquet under this prefix, partitioned by day, for ad-hoc DuckDB/Athena
# queries (Glue table aggregator_facts in stats.tf). Private analytics layer: keeps client IPs and exact
# coordinates (CloudFront doesn't serve facts/), unlike the JSON stats.
FACTS_PREFIX = "facts/"

IP_INT = """(CAST(split_part({c}, '.', 1) AS bigint) * 16777216 + CAST(split_part({c}, '.', 2) AS bigint) * 65536
             + CAST(split_part({c}, '.', 3) AS bigint) * 256 + CAST(split_part({c}, '.', 4) AS bigint))"""

# A range join is a cross join in Athena, so each range is copied into every /16 "bucket" it
# touches; lookups then equi-join on bucket and only range-check the handful of rows in it.
GEOIP_CTAS = """
    CREATE TABLE geoip WITH (format = 'PARQUET', external_location = '{location}') AS
    WITH v4 AS (
      SELECT {ip_from} AS ip_from, {ip_to} AS ip_to, country, region, city,
             TRY_CAST(lat AS double) AS lat, TRY_CAST(lng AS double) AS lng
      FROM geoip_raw
      WHERE ip_start NOT LIKE '%:%' AND country <> 'ZZ'
    )
    SELECT b AS bucket, ip_from, ip_to, country, region, city, lat, lng
    FROM v4 CROSS JOIN UNNEST(sequence(ip_from / 65536, ip_to / 65536)) AS t(b)
"""


def per_app(template, sep=",\n               "):
    """The template once per app, with {name} and {p} (the field prefix) filled in."""
    return sep.join(template.format(name=name, p=prefix) for prefix, (name, _) in APPS.items())


# {day} is the ALB partition value (yyyy/MM/dd); {day7}/{day30} are trailing-window starts.
QUERIES = {
    # {excl_*} drop the EXCLUDED_CITIES client IPs (filled by rollup; empty when GeoIP is absent).
    "summary": """
        WITH day_rows AS (SELECT * FROM aggregator_requests WHERE day = '{day}'){excl_cte}
        SELECT count(*) AS requests,
               count(DISTINCT client_ip) AS unique_ips,
               count_if(elb_status_code >= 500) AS errors_5xx,
               -- 500 is the application failing; the rest of errors_5xx (502/503/504) is the ALB finding no healthy target
               count_if(elb_status_code = 500) AS errors_500,
               count(DISTINCT user_agent) AS unique_user_agents,
               round(approx_percentile(target_processing_time, 0.95), 3) AS p95_seconds,
               """ + per_app("""count_if(app = '{name}') AS {p}_requests,
               count(DISTINCT IF(app = '{name}', client_ip)) AS {p}_unique_ips,
               count(DISTINCT IF(app = '{name}' AND app_os = 'iOS', client_ip)) AS {p}_unique_ips_ios,
               count(DISTINCT IF(app = '{name}' AND app_os = 'Android', client_ip)) AS {p}_unique_ips_android,
               count_if(app = '{name}' AND elb_status_code >= 500) AS {p}_errors_5xx,
               count_if(app = '{name}' AND elb_status_code = 500) AS {p}_errors_500""") + """
        FROM day_rows r {excl_join}
        {excl_where}
    """,
    "app_active": """
        WITH win AS (SELECT * FROM aggregator_requests WHERE day BETWEEN '{day30}' AND '{day}' AND app IS NOT NULL){excl_cte_win}
        SELECT """ + per_app("""count(DISTINCT IF(app = '{name}' AND day >= '{{day7}}', client_ip)) AS {p}_unique_ips_7d,
               count(DISTINCT IF(app = '{name}', client_ip)) AS {p}_unique_ips_30d""") + """
        FROM win r {excl_join}
        {excl_where}
    """,
    "clients": """
        SELECT coalesce(app, calling_app, '(none)') AS client,
               count(*) AS requests, count(DISTINCT client_ip) AS unique_ips
        FROM aggregator_requests WHERE day = '{day}'
        GROUP BY 1 ORDER BY requests DESC LIMIT 50
    """,
    # ~540 distinct a day; 300 is ~97% of requests and reaches down to ~4 requests, so small crawlers are searchable.
    "user_agents": """
        SELECT user_agent, count(*) AS requests, count(DISTINCT client_ip) AS unique_ips,
               count_if(elb_status_code >= 500) AS errors_5xx
        FROM aggregator_requests WHERE day = '{day}'
        GROUP BY 1 ORDER BY requests DESC LIMIT 300
    """,
    "app_versions": """
        SELECT app, app_os AS os, app_version AS version, count(*) AS requests, count(DISTINCT client_ip) AS unique_ips
        FROM aggregator_requests WHERE day = '{day}' AND app IS NOT NULL
        GROUP BY 1, 2, 3 ORDER BY requests DESC
    """,
    # scope is the app's field prefix, or 'other'.
    "request_kinds": """
        SELECT CASE app """ + per_app("WHEN '{name}' THEN '{p}'", " ") + """ ELSE 'other' END AS scope, request_kind,
               count(*) AS requests, count(DISTINCT client_ip) AS unique_ips,
               count_if(elb_status_code >= 500) AS errors_5xx,
               round(approx_percentile(target_processing_time, 0.5), 3) AS p50_seconds,
               round(approx_percentile(target_processing_time, 0.95), 3) AS p95_seconds
        FROM aggregator_requests WHERE day = '{day}'
        GROUP BY 1, 2 ORDER BY requests DESC
    """,
    "hourly": """
        SELECT hour(ts) AS hour, count(*) AS requests,
               """ + per_app("count_if(app = '{name}') AS {p}_requests") + """
        FROM aggregator_requests WHERE day = '{day}'
        GROUP BY 1 ORDER BY 1
    """,
    # 1 decimal place is ~11km: areas, not people.
    "locations": """
        SELECT round(lat, 1) AS lat, round(lng, 1) AS lng, count(*) AS searches,
               """ + per_app("count_if(app = '{name}') AS {p}_searches") + """
        FROM aggregator_requests
        WHERE day = '{day}' AND lat BETWEEN -90 AND 90 AND lng BETWEEN -180 AND 180
        GROUP BY 1, 2 ORDER BY searches DESC LIMIT 3000
    """,
    # Where requests come from by client IP (rough: mobile carriers route through a few cities).
    "geo": """
        WITH ips AS (
          SELECT client_ip, count(*) AS requests,
               """ + per_app("count_if(app = '{name}') AS {p}_requests") + """
          FROM aggregator_requests
          WHERE day = '{day}' AND client_ip NOT LIKE '%:%'
          GROUP BY 1
        ),
        n AS (SELECT *, {ip_int} AS ip_int FROM ips)
        SELECT coalesce(g.country, '??') AS country, g.region, g.city,
               round(g.lat, 1) AS lat, round(g.lng, 1) AS lng,
               sum(n.requests) AS requests, count(*) AS unique_ips,
               """ + per_app("sum(n.{p}_requests) AS {p}_requests, count_if(n.{p}_requests > 0) AS {p}_unique_ips") + """
        FROM n LEFT JOIN geoip g ON g.bucket = n.ip_int / 65536 AND n.ip_int BETWEEN g.ip_from AND g.ip_to
        GROUP BY 1, 2, 3, 4, 5 ORDER BY requests DESC LIMIT 3000
    """,
}

# One raw Parquet row per request for ad-hoc querying (Glue table aggregator_facts). This is the private
# analytics layer: it keeps client IPs and exact coordinates, unlike the JSON stats. It lives under facts/
# in the stats bucket, which CloudFront does not serve (only app/ and stats/), so it stays S3-only.
# {geo_*} add the GeoIP columns when the table exists.
FACTS_UNLOAD = """
    UNLOAD (
      WITH day_rows AS (SELECT * FROM aggregator_requests WHERE day = '{day}'){geo_cte}
      SELECT client_ip, ts, CAST(hour(ts) AS integer) AS hour, domain_name, user_agent, elb_status_code,
             target_processing_time, sent_bytes, path, switcher, calling_app,
             r.lat AS search_lat, r.lng AS search_lng, geo_width_km, geo_width_mi,
             app, app_version, app_os, request_kind{geo_cols}
      FROM day_rows r {geo_join}
    )
    TO '{location}'
    WITH (format = 'PARQUET', compression = 'SNAPPY')
"""


def excluded_values():
    """EXCLUDED_CITIES as a SQL VALUES list of (country, region, city) rows."""
    return ", ".join("('%s', '%s', '%s')" % city for city in EXCLUDED_CITIES)


def mv_cte(base):
    """A `, mv AS (...)` CTE of the EXCLUDED_CITIES client IPs among `base`'s rows, for an anti-join."""
    return f""", mv AS (
              SELECT DISTINCT ip
              FROM (SELECT client_ip AS ip, {IP_INT.format(c='client_ip')} AS ip_int FROM {base} WHERE client_ip NOT LIKE '%:%') d
              JOIN geoip g ON g.bucket = d.ip_int / 65536 AND d.ip_int BETWEEN g.ip_from AND g.ip_to
              WHERE (g.country, g.region, g.city) IN (VALUES {excluded_values()}))"""


def facts_geo(geoip_present):
    """(cte, columns, join) that add GeoIP columns to the facts UNLOAD, or NULL columns when absent."""
    if not geoip_present:
        return ("", (", CAST(NULL AS varchar) AS geo_country, CAST(NULL AS varchar) AS geo_region,"
                     " CAST(NULL AS varchar) AS geo_city, CAST(NULL AS double) AS geo_lat, CAST(NULL AS double) AS geo_lng"), "")
    cte = f""", ip_geo AS (
              SELECT ip, arbitrary(g.country) AS country, arbitrary(g.region) AS region, arbitrary(g.city) AS city,
                     arbitrary(g.lat) AS lat, arbitrary(g.lng) AS lng
              FROM (SELECT client_ip AS ip, {IP_INT.format(c='client_ip')} AS ip_int FROM day_rows WHERE client_ip NOT LIKE '%:%') d
              JOIN geoip g ON g.bucket = d.ip_int / 65536 AND d.ip_int BETWEEN g.ip_from AND g.ip_to
              GROUP BY ip)"""
    cols = (", x.country AS geo_country, x.region AS geo_region, x.city AS geo_city,"
            " x.lat AS geo_lat, x.lng AS geo_lng")
    return (cte, cols, "LEFT JOIN ip_geo x ON x.ip = r.client_ip")


def geoip_ready():
    """Whether the GeoIP table exists yet (built by the monthly {"geoip": true} run)."""
    try:
        glue.get_table(DatabaseName=DATABASE, Name="geoip")
        return True
    except glue.exceptions.EntityNotFoundException:
        return False


def start(sql):
    return athena.start_query_execution(
        QueryString=sql,
        WorkGroup=WORKGROUP,
        QueryExecutionContext={"Database": DATABASE},
    )["QueryExecutionId"]


def wait(query_id):
    while True:
        status = athena.get_query_execution(QueryExecutionId=query_id)["QueryExecution"]["Status"]
        if status["State"] == "SUCCEEDED":
            return
        if status["State"] in ("FAILED", "CANCELLED"):
            raise RuntimeError(f"Athena query {query_id} {status['State']}: {status.get('StateChangeReason')}")
        time.sleep(1)


def convert(value, athena_type):
    if value is None:
        return None
    if athena_type in ("bigint", "integer", "int", "smallint", "tinyint"):
        return int(value)
    if athena_type in ("double", "float", "real", "decimal"):
        return float(value)
    return value


def rows(query_id):
    out, columns = [], None
    for page in athena.get_paginator("get_query_results").paginate(QueryExecutionId=query_id):
        if columns is None:
            columns = [(c["Name"], c["Type"]) for c in page["ResultSet"]["ResultSetMetadata"]["ColumnInfo"]]
            page["ResultSet"]["Rows"].pop(0)  # header row
        for row in page["ResultSet"]["Rows"]:
            out.append({
                name: convert(cell.get("VarCharValue"), athena_type)
                for (name, athena_type), cell in zip(columns, row["Data"])
            })
    return out


def rollup(day, geoip_present):
    fmt = "%Y/%m/%d"
    # Anti-join the excluded cities out of the headline counts, or leave the queries plain when GeoIP is absent.
    join = "LEFT JOIN mv ON mv.ip = r.client_ip" if geoip_present else ""
    where = "WHERE mv.ip IS NULL" if geoip_present else ""
    params = {
        "ip_int": IP_INT.format(c="client_ip"),
        "day": day.strftime(fmt),
        "day7": (day - timedelta(days=6)).strftime(fmt),
        "day30": (day - timedelta(days=29)).strftime(fmt),
        "excl_cte": mv_cte("day_rows") if geoip_present else "",
        "excl_cte_win": mv_cte("win") if geoip_present else "",
        "excl_join": join,
        "excl_where": where,
    }
    queries = {name: sql for name, sql in QUERIES.items() if day >= APP_LAUNCH or name not in APP_ONLY}
    running = {name: start(sql.format(**params)) for name, sql in queries.items()}
    results = {}
    for name, query_id in running.items():
        try:
            wait(query_id)
        except RuntimeError as e:
            if name not in OPTIONAL:
                raise
            print(f"skipping {name}: {e}")
            results[name] = []
            continue
        results[name] = rows(query_id)

    results.setdefault("app_versions", [])
    app_active = results.pop("app_active", [{f"{p}_unique_ips_{window}": 0 for p in APPS for window in ("7d", "30d")}])[0]
    summary = {**results.pop("summary")[0], **app_active}
    doc = {
        "day": day.isoformat(),
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "summary": summary,
        **results,
    }
    put(f"stats/daily/{day.isoformat()}.json", doc)
    return summary


def clear_prefix(prefix):
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=STATS_BUCKET, Prefix=prefix):
        objs = [{"Key": o["Key"]} for o in page.get("Contents", [])]
        if objs:
            s3.delete_objects(Bucket=STATS_BUCKET, Delete={"Objects": objs})


def write_facts(day, geoip_present):
    """UNLOAD one day of requests to Parquet for ad-hoc querying (aggregator_facts)."""
    prefix = f"{FACTS_PREFIX}day={day.isoformat()}/"
    clear_prefix(prefix)  # UNLOAD needs an empty destination, and this makes a backfill idempotent.
    geo_cte, geo_cols, geo_join = facts_geo(geoip_present)
    wait(start(FACTS_UNLOAD.format(
        day=day.strftime("%Y/%m/%d"),
        location=f"s3://{STATS_BUCKET}/{prefix}",
        geo_cte=geo_cte, geo_cols=geo_cols, geo_join=geo_join,
    )))


def put(key, doc):
    s3.put_object(
        Bucket=STATS_BUCKET,
        Key=key,
        Body=json.dumps(doc, separators=(",", ":")).encode(),
        ContentType="application/json",
        CacheControl="max-age=300",
    )


def get(key):
    return json.loads(s3.get_object(Bucket=STATS_BUCKET, Key=key)["Body"].read())


def load_index():
    try:
        return get("stats/index.json")
    except s3.exceptions.NoSuchKey:
        return {"days": []}


def update_index(summaries):
    index = load_index()
    by_day = {d["day"]: d for d in index["days"]}
    for day, summary in summaries.items():
        by_day[day] = {"day": day, **summary}
    index["days"] = [by_day[d] for d in sorted(by_day)]
    index["generated_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    put("stats/index.json", index)
    return index


# Monthly files: list name -> (key fields, summed fields). Distinct-IP counts can't be added
# across days, so they are left out. request_kinds is merged separately for its latencies.
MONTHLY = {
    "clients": (("client",), ("requests",)),
    "user_agents": (("user_agent",), ("requests", "errors_5xx")),
    "app_versions": (("app", "os", "version"), ("requests",)),
    "hourly": (("hour",), ("requests", *(f"{p}_requests" for p in APPS))),
    "locations": (("lat", "lng"), ("searches", *(f"{p}_searches" for p in APPS))),
    "geo": (("country", "region", "city", "lat", "lng"), ("requests", "ip_days", *(f"{p}_requests" for p in APPS), *(f"{p}_ip_days" for p in APPS))),
}
# A place's distinct IPs can't be added across days, but its IP-days can: the sum of each day's count. Divided by
# the days in a range that is "average daily IPs", which ranks places by people rather than by requests, so one
# busy server no longer puts its datacenter's city at the top. Summed field -> the daily field it is summed from.
MONTHLY_FROM = {"ip_days": "unique_ips", **{f"{p}_ip_days": f"{p}_unique_ips" for p in APPS}}
MONTHLY_LIMIT = 3000


def build_month(month, days):
    """Merge a month's daily files into stats/monthly/YYYY-MM.json so long ranges load one file per month."""
    totals = {name: {} for name in MONTHLY}
    kinds = {}
    for day in days:
        doc = get(f"stats/daily/{day}.json")
        for name, (keys, sums) in MONTHLY.items():
            for item in doc.get(name, []):
                total = totals[name].setdefault(tuple(item.get(k) for k in keys), dict.fromkeys(sums, 0))
                for field in sums:
                    total[field] += item.get(MONTHLY_FROM.get(field, field)) or 0  # older files lack newer apps' fields
        for item in doc["request_kinds"]:
            k = kinds.setdefault((item["scope"], item["request_kind"]), {"requests": 0, "errors_5xx": 0, "timed": 0, "p50": 0, "p95": 0})
            k["requests"] += item["requests"]
            k["errors_5xx"] += item["errors_5xx"]
            if item["p50_seconds"] is not None and item["p95_seconds"] is not None:
                k["timed"] += item["requests"]
                k["p50"] += item["p50_seconds"] * item["requests"]
                k["p95"] += item["p95_seconds"] * item["requests"]

    merged = {}
    for name, (keys, sums) in MONTHLY.items():
        items = [{**dict(zip(keys, key)), **total} for key, total in totals[name].items()]
        merged[name] = sorted(items, key=lambda i: -i[sums[0]])[:MONTHLY_LIMIT]
    merged["hourly"].sort(key=lambda i: i["hour"])
    # Latencies are request-weighted means of the daily percentiles: an approximation, like the frontend's.
    merged["request_kinds"] = sorted(
        (
            {
                "scope": scope,
                "request_kind": kind,
                "requests": k["requests"],
                "errors_5xx": k["errors_5xx"],
                "p50_seconds": round(k["p50"] / k["timed"], 3) if k["timed"] else None,
                "p95_seconds": round(k["p95"] / k["timed"], 3) if k["timed"] else None,
            }
            for (scope, kind), k in kinds.items()
        ),
        key=lambda i: -i["requests"],
    )
    put(f"stats/monthly/{month}.json", {
        "month": month,
        "days": days,
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        **merged,
    })


def build_months(index, months=None):
    by_month = {}
    for d in index["days"]:
        by_month.setdefault(d["day"][:7], []).append(d["day"])
    for month in sorted(months or by_month):
        build_month(month, by_month[month])
        print(f"monthly {month}: {len(by_month[month])} days")
    return sorted(months or by_month)


def refresh_geoip():
    today = datetime.now(timezone.utc).date()
    for month in (today, today.replace(day=1) - timedelta(days=1)):  # this month's file may not be out yet
        url = GEOIP_URL.format(month=month.strftime("%Y-%m"))
        try:
            # DB-IP answers 403 to the default Python-urllib user agent.
            response = urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": GEOIP_USER_AGENT}), timeout=60)
            break
        except urllib.error.HTTPError as e:
            print(f"{url}: {e}")
    else:
        raise RuntimeError("no DB-IP download available")
    with response:
        s3.upload_fileobj(response, STATS_BUCKET, GEOIP_RAW_KEY)

    # CTAS needs an empty location, so each load gets its own prefix and the old ones are removed after.
    prefix = f"{GEOIP_TABLE_PREFIX}{int(time.time())}/"
    wait(start("DROP TABLE IF EXISTS geoip"))
    wait(start(GEOIP_CTAS.format(
        location=f"s3://{STATS_BUCKET}/{prefix}",
        ip_from=IP_INT.format(c="ip_start"),
        ip_to=IP_INT.format(c="ip_end"),
    )))
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=STATS_BUCKET, Prefix=GEOIP_TABLE_PREFIX):
        stale = [{"Key": o["Key"]} for o in page.get("Contents", []) if not o["Key"].startswith(prefix)]
        if stale:
            s3.delete_objects(Bucket=STATS_BUCKET, Delete={"Objects": stale})
    return {"geoip": url}


def event_days(event):
    """The [first, last] range an event asks for (yesterday UTC by default), capped at MAX_BACKFILL_DAYS."""
    if "start" in event:
        first, last = date.fromisoformat(event["start"]), date.fromisoformat(event.get("end", event["start"]))
    elif "day" in event:
        first = last = date.fromisoformat(event["day"])
    else:
        first = last = datetime.now(timezone.utc).date() - timedelta(days=1)
    if not 0 <= (last - first).days < MAX_BACKFILL_DAYS:
        raise ValueError(f"range must be 1-{MAX_BACKFILL_DAYS} days")
    days, day = [], first
    while day <= last:
        days.append(day)
        day += timedelta(days=1)
    return days


def recreate_view():
    """(Re)create the requests view from the saved query so its SQL lives in one place (athena.tf)."""
    view_sql = athena.get_named_query(NamedQueryId=VIEW_QUERY_ID)["NamedQuery"]["QueryString"]
    wait(start(view_sql))


def lambda_handler(event, context):
    event = event or {}
    if event.get("geoip"):
        return refresh_geoip()
    if event.get("monthly"):
        return {"months": build_months(load_index())}

    days = event_days(event)
    recreate_view()
    # GeoIP presence doesn't change mid-run: check once and reuse for the excluded-city filter and facts.
    geoip_present = geoip_ready()

    if event.get("facts"):
        for day in days:
            write_facts(day, geoip_present)
            print(f"facts {day.isoformat()}")
        return {"facts": [d.isoformat() for d in days]}

    summaries = {}
    for day in days:
        summaries[day.isoformat()] = rollup(day, geoip_present)
        print(json.dumps({"day": day.isoformat(), **summaries[day.isoformat()]}))
    index = update_index(summaries)
    build_months(index, {day[:7] for day in summaries})
    return {"days": list(summaries)}
