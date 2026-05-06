#!/usr/bin/env bash
set -euo pipefail

# Deploy hourly Cloud Run Job that marks overdue assignments as expired.
# Required env vars:
#   NETWORK, SUBNET, DB_PASSWORD
# Optional:
#   PROJECT_ID (default: trypr-5ee47)
#   REGION (default: northamerica-northeast1)
#   JOB_NAME (default: trypr-expire-assignments)
#   SERVICE_ACCOUNT_EMAIL (for scheduler invocation)
#   DB_USER, DB_NAME, DB_HOST, DB_PORT
#   SCHEDULER_JOB_NAME (default: trypr-expire-assignments-hourly)

PROJECT_ID="${PROJECT_ID:-trypr-5ee47}"
REGION="${REGION:-northamerica-northeast1}"
JOB_NAME="${JOB_NAME:-trypr-expire-assignments}"
DB_USER="${DB_USER:-postgres}"
DB_NAME="${DB_NAME:-postgres}"
DB_PORT="${DB_PORT:-5432}"
SERVICE_ACCOUNT_EMAIL="${SERVICE_ACCOUNT_EMAIL:-}"
SCHEDULER_JOB_NAME="${SCHEDULER_JOB_NAME:-trypr-expire-assignments-hourly}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)}"
IMAGE="gcr.io/${PROJECT_ID}/trypr-backend:${IMAGE_TAG}"

if [[ -z "${NETWORK:-}" || -z "${SUBNET:-}" ]]; then
  echo "NETWORK and SUBNET are required." >&2
  exit 1
fi

if [[ -z "${DB_PASSWORD:-}" ]]; then
  echo "DB_PASSWORD is required." >&2
  exit 1
fi

if [[ -z "${DB_HOST:-}" ]]; then
  DB_HOST="$(gcloud sql instances describe trypr-main-db \
    --project="${PROJECT_ID}" \
    --format='value(ipAddresses[0].ipAddress)')"
fi

echo "Building image ${IMAGE}"
gcloud builds submit --project="${PROJECT_ID}" --tag "${IMAGE}" .

echo "Deploying Cloud Run Job ${JOB_NAME}"
gcloud run jobs deploy "${JOB_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --image="${IMAGE}" \
  --tasks=1 \
  --max-retries=1 \
  --command="python" \
  --args="-m,app.jobs.expire_assignments" \
  --network="${NETWORK}" \
  --subnet="${SUBNET}" \
  --vpc-egress=private-ranges-only \
  --set-env-vars="ENVIRONMENT=production,DB_USER=${DB_USER},DB_PASSWORD=${DB_PASSWORD},DB_NAME=${DB_NAME},DB_HOST=${DB_HOST},DB_PORT=${DB_PORT},USE_CLOUD_SQL_PROXY=false"

if [[ -n "${SERVICE_ACCOUNT_EMAIL}" ]]; then
  RUN_JOBS_URI="https://${REGION}-run.googleapis.com/apis/run.googleapis.com/v1/namespaces/${PROJECT_ID}/jobs/${JOB_NAME}:run"
  gcloud scheduler jobs create http "${SCHEDULER_JOB_NAME}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --schedule="0 * * * *" \
    --uri="${RUN_JOBS_URI}" \
    --http-method=POST \
    --oauth-service-account-email="${SERVICE_ACCOUNT_EMAIL}" \
    --oauth-token-scope="https://www.googleapis.com/auth/cloud-platform" \
    --attempt-deadline="320s" \
    --description="Runs Cloud Run Job hourly to expire overdue assignments" \
    || gcloud scheduler jobs update http "${SCHEDULER_JOB_NAME}" \
      --project="${PROJECT_ID}" \
      --location="${REGION}" \
      --schedule="0 * * * *" \
      --uri="${RUN_JOBS_URI}" \
      --http-method=POST \
      --oauth-service-account-email="${SERVICE_ACCOUNT_EMAIL}" \
      --oauth-token-scope="https://www.googleapis.com/auth/cloud-platform" \
      --attempt-deadline="320s" \
      --description="Runs Cloud Run Job hourly to expire overdue assignments"

  echo "Hourly scheduler configured: ${SCHEDULER_JOB_NAME}"
else
  echo "SERVICE_ACCOUNT_EMAIL not set. Skipping scheduler creation."
  echo "Manually run with: gcloud run jobs execute ${JOB_NAME} --project=${PROJECT_ID} --region=${REGION}"
fi
