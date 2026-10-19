# Trypr — Collaborative Trip Planner

**Live at [tryprtravel.com](https://tryprtravel.com)**

Trypr is a full-stack trip planning web application built because spreadsheets and Google Maps weren't enough. It brings route building, itinerary management, packing lists, shared budgets, and group chat into one place — designed for people who take trip planning seriously.

---

## Tech Stack

| Layer | Technologies |
|---|---|
| Frontend | React 19, TypeScript, Vite (in `frontend/`), static files on Hostinger |
| Backend | Python (FastAPI + asyncpg) in `backend/`, Docker, self-hosted on a VPS |
| Database | PostgreSQL 16 (JSONB document store + auth tables) |
| Auth | Email + password, bcrypt, HttpOnly session cookie |
| Files | Local disk on the VPS (Docker volume) |
| Payments | Stripe |
| Maps & Routing | Google Maps Platform, OpenRouteService, GraphHopper (server-side proxy) |
| AI | Claude API (premium trip suggestions) |
| Deployment | `./deploy.sh` — Hostinger (site) + DigitalOcean droplet (API) |

---

## Features

### Interactive Route Builder
- Multi-stop route planning with support for driving, transit, and waterway (portaging/paddling) routing modes
- Per-segment transport mode selection — mix and match driving legs with canoe portages on a single trip
- 2D map view (Google Maps embed) and an interactive 3D globe view for visualizing trips globally
- Address autocomplete, geocoding, and reverse geocoding via the Google Maps and Geocoding APIs
- Route caching layer to reduce redundant API calls

### Collaboration
- Friend system with friend requests and discovery by username
- Shared trip ownership — invite friends to co-plan a trip in real time
- Group chat embedded inside trip detail pages
- Collaborative packing lists with per-item assignment

### Budget Tracking
- Shared expense ledger per trip, split across participants
- Expense categories (Accommodation, Food, Transport, Activities, Groceries, Shopping, Other)
- Per-person cost breakdown

### AI Suggestions *(Premium)*
- AI-powered accommodation and itinerary suggestions via the backend (Claude API)
- Suggestions are contextual to destination, travel dates, and user preferences

### Premium Tier
- Stripe-powered subscription billing (monthly / yearly plans)
- Checkout and billing portal flows handled server-side via Cloud Run backend

### Admin Panel
- Internal dashboard for managing users, trips, and verified trip content
- Role-gated access enforced by the backend's authorization rules

### Verified Trips
- Curated public trip routes with dedicated detail pages and map views
- SEO-optimized with JSON-LD structured data, Open Graph, and canonical URLs

### Progressive Web App
- Installable PWA with custom splash screen, manifest, and app icons
- Mobile-responsive layout with a separate mobile home screen

---

## Architecture

```
Browser ─► tryprtravel.com      Hostinger: static React build (public_html)
        └► api.tryprtravel.com  VPS: shared nginx (TLS) ─► trypr-backend (FastAPI) ─► trypr-db (Postgres 16)
                                                           └► uploads volume (trip docs/photos)
```

The site talks to the API with a session cookie (`SameSite=Lax`, both hosts share the
`tryprtravel.com` registrable domain). The React app uses a small Firestore-compatible client
(`frontend/src/backend/`) so screens keep the `doc/getDoc/onSnapshot/...` call style, but every call
goes to `/api/db/*`, where `backend/app/docstore/rules.py` enforces the access rules. Live listeners
poll (and refresh immediately after local writes).

The droplet is shared with the Refey portal: one nginx owns ports 80/443 and each app has its own
containers and network. Details and the first-time setup are in [deploy/README.md](deploy/README.md).

---

## Local Development

**Prerequisites:** Node.js ≥ 20, Python ≥ 3.12, PostgreSQL 16.

```bash
# 1. Backend (http://127.0.0.1:8080)
createdb trypr
cd backend
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
DB_NAME=trypr DB_USER=$USER DB_PASSWORD= uvicorn app.main:app --reload --port 8080   # tables are created on start

# 2. Frontend (http://localhost:5173, proxies /api to the backend)
cd frontend
npm install
cp .env.example .env.local   # fill in VITE_GOOGLE_MAPS_API_KEY etc.
npm run dev

# Backend tests (need a Postgres database to run against)
cd backend && TEST_DATABASE_URL=postgresql://localhost/trypr_test pytest
```

Set `ADMIN_EMAILS=you@example.com` for the backend to make that account an admin on sign-in.

## Deploying

```bash
./deploy.sh              # backend (VPS) + frontend (Hostinger)
./deploy.sh frontend     # just the site
./deploy.sh backend      # just the API
./deploy.sh --help
```

First time? See [deploy/README.md](deploy/README.md).

---

## Planned Features

- Hiking / backpacking route mode
- Bikepacking route mode
- Equestrian route mode
- Live trip mode — real-time location sharing and photo upload during active trips (full-quality, no compression)
- Expanded waterway routing (lakes, rivers, portage detection)
