#!/usr/bin/env bash
#
# Back up an OJS database from a MariaDB/MySQL container.
#
#   ./ojs-database-backup.sh <db-container> <db-name> <db-user> [db-password] [backup-dir]
#
# Produces ojs-database-<datetime>.sql.zip. The dump is taken with
# --single-transaction, so the site keeps running and tables are not locked.
#
# Designed for cron (keep the password out of the crontab):
#   . /etc/ojs/backup.env
#   10 2 * * * /opt/ojs/scripts/ojs-database-backup.sh mariadb ojs ojs_backup \
#                >> /var/log/ojs-backup.log 2>&1
#
set -euo pipefail
umask 077

SCRIPT_NAME="ojs-database"
DEFAULT_BACKUP_DIR="/var/backups/ojs"
ARCHIVE_PATTERN="ojs-database-*.sql.zip"

KEEP_COUNT="${KEEP_COUNT:-15}"
OJS_IMAGE="${OJS_IMAGE:-pizaini/ojs-apache:latest}"

usage() {
    cat <<EOF
Usage: $(basename "$0") <db-container> <db-name> <db-user> [db-password] [backup-dir]

Dump a database with mariadb-dump and store it as
ojs-database-<datetime>.sql.zip.

Arguments:
  db-container    name of the MariaDB/MySQL container
  db-name         schema to dump
  db-user         user allowed to read the schema (needs routines/triggers)
  db-password     optional. Prefer OJS_DB_PASSWORD or OJS_DB_PASSWORD_FILE;
                  a password on the command line is visible in \`ps\`.
  backup-dir      optional. Overrides OJS_BACKUP_DIR.

Environment:
  OJS_DB_PASSWORD       password (used when the 4th argument is empty)
  OJS_DB_PASSWORD_FILE  file whose first line is the password
  OJS_BACKUP_DIR        base directory (default: ${DEFAULT_BACKUP_DIR})
  OJS_IMAGE             image used as the zip helper (default: ${OJS_IMAGE})
  KEEP_COUNT            keep the newest N archives (default: 15, 0 = keep all)
EOF
}

log() { printf '[%s] [%s] %s\n' "$(date '+%F %T')" "${SCRIPT_NAME}" "$*"; }
die() {
    local message="$1"
    local code="${2:-3}"
    log "ERROR: ${message}" >&2
    exit "${code}"
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$#" -lt 3 ]; then
    usage >&2
    exit 1
fi

DB_CONTAINER="$1"
DB_NAME="$2"
DB_USER="$3"

DB_PASSWORD="${4:-${OJS_DB_PASSWORD:-}}"
if [ -z "${DB_PASSWORD}" ] && [ -n "${OJS_DB_PASSWORD_FILE:-}" ]; then
    [ -r "${OJS_DB_PASSWORD_FILE}" ] || die "cannot read ${OJS_DB_PASSWORD_FILE}" 1
    DB_PASSWORD="$(head -n 1 "${OJS_DB_PASSWORD_FILE}")"
fi
[ -n "${DB_PASSWORD}" ] || die "no database password provided (argument, OJS_DB_PASSWORD or OJS_DB_PASSWORD_FILE)" 1

BASE_DIR="${5:-${OJS_BACKUP_DIR:-${DEFAULT_BACKUP_DIR}}}"
DEST="${BASE_DIR}/db-${DB_NAME}"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
SQL_NAME="ojs-database-${TIMESTAMP}.sql"
ARCHIVE="ojs-database-${TIMESTAMP}.sql.zip"

command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH"

docker inspect "${DB_CONTAINER}" >/dev/null 2>&1 \
    || die "container '${DB_CONTAINER}' does not exist" 2

docker exec "${DB_CONTAINER}" sh -c 'command -v mariadb-dump >/dev/null' \
    || die "mariadb-dump is not available inside '${DB_CONTAINER}'" 3

docker image inspect "${OJS_IMAGE}" >/dev/null 2>&1 \
    || die "helper image '${OJS_IMAGE}' is not available locally" 3

mkdir -p "${DEST}" 2>/dev/null || die "cannot create ${DEST}; run as root or set OJS_BACKUP_DIR" 3
TMP_DIR="$(mktemp -d "${DEST}/.tmp.XXXXXX")"
trap 'rm -rf "${TMP_DIR}"' EXIT

exec 9>"${DEST}/.lock"
if command -v flock >/dev/null 2>&1; then
    if ! flock -n 9; then
        log "another backup is running for ${DB_CONTAINER}/${DB_NAME}, skipping this run"
        exit 0
    fi
fi

log "dumping ${DB_CONTAINER}:${DB_NAME} as ${DB_USER}"

# The password travels through the environment of the docker CLI, which is
# forwarded into the container with `-e MYSQL_PWD` (no value = inherit).
# It never appears in the process argument list.
MYSQL_PWD="${DB_PASSWORD}" docker exec -e MYSQL_PWD "${DB_CONTAINER}" \
    mariadb-dump \
        -u"${DB_USER}" \
        --single-transaction \
        --quick \
        --routines \
        --triggers \
        --default-character-set=utf8mb4 \
        "${DB_NAME}" > "${TMP_DIR}/${SQL_NAME}" \
    || die "mariadb-dump failed for ${DB_NAME}" 3

[ -s "${TMP_DIR}/${SQL_NAME}" ] || die "dump is empty, refusing to archive" 3

docker run --rm --entrypoint sh \
    -v "${TMP_DIR}:/in:ro" \
    -v "${DEST}:/backup" \
    -e "ARCHIVE=${ARCHIVE}" \
    -e "SQLNAME=${SQL_NAME}" \
    "${OJS_IMAGE}" -c '
        cd /in &&
        zip -q "/backup/${ARCHIVE}" "${SQLNAME}" &&
        unzip -t "/backup/${ARCHIVE}" >/dev/null
    ' || die "failed to create or verify ${ARCHIVE}" 3

chmod 600 "${DEST}/${ARCHIVE}" 2>/dev/null || log "WARNING: could not set 600 on ${ARCHIVE}"
log "created ${DEST}/${ARCHIVE} ($(du -h "${DEST}/${ARCHIVE}" | cut -f1 | tr -d ' '))"

if [ "${KEEP_COUNT}" -gt 0 ] 2>/dev/null; then
    old_files="$(ls -1t "${DEST}"/${ARCHIVE_PATTERN} 2>/dev/null | tail -n +$((KEEP_COUNT + 1)) || true)"
    if [ -n "${old_files}" ]; then
        while IFS= read -r file; do
            log "retention: removing $(basename "${file}")"
            rm -f -- "${file}"
        done <<< "${old_files}"
    fi
fi

log "done"