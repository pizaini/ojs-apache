# Keamanan OJS

Dokumen ini memisahkan tiga lapisan yang sering tertukar:

1. **Image** — sudah dikerjakan di repository ini (Apache, PHP, proses).
2. **Aplikasi OJS** — harus diatur di `config.inc.php` dan panel admin setiap jurnal.
3. **Edge (nginx)** — TLS, rate limit, dan header yang tidak bisa ditangani image.

Legenda status: **✅ sudah** (ada di image), **⚙️ konfigurasi** (harus Anda set),
**🔍 opsional** (tergantung kebijakan).

---

## 1. Checklist asli OJS

| # | Item | Status | Implementasi |
| --- | --- | --- | --- |
| 1 | Disable `.htaccess` | ✅ sudah | `AllowOverride None` di `docker/php-apache/conf/apache2.conf`. File `docker/.htaccess` hanya warisan lama dan **tidak** dipakai image. |
| 2 | Disable upload/eksekusi script oleh user | ✅ sudah | Semua `.php` kecuali `index.php` di document root ditolak (`<FilesMatch>`), sehingga file yang diunggah tidak bisa dieksekusi. `Options -ExecCGI` juga aktif. |
| 3 | Disable akses `.php` selain `index.php` | ✅ sudah | `<FilesMatch "^(?!index\.php$).*\.php$"> Require all denied` + `DirectoryMatch` untuk `lib/`, `plugins/`, `api/`, dll. |
| 4 | Aktifkan validasi registrasi user | ⚙️ konfigurasi | `config.inc.php`: `[email] require_validation = On`. |
| 5 | Validasi maksimal 3 hari | ⚙️ konfigurasi | `config.inc.php`: `[email] validation_timeout = 3` (satuan hari, default 14). |
| 6 | Session aktif maksimal 1 hari | ⚙️ konfigurasi | `config.inc.php`: `[general] session_lifetime = 1` (satuan hari). Catatan: OJS 3.5 menyimpan session di MariaDB; `session.gc_maxlifetime` PHP **tidak** berlaku untuk OJS. |

Contoh blok yang perlu ditambahkan:

```ini
[general]
session_lifetime = 1
session_cookie_name = OJSSID
session_samesite = Lax
allowed_hosts = '["ojs.example.org"]'

[email]
require_validation = On
validation_timeout = 3

[security]
force_ssl = On
force_login_ssl = On
cookie_encryption = On
session_check_ip = On
```

Tiga peringatan sebelum menyalakan blok di atas:

* `force_ssl`/`force_login_ssl` hanya bekerja jika nginx mengirim
  `X-Forwarded-Proto: https`; tanpa header itu OJS melihat request sebagai HTTP
  dan terjadi **redirect loop**.
* `cookie_encryption = On` akan **melogout semua user** saat diubah. Lakukan
  pada jam sepi.
* `session_check_ip = On` dapat memaksa login ulang pada pengguna mobile yang
  IP-nya berubah. Pastikan `OJS_TRUSTED_PROXIES` benar agar pemeriksaan memakai
  IP asli, bukan IP nginx.

---

## 2. Hardening yang sudah ada di image

### Apache

| Kontrol | Lokasi |
| --- | --- |
| `ServerTokens Prod`, `ServerSignature Off` | `docker/php-apache/conf/apache2.conf` |
| `TraceEnable Off` (cegah XST) | idem |
| `Options -Indexes -ExecCGI` | idem |
| Hanya `index.php` yang boleh dieksekusi | idem |
| `.htaccess`/`.htpasswd` tidak dapat diakses | idem |
| `.ojs-version` (penanda versi rilis) tidak dapat diakses | idem |
| Rewrite aman (`!-f`, `!-d`) | idem |
| Header: `X-Content-Type-Options`, `X-Frame-Options`, `Referrer-Policy`, `Permissions-Policy`, `X-XSS-Protection` | `000-default.conf`, `ssl-vhost.conf` |
| HSTS | `ssl-vhost.conf` (mode SSL internal) atau nginx (mode proxy) |
| `mod_remoteip` hanya memercayai `OJS_TRUSTED_PROXIES` | `run.sh` → `conf-enabled/ojs-proxy.conf` |
| TLS 1.2/1.3, session tickets off | `ssl-vhost.conf` |

### PHP

| Kontrol | Nilai |
| --- | --- |
| `expose_php` | `Off` |
| `display_errors` / `display_startup_errors` | `Off`, `log_errors = On` |
| `allow_url_include` | `Off` |
| `enable_dl` | `Off` |
| `session.use_strict_mode` | `1` |
| `session.cookie_httponly` | `true` |
| `session.name` | `OJSSID` |
| `upload_max_filesize` / `post_max_size` | `64M` / `80M` (post harus lebih besar) |
| OPcache | aktif, tidak untuk CLI |

### Proses

| Proses | User |
| --- | --- |
| supervisord (PID 1) | root (perlu untuk bind :80 dan `chown`) |
| Apache master | root, worker → `www-data` |
| Queue worker, scheduler | `www-data` |
| Entrypoint saat start | root (lalu turun ke supervisord) |

Tidak ada kredensial, sertifikat, atau private key yang tersimpan di image.
Sertifikat self-signed hanya dibuat saat `OJS_ENABLE_SSL=1`.

---

## 3. Edge (nginx)

### TLS dan header

```nginx
server_tokens off;

ssl_protocols       TLSv1.2 TLSv1.3;
ssl_session_cache   shared:SSL:10m;
ssl_session_timeout 1h;
add_header Strict-Transport-Security "max-age=31536000" always;
add_header X-Content-Type-Options    "nosniff" always;
add_header X-Frame-Options           "SAMEORIGIN" always;
add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
```

### Rate limit endpoint sensitif

Sudah aktif di `docs/nginx/` — tidak perlu ditambahkan manual:

```nginx
# docs/nginx/ojs-cache-zone.conf  (http context)
limit_req_zone "$host$binary_remote_addr" zone=ojs_auth:10m rate=10r/m;
limit_req_status 429;

# docs/nginx/ojs-server.conf  (server context)
location ~ ^/(?:index\.php/)?[^/.]+/(?:login(?:/|$)|user/(?:register|lostPassword)) {
    limit_req zone=ojs_auth burst=5 nodelay;
    proxy_pass http://127.0.0.1:8081;
}
```

Nilai `10r/m` + `burst=5` berarti satu IP dapat mencoba ±6 kali sebelum
menerima `429`. Kunci memakai `$host`, sehingga penyerang di satu jurnal tidak
mengunci pengguna jurnal lain.

Untuk memutihkan IP kantor/admin, kosongkan kunci — nginx tidak menghitung
request dengan kunci kosong:

```nginx
geo $ojs_auth_key {
    default      $binary_remote_addr;
    203.0.113.10 "";              # IP admin, tanpa limit
}
limit_req_zone "$host$ojs_auth_key" zone=ojs_auth:10m rate=10r/m;
```

### Blokir sisa installer

Blok ini tersedia **dalam keadaan dikomentari** di `docs/nginx/ojs-server.conf`.
Jangan aktifkan sebelum instalasi selesai — kalau aktif, wizard installer ikut
tertutup:

```nginx
location ~ ^/(?:index\.php/)?index/install {
    return 404;
}
```

### Yang tidak boleh di-cache

Lihat `docs/nginx/README.md`. Ringkasnya: `article/download`, `login`, `user`,
`submission`, `admin`, `api/v1`, `install`, dan semua request ber-`OJSSID` tidak
pernah disajikan dari cache. Cacheable hanya halaman anonim tanpa form CSRF.

---

## 4. Runtime container

```yaml
security_opt:
  - no-new-privileges:true
ports:
  - "127.0.0.1:8081:80"      # jangan pernah 0.0.0.0:80
```

Keduanya sudah diterapkan di `docker-compose.tier1.yml`, `tier2.yml`, dan
`tier3.yml` (port sudah `127.0.0.1` sejak awal).

* **Jangan** mempublikasikan port ke semua interface; nginx harus satu-satunya
  pintu masuk publik.
* `no-new-privileges` aman untuk image ini (proses hanya **menurunkan**
  privilege, tidak menaikkannya).
* Jalankan `docker scout`/`trivy image` pada setiap build.
* Batasi `pids_limit` dan `nofile` (sudah di-set di compose per tier).

---

## 5. Supply chain dan update

* **Pin versi OJS** lewat `--build-arg OJS_VERSION` dan verifikasi dengan
  `OJS_SHA256`; build tanpa checksum akan menulis peringatan.
* **Rebuild rutin** (minimal bulanan) agar base `php:8.3-apache` dan paket
  Debian mendapat patch keamanan. Extended support PHP 8.3 berakhir, jadi
  siapkan jalur upgrade ke 8.4.
* **Pin image digest** di produksi (`pizaini/ojs-apache@sha256:...`) agar
  `latest` tidak berubah diam-diam.
* CI sudah membangun multi-arch dan menjalankan smoke test pada PR; tambahkan
  pemindaian CVE sebelum push tag.
* Jangan menambahkan kembali `pecl memcache`, `msgpack`, atau `libmcrypt` —
  semuanya sudah dihapus karena tidak dipakai OJS dan menambah permukaan
  serangan.

---

## 6. Data dan operasional

* **Backup**: volume `ojs-files`, volume `ojs-code` (`/var/www/html` — berisi
  tema kustom, template yang diedit, `public/`, dan `config.inc.php`), serta
  database MariaDB. Uji restore secara berkala, bukan hanya backup.
* **Retensi log**: log akses berisi IP dan User-Agent (PII). Rotasi sudah
  dibatasi per tier (5–20 MB × 2–3); kirim ke agregator jika butuh histori dan
  tetapkan masa simpan.
* **Kredensial DB**: gunakan user MariaDB terpisah per jurnal dengan
  `MAX_USER_CONNECTIONS`, jangan pakai `root`.
* **`config.inc.php`** berisi password database — mount sebagai read-only
  (`:ro`) dan jangan commit.
* **Registrasi terbuka**: jika jurnal tidak menerima pendaftaran publik,
  matikan di Site Settings → Registration dan aktifkan CAPTCHA plugin.
* **Akun admin**: satu akun per orang, password kuat, dan hapus akun default
  setelah instalasi.

---

## 7. Verifikasi cepat

```bash
# header keamanan
curl -sI https://ojs.example.org/ | grep -Ei 'strict-transport|x-frame|x-content|referrer|permissions'

# PHP tidak terekspos
curl -sI https://ojs.example.org/ | grep -i 'x-powered-by'   # harus kosong

# eksekusi PHP selain index.php ditolak
curl -s -o /dev/null -w '%{http_code}\n' https://ojs.example.org/config.inc.php   # 403
curl -s -o /dev/null -w '%{http_code}\n' https://ojs.example.org/plugins/generic/x/x.php  # 403

# instalasi tidak dapat diakses ulang
curl -s -o /dev/null -w '%{http_code}\n' https://ojs.example.org/index/install     # 404/403

# rate limit login
for i in $(seq 1 12); do curl -s -o /dev/null -w '%{http_code} ' -X POST https://ojs.example.org/index/login; done; echo
# harapan: 429 setelah beberapa percobaan
```

## 8. Pelaporan

Temuan keamanan pada image ini: buka issue privat atau hubungi maintainer
sebelum mempublikasikan. Kerentanan pada OJS sendiri dilaporkan ke PKP
(<https://pkp.sfu.ca/>), bukan ke repository ini.