#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Build the local Sub2API source and deploy it to the host-level systemd service.
The deployment replaces only the application binary and model-pricing
resources. It does not modify PostgreSQL, Redis, or application data.

Required when SSH keys are not configured:
  SUB2API_SSH_PASSWORD='your-password'

Common overrides:
  SUB2API_SSH_HOST=45.205.31.15
  SUB2API_SSH_USER=root
  SUB2API_SSH_PORT=22
  SUB2API_REMOTE_APP_DIR=/opt/sub2api
  SUB2API_REMOTE_SERVICE=sub2api.service
  SUB2API_HEALTH_URL=http://127.0.0.1:8080/health
  SUB2API_SKIP_FRONTEND_BUILD=1
  SUB2API_SKIP_FRONTEND_INSTALL=1
  SUB2API_BUILD_ONLY=1

Example:
  SUB2API_SSH_PASSWORD='...' ./deploy/deploy-custom-sub2api-systemd.sh
USAGE
}

log() {
  printf '[sub2api-systemd-deploy] %s\n' "$*"
}

fail() {
  printf '[sub2api-systemd-deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
FRONTEND_DIR="${REPO_ROOT}/frontend"
BACKEND_DIR="${REPO_ROOT}/backend"
MODEL_PRICING_DIR="${BACKEND_DIR}/resources/model-pricing"
BUILD_DIR="${SUB2API_BUILD_DIR:-${REPO_ROOT}/../work/sub2api-deploy-build}"
DIST_BINARY="${BUILD_DIR}/sub2api-linux-amd64"
DEPLOY_TS="$(date -u +%Y%m%d%H%M%S)"

SSH_HOST="${SUB2API_SSH_HOST:-45.205.31.15}"
SSH_USER="${SUB2API_SSH_USER:-root}"
SSH_PORT="${SUB2API_SSH_PORT:-22}"
SSH_CONTROL_PATH="${SUB2API_SSH_CONTROL_PATH:-}"
REMOTE_APP_DIR="${SUB2API_REMOTE_APP_DIR:-/opt/sub2api}"
REMOTE_SERVICE="${SUB2API_REMOTE_SERVICE:-sub2api.service}"
HEALTH_URL="${SUB2API_HEALTH_URL:-http://127.0.0.1:8080/health}"
REMOTE_TMP="/tmp/sub2api-systemd-deploy-${DEPLOY_TS}"
SSH_DEST="${SSH_USER}@${SSH_HOST}"
GO_BIN="${GO_BIN:-go}"

if [[ -n "${PNPM_BIN:-}" ]]; then
  PNPM_CMD=("$PNPM_BIN")
elif command -v corepack >/dev/null 2>&1; then
  PNPM_CMD=(corepack pnpm@9)
else
  PNPM_CMD=(pnpm)
fi

require_cmd "${PNPM_CMD[0]}"
require_cmd "$GO_BIN"
require_cmd ssh
require_cmd scp
require_cmd awk
require_cmd date

mkdir -p "$BUILD_DIR"

if [[ "${SUB2API_SKIP_FRONTEND_BUILD:-0}" != "1" ]]; then
  log "Using pnpm $("${PNPM_CMD[@]}" --version)"
  if [[ "${SUB2API_SKIP_FRONTEND_INSTALL:-0}" != "1" ]]; then
    log "Installing frontend dependencies with frozen lockfile"
    (cd "$FRONTEND_DIR" && CI=true "${PNPM_CMD[@]}" install --frozen-lockfile)
  fi

  log "Building frontend assets"
  (cd "$FRONTEND_DIR" && "${PNPM_CMD[@]}" run build)
else
  log "Skipping frontend build because SUB2API_SKIP_FRONTEND_BUILD=1"
fi

log "Building linux/amd64 backend binary with embedded frontend"
VERSION="$(
  cd "$BACKEND_DIR"
  ./scripts/resolve-version.sh 2>/dev/null || cat cmd/server/VERSION 2>/dev/null || printf 'custom'
)"
COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || printf 'local')"
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain 2>/dev/null)" ]]; then
  COMMIT="${COMMIT}-dirty"
fi
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILD_VERSION="$VERSION"
if [[ "$BUILD_VERSION" != *-custom* ]]; then
  BUILD_VERSION="${BUILD_VERSION}-custom"
fi

(
  cd "$BACKEND_DIR"
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 "$GO_BIN" build \
    -tags embed \
    -ldflags="-s -w -X main.Version=${BUILD_VERSION} -X main.Commit=${COMMIT} -X main.Date=${BUILD_DATE} -X main.BuildType=release" \
    -trimpath \
    -o "$DIST_BINARY" \
    ./cmd/server
)

chmod 0755 "$DIST_BINARY"
LOCAL_SHA="$(sha256_file "$DIST_BINARY")"
log "Built ${DIST_BINARY}"
log "SHA256 ${LOCAL_SHA}"

if [[ "${SUB2API_BUILD_ONLY:-0}" == "1" ]]; then
  log "Build-only mode enabled; skipping remote deployment"
  exit 0
fi

[[ -d "$MODEL_PRICING_DIR" ]] || fail "Model pricing resources not found: ${MODEL_PRICING_DIR}"

SSH_BASE=(ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new)
SCP_BASE=(scp -P "$SSH_PORT" -o StrictHostKeyChecking=accept-new)

if [[ -n "$SSH_CONTROL_PATH" ]]; then
  SSH_BASE+=(-o "ControlPath=${SSH_CONTROL_PATH}")
  SCP_BASE+=(-o "ControlPath=${SSH_CONTROL_PATH}")
fi

if [[ -n "${SUB2API_SSH_PASSWORD:-}" ]]; then
  require_cmd sshpass
  export SSHPASS="$SUB2API_SSH_PASSWORD"
  SSH_BASE=(sshpass -e "${SSH_BASE[@]}")
  SCP_BASE=(sshpass -e "${SCP_BASE[@]}")
fi

log "Uploading binary and model-pricing resources"
"${SSH_BASE[@]}" "$SSH_DEST" "install -d -m 0700 '$REMOTE_TMP'"
"${SCP_BASE[@]}" "$DIST_BINARY" "${SSH_DEST}:${REMOTE_TMP}/sub2api"
"${SCP_BASE[@]}" -r "$MODEL_PRICING_DIR" "${SSH_DEST}:${REMOTE_TMP}/model-pricing"

log "Switching the host service with automatic rollback"
"${SSH_BASE[@]}" "$SSH_DEST" \
  "REMOTE_APP_DIR='$REMOTE_APP_DIR' REMOTE_SERVICE='$REMOTE_SERVICE' HEALTH_URL='$HEALTH_URL' REMOTE_TMP='$REMOTE_TMP' DEPLOY_TS='$DEPLOY_TS' LOCAL_SHA='$LOCAL_SHA' bash -s" <<'REMOTE_SCRIPT'
set -Eeuo pipefail

log() {
  printf '[sub2api-systemd-remote] %s\n' "$*"
}

fail() {
  printf '[sub2api-systemd-remote] ERROR: %s\n' "$*" >&2
  exit 1
}

APP_USER="$(stat -c '%U' "${REMOTE_APP_DIR}/sub2api")"
APP_GROUP="$(stat -c '%G' "${REMOTE_APP_DIR}/sub2api")"
BACKUP_DIR="${REMOTE_APP_DIR}/backups/deploy-${DEPLOY_TS}"
NEW_PRICING_DIR="${REMOTE_APP_DIR}/resources/model-pricing.new-${DEPLOY_TS}"
SWITCHED=0

cleanup() {
  rm -rf "$REMOTE_TMP" "$NEW_PRICING_DIR"
}

rollback() {
  if [[ "$SWITCHED" != "1" ]]; then
    return
  fi

  log "Health check failed; restoring the previous binary and resources"
  install -o "$APP_USER" -g "$APP_GROUP" -m 0755 \
    "${BACKUP_DIR}/sub2api" "${REMOTE_APP_DIR}/sub2api"
  rm -rf "${REMOTE_APP_DIR}/resources/model-pricing"
  cp -a "${BACKUP_DIR}/model-pricing" "${REMOTE_APP_DIR}/resources/model-pricing"
  chown -R "${APP_USER}:${APP_GROUP}" "${REMOTE_APP_DIR}/resources/model-pricing"
  systemctl restart "$REMOTE_SERVICE" || true
}

trap cleanup EXIT
trap 'rollback; exit 1' ERR

systemctl cat "$REMOTE_SERVICE" >/dev/null 2>&1 ||
  fail "systemd service not found: ${REMOTE_SERVICE}"
[[ -f "${REMOTE_APP_DIR}/sub2api" ]] ||
  fail "Current binary not found: ${REMOTE_APP_DIR}/sub2api"
[[ -f "${REMOTE_TMP}/sub2api" ]] ||
  fail "Uploaded binary not found"
[[ -f "${REMOTE_TMP}/model-pricing/model_prices_and_context_window.json" ]] ||
  fail "Uploaded model-pricing resource not found"

REMOTE_SHA="$(sha256sum "${REMOTE_TMP}/sub2api" | awk '{print $1}')"
[[ "$REMOTE_SHA" == "$LOCAL_SHA" ]] ||
  fail "Uploaded binary checksum mismatch"

install -d -o root -g root -m 0700 "$BACKUP_DIR"
cp -a "${REMOTE_APP_DIR}/sub2api" "${BACKUP_DIR}/sub2api"
cp -a "${REMOTE_APP_DIR}/resources/model-pricing" "${BACKUP_DIR}/model-pricing"
systemctl status "$REMOTE_SERVICE" --no-pager > "${BACKUP_DIR}/service-status-before.txt" || true

cp -a "${REMOTE_TMP}/model-pricing" "$NEW_PRICING_DIR"
chown -R "${APP_USER}:${APP_GROUP}" "$NEW_PRICING_DIR"
find "$NEW_PRICING_DIR" -type d -exec chmod 0755 {} +
find "$NEW_PRICING_DIR" -type f -exec chmod 0644 {} +

install -o "$APP_USER" -g "$APP_GROUP" -m 0755 \
  "${REMOTE_TMP}/sub2api" "${REMOTE_APP_DIR}/sub2api.new"
mv -f "${REMOTE_APP_DIR}/sub2api.new" "${REMOTE_APP_DIR}/sub2api"
rm -rf "${REMOTE_APP_DIR}/resources/model-pricing"
mv "$NEW_PRICING_DIR" "${REMOTE_APP_DIR}/resources/model-pricing"
SWITCHED=1

systemctl restart "$REMOTE_SERVICE"
for _ in $(seq 1 75); do
  if curl --fail --silent --show-error --max-time 3 "$HEALTH_URL" >/dev/null; then
    break
  fi
  if systemctl is-failed --quiet "$REMOTE_SERVICE"; then
    exit 1
  fi
  sleep 2
done

curl --fail --silent --show-error --max-time 5 "$HEALTH_URL" >/dev/null
systemctl is-active --quiet "$REMOTE_SERVICE"
INSTALLED_SHA="$(sha256sum "${REMOTE_APP_DIR}/sub2api" | awk '{print $1}')"
[[ "$INSTALLED_SHA" == "$LOCAL_SHA" ]]

trap - ERR
log "Deployment succeeded"
"${REMOTE_APP_DIR}/sub2api" -version 2>&1 | tail -n 1
log "Rollback backup: ${BACKUP_DIR}"
REMOTE_SCRIPT

log "Deployment completed successfully"
