#!/usr/bin/env bash
set -Eeuo pipefail

# Production migrated to a host-level systemd service in July 2026. Keep this
# familiar entry point safe by forwarding to the systemd deployment workflow.
# The previous Docker image workflow remains available only for manual recovery.
if [[ "${SUB2API_USE_LEGACY_DOCKER_DEPLOY:-0}" != "1" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  exec "${SCRIPT_DIR}/deploy-custom-sub2api-systemd.sh" "$@"
fi

usage() {
  cat <<'USAGE'
Build the local Sub2API source and deploy it to a Docker Compose server by
creating a derived image that only replaces /app/sub2api.

Required when SSH keys are not configured:
  SUB2API_SSH_PASSWORD='your-password'

Common overrides:
  SUB2API_SSH_HOST=45.205.31.15
  SUB2API_SSH_USER=root
  SUB2API_SSH_PORT=22
  SUB2API_CONTAINER_NAME=sub2api
  SUB2API_REMOTE_DIR=/root/sub2api-deploy
  SUB2API_IMAGE_TAG=sub2api:custom-YYYYmmddHHMMSS
  SUB2API_SKIP_FRONTEND_BUILD=1
  SUB2API_SKIP_FRONTEND_INSTALL=1
  SUB2API_BUILD_ONLY=1

Example:
  SUB2API_SSH_PASSWORD='...' ./deploy/deploy-custom-sub2api.sh
USAGE
}

log() {
  printf '[sub2api-deploy] %s\n' "$*"
}

fail() {
  printf '[sub2api-deploy] ERROR: %s\n' "$*" >&2
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
CONTAINER_NAME="${SUB2API_CONTAINER_NAME:-sub2api}"
REMOTE_DIR="${SUB2API_REMOTE_DIR:-/root/sub2api-deploy}"
IMAGE_TAG="${SUB2API_IMAGE_TAG:-sub2api:custom-${DEPLOY_TS}}"
REMOTE_TMP="/tmp/sub2api-custom-deploy-${DEPLOY_TS}"

GO_BIN="${GO_BIN:-go}"
SSH_DEST="${SSH_USER}@${SSH_HOST}"

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

SSH_BASE=(ssh -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new)
SCP_BASE=(scp -P "$SSH_PORT" -o StrictHostKeyChecking=accept-new)

if [[ -n "${SUB2API_SSH_PASSWORD:-}" ]]; then
  require_cmd sshpass
  export SSHPASS="$SUB2API_SSH_PASSWORD"
  SSH_BASE=(sshpass -e "${SSH_BASE[@]}")
  SCP_BASE=(sshpass -e "${SCP_BASE[@]}")
fi

DOCKERFILE_DEPLOY="${BUILD_DIR}/Dockerfile.sub2api-binary"
cat > "$DOCKERFILE_DEPLOY" <<'DOCKERFILE'
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER root
COPY sub2api /app/sub2api
COPY model-pricing /app/resources/model-pricing
RUN chmod 0755 /app/sub2api && \
    find /app/resources/model-pricing -type d -exec chmod 0755 {} \; && \
    find /app/resources/model-pricing -type f -exec chmod 0644 {} \; && \
    if id sub2api >/dev/null 2>&1; then chown sub2api:sub2api /app/sub2api; fi
DOCKERFILE

log "Preparing remote deployment directory ${REMOTE_TMP}"
"${SSH_BASE[@]}" "$SSH_DEST" "mkdir -p '$REMOTE_TMP'"

[[ -d "$MODEL_PRICING_DIR" ]] || fail "Model pricing resources not found: ${MODEL_PRICING_DIR}"

log "Uploading binary, pricing resources, and deployment Dockerfile"
"${SCP_BASE[@]}" "$DIST_BINARY" "${SSH_DEST}:${REMOTE_TMP}/sub2api"
"${SCP_BASE[@]}" -r "$MODEL_PRICING_DIR" "${SSH_DEST}:${REMOTE_TMP}/model-pricing"
"${SCP_BASE[@]}" "$DOCKERFILE_DEPLOY" "${SSH_DEST}:${REMOTE_TMP}/Dockerfile"

log "Building remote derived image and switching compose service"
"${SSH_BASE[@]}" "$SSH_DEST" \
  "CONTAINER_NAME='$CONTAINER_NAME' REMOTE_DIR='$REMOTE_DIR' IMAGE_TAG='$IMAGE_TAG' REMOTE_TMP='$REMOTE_TMP' DEPLOY_TS='$DEPLOY_TS' LOCAL_SHA='$LOCAL_SHA' bash -s" <<'REMOTE_SCRIPT'
set -Eeuo pipefail

log() {
  printf '[sub2api-remote] %s\n' "$*"
}

fail() {
  printf '[sub2api-remote] ERROR: %s\n' "$*" >&2
  exit 1
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    fail "Missing sha256sum or shasum on remote host"
  fi
}

docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || fail "Container ${CONTAINER_NAME} does not exist"

BASE_IMAGE="$(docker inspect "$CONTAINER_NAME" --format '{{.Config.Image}}')"
COMPOSE_DIR="$(docker inspect "$CONTAINER_NAME" --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null || true)"
COMPOSE_SERVICE="$(docker inspect "$CONTAINER_NAME" --format '{{ index .Config.Labels "com.docker.compose.service" }}' 2>/dev/null || true)"

if [[ -z "$COMPOSE_DIR" || "$COMPOSE_DIR" == "<no value>" ]]; then
  COMPOSE_DIR="$REMOTE_DIR"
fi
if [[ -z "$COMPOSE_SERVICE" || "$COMPOSE_SERVICE" == "<no value>" ]]; then
  COMPOSE_SERVICE="$CONTAINER_NAME"
fi
[[ -f "${COMPOSE_DIR}/docker-compose.yml" ]] || fail "docker-compose.yml not found in ${COMPOSE_DIR}"
[[ -f "${REMOTE_TMP}/sub2api" ]] || fail "Uploaded binary not found"
[[ -f "${REMOTE_TMP}/Dockerfile" ]] || fail "Uploaded Dockerfile not found"
[[ -f "${REMOTE_TMP}/model-pricing/model_prices_and_context_window.json" ]] || fail "Uploaded model pricing resource not found"

REMOTE_SHA="$(sha256_file "${REMOTE_TMP}/sub2api")"
if [[ "$REMOTE_SHA" != "$LOCAL_SHA" ]]; then
  fail "Uploaded binary checksum mismatch: local=${LOCAL_SHA}, remote=${REMOTE_SHA}"
fi

BACKUP_DIR="${COMPOSE_DIR}/backups/custom-deploy-${DEPLOY_TS}"
mkdir -p "$BACKUP_DIR"
docker inspect "$CONTAINER_NAME" > "${BACKUP_DIR}/${CONTAINER_NAME}.inspect.json"
docker image inspect "$BASE_IMAGE" > "${BACKUP_DIR}/base-image.inspect.json" 2>/dev/null || true
cp "${COMPOSE_DIR}/docker-compose.yml" "${BACKUP_DIR}/docker-compose.yml"
cp "${COMPOSE_DIR}/.env" "${BACKUP_DIR}/.env" 2>/dev/null || true

HAD_OVERRIDE=0
if [[ -f "${COMPOSE_DIR}/docker-compose.override.yml" ]]; then
  HAD_OVERRIDE=1
  cp "${COMPOSE_DIR}/docker-compose.override.yml" "${BACKUP_DIR}/docker-compose.override.yml"
fi

rollback() {
  log "Rolling back compose override and recreating ${COMPOSE_SERVICE}"
  if [[ "$HAD_OVERRIDE" == "1" ]]; then
    cp "${BACKUP_DIR}/docker-compose.override.yml" "${COMPOSE_DIR}/docker-compose.override.yml"
  else
    rm -f "${COMPOSE_DIR}/docker-compose.override.yml"
  fi
  (cd "$COMPOSE_DIR" && docker compose up -d --no-deps --force-recreate "$COMPOSE_SERVICE") || true
}

log "Base image: ${BASE_IMAGE}"
log "New image: ${IMAGE_TAG}"
docker build --build-arg "BASE_IMAGE=${BASE_IMAGE}" -t "$IMAGE_TAG" "$REMOTE_TMP"

cat > "${COMPOSE_DIR}/docker-compose.override.yml" <<EOF
services:
  ${COMPOSE_SERVICE}:
    image: ${IMAGE_TAG}
    pull_policy: never
EOF

cd "$COMPOSE_DIR"
docker compose config >/dev/null || {
  rollback
  fail "docker compose config validation failed"
}

docker compose up -d --no-deps --force-recreate "$COMPOSE_SERVICE" || {
  rollback
  fail "docker compose recreate failed"
}

CONTAINER_ID="$(docker compose ps -q "$COMPOSE_SERVICE")"
[[ -n "$CONTAINER_ID" ]] || {
  rollback
  fail "compose did not return a container id for ${COMPOSE_SERVICE}"
}

STATUS=""
for _ in $(seq 1 75); do
  STATUS="$(docker inspect "$CONTAINER_ID" --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' 2>/dev/null || true)"
  case "$STATUS" in
    healthy|running)
      break
      ;;
    unhealthy|exited|dead)
      docker logs --tail=160 "$CONTAINER_ID" >&2 || true
      rollback
      fail "container became ${STATUS}"
      ;;
  esac
  sleep 2
done

if [[ "$STATUS" != "healthy" && "$STATUS" != "running" ]]; then
  docker logs --tail=160 "$CONTAINER_ID" >&2 || true
  rollback
  fail "container did not become healthy/running in time; last status=${STATUS:-unknown}"
fi

if [[ "$STATUS" == "healthy" ]]; then
  log "Health check status: healthy"
else
  log "Container status: running"
fi

log "Runtime version:"
docker exec "$CONTAINER_ID" /app/sub2api --version 2>/dev/null || true

rm -rf "$REMOTE_TMP"

log "Deployment complete"
printf 'IMAGE_TAG=%s\n' "$IMAGE_TAG"
printf 'COMPOSE_DIR=%s\n' "$COMPOSE_DIR"
printf 'BACKUP_DIR=%s\n' "$BACKUP_DIR"
printf 'CONTAINER_ID=%s\n' "$CONTAINER_ID"
REMOTE_SCRIPT

log "Done"
