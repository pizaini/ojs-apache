# AGENTS.md

Context and rules for AI agents working in this repository.

The maintainer communicates in **Indonesian**; code, comments, commit messages
and documentation are in **English** (except `Security.md`, which is Indonesian
for the journal administrators).

---

## 1. What this project is

A single Docker image that packages **Open Journal Systems 3.5** on
`php:8.3-apache`, designed to run **many independent single-instance journals on
one host** behind nginx.

Reference deployment: 21 journals (5 small / 10 standard / 6 priority) on a
48 GB RAM, 12 core host. OJS containers are restricted to 6 cores via `cpuset`,
MariaDB runs on 2 cores. Published as `pizaini/ojs-apache` (multi-arch, built on
git tags).

Not a generic PHP image: every decision below exists because of OJS-specific
behaviour (DB-backed sessions, component URLs, LESS compilation, PKP CLI jobs).

---

## 2. Architecture

```
client -> nginx (TLS, optional proxy_cache)
              |  HTTP :80 on 127.0.0.1:<port>
              v
        supervisord (PID 1, root)
          |- apache2        (master root, workers www-data)
          |- ojs-queue-monitor  (bash retry loop -> php jobs.php work, www-data)
          `- ojs-scheduler      (bash loop -> php scheduler.php run, www-data)
              |
              `-> MariaDB (shared container, cores 6-7)

/var/www/html      OJS code VOLUME (custom themes, edited templates, public/)
/opt/ojs/<ver>.tgz release tarball kept as a restore source
/var/www/ojs-data  files_dir (volume), sessions fallback, uploads
```

### Container start (`docker/run.sh`, `set -euo pipefail`)

1. TLS: default **off**; `OJS_ENABLE_SSL=1` enables `mod_ssl`, the 443 vhost and
   generates a self-signed cert when none is mounted. Otherwise `a2dismod ssl`.
2. Reverse proxy: writes `conf-enabled/ojs-proxy.conf` from `OJS_TRUSTED_PROXIES`
   (`mod_remoteip`), or removes it.
3. OJS: normally already present (baked). Unpacks the tarball only when
   `/var/www/html/index.php` is missing.
4. Writes `/usr/local/etc/php/conf.d/zz-ojs-runtime.ini` from the `OJS_*`
   profile variables (memory limit, OPcache, realpath cache, session dir).
5. Optional HTTP→HTTPS redirect inside Apache (`OJS_REDIRECT_HTTPS=1`).
6. `chown` only when `index.php` is not owned by `www-data` (never on the normal
   path) and only when `files_dir` has foreign files.
7. `exec supervisord`.

Startup must stay in the 1–3 second range. Do not add recursive operations over
`/var/www/html` (34,295 files) to the start path.

---

## 3. File map

| File | Responsibility |
| --- | --- |
| `Dockerfile` | base image, extensions, OJS download + checksum, document root seed, `HEALTHCHECK` |
| `docker/run.sh` | entrypoint: TLS, proxy, code, PHP profile, ownership, supervisord |
| `docker/supervisord.conf` | 3 programs, retry loops, stdout logging |
| `docker/php-apache/conf/apache2.conf` | global Apache: rewrite, PHP handler deny rules, hardening |
| `docker/php-apache/conf/000-default.conf` | port 80 vhost, headers, log routing |
| `docker/php-apache/conf/ssl-vhost.conf` | optional 443 vhost (not enabled by default) |
| `docker/php-apache/conf/mpm_prefork.conf` | worker cap from `APACHE_*` env |
| `docker/php-apache/conf/php.ini` | PHP baseline; per-container overrides come from `run.sh` |
| `docker-compose.yml` | shared MariaDB + `ojs-net` network |
| `docker-compose.tier{1,2,3}.yml` | per-journal resource profiles |
| `docs/nginx/*` | edge cache + log format, one server block per journal |
| `scripts/ojs-system-backup.sh` | host-side zip of `/var/www/html` (`cache/` excluded) |
| `scripts/ojs-data-backup.sh` | host-side zip of `/var/www/ojs-data` |
| `scripts/ojs-database-backup.sh` | host-side `mariadb-dump` + zip |
| `Security.md` | image + OJS + nginx hardening checklist |
| `.github/workflows/` | multi-arch publish on tags, build/smoke test on PR |

`docker/.htaccess` is legacy and unused: `AllowOverride None` makes it dead.
Do not rely on it.

---

## 4. Hard rules

Break these only with an explicit decision recorded in the README.

1. **Never commit certificates or private keys.** `docker/ssl/` is gitignored;
   certs are generated at runtime or mounted.
2. **Do not reintroduce `pecl`, `memcache`, `msgpack`, `libmcrypt`, or a compiler
   toolchain.** None are needed by OJS; they bloat the image and add CVE surface.
3. **Keep GD built with JPEG and FreeType** (`--with-jpeg --with-freetype`).
   OJS cover images and thumbnails need JPEG.
4. **`post_max_size` must stay above `upload_max_filesize`.** Currently 80M/64M.
5. **Apache must only listen on 80 unless `OJS_ENABLE_SSL=1`.** Port 443 is
   opt-in; behind nginx `mod_ssl` is disabled at runtime.
6. **Workers never run as root.** Queue worker and scheduler use `user=www-data`
   so files they create stay writable by Apache.
7. **`APACHE_MAX_REQUEST_WORKERS` must match `mem_limit`** using the formula in
   §6. The upstream default of 150 can reserve ~12 GB in one container.
8. **`stop_grace_period` must exceed supervisord `stopwaitsecs`** (15 s for
   Apache, 10 s for the others). Compose sets 40 s.
9. **Everything logs to stdout.** No log files inside the container except
   `/dev/null`; rotation belongs to the runtime.
10. **supervisord `logfile` must not be `/dev/stdout`.** With `nodaemon=true`
    supervisord already adds a stdout handler; pointing the logfile there
    duplicates every line. It is `/dev/null`.
11. **Long-running programs use a retry loop.** `jobs.php work` exits with status
    0 while OJS is not installed or in maintenance; a plain `autorestart=true`
    produced a respawn every second. Keep the `while true; ... sleep N` wrapper.
12. **Do not enable OJS `web_cache`.** Decision: page caching happens only in
    nginx. `web_cache` still boots PHP and writes the session row.
13. **nginx cache key must include `$host`.** 21 journals share one nginx zone.
14. **`proxy_hide_header Set-Cookie` is only legal inside the explicit allow
    list** of anonymous pages. Extending that list to a page with CSRF forms
    means serving one user's token to another.
15. **Never cache** `article/download`, `login`, `user`, `submission`, `admin`,
    `api/v1`, `install`, `gateway/*`, or any `$$$call$$$` route other than
    `page/page/css|js`.
16. **The healthcheck stays on the static `/healthz.txt`.** Pointing it back to
    `/index.php` makes 21 containers boot PHP and hit the DB every 15–60 s. The
    entrypoint recreates the file at every start if it is missing; do not replace
    that with a probe that depends on PHP or the database.
17. **TLS material lives at `/etc/apache2/ssl/ssl.crt` and `ssl.key`.** Keep the
    paths stable so existing mounts keep working.
18. **`cpuset` belongs in compose, never in the image.** Docker Desktop has too
    few cores and hard-coding core numbers breaks other hosts.
19. **OJS 3.5 sessions are in MariaDB** (`PKPContainer.php`, driver `database`,
    table `sessions`). `session.save_path` only covers native PHP sessions used
    by third-party plugins. Do not present tmpfs sessions as a DB optimisation.
20. **Validate before claiming success.** At minimum: `bash -n` on shell files,
    YAML parse on compose/workflows, nginx regex checks, and `nginx -t` /
    `apache2ctl -t` inside a built image when Docker is available.
21. **`/var/www/html` is a persistent volume** seeded from the image. It holds
    custom themes, edited templates and `public/`, so the entrypoint must never
    overwrite it silently. Version drift is read from
    `dbscripts/xml/version.xml` (shipped with the code) and only reported, never
    repaired automatically. There is no separate version marker file to keep in
    sync.
22. **Upgrades are manual.** There is no upgrade helper by design: the release
    must be merged by hand after backing up both volumes and the database.
    Whatever the operator does, never `rsync --delete`, `rm -rf` or bulk-copy
    over the tree — that destroys custom themes and template edits.
23. **Both volumes are mandatory** in the Dockerfile and in every tier compose:
    `ojs-files` (`/var/www/ojs-data`) and `ojs-code` (`/var/www/html`). Both are
    part of the backup set.
24. **Backup scripts are host-side and cron-safe.** They must keep `cache/` out
    of the system archive, verify each zip with `unzip -t`, chmod the archive
    `600` (the system archive holds `config.inc.php`), keep the database password
    out of the process arguments, and prune per archive type (`KEEP_COUNT`).

---

## 5. Configuration surface

Environment variables are the only supported way to make one image serve every
tier. Adding a per-tier value must not require a rebuild.

| Env | Lands in |
| --- | --- |
| `APACHE_MAX_REQUEST_WORKERS`, `APACHE_START_SERVERS` | `mpm_prefork.conf` via `${...}` substitution |
| `OJS_MEMORY_LIMIT`, `OJS_OPCACHE_MB`, `OJS_OPCACHE_STRINGS_MB`, `OJS_REALPATH_KB` | generated `zz-ojs-runtime.ini` |
| `OJS_QUEUE_SLEEP`, `OJS_SCHEDULER_INTERVAL` | `supervisord.conf` via `%(ENV_x)s` |
| `OJS_ENABLE_SSL`, `OJS_SSL_CN` | entrypoint: vhost symlink, cert generation |
| `OJS_TRUSTED_PROXIES` | generated `conf-enabled/ojs-proxy.conf` |
| `OJS_REDIRECT_HTTPS` | generated `conf-enabled/ojs-https-redirect.conf` |
| `OJS_FILES_DIR`, `OJS_TARBALL` | entrypoint paths |

`/etc/apache2/envvars` from the base image **overrides** `APACHE_LOG_DIR` and
friends, so do not try to control log paths with `ENV`.

---

## 6. Capacity model

Worker count is derived, not guessed:

```
workers = (mem_limit
           - opcache_mb
           - 60 MB   queue worker
           - 100 MB  scheduler peak
           - 40 MB   httpd base
           - headroom) / 80 MB      # 80 MB = typical OJS worker RSS
```

| Tier | Count | `mem_limit` | Reservation | Workers | `cpus` | `cpu_shares` |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 5 | 768m | 384m | 5 | 0.5 | 256 |
| 2 | 10 | 1536m | 768m | 12 | 1.0 | 512 |
| 3 | 6 | 2048m | 1536m | 18 | 2.0 | 1024 |

* All OJS containers share `cpuset: "0-5"`; the fleet cannot exceed 6 cores.
* `cpus` is a per-container burst cap and intentionally sums to 24.5.
* `cpu_shares` decides who wins under contention (1 : 2 : 4 per container).
* MariaDB: `cpuset: "6,7"`, `cpus: 2`, buffer pool 4 GB, `max_connections=512`
  (5×5 + 10×12 + 6×18 = 253 potential connections).
* Reserved memory must fit in RAM; limits may be oversubscribed.

---

## 7. Edge cache contract (`docs/nginx/`)

Three files, installed together — the include references variables defined in
the zone file (`$ojs_cache_zone`, `$ojs_refresh`, `$ojs_bypass`):

| File | Installed to |
| --- | --- |
| `ojs-cache-zone.conf` | `/etc/nginx/conf.d/` |
| `ojs-cache-location.inc` | `/etc/nginx/snippets/` |
| `ojs-server.conf` | `/etc/nginx/sites-available/`, one per journal |

Allow list (mirrors `APP\core\PageRouter::getCacheablePages()`):

| URL | TTL |
| --- | --- |
| `/`, `/index.php` (site landing) | 5m |
| journal home, `index`, `about`, `help`, `information`, `announcement`, `issue/*`, `article/view` | 5m |
| `/page/page/css`, `/page/page/js` (compiled LESS served by PHP) | 24h |
| static assets under `plugins/`, `public/`, `styles/`, `js/`, `lib/pkp/` | 7d |

Both URL styles must keep working: `restful_urls = On` (`/journal1/...`) and
`Off` (`/index.php/journal1/...`). Regexes use `(?:index\.php/)?`.

Invalidation:

* targeted: `curl -H 'X-OJS-Cache-Refresh: 1' <url>` from loopback only
  (`geo $ojs_admin`);
* full: `find /var/cache/nginx/ojs -type f -delete`;
* per journal: separate `proxy_cache_path` + one `map $host` entry.

`nginx -s reload` does **not** clear the cache. Existing entries keep the TTL
they were stored with.

Authentication endpoints (`login`, `login/signIn`, `user/register`,
`user/lostPassword`) are explicitly excluded from every cache location and are
rate limited in the same files:

```nginx
limit_req_zone "$host$binary_remote_addr" zone=ojs_auth:10m rate=10r/m;
limit_req_status 429;
```

The key includes `$host`, so an attacker on one journal cannot lock users out of
another. The installer block (`index/install -> 404`) ships commented out on
purpose: enabling it before installation closes the wizard.

---

## 8. Commands

```bash
# build (checksum optional but recommended)
docker build --build-arg OJS_SHA256=<sha256> -t ojs-apache:local .

# single instance
docker run --rm -p 127.0.0.1:8080:80 -v ojs-files:/var/www/ojs-data ojs-apache:local

# fleet
docker compose up -d
OJS_PROJECT=ojs-j1 OJS_NAME=ojs-j1 OJS_PORT=8081 \
  docker compose -f docker-compose.tier1.yml up -d

# verify a running container
docker exec <c> apache2ctl -t
docker exec <c> ps -eo pid,ppid,args | grep '[a]pache2'   # 3 idle, max workers+1
docker exec <c> curl -fsS http://127.0.0.1/healthz.txt
docker inspect --format '{{.State.Health.Status}}' <c>

# database upgrade, after a manual code upgrade (see README "Upgrading")
docker exec <c> php /var/www/html/tools/upgrade.php upgrade

# host-side backups (cron-safe, default /var/backups/ojs)
scripts/ojs-system-backup.sh ojs-j1
scripts/ojs-data-backup.sh ojs-j1
OJS_DB_PASSWORD=... scripts/ojs-database-backup.sh mariadb ojs ojs_backup
```

Static validation when Docker is unavailable (common on this workstation):

```bash
bash -n docker/run.sh
ruby -ryaml -e 'YAML.load_file(ARGV[0])' docker-compose.tier1.yml
python3 - <<'PY'   # nginx regex behaviour
import re
PY
```

---

## 9. Known pitfalls

1. **"maintenance mode is enabled"** on a fresh container is normal:
   `PKPApplication::isUnderMaintenance()` is true while the site is not installed
   (`[general] installed = Off`, shipped that way in the release tarball). The
   entrypoint only re-seeds a *missing* `config.inc.php`; it never flips
   `installed`. Do not "fix" it in the image.
2. **Duplicate supervisord log lines** — see rule 10.
3. **Worker respawn loop** — see rule 11.
4. **Apache comments start with `#`, never `;`.** A stray `;` yields
   `Invalid command ';'` and Apache refuses to start. The build now runs
   `apache2ctl -t` so this fails at build time instead of at runtime.
5. **`http2 on;` requires nginx ≥ 1.25.1**; older releases need
   `listen 443 ssl http2;`.
6. **`blkio_config.weight`** is effective on Docker ≥ 25 with cgroup v2
   (mapped to `io.weight`).
7. **`cpuset` core numbering** differs per host; verify with `lscpu` before
   deploying.
8. **`OJS_TRUSTED_PROXIES` empty** means the real client IP is lost and
   `session_check_ip` sees the proxy address.
9. **`/var/www/html` is a volume.** Pulling a new image does not replace the
   code; the container only warns. Upgrading is manual (README "Upgrading").
   Never rsync `--delete` over it — that erases custom themes and template edits.
10. **`post_max_size <= upload_max_filesize`** silently rejects large uploads.
11. **Compiled CSS has no cache-buster**; with a 24 h TTL a theme change
    requires a purge.
12. **`page/page/css` is PHP**, not a static file. It is the second most
    expensive request per page view and must stay in the cache allow list.
13. **MariaDB is shared**: one noisy journal can exhaust connections. Use
    per-tier users with `MAX_USER_CONNECTIONS`.
14. **`docker/.htaccess`** is not applied anywhere.
15. **`healthz.txt` is only restored at start.** The entrypoint recreates it when
    missing, but deleting it while the container runs fails the probe until the
    next restart. That is an accepted limitation of the start-only design; do not
    "fix" it with a probe that boots PHP.

---

## 10. Change checklist

Before finishing any change:

1. Does it affect start-up time? Keep it O(1); no recursive file walks.
2. Does it affect DB load? Remember every uncached request writes a `sessions`
   row.
3. Does it add a secret or key? It must not be committed.
4. Does it change a tier value? Put it in the compose/tier file, not the image.
5. Did you update both `README.md` and, when relevant, `docs/nginx/README.md`
   and `Security.md`?
6. Validate: shell syntax, YAML, nginx variables/`nginx -t`, Apache
   `apache2ctl -t`, container start, `healthz.txt`, worker not looping.
7. If you cannot run Docker, say so explicitly instead of claiming the image
   was tested.

---

## 11. Out of scope (decided)

* **PHP-FPM / event MPM** — rejected. nginx already handles keep-alive, so
  `mod_php` + prefork is acceptable; revisit only if density must increase.
* **Varnish** — rejected. nginx `proxy_cache` already stops requests before PHP;
  adding Varnish adds a component without removing the cookie/CSRF constraints.
* **OJS `web_cache`** — off, see rule 12.
* **Redis sessions** — unnecessary: OJS 3.5 sessions live in MariaDB and every
  instance is a single container.
* **`.htaccess`-based configuration** — disabled by design.
