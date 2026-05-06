# DEPLOYMENT_FINAL

Generated: 2026-04-15

## Production Endpoints

- Cloud Run service: https://trypr-backend-kvucn5wbrq-nn.a.run.app
- Secondary Cloud Run URL: https://trypr-backend-39789168828.northamerica-northeast1.run.app
- API base: https://trypr-backend-kvucn5wbrq-nn.a.run.app/api
- Health checks:
  - /healthz/ (canonical, returns 200)
  - /healthz (currently returns Cloud Run edge 404)

## Internal Infrastructure IPs

- VPC network: default
- Subnet: default (northamerica-northeast1)
- Subnet CIDR: 10.162.0.0/20
- Subnet gateway: 10.162.0.1
- Stalwart VM (trypr-stalwart) internal IP: 10.162.0.2
- Cloud Run egress source observed in SMTP logs: 10.162.0.16
- Cloud SQL instance (trypr-main-db):
  - Primary IP: 34.47.36.217
  - Additional IP: 35.203.85.137

## VPC Routing Map (Portfolio Summary)

- User traffic enters Cloud Run over HTTPS.
- Cloud Run service uses Direct VPC Egress on default/default subnet.
- SMTP traffic from Cloud Run to Stalwart stays private over 10.162.0.0/20.
- Relay policy on Stalwart allows:
  - Source IPs strictly in 10.162.0.0/20, or
  - Authenticated SMTP clients.
- FastAPI backend sends authenticated SMTP over submission (587 + STARTTLS).

```text
Internet Client
    |
    v
Cloud Run: trypr-backend (HTTPS)
    |  (Direct VPC Egress: default/default)
    +--> Stalwart VM 10.162.0.2:587 (SMTP AUTH + STARTTLS)
    |
    +--> Cloud SQL trypr-main-db:5432
```

## Probe and Health Hardening

Cloud Run container probes are configured to use HTTP path /healthz/ on port 8080:

- startupProbe: httpGet.path=/healthz/, httpGet.port=8080
- livenessProbe: httpGet.path=/healthz/, httpGet.port=8080

FastAPI now serves both:

- GET /healthz
- GET /healthz/

Observed externally on Cloud Run:

- GET /healthz/ => 200 {"status":"ok"}
- GET /healthz => 404 (Google/Cloud Run edge response)

## SMTP Hardening Summary

- Dedicated SMTP principal: smtp-gateway
- Dedicated SMTP API key generated and provisioned in Stalwart.
- Cloud Run env vars (sensitive values omitted):
  - SMTP_HOST=10.162.0.2
  - SMTP_PORT=587
  - SMTP_USERNAME=smtp-gateway
  - SMTP_API_KEY=<redacted>
  - SMTP_USE_STARTTLS=true

Latest relay checks:

- Unauthenticated send on port 25 from non-VPC container IP => 550 Relay not allowed.
- Unauthenticated send on port 587 => 503 You must authenticate first.
- Authenticated send on 587 + STARTTLS => accepted and queued.

## Smoke & Fire Verification Script

Script: verify_infrastructure.py

Validates:

1. Cloud Run /healthz/ (required healthy), and /healthz (checked)
2. Assignment API returns 201
3. Assignment row exists in Cloud SQL
4. Stalwart logs include queue.queue-message for referee recipient

Execution notes:

- Default mode accepts known Cloud Run edge behavior where /healthz may return 404 while /healthz/ is healthy.
- Use --strict-health to require both /healthz and /healthz/ to return 200.
- Use --skip-api to run health-only validation when FIREBASE_ID_TOKEN is not available.

Required environment variables:

- FIREBASE_ID_TOKEN
- SMOKE_GAME_ID
- SMOKE_REFEREE_UID
- DB_HOST
- DB_PORT (default 5432)
- DB_NAME (default postgres)
- DB_USER (default postgres)
- DB_PASSWORD

Optional:

- CLOUD_RUN_URL (default set to current production URL)
- GCP_PROJECT
- STALWART_VM_NAME
- STALWART_VM_ZONE

## Security Follow-up

- Rotate DB and SMTP credentials if any plaintext values were exposed during deploy logs or temporary exports.
- Prefer Secret Manager references in Cloud Run for DB_PASSWORD and SMTP_API_KEY on the next deployment iteration.
