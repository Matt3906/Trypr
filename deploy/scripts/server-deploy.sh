#!/usr/bin/env bash
# ============================================================================
# Runs ON THE DROPLET (normally via `./deploy.sh backend` from your laptop).
# Rebuilds ONLY the Trypr backend (+ ensures its Postgres is up). It never touches Refey's
# containers or the shared nginx.
#
#   ./deploy/scripts/server-deploy.sh                # build + restart
#   ROLLBACK=1 ./deploy/scripts/server-deploy.sh     # go back to the previous image
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."

ENV_FILE=".env.production"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE missing. Run: ./deploy.sh setup" >&2; exit 1; }
docker network inspect trypr-net >/dev/null 2>&1 || { echo "ERROR: docker network 'trypr-net' missing. Run: ./deploy.sh setup" >&2; exit 1; }

COMPOSE="docker compose --env-file ${ENV_FILE}"

if [[ "${ROLLBACK:-0}" == "1" ]]; then
  docker image inspect trypr-backend:previous >/dev/null 2>&1 || { echo "ERROR: no previous image to roll back to." >&2; exit 1; }
  echo "==> Rolling back to the previous backend image"
  docker tag trypr-backend:previous trypr-backend:latest
  $COMPOSE up -d --no-build db backend
else
  # Keep the image we're replacing so a bad deploy can be undone with ROLLBACK=1.
  if docker image inspect trypr-backend:latest >/dev/null 2>&1; then
    docker tag trypr-backend:latest trypr-backend:previous
  fi
  echo "==> Building backend image"
  $COMPOSE build backend
  echo "==> Starting / updating db + backend"
  $COMPOSE up -d db backend
fi

echo "==> Waiting for the backend to become healthy"
for i in $(seq 1 30); do
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' trypr-backend 2>/dev/null || echo missing)"
  [[ "$status" == "healthy" ]] && break
  sleep 2
done
if [[ "$status" != "healthy" ]]; then
  echo "ERROR: backend is '$status' after 60s. Last logs:" >&2
  $COMPOSE logs --tail 60 backend >&2
  echo "Undo with: ROLLBACK=1 ./deploy/scripts/server-deploy.sh" >&2
  exit 1
fi

docker image prune -f >/dev/null || true
echo "==> Status (trypr only)"
$COMPOSE ps
echo "OK — backend healthy."
