#!/usr/bin/env bash
# ============================================================================
# Trypr deploy — run from your laptop, repo root.
#
#   ./deploy.sh                 # backend + frontend (same as `all`)
#   ./deploy.sh frontend        # build the React app and push it to Hostinger
#   ./deploy.sh backend         # sync backend to the VPS and rebuild it there
#   ./deploy.sh setup           # ONE-TIME: prepare the VPS (network, env file, TLS cert, nginx block)
#   ./deploy.sh status          # container status + API health check
#   ./deploy.sh logs            # tail the backend logs on the VPS
#   ./deploy.sh rollback        # put the previous backend image back
#   ./deploy.sh pull-backups    # run a backup on the VPS and download the newest copy
#
#   --dry-run    show what would be uploaded; change nothing (frontend still builds)
#
# Config: .env.deploy.local (gitignored; copy .env.deploy.example).
# The website goes to Hostinger over SSH/rsync; the API runs on the VPS (Docker, shared nginx).
# Nothing here touches the Refey containers or the shared nginx, except `setup`, which adds
# one nginx server block + certificate for the API hostname.
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")"

CMD="all"; DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    all|frontend|backend|setup|status|logs|rollback|pull-backups) CMD="$arg" ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg (try --help)" >&2; exit 1 ;;
  esac
done

CONFIG=".env.deploy.local"
[[ -f "$CONFIG" ]] || { echo "ERROR: $CONFIG not found. Run: cp .env.deploy.example $CONFIG  and fill it in." >&2; exit 1; }
set -a; source "$CONFIG"; set +a

need() { for v in "$@"; do [[ -n "${!v:-}" ]] || { echo "ERROR: $v is not set in $CONFIG" >&2; exit 1; }; done; }
API_URL="${API_URL:-https://api.tryprtravel.com}"
VPS_PATH="${VPS_PATH:-/apps/trypr}"
VPS_PORT="${VPS_PORT:-22}"
HOSTINGER_PORT="${HOSTINGER_PORT:-65002}"

ssh_opts() { # $1 port, $2 optional key
  local o=(-p "$1" -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15)
  [[ -n "${2:-}" ]] && o+=(-i "${2/#\~/$HOME}")
  printf '%q ' "${o[@]}"
}
VPS_SSH="ssh $(ssh_opts "$VPS_PORT" "${VPS_SSH_KEY:-}")"
vps() { # run a command on the VPS
  # shellcheck disable=SC2086
  $VPS_SSH "$VPS_USER@$VPS_HOST" "$@"
}

step() { echo; echo "==> $*"; }

# ---------------------------------------------------------------- backend --
sync_backend() {
  need VPS_HOST VPS_USER
  local dry=""; [[ $DRY_RUN == 1 ]] && dry="--dry-run"
  step "Syncing backend to ${VPS_USER}@${VPS_HOST}:${VPS_PATH}"
  vps "mkdir -p '$VPS_PATH/backend' '$VPS_PATH/deploy'"
  local RB=(rsync -rltz --human-readable --itemize-changes -e "$VPS_SSH")
  [[ -n "$dry" ]] && RB+=("$dry")
  local R=("${RB[@]}" --delete)
  # .env.production, deploy/backups and docker volumes live only on the server and are never touched.
  "${R[@]}" --exclude='__pycache__' --exclude='.pytest_cache' --exclude='tests/' --exclude='.venv/' --exclude='.env' \
    --exclude='pytest.ini' --exclude='requirements-dev.txt' \
    backend/ "$VPS_USER@$VPS_HOST:$VPS_PATH/backend/"
  "${R[@]}" --exclude='backups/' deploy/ "$VPS_USER@$VPS_HOST:$VPS_PATH/deploy/"
  "${RB[@]}" docker-compose.yml .env.production.example "$VPS_USER@$VPS_HOST:$VPS_PATH/"
}

deploy_backend() {
  sync_backend
  if [[ $DRY_RUN == 1 ]]; then echo "(dry run: not rebuilding the VPS)"; return; fi
  step "Rebuilding the backend on the VPS"
  vps "cd '$VPS_PATH' && chmod +x deploy/scripts/*.sh && ./deploy/scripts/server-deploy.sh"
  check_health
}

check_health() {
  step "Health check: ${API_URL}/healthz"
  for i in $(seq 1 10); do
    if curl -fsS --max-time 10 "${API_URL}/healthz" >/dev/null 2>&1; then echo "    OK"; return 0; fi
    sleep 3
  done
  echo "WARNING: ${API_URL}/healthz did not answer. Has ./deploy.sh setup been run (DNS + cert + nginx)?" >&2
  return 1
}

# --------------------------------------------------------------- frontend --
deploy_frontend() {
  need HOSTINGER_HOST HOSTINGER_USER HOSTINGER_PATH
  case "$HOSTINGER_PATH" in ""|"/"|"~"|".") echo "ERROR: HOSTINGER_PATH must be the site folder, not '$HOSTINGER_PATH'" >&2; exit 1 ;; esac

  step "Building the React app (API = ${API_URL})"
  # Process env beats frontend/.env.local, so a dev value can't leak into a production build.
  VITE_API_BASE_URL="$API_URL" bash tool/build_web.sh
  [[ -f frontend/dist/index.html && -f frontend/dist/.htaccess ]] || { echo "ERROR: build output incomplete" >&2; exit 1; }
  if grep -rqE "firebaseapp\.com|cloudfunctions\.net|run\.app" frontend/dist/assets 2>/dev/null; then
    echo "WARNING: the build still references Firebase/Google Cloud hosts — check before going live." >&2
  fi

  local o=(-rltz --delete --delete-excluded --exclude=.DS_Store --human-readable --itemize-changes
           # Hostinger-managed or separately deployed folders must survive --delete.
           --filter='P /.well-known/' --filter='P /cgi-bin/' --filter='P /tournamentPlanner/')
  [[ $DRY_RUN == 1 ]] && o+=(--dry-run)
  local ssh_cmd="ssh $(ssh_opts "$HOSTINGER_PORT" "${HOSTINGER_SSH_KEY:-}")"
  step "Uploading to ${HOSTINGER_USER}@${HOSTINGER_HOST}:${HOSTINGER_PATH}"
  rsync "${o[@]}" -e "$ssh_cmd" frontend/dist/ "$HOSTINGER_USER@$HOSTINGER_HOST:$HOSTINGER_PATH/"
  [[ $DRY_RUN == 1 ]] && echo "(dry run: nothing uploaded)" || echo "    Site updated. Hard-refresh once if you still see the old version."
}

# ----------------------------------------------------------------- others --
case "$CMD" in
  all)      deploy_backend; deploy_frontend ;;   # API first: it only ever adds endpoints, so the live site stays compatible
  backend)  deploy_backend ;;
  frontend) deploy_frontend ;;
  setup)
    need VPS_HOST VPS_USER
    sync_backend
    step "Running first-time setup on the VPS"
    vps "cd '$VPS_PATH' && chmod +x deploy/scripts/*.sh && ./deploy/scripts/setup-droplet.sh"
    ;;
  status)
    need VPS_HOST VPS_USER
    vps "cd '$VPS_PATH' && docker compose --env-file .env.production ps"
    check_health || true
    ;;
  logs)
    need VPS_HOST VPS_USER
    vps "cd '$VPS_PATH' && docker compose --env-file .env.production logs -f --tail 100 backend"
    ;;
  rollback)
    need VPS_HOST VPS_USER
    vps "cd '$VPS_PATH' && ROLLBACK=1 ./deploy/scripts/server-deploy.sh"
    check_health
    ;;
  pull-backups)
    need VPS_HOST VPS_USER
    vps "cd '$VPS_PATH' && ./deploy/scripts/backup.sh"
    mkdir -p backups
    # shellcheck disable=SC2086
    rsync -avz -e "$VPS_SSH" "$VPS_USER@$VPS_HOST:$VPS_PATH/deploy/backups/" backups/
    echo "Downloaded to ./backups/"
    ;;
esac
echo; echo "Done."
