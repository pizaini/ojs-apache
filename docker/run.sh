#!/bin/bash
#
# OJS container entrypoint.
#
# Responsibilities:
#   1. Configure TLS: HTTP-only on port 80 by default (behind a reverse proxy),
#      or Apache-served HTTPS on 443 when OJS_ENABLE_SSL=1.
#   1b. Trust the reverse proxy for X-Forwarded-For / X-Forwarded-Proto.
#   2. Populate the document root with the OJS release baked into the image.
#   3. Optional HTTP -> HTTPS redirect (OJS_REDIRECT_HTTPS=1).
#   4. Fix ownership so Apache and the queue workers can both write.
#   5. Hand over to supervisord (Apache + queue worker + scheduler).
#
set -euo pipefail

OJS_VERSION="${OJS_VERSION:-3.5.0-5}"
OJS_TARBALL="${OJS_TARBALL:-/opt/ojs/ojs-${OJS_VERSION}.tar.gz}"
OJS_ROOT="${APACHE_DOCUMENT_ROOT:-/var/www/html}"
OJS_FILES_DIR="${OJS_FILES_DIR:-/var/www/ojs-data}"
OJS_RUN_USER="${OJS_RUN_USER:-www-data}"
OJS_RUN_GROUP="${OJS_RUN_GROUP:-www-data}"

SSL_DIR="/etc/apache2/ssl"
SSL_CRT="${SSL_DIR}/ssl.crt"
SSL_KEY="${SSL_DIR}/ssl.key"
SSL_CN="${OJS_SSL_CN:-localhost}"

REDIRECT_CONF="/etc/apache2/conf-enabled/ojs-https-redirect.conf"

log() {
    echo "[ojs-entrypoint] $*"
}

# OJS ships its own version marker. Read it instead of keeping a copy that can
# go stale; <tag>3_5_0-5</tag> normalises to 3.5.0-5, matching OJS_VERSION.
read_code_version() {
    local file="${OJS_ROOT}/dbscripts/xml/version.xml"
    [ -f "${file}" ] || return 1
    local tag
    tag="$(tr -d '\n' < "${file}" \
        | sed -n 's:.*<tag>[[:space:]]*\([^<]*\)</tag>.*:\1:p')"
    [ -n "${tag}" ] || return 1
    printf '%s\n' "${tag//_/.}"
}

# ---------------------------------------------------------------------------
# 1. TLS (optional)
#
# The default is HTTP-only on port 80, because the usual deployment puts this
# container behind nginx/HAProxy/Traefik which terminates TLS. Set
# OJS_ENABLE_SSL=1 only when Apache itself must serve HTTPS on port 443.
# ---------------------------------------------------------------------------
SSL_VHOST_SRC="${SSL_VHOST_SRC:-/etc/apache2/ojs-ssl-vhost.conf}"
SSL_VHOST_ENABLED="/etc/apache2/conf-enabled/ojs-ssl-vhost.conf"

case "${OJS_ENABLE_SSL:-0}" in
    1|true|TRUE|yes|on)
        mkdir -p "${SSL_DIR}"

        if [ -s "${SSL_CRT}" ] && [ -s "${SSL_KEY}" ]; then
            log "Using existing certificate at ${SSL_CRT}"
        else
            log "No certificate found, generating self-signed certificate (CN=${SSL_CN})"
            openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
                -keyout "${SSL_KEY}" \
                -out "${SSL_CRT}" \
                -subj "/CN=${SSL_CN}" \
                -addext "subjectAltName=DNS:${SSL_CN}" >/dev/null 2>&1
            chmod 600 "${SSL_KEY}"
            log "WARNING: self-signed certificate in use. For production mount your own"
            log "         certificate to ${SSL_CRT} and ${SSL_KEY}."
        fi

        ln -sf "${SSL_VHOST_SRC}" "${SSL_VHOST_ENABLED}"
        a2enmod ssl >/dev/null
        log "HTTPS enabled: Apache also listens on port 443"
        ;;
    *)
        rm -f "${SSL_VHOST_ENABLED}"
        a2dismod ssl >/dev/null 2>&1 || true
        log "HTTPS disabled: Apache listens on port 80 only (TLS is expected to be"
        log "                terminated by the reverse proxy in front of it)."
        ;;
esac

# ---------------------------------------------------------------------------
# 1b. Reverse proxy awareness
#
# OJS must keep generating https:// URLs when the proxy terminates TLS, and it
# should see the real client IP instead of the proxy address. mod_remoteip only
# rewrites REMOTE_ADDR for the proxies listed in OJS_TRUSTED_PROXIES, so a
# client sending a forged X-Forwarded-For header cannot spoof its address.
# ---------------------------------------------------------------------------
PROXY_CONF="/etc/apache2/conf-enabled/ojs-proxy.conf"

if [ -n "${OJS_TRUSTED_PROXIES:-}" ]; then
    {
        echo "RemoteIPHeader X-Forwarded-For"
        IFS=',' read -r -a trusted_proxies <<< "${OJS_TRUSTED_PROXIES}"
        for proxy in "${trusted_proxies[@]}"; do
            proxy="${proxy//[[:space:]]/}"
            if [ -n "${proxy}" ]; then
                echo "RemoteIPTrustedProxy ${proxy}"
            fi
        done
    } > "${PROXY_CONF}"
    log "Trusting X-Forwarded-For from proxy addresses: ${OJS_TRUSTED_PROXIES}"
else
    rm -f "${PROXY_CONF}"
    log "OJS_TRUSTED_PROXIES is empty: client IPs will be logged as the proxy address"
fi

# ---------------------------------------------------------------------------
# 2. OJS application
#
# The document root is baked into the image, so a normal start does no file
# copying (378 MB / 34k files per instance would be a serious I/O burst when
# many containers restart together). The release tarball is kept in the image
# and is only unpacked when the document root is empty, e.g. when a bind mount
# replaces it or a backup was restored without code.
# ---------------------------------------------------------------------------
NEED_CHOWN=0

if [ ! -f "${OJS_ROOT}/index.php" ]; then
    mkdir -p "${OJS_ROOT}"

    if [ -f "${OJS_TARBALL}" ]; then
        log "No OJS found in ${OJS_ROOT}, restoring from ${OJS_TARBALL}"
        tar -xzf "${OJS_TARBALL}" -C "${OJS_ROOT}" --strip-components=1
    else
        # Last resort: no baked tarball at all.
        tmp_dir="$(mktemp -d)"
        url="https://pkp.sfu.ca/ojs/download/ojs-${OJS_VERSION}.tar.gz"
        log "No baked OJS tarball, downloading ${url}"
        curl -fsSL --retry 3 --retry-delay 5 --max-time 300 "${url}" \
            -o "${tmp_dir}/ojs.tar.gz"
        if [ -n "${OJS_SHA256:-}" ]; then
            echo "${OJS_SHA256}  ${tmp_dir}/ojs.tar.gz" | sha256sum -c -
        else
            log "WARNING: OJS_SHA256 not set, downloaded tarball was not verified"
        fi
        tar -xzf "${tmp_dir}/ojs.tar.gz" -C "${OJS_ROOT}" --strip-components=1
        rm -rf "${tmp_dir}"
    fi

    NEED_CHOWN=1
else
    log "OJS already present in ${OJS_ROOT}, skipping unpack"

    # The release tarball ships config.inc.php with `installed = Off`, which
    # makes OJS report "maintenance mode" to every CLI job. A document root
    # restored from a backup (or a volume seeded by an older image) may lack it
    # entirely. Seed both from the template so the queue worker and scheduler
    # can run as soon as the site is installed.
    if [ ! -f "${OJS_ROOT}/config.inc.php" ]; then
        if [ -f "${OJS_ROOT}/config.TEMPLATE.inc.php" ]; then
            log "config.inc.php missing, seeding it from config.TEMPLATE.inc.php"
            cp "${OJS_ROOT}/config.TEMPLATE.inc.php" "${OJS_ROOT}/config.inc.php"
            NEED_CHOWN=1
        else
            log "WARNING: neither config.inc.php nor config.TEMPLATE.inc.php exists in ${OJS_ROOT}"
        fi
    fi

    # The document root may be a volume seeded by an older image. Never
    # overwrite user edits automatically: warn and let the operator decide.
    if code_version="$(read_code_version)"; then
        if [ "${code_version}" != "${OJS_VERSION}" ]; then
            log "WARNING: code in the volume is ${code_version} but the image ships ${OJS_VERSION}."
            log "         The volume wins. Upgrade manually (README: Upgrading) or"
            log "         recreate the code volume to adopt the image version."
        else
            log "Code version ${code_version} matches the image"
        fi
    else
        log "WARNING: cannot read ${OJS_ROOT}/dbscripts/xml/version.xml."
        log "         The volume is authoritative; upgrade it manually (see README)."
    fi
fi

# The liveness probe reads this file. Recreate it on every start so a deleted or
# restored-away healthz.txt cannot leave the container permanently unhealthy.
# Note: deleting it while the container runs still fails the probe until the
# next restart; the entrypoint only runs at start.
if [ ! -s "${OJS_ROOT}/healthz.txt" ]; then
    log "healthz.txt missing, recreating"
    if printf 'ok\n' > "${OJS_ROOT}/healthz.txt" 2>/dev/null; then
        chown "${OJS_RUN_USER}:${OJS_RUN_GROUP}" "${OJS_ROOT}/healthz.txt" 2>/dev/null || true
    else
        log "WARNING: could not create ${OJS_ROOT}/healthz.txt (read-only mount?)"
    fi
fi

mkdir -p "${OJS_FILES_DIR}"

# ---------------------------------------------------------------------------
# 2b. PHP runtime profile
#
# The same image serves every tier, so the values that differ per tier come from
# the environment instead of baked files. Sessions go to a dedicated directory
# (tmpfs in the compose files) so they never grow the data volume.
# ---------------------------------------------------------------------------
mkdir -p "${OJS_SESSION_DIR}"
chmod 1733 "${OJS_SESSION_DIR}" 2>/dev/null || true

RUNTIME_INI="/usr/local/etc/php/conf.d/zz-ojs-runtime.ini"
cat > "${RUNTIME_INI}" <<EOF
; Generated by the OJS entrypoint at container start. Do not edit.
session.save_path = "${OJS_SESSION_DIR}"
session.gc_maxlifetime = 86400
memory_limit = ${OJS_MEMORY_LIMIT:-256M}
opcache.memory_consumption = ${OJS_OPCACHE_MB:-128}
opcache.interned_strings_buffer = ${OJS_OPCACHE_STRINGS_MB:-16}
realpath_cache_size = ${OJS_REALPATH_KB:-2048}k
EOF

log "PHP profile: memory_limit=${OJS_MEMORY_LIMIT:-256M} opcache=${OJS_OPCACHE_MB:-128}M realpath=${OJS_REALPATH_KB:-2048}k sessions=${OJS_SESSION_DIR}"
log "Apache workers: max=${APACHE_MAX_REQUEST_WORKERS:-12} start=${APACHE_START_SERVERS:-2}"

if [ ! -f "${OJS_ROOT}/config.inc.php" ]; then
    log "WARNING: config.inc.php not found. Finish the installation via the web installer"
    log "         or restore your configuration before exposing this instance."
fi

# ---------------------------------------------------------------------------
# 3. Optional HTTP -> HTTPS redirect
# ---------------------------------------------------------------------------
case "${OJS_REDIRECT_HTTPS:-0}" in
    1|true|TRUE|yes|on)
        log "Enabling HTTP -> HTTPS redirect"
        cat > "${REDIRECT_CONF}" <<'EOF'
<IfModule mod_rewrite.c>
    RewriteEngine On
    RewriteCond %{HTTPS} !=on
    RewriteCond %{HTTP:X-Forwarded-Proto} !https
    RewriteRule ^(.*)$ https://%{HTTP_HOST}$1 [R=301,L]
</IfModule>
EOF
        ;;
    *)
        rm -f "${REDIRECT_CONF}"
        ;;
esac

# ---------------------------------------------------------------------------
# 4. Ownership
# ---------------------------------------------------------------------------
# Application code is baked into the image and already owned by www-data, so a
# normal start does no recursive chown. The full walk (34k files) only happens
# after an unpack or when a restored/copied tree has the wrong owner.
if [ "${NEED_CHOWN}" = "1" ] || \
   [ "$(stat -c '%U' "${OJS_ROOT}/index.php" 2>/dev/null || echo unknown)" != "${OJS_RUN_USER}" ]; then
    log "Setting ownership of ${OJS_ROOT} to ${OJS_RUN_USER}:${OJS_RUN_GROUP}"
    if ! chown -R "${OJS_RUN_USER}:${OJS_RUN_GROUP}" "${OJS_ROOT}"; then
        log "WARNING: could not change ownership of ${OJS_ROOT} (read-only mount?)."
        log "         Make sure Apache and the queue workers can write to the"
        log "         cache and files directories."
    fi
else
    log "Ownership of ${OJS_ROOT} already correct, skipping recursive chown"
fi

if [ -n "$(find "${OJS_FILES_DIR}" \! -user "${OJS_RUN_USER}" -print -quit 2>/dev/null)" ]; then
    log "Fixing ownership of ${OJS_FILES_DIR}"
    chown -R "${OJS_RUN_USER}:${OJS_RUN_GROUP}" "${OJS_FILES_DIR}" || \
        log "WARNING: could not change ownership of ${OJS_FILES_DIR}"
else
    log "Ownership of ${OJS_FILES_DIR} already correct, skipping recursive chown"
fi

# ---------------------------------------------------------------------------
# 5. Start services
# ---------------------------------------------------------------------------
log "Starting supervisord"
exec supervisord -c /etc/supervisor/conf.d/supervisord.conf
