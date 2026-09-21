# Using the BMLT aggregator responsibly

The BMLT aggregator (`https://aggregator.bmltenabled.org/main_server/`) collects the meeting lists of every
participating Narcotics Anonymous BMLT root server into one place, so an app or a website can find meetings
anywhere with one API. It is free to use, needs no key, and is run by volunteers on a small budget.

This guide is for anyone who pulls data from it: app developers, website owners, and people building
meeting directories. Following it keeps the service fast for the person who is looking for a meeting right
now, which is the only reason it exists.

Questions, or a use that does not fit what is described here: **admin@bmlt.app**. We would much rather help
you get the data efficiently than block anyone.

## The short version

1. **Say who you are.** Send a `User-Agent` with your project's name, a version and a way to reach you.
2. **The data changes at most every 4 hours.** Do not fetch the same thing more often than that. Cache it.
3. **Ask only for what you need**: filter the search, and trim the fields with `data_field_key`.
4. **Cache the big lists for a day**: formats and service bodies hardly ever change.
5. **Want everything? Download the daily export** instead of crawling the API. It is one 4 MB file.

## How the aggregator works

- An import runs **about every 4 hours** and copies each root server's meetings, formats and service bodies.
  Between imports nothing changes, so a second identical request within that window returns the same bytes.
- `GET /main_server/api/v1/rootservers` lists the root servers with a `lastSuccessfulImport` time for each.
  It is small (about 80 KB). If that time has not moved since your last pull, that server's data has not
  changed.
- Responses are **not compressed** and carry **no `ETag` or `Last-Modified`**, so the server cannot tell you
  "not modified". Caching is up to the client, and response size is exactly what travels over the wire.
- It sends `Access-Control-Allow-Origin: *`, so browser apps can call it directly.

## 1. Identify yourself

Set a descriptive `User-Agent`, and add `callingApp` to the query string:

```
User-Agent: MyMeetingFinder/1.4 (+https://example.org/about; admin@example.org)
…&callingApp=my_meeting_finder
```

- A contact is what lets us write to you instead of blocking you when something goes wrong. A user agent
  that says "contact in the README" of a private repository is not a contact.
- Do not pretend to be a browser. It gains you nothing here.
- Browsers and some mobile HTTP stacks will not let you set `User-Agent`. `callingApp` works everywhere.

## 2. Do not re-fetch what has not changed

| What                                      | How often it changes        | Refresh it                         |
|-------------------------------------------|-----------------------------|------------------------------------|
| Meetings                                  | at most every 4 hours       | every 4 to 6 hours at the most     |
| Formats (`GetFormats`)                    | a few times a year          | once a day, or once a week         |
| Service bodies (`GetServiceBodies`)       | rarely                      | once a day                         |
| Root server list (`/api/v1/rootservers`)  | with each import            | every few hours                    |
| Server info (`GetServerInfo`)             | on server upgrades          | once a day                         |

- **Websites and plugins:** cache on your server. A page that fetches the 350 KB service body list on every
  view is the most common way a small site becomes one of our largest clients. In the bread plugin this is
  the `cache_time` setting: set it to 24 hours, not 0.
- **Mobile apps:** keep formats and other reference data on the device between launches. Phones restart apps
  constantly, so "cached for this session" means "fetched on nearly every open".
- **Tools that others call through you** (an MCP server, a proxy): cache the root server list and reference
  data for at least an hour on your side.

## 3. Ask only for what you need

**Filter the search.** A `GetSearchResults` with no filter returns an empty list on the aggregator, on
purpose. Use one of:

| Need                          | Parameters                                                                 |
|-------------------------------|----------------------------------------------------------------------------|
| Meetings near a point         | `lat_val`, `long_val` and `geo_width_km` (or `geo_width` in miles)          |
| The nearest N meetings        | the same, with a **negative** width: `geo_width_km=-25` means "nearest 25" |
| One area or region            | `services=<id>`, with `recursive=1` to include the bodies beneath it       |
| One root server               | `root_server_ids[]=<id>`                                                    |
| Specific meetings             | `meeting_ids[]=<id>&meeting_ids[]=<id>`                                     |
| Online meetings               | `venue_types[]=2&venue_types[]=3` (a repeated key, not `2,3`)               |
| A day or a time window        | `weekdays[]=`, `StartsAfterH`/`StartsAfterM`, `StartsBeforeH`/`StartsBeforeM` |

**Trim the fields.** `data_field_key` returns only the fields you name:

```
…switcher=GetSearchResults&lat_val=32.78&long_val=-79.93&geo_width_km=25
   &data_field_key=id_bigint,meeting_name,weekday_tinyint,start_time,latitude,longitude
```

A full meeting record has about 45 fields. A map that needs an id and two coordinates is around six times
smaller when trimmed, and because nothing is compressed that is the real saving on someone's phone.

- The commas must reach the server as commas (or `%2C`). If your HTTP library encodes an already-encoded URL
  they arrive as `%252C`, the server does not recognise the field name, and it **silently returns every
  field**. Check one request in your logs. (CapacitorHttp on iOS does this unless
  `shouldEncodeUrlParams: false` is set.)

**Get formats with the meetings.** Add `get_used_formats=1` to a search and the response becomes
`{ "meetings": […], "formats": […] }`, holding just the formats those meetings use. It costs the server
nothing extra and replaces a separate `GetFormats` call. If you do need `GetFormats`, pass
`format_ids=1,2,3`: two formats are about 600 bytes, the unfiltered list is about 400 KB.

**Filter the reference lists too.** `GetServiceBodies&root_server_ids[]=1` is about 12 KB; the unfiltered
list is about 350 KB.

**Page large results.** `page_size=500&page_num=1`, then `page_num=2`, and so on until a page comes back
short.

### Things that are slow or do not work

- **Whole states, provinces or cities by text**: `meeting_key=location_province&meeting_key_value=CA`, or
  `location_municipality`, takes 5 to 7 seconds and returns up to a megabyte. Use a lat/long search or a
  service body id instead.
- **Very wide radius searches** (`geo_width=800`) return thousands of meetings and megabytes. Search where
  your user is.
- **Text search** (`SearchString`) is too slow on the aggregator to sit behind a search box.
- **A whole large root server in one request.** The largest ones time out or fail. Page it.
- `lang_enum` and `meeting_key` each take **one** value on a search; an array returns a 422.
  (`meeting_key_value[]` may be an array.)
- `lang_enum` on a search also decides which format ids are listed on each meeting: formats with no
  translation in that language are left off. If you filter by format id, search with `lang_enum=en` and
  translate the names separately with `GetFormats&format_ids=…&lang_enum=xx`.

## 4. If you need a copy of everything

Building a directory or an index is a legitimate use. It is also where almost all of the aggregator's load
came from: a handful of bulk copiers used more capacity than all the apps and websites together. So there is
now a **daily export**, and it is the right way to get everything:

Everything is under `https://cdn.aws.bmlt.app/aggregator/`:

| File                               | What it holds                                                     |
|------------------------------------|-------------------------------------------------------------------|
| `manifest.json`                    | start here: every file with its size, checksum and record count   |
| `meetings.ndjson.gz`               | every current meeting, one JSON object per line                   |
| `meetings/root-<id>.ndjson.gz`     | the same, one file per root server                                |
| `formats.json.gz`                  | formats                                                           |
| `service_bodies.json.gz`           | service bodies                                                    |
| `root_servers.json`                | root servers, with `lastSuccessfulImport`                         |

```bash
curl -s https://cdn.aws.bmlt.app/aggregator/meetings.ndjson.gz | gunzip | head -1
```

- About 35,000 meetings in about 4 MB, regenerated **once a day around 05:20 UTC**.
- **Each line has exactly the fields `GetSearchResults` returns**, so code written against the API reads it
  unchanged.
- It is served from a CDN, not from the aggregator, so downloading it costs the service nothing. Poll it as
  often as you like **with `If-None-Match`**: a file whose data did not change keeps its `ETag` and answers
  `304` with no body.
- `manifest.json` lists every file with its size, SHA-256 and record count, and each root server's last
  successful import, so you can fetch only the root servers that changed.
- **Stale root servers are left out of `meetings.ndjson.gz`.** If the aggregator has not managed to import a
  root server for more than 14 days it only holds an old copy, and publishing that as current would send
  people to meetings that may not exist. Those servers are listed under `stale_root_servers` in the manifest
  and still have their own `root-<id>` file if you want them knowingly.
- Check `schema_version` in the manifest; it changes if the layout ever does.

If the export does not fit, for example you need data fresher than a day, **write to admin@bmlt.app** before
building a crawler. If you do crawl the API:

1. **Copy at most every 4 hours**, and preferably 2 to 4 times a day. Anything more often fetches data that
   cannot have changed.
2. **Skip what has not changed.** Read `/api/v1/rootservers` first, and only re-pull a root server whose
   `lastSuccessfulImport` has moved since your last copy.
3. **Go one root server at a time, paged and sorted**:
   `root_server_ids[]=<id>&sort_keys=id_bigint&page_size=1000&page_num=N`. Without the sort, pages can repeat
   or skip meetings. Do not slice the world into geographic boxes, and do not request whole countries by name.
4. **One request in flight, with a pause between them.** A second or so between requests costs you a few
   minutes a day and keeps you from competing with someone searching for a meeting.
5. **Stay off the top of the hour.** Everyone's cron job runs at `:00`. Pick a random minute.
6. **Trim the fields** to what your index stores.
7. **Back off on errors.** On a 429, 502, 503 or 504, wait and retry later with increasing delays. Do not
   retry immediately or in a loop.
8. **If you only serve one area, do not use the aggregator for it.** Ask that area's own root server; its
   address is in the root server list.

## If you get blocked

A `403` from the aggregator with a message addressed to your client means it was using a large share of the
server and we had no other way to reach you. Email **admin@bmlt.app**: the block is lifted as soon as we
have talked, and we will help you get the data more efficiently. Usually that means the daily export above.

## A good citizen, in one request

```bash
curl -A 'MyMeetingFinder/1.4 (+https://example.org/about; admin@example.org)' \
  'https://aggregator.bmltenabled.org/main_server/client_interface/json/?switcher=GetSearchResults&lat_val=32.78&long_val=-79.93&geo_width_km=-25&data_field_key=id_bigint,meeting_name,weekday_tinyint,start_time,latitude,longitude,venue_type,format_shared_id_list&get_used_formats=1&callingApp=my_meeting_finder'
```

It says who is asking, searches where the user is, asks for the nearest 25 meetings, names the fields it
will show, and gets the format names in the same response.

---

To explore the API and build queries interactively, use the BMLT Semantic Workshop:
<https://aggregator.bmltenabled.org/main_server/semantic>. Thank you for building something that helps
people find a meeting.
