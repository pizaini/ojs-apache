# OJS 3 on Apache + PHP — production image

`php:8.3-apache` image with everything Open Journal Systems 3.5 needs, tuned to
run **many single-instance journals on one host** behind nginx.

Reference deployment: 21 journals on a 48 GB / 12 core host, OJS containers
restricted to 6 cores.

## Contents

* PHP 8.3 with the extensions OJS requires: `gd` (with JPEG/FreeType), `intl`,
  `mysqli`/`pdo_mysql`, `zip`, `mbstring`, `curl`, `xml`, `exif`, `opcache`
* Apache 2.4 with `mod_rewrite`, `mod_headers`, `mod_ssl`, `mod_remoteip`
* OJS release is baked into the image and seeded into the `ojs-code` volume on
  first start; later starts copy nothing (no 378 MB / 34,295 file burst)
* Document root is a volume, so custom themes and template edits survive
  restarts. Upgrading is a deliberate manual procedure (see *Upgrading*)
* Apache worker count capped via `APACHE_MAX_REQUEST_WORKERS` (the upstream
  default of 150 can reserve ~12 GB per container)
* Queue worker and scheduler under supervisord, running as `www-data`
* PHP memory limit, OPcache, realpath cache and session path sized per
  container through environment variables — one image serves every tier
* HTTP on port 80; HTTPS on 443 is opt-in (`OJS_ENABLE_SSL=1`)
* Liveness `HEALTHCHECK` against a static file (no PHP, no database)
* All processes log to stdout; log rotation belongs to the container runtime

## Quick start

```bash
docker run -d --name ojs-apache \
  -p 127.0.0.1:8080:80 \
  -v ojs-files:/var/www/ojs-data \
  -v ojs-code:/var/www/html \
  pizaini/ojs-apache:latest
```

Open `http://localhost:8080` and complete the web installer. OJS needs a
MariaDB database; the shared one is defined in `docker-compose.yml`.

## Deployment topologies

### Shared database + per-journal containers (intended)

| File | Purpose |
| --- | --- |
| `docker-compose.yml` | shared MariaDB + the `ojs-net` network |
| `docker-compose.tier1.yml` | small journal — 768 MB, 5 workers |
| `docker-compose.tier2.yml` | standard journal — 1536 MB, 12 workers |
| `docker-compose.tier3.yml` | priority journal — 2048 MB, 18 workers |

```bash
# once: shared database and network
docker compose up -d

# per journal: unique project, container name and loopback port
OJS_PROJECT=ojs-j1 OJS_NAME=ojs-j1 OJS_PORT=8081 \
  docker compose -f docker-compose.tier1.yml up -d

OJS_PROJECT=ojs-j2 OJS_NAME=ojs-j2 OJS_PORT=8101 \
  docker compose -f docker-compose.tier2.yml up -d
```

Every instance needs its own `OJS_PROJECT`, `OJS_NAME` and `OJS_PORT`. Ports are
published on `127.0.0.1` only; nginx is the only public entry point.

### Single instance

`docker run` (see Quick start) or pick any tier file with one `OJS_*` set.

## Volumes

| Path | Volume | Purpose |
| --- | --- | --- |
| `/var/www/ojs-data` | `ojs-files` | OJS `files_dir`: submissions, uploads, caches — **back this up** |
| `/var/www/html` | `ojs-code` | OJS code **plus** custom themes, edited templates and the `public/` directory — **back this up** |
| `/etc/apache2/ssl` | — | TLS material. Only used when `OJS_ENABLE_SSL=1` |

Both volumes are seeded from the image the first time they are created. After
that the volume wins, which is what makes theme and template edits survive
restarts, rebuilds and `docker rm`.

Because `/var/www/html` is now authoritative, **image upgrades do not replace
the code automatically** — see [Upgrading](#upgrading).

Migrating a container that was created before `ojs-code` existed: copy your
edited files out first (`docker cp <old-container>:/var/www/html/plugins ./`
etc.), then start the new container with the volume and copy them back.

## Environment variables

| Variable | Default | Description |
| --- | --- | --- |
| `OJS_VERSION` | build arg `3.5.0-5` | OJS release baked into the image |
| `OJS_SHA256` | empty | Optional checksum of the OJS tarball, verified at build time |
| `OJS_FILES_DIR` | `/var/www/ojs-data` | OJS `files_dir` |
| `OJS_SESSION_DIR` | `/var/lib/php/sessions` | Native PHP session directory (OJS 3.5 itself uses database sessions) |
| `OJS_MEMORY_LIMIT` | `256M` | PHP `memory_limit` |
| `OJS_OPCACHE_MB` | `128` | OPcache shared memory |
| `OJS_OPCACHE_STRINGS_MB` | `16` | OPcache interned strings buffer |
| `OJS_REALPATH_KB` | `2048` | realpath cache per Apache worker |
| `OJS_SCHEDULER_INTERVAL` | `300` | Seconds between `scheduler.php run` invocations |
| `OJS_QUEUE_SLEEP` | `30` | Seconds the queue worker idles between polls |
| `APACHE_MAX_REQUEST_WORKERS` | `12` | Hard cap on Apache workers |
| `APACHE_START_SERVERS` | `2` | Workers started at boot |
| `OJS_ENABLE_SSL` | `0` | `1` makes Apache serve HTTPS on 443 itself |
| `OJS_TRUSTED_PROXIES` | empty | Comma-separated IPs/CIDRs allowed to send `X-Forwarded-For` |
| `OJS_REDIRECT_HTTPS` | `0` | `1` forces HTTP → HTTPS redirect inside Apache |
| `OJS_SSL_CN` | `localhost` | CN/SAN for the self-signed certificate generated when `OJS_ENABLE_SSL=1` |

## Reverse proxy (nginx)

The container speaks plain HTTP on port 80 and expects nginx to terminate TLS.
Two headers must arrive:

* `X-Forwarded-Proto: https` — Apache turns it into `HTTPS=on`, so OJS builds
  `https://` URLs
* `X-Forwarded-For` — restored as the client IP by `mod_remoteip`

Set `OJS_TRUSTED_PROXIES` to the address nginx connects from. Without it Apache
ignores forwarded IPs (safer than trusting everyone) and logs the proxy address.

```nginx
server {
    listen 80;
    server_name ojs.example.org;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    http2 on;                          # nginx >= 1.25.1; older: listen 443 ssl http2;
    server_name ojs.example.org;

    ssl_certificate     /etc/letsencrypt/live/ojs.example.org/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/ojs.example.org/privkey.pem;

    client_max_body_size 80m;          # must be >= PHP upload_max_filesize (64M)

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host  $host;
        proxy_read_timeout 300s;
    }
}
```

Set `base_url` to the public HTTPS URL in `config.inc.php`:

```ini
[general]
base_url = "https://ojs.example.org"
restful_urls = On
```

### Caching at the edge

OJS 3.5 keeps sessions in MariaDB, and every page view costs **three** PHP
requests: the HTML page plus the compiled stylesheet and font. Anonymous pages
answered by nginx never touch PHP or the database. Complete, ready-to-install
configuration (both `restful_urls` styles, cache invalidation, logging):

* [docs/nginx/README.md](docs/nginx/README.md) — guide
* [docs/nginx/ojs-cache-zone.conf](docs/nginx/ojs-cache-zone.conf) — zones, maps, log format
* [docs/nginx/ojs-cache-location.inc](docs/nginx/ojs-cache-location.inc) — shared cache directives
* [docs/nginx/ojs-server.conf](docs/nginx/ojs-server.conf) — full server block

Caching happens **only** in nginx. OJS's own `web_cache` stays `Off`: it still
boots PHP and writes the session row, and it ignores domain-based subscriptions.

The same files also rate limit authentication endpoints (`10r/m`, burst 5, keyed
by host + client IP) and contain a commented installer block to enable once the
site is installed.

## Building

```bash
docker build \
  --build-arg OJS_VERSION=3.5.0-5 \
  --build-arg OJS_SHA256=<sha256-of-ojs-3.5.0-5.tar.gz> \
  -t pizaini/ojs-apache:local .
```

`OJS_SHA256` makes the release verifiable; without it the build logs a warning.
Tarballs live at `https://pkp.sfu.ca/ojs/download/ojs-<version>.tar.gz`.

CI (`.github/workflows/`) builds multi-arch on tags and runs a smoke test on pull
requests: extension checks, JPEG support, OPcache, container start, and a check
that the default deployment is HTTP-only.

## TLS

Default is HTTP-only on port 80, which is correct behind nginx. Use
`OJS_ENABLE_SSL=1` only when Apache itself must serve HTTPS: the entrypoint then
generates a self-signed certificate if none is mounted.

```bash
-e OJS_ENABLE_SSL=1 \
-v /etc/letsencrypt/live/ojs.example.org/fullchain.pem:/etc/apache2/ssl/ssl.crt:ro \
-v /etc/letsencrypt/live/ojs.example.org/privkey.pem:/etc/apache2/ssl/ssl.key:ro
```

No certificate or private key is stored in this repository or baked into the
image.

## Capacity planning

One OJS 3.5.0-5 instance: 34,295 files / 378 MB unpacked, 9,340 PHP files
(39 MB of source). The 115 MB release tarball stays in the image as a restore
source; Docker layers are shared, so 21 containers do not cost 21 copies.

| Component | Typical |
| --- | --- |
| Each Apache worker | 60–90 MB RSS |
| OPcache | 128 MB, shared within the container |
| Queue worker (idle) | 50–80 MB |
| Scheduler burst | 60–100 MB, every `OJS_SCHEDULER_INTERVAL` |
| realpath cache | ~2 MB × worker count |

```
APACHE_MAX_REQUEST_WORKERS
    = (mem_limit - opcache - 60 MB queue - 100 MB scheduler - 40 MB httpd
       - headroom) / 80 MB
```

| `mem_limit` | Workers | Approx. peak |
| --- | --- | --- |
| 768m | 5 | ~0.7 GB |
| 1536m | 12 | ~1.3 GB |
| 2048m | 18 | ~1.8 GB |

### Reference deployment: 48 GB RAM, 12 cores, 21 journals

| Tier | Count | `mem_limit` | Reservation | Workers | `cpus` | `cpu_shares` |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 5 | 768m | 384m | 5 | 0.5 | 256 |
| 2 | 10 | 1536m | 768m | 12 | 1.0 | 512 |
| 3 | 6 | 2048m | 1536m | 18 | 2.0 | 1024 |

```
Limits       : 5x0.75 + 10x1.5 + 6x2.0            = 31.5 GB
Reservations : 5x0.384 + 10x0.768 + 6x1.536       = 18.8 GB
MariaDB      : 8 GB limit / 6 GB reservation      (buffer pool 4 GB)
nginx + OS   : ~6 GB
=> ~32 GB committed, ~16 GB burst headroom
```

All OJS containers share `cpuset: "0-5"`, so the fleet cannot exceed 6 of the
12 cores regardless of worker counts. `cpus` is a per-container burst cap
(summing to 24.5 on purpose); `cpu_shares` decides who wins when those 6 cores
saturate (1 : 2 : 4 per container).

Database connections: 5×5 + 10×12 + 6×18 = 253, so the shared MariaDB runs
`max_connections=512`.

Rules that matter more than the numbers:

1. **Always set `mem_limit`.** Without it one container can reserve gigabytes
   through Apache workers and OOM the host.
2. **Match workers to `mem_limit`.** See the formula above.
3. **`max_connections >= containers × workers`.** Each worker may hold one
   connection.
4. **`stop_grace_period` must exceed supervisord's `stopwaitsecs`** (15 s for
   Apache), otherwise Docker SIGKILLs Apache mid-request on every restart.
5. **Rotate logs at the runtime level.** Everything logs to stdout; the compose
   files cap `json-file` per tier (5 MB × 2 to 20 MB × 3).
6. **Keep `pids_limit` and `nofile`.** They contain fork bombs and descriptor
   leaks per container.

Startup profile: no file copying and no recursive `chown`, so a start is a few
stat calls plus Apache boot (1–3 s). The first requests after a restart pay a
one-off OPcache compile cost.

## Jobs

Per the [PKP admin guide](https://docs.pkp.sfu.ca/admin-guide/en/deploy-jobs),
supervisord runs two long-lived processes:

* `ojs-queue-monitor` — `php lib/pkp/tools/jobs.php work --sleep=<OJS_QUEUE_SLEEP>`
* `ojs-scheduler` — `php lib/pkp/tools/scheduler.php run` every
  `OJS_SCHEDULER_INTERVAL` seconds

Both run as `www-data` so files they create stay writable by Apache. Both are
wrapped in a retry loop: OJS refuses CLI jobs while it is not installed
(`PKPApplication::isUnderMaintenance()` is true when `config.inc.php` is
missing), so a fresh container logs this once per minute:

```
[queue] OJS is not installed yet, retrying in 60s
```

That is expected. The worker starts by itself once the installer writes
`config.inc.php`; no restart needed.

## Health check

`HEALTHCHECK` requests the static `/healthz.txt`. It proves Apache and the
filesystem are alive without booting PHP or querying the database — meaningful
when 21 containers probe simultaneously.

This is liveness only. Monitor the application (login page, `sessions` table
growth, queue depth) externally.

## Backups and restore

Three host-side scripts live in `scripts/`. They run **from the host**, reach
into a container, and write zip archives to disk. They default to
`/var/backups/ojs` (override with `OJS_BACKUP_DIR`), use the published image as
the zip helper, and are safe to call from cron.

| Script | Arguments | Produces |
| --- | --- | --- |
| `ojs-system-backup.sh` | `<ojs-container> [dir]` | `ojs-system-<datetime>.zip` (`/var/www/html`, `cache/` excluded) |
| `ojs-data-backup.sh` | `<ojs-container> [dir]` | `ojs-data-<datetime>.zip` (all of `/var/www/ojs-data`) |
| `ojs-database-backup.sh` | `<db-container> <db> <user> [password] [dir]` | `ojs-database-<datetime>.sql.zip` |

Layout (one directory per target, so 21 journals never collide):

```
/var/backups/ojs/
├── ojs-j1/ojs-system-20261027-020000.zip
├── ojs-j1/ojs-data-20261027-020005.zip
├── ojs-j2/...
└── db-ojs/ojs-database-20261027-020010.sql.zip
```

Behaviour:

* `zip`/`unzip` run inside a throwaway container from `OJS_IMAGE`, so the host
  does not need `zip`.
* `unzip -t` verifies every archive before the script exits 0.
* Archives are created with mode `600` (the system archive contains
  `config.inc.php` with database credentials) and directories with `700`.
* `flock` prevents overlapping cron runs per target; a second run exits 0.
* Retention keeps the newest `KEEP_COUNT` archives **per type** (default 15,
  `0` disables pruning).
* The database dump uses `--single-transaction --quick --routines --triggers`,
  so the site stays online and tables are not locked.

### Cron

```cron
# /etc/ojs/backup.env  (mode 600, owned by root)
# OJS_DB_PASSWORD=...
# OJS_BACKUP_DIR=/var/backups/ojs

# database first: consistent snapshot before the files
10 2 * * * . /etc/ojs/backup.env; /opt/ojs/scripts/ojs-database-backup.sh mariadb ojs ojs_backup >> /var/log/ojs-backup.log 2>&1

# every OJS container except the database
15 2 * * * for c in $(docker ps --format '{{.Names}}' --filter 'name=^ojs-'); do \
             /opt/ojs/scripts/ojs-data-backup.sh "$c"; \
             /opt/ojs/scripts/ojs-system-backup.sh "$c"; \
           done >> /var/log/ojs-backup.log 2>&1
```

Never put the database password directly in the crontab: it is readable and it
shows up in the process list. Use `OJS_DB_PASSWORD`, `OJS_DB_PASSWORD_FILE`, or
`--password-file`-style env loading as above.

### Restore

1. Start the container with the target `OJS_VERSION` and both volumes attached.
2. Unzip `ojs-system-*.zip` into `/var/www/html` (it already contains
   `config.inc.php`, custom themes and edited templates).
3. Unzip `ojs-data-*.zip` into `/var/www/ojs-data`.
4. Unzip `ojs-database-*.sql.zip` and import the `.sql` with `mariadb`.
5. Check `/var/www/html/.ojs-version` against the image; the entrypoint warns on
   mismatch.
6. Fix ownership if the restored tree is not `www-data` — the entrypoint detects
   the wrong owner and re-chowns automatically.

```bash
# example: restore into a fresh volume pair
docker run --rm -v ojs-j1_ojs-code:/target -v "$PWD":/in alpine \
  sh -c 'cd /target && unzip -o /in/ojs-system-20261027-020000.zip'
docker run --rm -v ojs-j1_ojs-files:/target -v "$PWD":/in alpine \
  sh -c 'cd /target && unzip -o /in/ojs-data-20261027-020005.zip'
unzip -p ojs-database-20261027-020010.sql.zip | docker exec -i mariadb \
  sh -c 'MYSQL_PWD="$MARIADB_ROOT_PASSWORD" mariadb -uroot ojs'
```

## Upgrading

The document root is a volume, so pulling a new image does **not** replace the
code. The container logs a warning when the image and the volume disagree:

```
[ojs-entrypoint] WARNING: code in the volume is 3.5.0-5 but the image ships 3.5.1-1.
```

There is **no automated upgrade helper on purpose**. An OJS upgrade touches
templates, plugins and the database schema, and a bad merge is destructive. Do it
manually, per journal, with both backups in place.

### Manual upgrade checklist

```bash
# 1. back up both volumes and the database
docker run --rm \
  -v ojs-j2_ojs-code:/code:ro \
  -v ojs-j2_ojs-files:/files \
  alpine tar -czf /files/backups/html-$(date +%F).tar.gz -C /code .
docker exec ojs-db mariadb-dump -u root -p"$MARIADB_ROOT_PASSWORD" ojs > ojs-$(date +%F).sql

# 2. extract the new release from the new image, without starting it
docker pull pizaini/ojs-apache:3.5.1-1
docker create --name ojs-stage pizaini/ojs-apache:3.5.1-1
docker cp ojs-stage:/opt/ojs/ojs-3.5.1-1.tar.gz ./ojs-3.5.1-1.tar.gz
docker rm ojs-stage

# 3. merge the code into the volume yourself
#    - preserve plugins/themes/, your edited templates and config.inc.php
#    - never use rsync --delete on the document root
docker run --rm -v ojs-j2_ojs-code:/code -v "$PWD":/in alpine \
  sh -c 'cd /code && tar -xzf /in/ojs-3.5.1-1.tar.gz --strip-components=1 --keep-newer-files'

# 4. database upgrade
docker compose -f docker-compose.tier2.yml up -d
docker exec ojs-j2 php /var/www/html/tools/upgrade.php upgrade

# 5. clear caches and restart
docker exec ojs-j2 rm -rf /var/www/html/cache/*.php /var/www/html/cache/wc-*.html
find /var/cache/nginx/ojs -type f -delete
docker restart ojs-j2
```

Notes:

* `--keep-newer-files` keeps files whose mtime is newer than the release copy,
  which is usually your edits. Verify the diff afterwards regardless.
* `config.inc.php`, `plugins/themes/*` and `public/` are the files most likely to
  be customized. Confirm they survived before starting the container.
* The alternative, arguably cleaner, path is to **recreate the code volume** from
  the new image and re-apply your customizations from the backup. That gives a
  pristine tree with no dead files left from the old release.
* Update `.ojs-version` only after the code really matches, otherwise the runtime
  warning becomes meaningless:

  ```bash
  docker exec ojs-j2 sh -c 'echo 3.5.1-1 > /var/www/html/.ojs-version'
  ```

Skip steps 2–5 only if you consciously want to stay on the old code.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| `Can not run queue jobs ... maintenance mode` | OJS not installed yet, or `config.inc.php` missing. Expected before the installer finishes. |
| `[queue] OJS is not installed yet` every 60 s | Same as above. |
| `docker inspect` health `unhealthy` | `curl /healthz.txt` failing: Apache down, or `/var/www/html` replaced without OJS. |
| `WARNING: code in the volume is X but the image ships Y` | Expected after pulling a new image. The volume wins; upgrade manually (see *Upgrading*) or recreate the code volume. |
| Theme/template edits vanished after recreation | `/var/www/html` was not on the `ojs-code` volume; only the image content was in use. |
| Pages look stale | nginx cache. Refresh one URL with `-H 'X-OJS-Cache-Refresh: 1'` or wipe `/var/cache/nginx/ojs`. |
| `unknown variable "$ojs_cache_zone"` on `nginx -t` | `ojs-cache-zone.conf` not installed, or installed after the include. Both are required together. |
| Uploads rejected at ~64 MB | `client_max_body_size` in nginx or `upload_max_filesize`/`post_max_size` in PHP. |
| Real client IP shows as proxy | `OJS_TRUSTED_PROXIES` empty or not covering the nginx address. |

## Security

Hardening checklist for both the image and the OJS application:
[Security.md](Security.md).

## License

GPL-3.0 — see [LICENSE](LICENSE). OJS itself is distributed by PKP under the
same license.