# syntax=docker/dockerfile:1
#
# OJS 3 + Apache + PHP production image
#
# OJS source is downloaded and baked into the image at build time so container
# starts are reproducible and do not depend on outbound internet access.
# Override the version/checksum at build time:
#
#   docker build \
#     --build-arg OJS_VERSION=3.5.0-5 \
#     --build-arg OJS_SHA256=<sha256-of-tarball> \
#     -t pizaini/ojs-apache:local .
#
FROM php:8.3-apache

LABEL org.opencontainers.image.title="ojs-apache" \
      org.opencontainers.image.description="OJS 3 with Apache and PHP, ready to run" \
      org.opencontainers.image.authors="pizaini <https://github.com/pizaini>" \
      org.opencontainers.image.source="https://github.com/pizaini/ojs-apache"

# OJS release baked into the image (pinned, not downloaded at runtime).
ARG OJS_VERSION=3.5.0-5
# Optional sha256 of the release tarball. Set it to make builds verifiable.
ARG OJS_SHA256=

ENV OJS_VERSION=${OJS_VERSION} \
    APACHE_DOCUMENT_ROOT=/var/www/html \
    OJS_FILES_DIR=/var/www/ojs-data \
    OJS_SESSION_DIR=/var/lib/php/sessions \
    OJS_TARBALL=/opt/ojs/ojs-${OJS_VERSION}.tar.gz \
    OJS_SCHEDULER_INTERVAL=300 \
    OJS_QUEUE_SLEEP=30 \
    OJS_REDIRECT_HTTPS=0 \
    OJS_SSL_CN=localhost \
    OJS_ENABLE_SSL=0 \
    OJS_TRUSTED_PROXIES= \
    OJS_MEMORY_LIMIT=256M \
    OJS_OPCACHE_MB=128 \
    OJS_OPCACHE_STRINGS_MB=16 \
    OJS_REALPATH_KB=2048 \
    APACHE_START_SERVERS=2 \
    APACHE_MAX_REQUEST_WORKERS=12

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Runtime + build dependencies in a single layer, cleaned immediately.
# Note: no compiler toolchain / pecl extensions here. OJS needs none of them,
# and they only made the image bigger and the build more fragile.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        openssl \
        supervisor \
        zip \
        unzip \
        libpng-dev \
        libjpeg-dev \
        libfreetype6-dev \
        libicu-dev \
        libzip-dev \
        libxml2-dev \
        libonig-dev \
        libcurl4-openssl-dev \
        zlib1g-dev; \
    docker-php-ext-configure gd --with-freetype --with-jpeg; \
    docker-php-ext-install -j"$(nproc)" \
        bcmath \
        exif \
        gd \
        mysqli \
        pdo_mysql \
        gettext \
        intl \
        curl \
        zip \
        xml \
        mbstring \
        ftp \
        opcache; \
    rm -rf /var/lib/apt/lists/*

# Directory layout used by the entrypoint.
# Apache logs go to /var/log/apache2 (set by /etc/apache2/envvars), which
# supersedes any APACHE_LOG_DIR set through ENV.
RUN set -eux; \
    mkdir -p \
        /etc/apache2/ssl \
        /opt/ojs \
        "${OJS_FILES_DIR}" \
        "${OJS_SESSION_DIR}" \
        "${APACHE_DOCUMENT_ROOT}"; \
    chmod 1733 "${OJS_SESSION_DIR}"

# Fetch, verify and unpack the OJS release once, at build time.
# The code is baked into the document root (owned by www-data) so container
# start does no copying. The tarball is kept as a restore source: it is used
# only when the document root is empty, e.g. with a bind-mounted directory.
RUN set -eux; \
    url="https://pkp.sfu.ca/ojs/download/ojs-${OJS_VERSION}.tar.gz"; \
    echo "Downloading ${url}"; \
    curl -fsSL --retry 3 --retry-delay 5 --max-time 300 "${url}" -o "${OJS_TARBALL}"; \
    if [ -n "${OJS_SHA256}" ]; then \
        echo "${OJS_SHA256}  ${OJS_TARBALL}" | sha256sum -c -; \
    else \
        echo "WARNING: OJS_SHA256 not set, release tarball was not verified"; \
    fi; \
    tar -xzf "${OJS_TARBALL}" -C "${APACHE_DOCUMENT_ROOT}" --strip-components=1; \
    test -f "${APACHE_DOCUMENT_ROOT}/index.php"; \
    printf 'ok\n' > "${APACHE_DOCUMENT_ROOT}/healthz.txt"; \
    printf '%s\n' "${OJS_VERSION}" > "${APACHE_DOCUMENT_ROOT}/.ojs-version"; \
    chown -R www-data:www-data "${APACHE_DOCUMENT_ROOT}" "${OJS_FILES_DIR}"

# Configuration files.
COPY docker/php-apache/conf/php.ini "${PHP_INI_DIR}/php.ini"
COPY docker/php-apache/conf/apache2.conf "${APACHE_CONFDIR}/apache2.conf"
COPY docker/php-apache/conf/000-default.conf "${APACHE_CONFDIR}/sites-available/000-default.conf"
# Cap the worker count: the PHP image default (150) can reserve gigabytes per
# container when many OJS instances share a host.
COPY docker/php-apache/conf/mpm_prefork.conf "${APACHE_CONFDIR}/mods-available/mpm_prefork.conf"
# HTTPS vhost is shipped but not enabled; the entrypoint enables it only when
# OJS_ENABLE_SSL=1.
COPY docker/php-apache/conf/ssl-vhost.conf "${APACHE_CONFDIR}/ojs-ssl-vhost.conf"
COPY docker/supervisord.conf /etc/supervisor/conf.d/supervisord.conf

# Entrypoint.
COPY docker/run.sh /usr/local/bin/run.sh
RUN chmod +x /usr/local/bin/run.sh

# Apache modules: a2enmod handles the symlinks, no manual `ln -s` needed.
# mod_ssl is enabled here for OJS_ENABLE_SSL=1 and disabled at runtime when the
# container only serves port 80 behind a reverse proxy.
RUN a2enmod rewrite headers ssl remoteip

WORKDIR /var/www/html

# Persistent locations.
#
#   /var/www/ojs-data  submissions, uploads, caches (back this up)
#   /var/www/html      OJS code, plus custom themes, edited templates and the
#                      public files directory
#
# The document root is seeded from the image the first time a volume is
# attached. After that the volume wins, so pulling a new image does not replace
# the code. Upgrading is deliberately manual: see README "Upgrading".
VOLUME ["/var/www/ojs-data", "/var/www/html"]

# Port 80 is always served. 443 is only bound when OJS_ENABLE_SSL=1; when the
# container sits behind nginx, only 80 needs to be published.
EXPOSE 80
EXPOSE 443

# Liveness probe against a static file: it proves Apache and the filesystem are
# healthy without booting PHP or querying the database on every check. With
# dozens of containers that difference is real load. Application-level checks
# (PHP + DB) belong to external monitoring.
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -fsS -o /dev/null http://127.0.0.1/healthz.txt || exit 1

ENTRYPOINT ["/usr/local/bin/run.sh"]
