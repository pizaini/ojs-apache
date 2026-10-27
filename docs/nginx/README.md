# nginx in front of OJS — caching guide

OJS 3.5 stores sessions in MariaDB (`sessions` table, Laravel database driver),
so **every page view that reaches PHP costs at least one write plus dozens of
reads**. Worse, a page view normally triggers **three** PHP requests: the HTML
page plus two `page/page/css` requests for the compiled stylesheet and font.

Stopping anonymous traffic at nginx is therefore the single biggest lever on
database load.

## Files

| File | Destination | Context |
| --- | --- | --- |
| `ojs-cache-zone.conf` | `/etc/nginx/conf.d/ojs-cache-zone.conf` | `http {}` |
| `ojs-cache-location.inc` | `/etc/nginx/snippets/ojs-cache-location.inc` | included in `location {}` |
| `ojs-server.conf` | `/etc/nginx/sites-available/ojs-j1.conf` | one per journal |

## Both URL styles are supported

| `restful_urls` | Journal home | Article page | CSS endpoint |
| --- | --- | --- | --- |
| `Off` (default) | `/index.php/journal1` | `/index.php/journal1/article/view/123` | `/index.php/journal1/$$$call$$$/page/page/css` |
| `On` | `/journal1` | `/journal1/article/view/123` | `/journal1/$$$call$$$/page/page/css` |

The locations match both forms with `(?:index\.php/)?`, and the CSS rule matches
on the `/page/page/css` suffix, so the context prefix does not matter.

## What is cached

| URL | TTL | Why |
| --- | --- | --- |
| `/` (site landing page) | 60s | busiest URL on most installs |
| `/journal1` (journal home) | 60s | second busiest |
| `issue/view`, `issue/archive` | 60s | table of contents |
| `article/view` | 60s | abstract landing page |
| `about`, `help`, `information`, `announcement`, `index` | 60s | static pages |
| `/page/page/css`, `/page/page/js` | 24h | compiled theme assets, 2 per page view |
| `/plugins`, `/public`, `/styles`, `/js`, `/lib/pkp` assets | 7d | static files |

The HTML allow list mirrors PKP's own
`classes/core/PageRouter.php::getCacheablePages()`.

Never cached:

* `article/download/...` — subscription- and access-controlled files
* `login`, `user`, `submission`, `admin`, `install`
* `api/v1`, `gateway/*`, any other `$$$call$$$` route
* anything carrying an `OJSSID` cookie

## Why the cache directives look unusual

1. Laravel's session middleware adds `Cache-Control: no-cache, private` to every
   response → `proxy_ignore_headers Cache-Control Expires`.
2. It also sets `Set-Cookie: OJSSID=...` → `proxy_ignore_headers ... Set-Cookie`
   plus `proxy_hide_header Set-Cookie`.

Hiding `Set-Cookie` is only safe because the cached locations are an explicit
allow list of anonymous pages. Never extend that list to pages containing forms
with CSRF tokens, or users will receive each other's tokens.

## Port mapping for 21 instances

| Tier | Count | Ports |
| --- | --- | --- |
| 1 | 5 | 8081–8085 |
| 2 | 10 | 8101–8110 |
| 3 | 6 | 8201–8206 |

Copy `ojs-server.conf` per journal and change `server_name` plus the three
`proxy_pass` ports.

## Verify

```bash
# landing page: first request MISS, second HIT
curl -sI https://ojs.example.org/ | grep -i x-cache-status
curl -sI https://ojs.example.org/ | grep -i x-cache-status

# journal home and compiled CSS
curl -sI https://ojs.example.org/journal1 | grep -i x-cache-status
curl -sI 'https://ojs.example.org/journal1/$$$call$$$/page/page/css?name=stylesheet' \
     | grep -i x-cache-status

# must never be cached
curl -sI https://ojs.example.org/index/login | grep -i x-cache-status   # no output
```

Access log (format `ojs`) shows both answers per request:

```
$host $remote_addr - [$time_local] "$request" $status $body_bytes_sent
cache=HIT rt=0.003 urt=0.120 "$http_referer" "$http_user_agent"
```

`urt` (upstream response time) is what you tune against. When `urt` is high and
`cache=MISS` dominates, the allow list is too small; when `cache=HIT` but pages
look stale, the TTL is too long.

Measure the database effect:

```sql
SHOW GLOBAL STATUS LIKE 'Questions';   -- sample twice, 60s apart
SHOW GLOBAL STATUS LIKE 'Com_insert';  -- session writes
```

## Does a cache HIT still touch the database?

No. On a HIT the request is answered entirely by nginx: it never reaches Apache,
never starts PHP, never opens a database connection and never writes a `sessions`
row. That is the whole point of caching here.

| Situation | PHP | MariaDB |
| --- | --- | --- |
| HIT (fresh entry) | ❌ | ❌ |
| HIT with `proxy_cache_use_stale updating` while one request refreshes | 1 request | 1 request |
| MISS / entry expired | ✅ | ✅ |
| Request with `OJSSID` cookie (`$ojs_bypass`) | ✅ | ✅ |
| `4xx`/`5xx` responses (only `200` is cached) | ✅ | ✅ |
| Static asset HIT | ❌ | ❌ |
| Queue worker + scheduler (background) | ✅ | ✅ |

Two conditions keep DB traffic alive even with a warm cache, and both are by
design:

1. **Logged-in users** always bypass the cache, so editors and authors get fresh
   pages and working CSRF tokens.
2. **One refresh per expiry**: with `proxy_cache_lock` + `proxy_cache_use_stale
   updating`, a single request repopulates an expired entry while everyone else
   keeps receiving the stale copy. With a 60s HTML TTL that is one backend
   request per minute per URL, not one per visitor.

Because cached responses are served without `Set-Cookie`, anonymous visitors who
only ever see cached pages never create a session row at all.

## Invalidating and refreshing the cache

Three mechanisms, pick per situation.

### 1. Refresh one URL (no extra module needed)

An operator on the nginx host can force a backend fetch for a single URL. The
response is fetched from PHP and stored again, so the entry is updated rather
than dropped:

```bash
curl -s -o /dev/null -w '%{http_code}\n' \
     -H 'X-OJS-Cache-Refresh: 1' \
     https://ojs.example.org/journal1/article/view/123
```

The header only works when the request comes from `127.0.0.1`/`::1` (the `geo`
block in `ojs-cache-zone.conf`). For any other source it is ignored, so it is not
a public purge endpoint. Adjust `geo` if your nginx sits in a container and sees
a bridge address instead of loopback.

### 2. Wipe the whole zone

```bash
# after a theme change, plugin install/upgrade or OJS upgrade
find /var/cache/nginx/ojs -type f -delete
```

Blunt but reliable. On a shared zone this clears all tenants at once — acceptable
because everything repopulates within one page view.

### 3. Per-journal zones (isolated purge)

If you must purge one journal without touching the other 20, give each instance
its own zone. Only two lines change, because the shared include takes the zone
name from `$ojs_cache_zone`:

```nginx
# http context — one proxy_cache_path per isolated journal
proxy_cache_path /var/cache/nginx/ojs-j1 levels=1:2 keys_zone=ojs_j1:16m
                 max_size=512m inactive=10m use_temp_path=off;

map $host $ojs_cache_zone {
    default              ojs;
    journal1.example.org ojs_j1;
}
```

Then purging journal 1 is `rm -rf /var/cache/nginx/ojs-j1/*` and nothing else is
affected. No location block has to be edited.

### What does NOT invalidate the cache

* `nginx -s reload` and `systemctl restart nginx` — cache files live on disk and
  survive both. A reload also does not recompute the expiry of existing entries.
* Changing `proxy_cache_valid` — new TTL applies to entries stored from then on.
* Editing content in OJS — HTML entries live up to 60s, which is the intended
  trade-off.

### TTL consequences you accepted

| What | TTL | Must purge when |
| --- | --- | --- |
| HTML pages | 60s | never (self-heals) |
| Compiled CSS/JS (`page/page/css`) | **24h** | theme change, plugin install/upgrade — OJS does not add a version/timestamp to these URLs, so nothing busts the cache automatically |
| Static assets | 7d | OJS upgrade or plugin file replacement |

If theme churn is frequent, lower the CSS location to `proxy_cache_valid 200
60m` or add a purge step to your deploy script. `inactive=10m` and `max_size=8g`
mean unused entries are dropped by the cache manager anyway.

Shorten `proxy_cache_valid` in `ojs-server.conf` (for example `30s`) for
journals that publish frequently.

## Apache-side log noise

The image configures Apache to skip `/healthz.txt` and static extensions:

```apache
SetEnvIf Request_URI "^/healthz\.txt$" dontlog
SetEnvIf Request_URI "\.(css|js|png|jpg|jpeg|gif|svg|ico|woff2?|ttf|eot)$" dontlog
CustomLog /proc/self/fd/1 combined env=!dontlog
```

Because nginx already logs every request (with cache status and timing), you can
go further and drop the Apache access log entirely:

```apache
CustomLog /dev/null combined      # keep ErrorLog on stderr
```

With 21 containers, one page view generates ~23 log lines. Logging only at the
edge roughly halves the write volume and keeps a single source of truth.

## Chosen configuration: nginx-only caching

This deployment deliberately uses **only** the nginx proxy cache. Keep OJS's own
page cache disabled:

```ini
[cache]
web_cache = Off
```

Reasons: `web_cache` still boots PHP, opens a database connection and writes the
session row before serving cached HTML, and the OJS template warns that it does
not respect domain-based subscriptions. nginx gives the same content savings
without touching PHP.

`[cache] default` is a different thing — the internal application cache for
settings, locales and plugin data. Leave it at the default (`file`); it is not
HTTP caching and does not affect the pages nginx serves.

RESTful URLs are enabled, which the nginx locations already support:

```ini
[general]
restful_urls = On
base_url = "https://ojs.example.org"
```

It requires `mod_rewrite`, which this image enables.