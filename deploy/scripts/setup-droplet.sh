#!/usr/bin/env bash
# ============================================================================
# One-time (re-runnable) setup of Trypr on the shared droplet. Run ON THE DROPLET
# (normally via `./deploy.sh setup` from your laptop, which uploads the files first).
#
# What it does — and what it deliberately does NOT touch:
#   1. creates the `trypr-net` docker network (idempotent)
#   2. creates .env.production with generated DB password (never overwrites an existing one)
#   3. checks api.tryprtravel.com DNS points at this droplet
#   4. issues a Let's Encrypt cert for api.tryprtravel.com ONLY (Refey's certs are left alone)
#   5. installs the shared-nginx server block (validated with `nginx -t`, rolled back on failure)
# ============================================================================
set -euo pipefail
cd "$(dirname "$0")/../.."
APP_DIR="$(pwd)"

API_HOST="${API_HOST:-api.tryprtravel.com}"
NGINX_DIR="${NGINX_DIR:-/apps/shared-nginx}"
CONF_NAME="trypr-api.conf"

echo "==> [1/5] Docker network"
docker network inspect trypr-net >/dev/null 2>&1 || docker network create trypr-net
mkdir -p deploy/backups

echo "==> [2/5] .env.production"
if [[ -f .env.production ]]; then
  echo "    exists — leaving it alone"
else
  cp .env.production.example .env.production
  chmod 600 .env.production
  pw="$(openssl rand -hex 24)"
  sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=${pw}/" .env.production
  echo "    created with a generated DB password. STILL TO FILL IN (see the file's comments):"
  echo "      STRIPE_*, ANTHROPIC_API_KEY, GMAIL_* + EMAIL_PROVIDER=gmail_api, OPENROUTESERVICE_API_KEY"
  echo "      edit with: nano ${APP_DIR}/.env.production   then: ./deploy.sh backend"
fi

echo "==> [3/5] DNS for ${API_HOST}"
my_ip="$(curl -fsS https://api.ipify.org || true)"
dns_ip="$(getent hosts "${API_HOST}" | awk '{print $1; exit}' || true)"
echo "    droplet IP: ${my_ip:-unknown}   ${API_HOST} resolves to: ${dns_ip:-nothing}"
if [[ -z "$dns_ip" || ( -n "$my_ip" && "$dns_ip" != "$my_ip" ) ]]; then
  echo "    DNS is not pointing here yet. In Hostinger hPanel -> DNS, add an A record:" >&2
  echo "        api  ->  ${my_ip:-<droplet IP>}" >&2
  echo "    then re-run: ./deploy.sh setup" >&2
  exit 2
fi

echo "==> [4/5] TLS certificate (${API_HOST} only)"
cd "$NGINX_DIR"
if [[ -f "certbot/conf/live/${API_HOST}/fullchain.pem" ]]; then
  echo "    certificate already present"
else
  email="$(sed -n 's/^CERTBOT_EMAIL=//p' .env | tail -n1)"
  [[ -n "$email" ]] || { echo "ERROR: CERTBOT_EMAIL not set in ${NGINX_DIR}/.env" >&2; exit 1; }
  # Port 80's default server (00-http.conf) already serves the ACME challenge for every host.
  docker compose --env-file .env run --rm --entrypoint "\
    certbot certonly --webroot -w /var/www/certbot \
      --email ${email} -d ${API_HOST} --cert-name ${API_HOST} \
      --rsa-key-size 2048 --agree-tos --no-eff-email --non-interactive" certbot
fi
# Keep init-letsencrypt.sh (which re-issues everything in CERT_DOMAINS) aware of this lineage.
if ! grep -q "${API_HOST}" .env; then
  sed -i "s/^CERT_DOMAINS=\"\(.*\)\"/CERT_DOMAINS=\"\1 ${API_HOST}\"/" .env
fi

echo "==> [5/5] nginx server block"
dest="nginx/conf.d/${CONF_NAME}"
[[ -f "$dest" ]] && cp "$dest" "${dest}.bak"
cp "${APP_DIR}/deploy/nginx/trypr-api.conf" "$dest"
if docker compose --env-file .env exec -T nginx nginx -t; then
  docker compose --env-file .env exec -T nginx nginx -s reload
  rm -f "${dest}.bak"
  echo "    nginx reloaded"
else
  echo "ERROR: nginx config test failed — restoring the previous config" >&2
  if [[ -f "${dest}.bak" ]]; then mv "${dest}.bak" "$dest"; else rm -f "$dest"; fi
  exit 1
fi

echo
echo "Setup complete. Next: ./deploy.sh backend   (then: curl https://${API_HOST}/healthz)"
