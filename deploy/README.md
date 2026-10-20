# Deploying Trypr

```
tryprtravel.com      ─ Hostinger ─ static React build         (./deploy.sh frontend)
api.tryprtravel.com  ─ VPS 165.245.232.212 (shared with Refey)
                         shared-nginx ─► trypr-backend ─► trypr-db        (./deploy.sh backend)
```

Everything is driven from your laptop by `./deploy.sh` (config in `.env.deploy.local`, gitignored).
It never touches Refey's containers. The only shared thing it changes is one extra nginx server block
and one certificate for `api.tryprtravel.com` (`./deploy.sh setup`).

## Everyday

| Command | What it does |
|---|---|
| `npm run ship` (= `./deploy.sh`) | backend first, then frontend |
| `./deploy.sh frontend` | `tool/build_web.sh` with `VITE_API_BASE_URL=https://api.tryprtravel.com`, then rsync `frontend/dist` to Hostinger (removes files that no longer exist; keeps `.well-known`, `cgi-bin`, `tournamentPlanner`) |
| `./deploy.sh backend` | rsync `backend/`, `deploy/`, `docker-compose.yml` to `/apps/trypr`, rebuild and restart on the VPS, wait for healthy, check `https://api.tryprtravel.com/healthz` |
| `./deploy.sh --dry-run [frontend\|backend]` | show what would be uploaded |
| `./deploy.sh status` / `logs` | container state + health / tail backend logs |
| `./deploy.sh rollback` | previous backend image back (the last build is kept as `trypr-backend:previous`) |
| `./deploy.sh pull-backups` | run a backup on the VPS and download it to `./backups/` |

Deploys use the files on your disk (no git push needed). The database and uploads are Docker volumes
and `.env.production` lives only on the server, so a deploy never overwrites them.

## First-time setup (once)

1. **SSH.** Your key must work for both `deploy@165.245.232.212` (VPS) and the Hostinger SSH user
   (hPanel → SSH Access). Check with `./deploy.sh status` once step 4 is done.
2. **DNS** (Hostinger hPanel → DNS): add `A  api  →  165.245.232.212`. Leave `@`/`www` pointing at
   Hostinger.
3. **`./deploy.sh setup`**: creates the `trypr-net` network, `/apps/trypr/.env.production` (with a
   generated database password), issues a certificate for `api.tryprtravel.com` only, and installs
   `deploy/nginx/trypr-api.conf` (validated with `nginx -t`, rolled back if it fails).
   It stops with instructions if the DNS record isn't live yet; re-run it afterwards.
4. **Fill in `/apps/trypr/.env.production`** on the VPS (`ssh deploy@165.245.232.212`, `nano`):
   Stripe keys, `ANTHROPIC_API_KEY`, Gmail API credentials (+ `EMAIL_PROVIDER=gmail_api`) and
   `OPENROUTESERVICE_API_KEY`. Every comment in the file says where the value comes from.
5. **`./deploy.sh backend`**, then `curl https://api.tryprtravel.com/healthz`.
6. **Register your admin account** on the site with an email listed in `ADMIN_EMAILS`.
7. **Stripe**: change the webhook endpoint to `https://api.tryprtravel.com/api/stripe/webhook`
   (events: `checkout.session.completed`, `customer.subscription.created|updated|deleted`) and copy
   the new signing secret into `STRIPE_WEBHOOK_SECRET`.
8. **Backups**: on the VPS run `./deploy/scripts/backup.sh --install-cron` (nightly, 14 days).
   Copy them off the droplet with `./deploy.sh pull-backups`.
9. **`./deploy.sh frontend`** (try `--dry-run` first).

## What lives where

| | Location |
|---|---|
| Users, trips, chat, packing, expenses, friends, pages | Postgres (`trypr-pgdata` volume), tables `accounts`, `sessions`, `documents`, `files` |
| Uploaded files | `trypr-uploads` volume (`/data/uploads` in the container) |
| Secrets | `/apps/trypr/.env.production` (VPS only) |
| Backups | `/apps/trypr/deploy/backups/` |

## Troubleshooting

- **Site loads but nothing saves / "Could not reach the server"**: `./deploy.sh status`, then `logs`.
  A CORS or cookie problem shows up as a blocked request in the browser console: check `CORS_ORIGINS`
  matches the site's exact origin and that the API host is on the `tryprtravel.com` domain.
- **502 from api.tryprtravel.com**: the backend container is down — `./deploy.sh logs`.
- **nginx config diff**: `diff /apps/shared-nginx/nginx/conf.d/trypr-api.conf /apps/trypr/deploy/nginx/trypr-api.conf`.
- **Password-reset emails don't arrive**: until `EMAIL_PROVIDER=gmail_api` is configured the link is only
  written to the backend log (`./deploy.sh logs`).

## Known follow-ups

- The **Tournament Builder** (`/tournamentPlanner`, separate Flutter app) still uses Firebase directly.
  `tool/build_web.sh` keeps building it from `tool/tournament-planner.env`; `deploy.sh` never deletes it.
- Existing Firebase accounts/data were not migrated (fresh start, by decision).
