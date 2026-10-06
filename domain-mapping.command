#!/usr/bin/env bash
# Set up Cloud Run domain mapping for tryprtravel.com and print DNS records.
set -euo pipefail

PROJECT_ID="trypr-5ee47"
SERVICE_NAME="trypr-backend"
REGION="northamerica-northeast1"
DOMAIN="tryprtravel.com"

echo "▶ Creating domain mapping for ${DOMAIN}..."
gcloud beta run domain-mappings create \
  --service="${SERVICE_NAME}" \
  --domain="${DOMAIN}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" 2>&1 || true

echo ""
echo "▶ DNS records to set in Hostinger:"
echo ""
gcloud beta run domain-mappings describe \
  --domain="${DOMAIN}" \
  --region="${REGION}" \
  --project="${PROJECT_ID}" \
  --format="yaml(status.resourceRecords)"

echo ""
echo "Press any key to close..."
read -r -n 1
