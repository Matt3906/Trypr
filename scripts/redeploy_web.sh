#!/usr/bin/env bash
# redeploy_web.sh — rebuild backend image with the React web build (frontend/dist) and redeploy.
# Usage:
#   DB_PASSWORD="..." bash scripts/redeploy_web.sh
# Or run without DB_PASSWORD and the script will prompt for it.
set -euo pipefail

PROJECT_ID="trypr-5ee47"
SERVICE_NAME="trypr-backend"
REGION="northamerica-northeast1"
IMAGE_TAG="$(git -C "$(dirname "$0")/.." rev-parse --short HEAD 2>/dev/null || date +%Y%m%d%H%M%S)"
IMAGE="gcr.io/${PROJECT_ID}/${SERVICE_NAME}:${IMAGE_TAG}"

# Prompt for DB_PASSWORD if not set in the environment
if [[ -z "${DB_PASSWORD:-}" ]]; then
  read -r -s -p "Enter DB_PASSWORD: " DB_PASSWORD
  echo
fi
if [[ -z "${DB_PASSWORD}" ]]; then
  echo "ERROR: DB_PASSWORD is required." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# The image bundles the prebuilt React app; build it first if it is missing.
if [[ ! -f "${PROJECT_DIR}/frontend/dist/index.html" ]]; then
  echo "frontend/dist not found — running tool/build_web.sh first..."
  bash "${PROJECT_DIR}/tool/build_web.sh"
fi

echo "──────────────────────────────────────────"
echo "Image:   $IMAGE"
echo "Service: $SERVICE_NAME ($REGION)"
echo "──────────────────────────────────────────"

# Step 1: Submit source to Cloud Build (builds & pushes the image)
echo ""
echo "▶ Building image via Cloud Build..."
gcloud builds submit \
  --project="${PROJECT_ID}" \
  --tag "${IMAGE}" \
  "${PROJECT_DIR}"

# Step 2: Deploy the new image to Cloud Run, keeping all existing settings.
#         Only the image and CORS/frontend URL env vars are updated.
echo ""
echo "▶ Deploying to Cloud Run..."
gcloud run deploy "${SERVICE_NAME}" \
  --project="${PROJECT_ID}" \
  --image="${IMAGE}" \
  --region="${REGION}" \
  --platform=managed \
  --update-env-vars "^|^DB_PASSWORD=${DB_PASSWORD}|CORS_ORIGINS=https://tryprtravel.com,https://refportal.trypr.com|FRONTEND_BASE_URL=https://tryprtravel.com"

echo ""
echo "✓ Deploy complete — image ${IMAGE_TAG} is live."
echo ""
echo "Next: set up the Cloud Run domain mapping for tryprtravel.com."
echo "Run this command to create the mapping and get the DNS records:"
echo ""
echo "  gcloud beta run domain-mappings create \\"
echo "    --service=${SERVICE_NAME} \\"
echo "    --domain=tryprtravel.com \\"
echo "    --region=${REGION} \\"
echo "    --project=${PROJECT_ID}"
echo ""
echo "Then run this to see the DNS records to set in Hostinger:"
echo ""
echo "  gcloud beta run domain-mappings describe \\"
echo "    --domain=tryprtravel.com \\"
echo "    --region=${REGION} \\"
echo "    --project=${PROJECT_ID}"
