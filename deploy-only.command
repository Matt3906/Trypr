#!/usr/bin/env bash
# Deploy the already-built image to Cloud Run (skips Cloud Build).
set -euo pipefail

PROJECT_ID="trypr-5ee47"
SERVICE_NAME="trypr-backend"
REGION="northamerica-northeast1"
IMAGE="gcr.io/trypr-5ee47/trypr-backend:2f0f6bf"

if [[ -z "${DB_PASSWORD:-}" ]]; then
  read -r -s -p "Enter DB_PASSWORD: " DB_PASSWORD
  echo
fi
if [[ -z "${DB_PASSWORD}" ]]; then
  echo "ERROR: DB_PASSWORD is required." >&2
  exit 1
fi

echo "▶ Deploying ${IMAGE} to Cloud Run..."
gcloud run deploy "${SERVICE_NAME}" \
  --project="${PROJECT_ID}" \
  --image="${IMAGE}" \
  --region="${REGION}" \
  --platform=managed \
  --update-env-vars "^|^DB_PASSWORD=${DB_PASSWORD}|CORS_ORIGINS=https://tryprtravel.com,https://refportal.trypr.com|FRONTEND_BASE_URL=https://tryprtravel.com"

echo ""
echo "✓ Deploy complete."
echo ""
echo "Next — set up the domain mapping:"
echo ""
echo "  gcloud beta run domain-mappings create \\"
echo "    --service=${SERVICE_NAME} --domain=tryprtravel.com \\"
echo "    --region=${REGION} --project=${PROJECT_ID}"
echo ""
echo "Then get the DNS records:"
echo ""
echo "  gcloud beta run domain-mappings describe \\"
echo "    --domain=tryprtravel.com \\"
echo "    --region=${REGION} --project=${PROJECT_ID}"
echo ""
echo "Press any key to close..."
read -r -n 1
