#!/usr/bin/env bash
set -euo pipefail

# Build and deploy FastAPI backend to Cloud Run with Direct VPC Egress.
# Required env vars:
#   PROJECT_ID, NETWORK, SUBNET, DB_PASSWORD
# Optional:
#   SERVICE_NAME (default: trypr-backend)
#   REGION (default: northamerica-northeast1)
#   SQL_INSTANCE (default: trypr-main-db)
#   STALWART_INTERNAL_IP (required for internal SMTP gateway)
#   SMTP_PORT (default: 587)
#   SMTP_SENDER (default: no-reply@refportal.trypr.com)
#   SMTP_USERNAME (default: smtp-gateway)
#   SMTP_API_KEY (optional, recommended)
#   SMTP_PASSWORD (optional)
#   SMTP_USE_STARTTLS (default: true)
#   FRONTEND_BASE_URL (default: https://refportal.trypr.com)
#   CORS_ORIGINS (default: FRONTEND_BASE_URL)
#   VPC_EGRESS (default: private-ranges-only)
#   DB_USER (default: postgres)
#   DB_NAME (default: postgres)
#   DB_HOST (autodetected from SQL_INSTANCE private/public IP if not provided)
#   IMAGE_TAG (default: git short sha)

PROJECT_ID="${PROJECT_ID:-trypr-5ee47}"
SERVICE_NAME="${SERVICE_NAME:-trypr-backend}"
REGION="${REGION:-northamerica-northeast1}"
SQL_INSTANCE="${SQL_INSTANCE:-trypr-main-db}"
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:-postgres}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)}"
IMAGE="gcr.io/${PROJECT_ID}/${SERVICE_NAME}:${IMAGE_TAG}"
SMTP_PORT="${SMTP_PORT:-587}"
SMTP_SENDER="${SMTP_SENDER:-no-reply@refportal.trypr.com}"
SMTP_USERNAME="${SMTP_USERNAME:-smtp-gateway}"
SMTP_API_KEY="${SMTP_API_KEY:-}"
SMTP_PASSWORD="${SMTP_PASSWORD:-}"
SMTP_USE_STARTTLS="${SMTP_USE_STARTTLS:-true}"
FRONTEND_BASE_URL="${FRONTEND_BASE_URL:-https://refportal.trypr.com}"
CORS_ORIGINS="${CORS_ORIGINS:-${FRONTEND_BASE_URL}}"
VPC_EGRESS="${VPC_EGRESS:-private-ranges-only}"

if [[ -z "${NETWORK:-}" || -z "${SUBNET:-}" ]]; then
  echo "NETWORK and SUBNET are required for Direct VPC Egress." >&2
  exit 1
fi

if [[ -z "${DB_PASSWORD:-}" ]]; then
  echo "DB_PASSWORD is required." >&2
  exit 1
fi

if [[ -z "${STALWART_INTERNAL_IP:-}" ]]; then
  echo "STALWART_INTERNAL_IP is required." >&2
  exit 1
fi

if [[ -z "${DB_HOST:-}" ]]; then
  DB_HOST="$(gcloud sql instances describe "${SQL_INSTANCE}" \
    --project="${PROJECT_ID}" \
    --format='value(ipAddresses[0].ipAddress)')"
fi

echo "Building container image: ${IMAGE}"
gcloud builds submit --project="${PROJECT_ID}" --tag "${IMAGE}" .

echo "Deploying Cloud Run service: ${SERVICE_NAME} (${REGION})"
gcloud run deploy "${SERVICE_NAME}" \
  --project="${PROJECT_ID}" \
  --image="${IMAGE}" \
  --region="${REGION}" \
  --platform=managed \
  --ingress=all \
  --allow-unauthenticated \
  --port=8080 \
  --startup-probe="httpGet.path=/healthz/,httpGet.port=8080,timeoutSeconds=10,periodSeconds=20,failureThreshold=3" \
  --liveness-probe="httpGet.path=/healthz/,httpGet.port=8080,timeoutSeconds=10,periodSeconds=30,failureThreshold=3" \
  --network="${NETWORK}" \
  --subnet="${SUBNET}" \
  --vpc-egress="${VPC_EGRESS}" \
  --set-env-vars="ENVIRONMENT=production,FIREBASE_PROJECT_ID=${PROJECT_ID},CORS_ORIGINS=${CORS_ORIGINS},FRONTEND_BASE_URL=${FRONTEND_BASE_URL},DB_USER=${DB_USER},DB_PASSWORD=${DB_PASSWORD},DB_NAME=${DB_NAME},DB_HOST=${DB_HOST},DB_PORT=5432,USE_CLOUD_SQL_PROXY=false,SMTP_HOST=${STALWART_INTERNAL_IP},SMTP_PORT=${SMTP_PORT},SMTP_SENDER=${SMTP_SENDER},SMTP_USERNAME=${SMTP_USERNAME},SMTP_API_KEY=${SMTP_API_KEY},SMTP_PASSWORD=${SMTP_PASSWORD},SMTP_USE_STARTTLS=${SMTP_USE_STARTTLS}"

echo "Deployment complete."
