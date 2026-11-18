# aggregator

The worldwide BMLT server aggregator (formerly *tomato*). It collects meeting data from
BMLT root servers around the world into a single searchable instance running the
[BMLT Server](https://github.com/bmlt-enabled/bmlt-server) codebase, served at
**https://aggregator.bmltenabled.org**.

This repository holds the public list of root servers the aggregator imports from.

## Server list

[`serverList.json`](./serverList.json) is the canonical list of root servers. Each entry is:

```json
{ "id": "102", "name": "Greater New York Server", "url": "https://bmlt.newyorkna.org/main_server/" }
```

- `id` — stable numeric identifier for the server (don't reuse an id).
- `name` — human-readable region name.
- `url` — the root server's base URL.

It is consumed directly over HTTPS by downstream tools, so keep the shape and the path
stable:

```
https://raw.githubusercontent.com/bmlt-enabled/aggregator/main/serverList.json
```

### Adding or changing a server

1. Add or edit the entry in `serverList.json` (keep it valid JSON; one object per line).
2. Open a pull request. Once it's merged to `main`, the raw URL above updates and
   importers pick it up on their next run.

## Responsible use

Need the whole dataset? Please use the daily export instead of scraping the live service:
see **https://cdn.aws.bmlt.app/aggregator/responsible-use.html**.
