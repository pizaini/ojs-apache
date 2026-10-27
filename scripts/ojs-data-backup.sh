#!/usr/bin/env bash
#
# Back up the OJS data directory (/var/www/ojs-data) from a container.
#
#   ./ojs-data-backup.sh <ojs-container> [backup-dir]
#
# Contains submissions, uploaded files and caches. Nothing is excluded.
#
# Designed for cron:
#   35 2 * * * /opt/ojs/scripts/ojs-data-backup.sh ojs-j1 >> /var/log/ojs-backup.log 2>&1
#
set -euo pipefail
umask 077

SCRIPT_NAME="ojs-data"
DEFAULT_BACKUP_DIR="/var/backups/ojs"
CONTAINER_PATH="/var/www/ojs-data"
ARCHIVE_PATTERN="ojs-data-*.zip"

KEEP_COUNT="${KEEP_COUNT:-15}"
OJS_IMAGE="${OJS_IMAGE:-pizaini/ojs-apache:latest}"

usage() {
    cat <<EOF
Usage: $(basename "$0") <ojs-container> [backup-dir]

Back up ${CONTAINER_PATH} as ojs-data-<datetime>.zip.

Arguments:
  ojs-container   name of the running (or stopped) OJS container

Environment:
  OJS_BACKUP_DIR  base directory for archives (default: ${DEFAULT_BACKUP_DIR})
  OJS_IMAGE       image used as the zip helper  (default: ${OJS_IMAGE})
  KEEP_COUNT      keep the newest N archives, older ones are deleted
                  (default: 15, 0 disables pruning)
EOF
}

log() { printf '[%s] [%s] %s\n' "$(date '+%F %T')" "${SCRIPT_NAME}" "$*"; }
die() { local message="$1"; local code="${2:-3}"; log "ERROR: ${message}" >&2; exit "${code}"; }

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

if [ "$#" -lt 1 ]; then
    usage >&2
    exit 1
fi

CONTAINER="$1"
BASE_DIR="${2:-${OJS_BACKUP_DIR:-${DEFAULT_BACKUP_DIR}}}"
DEST="${BASE_DIR}/${CONTAINER}"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
ARCHIVE="ojs-data-${TIMESTAMP}.zip"

command -v docker >/dev/null 2>&1 || die "docker is not installed or not in PATH"

docker inspect "${CONTAINER}" >/dev/null 2>&1 \
    || die "container '${CONTAINER}' does not exist" 2

docker image inspect "${OJS_IMAGE}" >/dev/null 2>&1 \
    || die "helper image '${OJS_IMAGE}' is not available locally" 3

if ! docker inspect -f '{{range .Mounts}}{{.Destination}} {{end}}' "${CONTAINER}" \
        | tr ' ' '\n' | grep -qx "${CONTAINER_PATH}"; then
    die "container '${CONTAINER}' has no volume at ${CONTAINER_PATH}; nothing to back up" 2
fi

mkdir -p "${DEST}" 2>/dev/null || die "cannot create ${DEST}; run as root or set OJS_BACKUP_DIR" 3

exec 9>"${DEST}/.lock"
if command -v flock >/dev/null 2>&1; then
    if ! flock -n 9; then
        log "another backup is running for ${CONTAINER}, skipping this run"
        exit 0
    fi
fi

log "backing up ${CONTAINER}:${CONTAINER_PATH}"

docker run --rm --entrypoint sh \
    --volumes-from "${CONTAINER}:ro" \
    -v "${DEST}:/backup" \
    -e "ARCHIVE=${ARCHIVE}" \
    "${OJS_IMAGE}" -c '
        cd '"${CONTAINER_PATH}"' &&
        zip -qr "/backup/${ARCHIVE}" . &&
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