#!/usr/bin/env bash
set -Eeuo pipefail

SYSTEMD_SERVICE="${SUB2API_SYSTEMD_SERVICE:-sub2api.service}"
CONTAINER_NAME="${SUB2API_CONTAINER_NAME:-sub2api}"
HEALTH_URL="${SUB2API_HEALTH_URL:-http://127.0.0.1:8080/health}"

log() {
  printf '[sub2api-rollback] %s\n' "$*"
}

if systemctl is-active --quiet "$SYSTEMD_SERVICE"; then
  log "Stopping host service ${SYSTEMD_SERVICE}"
  systemctl stop "$SYSTEMD_SERVICE"
fi

systemctl disable "$SYSTEMD_SERVICE" >/dev/null 2>&1 || true

log "Starting preserved Docker container ${CONTAINER_NAME}"
docker start "$CONTAINER_NAME" >/dev/null

for _ in $(seq 1 60); do
  if curl --fail --silent --show-error --max-time 3 "$HEALTH_URL" >/dev/null; then
    log "Rollback completed; Docker application is healthy"
    exit 0
  fi
  sleep 2
done

docker logs --tail=120 "$CONTAINER_NAME" >&2 || true
log "Docker container started, but the health check did not pass"
exit 1
