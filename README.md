# Trypr — Collaborative Trip Planner

**Live at [tryprtravel.com](https://tryprtravel.com)**

Trypr is a full-stack trip planning web application built because spreadsheets and Google Maps weren't enough. It brings route building, itinerary management, packing lists, shared budgets, and group chat into one place — designed for people who take trip planning seriously.

---

## Tech Stack

| Layer | Technologies |
|---|---|
| Frontend | React 19, TypeScript, Vite (in `frontend/`) |
| Backend | Python (FastAPI), Docker, Cloud Run |
| Database | Firebase Firestore, Firebase Storage |
| Auth | Firebase Auth, Google Sign-In |
| Payments | Stripe |
| Maps & Routing | Google Maps Platform, OpenRouteService, GraphHopper |
| AI | Firebase Cloud Functions + LLM-backed suggestions |
| Deployment | Hostinger (VPS), Google Cloud Console, Google Cloud Run |

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
- AI-powered accommodation and itinerary suggestions via Firebase Cloud Functions
- Suggestions are contextual to destination, travel dates, and user preferences

### Premium Tier
- Stripe-powered subscription billing (monthly / yearly plans)
- Checkout and billing portal flows handled server-side via Cloud Run backend

### Admin Panel
- Internal dashboard for managing users, trips, and verified trip content
- Role-gated access via Firestore security rules

### Verified Trips
- Curated public trip routes with dedicated detail pages and map views
- SEO-optimized with JSON-LD structured data, Open Graph, and canonical URLs

### Progressive Web App
- Installable PWA with custom splash screen, manifest, and app icons
- Mobile-responsive layout with a separate mobile home screen

---

## Architecture

```
tryprtravel.com  (React web app — Hostinger VPS via Google Cloud Console)
    │
    ├── Firebase Auth          — user identity & Google Sign-In
    ├── Cloud Firestore        — trips, users, friends, packing lists, expenses
    ├── Firebase Storage       — trip photos and user assets
    ├── Cloud Functions        — AI suggestion endpoints (Node/Python)
    │
    └── Cloud Run (FastAPI)    — premium billing logic, Stripe webhooks,
                                 background jobs (Python 3.13, Docker)
```

Firestore security rules enforce per-user data isolation and role-based access for admin features. The React app is a single-page app (react-router) that talks to Firebase directly from the browser; the FastAPI container serves the built `frontend/dist` with a client-side-routing fallback.

---

## Local Development

**Prerequisites:** Node.js ≥ 20, Firebase CLI, a Firebase project with Auth / Firestore / Storage enabled.

```bash
# Install dependencies and configure browser keys
cd frontend
npm install
cp .env.example .env.local   # then fill in VITE_GOOGLE_MAPS_API_KEY etc.

# Run the dev server (proxies /api to the FastAPI backend on :8080)
npm run dev

# Production build (outputs frontend/dist) — or `bash tool/build_web.sh` from the repo root
npm run build

# Run the FastAPI backend locally
cd app
uvicorn app.main:app --reload --port 8080

# Or via Docker
docker compose up
```

---

## Planned Features

- Hiking / backpacking route mode
- Bikepacking route mode
- Equestrian route mode
- Live trip mode — real-time location sharing and photo upload during active trips (full-quality, no compression)
- Expanded waterway routing (lakes, rivers, portage detection)
