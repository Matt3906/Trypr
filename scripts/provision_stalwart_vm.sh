#!/usr/bin/env bash
set -euo pipefail

# Provision internal-email gateway VM (Stalwart host) with static internal IP.
# Optional env vars:
#   PROJECT_ID (default: trypr-5ee47)
#   REGION (default: northamerica-northeast1)
#   ZONE (default: northamerica-northeast1-a)
#   NETWORK (default: default)
#   SUBNET (default: default)
#   VM_NAME (default: trypr-stalwart)
#   INTERNAL_IP_NAME (default: trypr-stalwart-ip)

PROJECT_ID="${PROJECT_ID:-trypr-5ee47}"
REGION="${REGION:-northamerica-northeast1}"
ZONE="${ZONE:-northamerica-northeast1-a}"
NETWORK="${NETWORK:-default}"
SUBNET="${SUBNET:-default}"
VM_NAME="${VM_NAME:-trypr-stalwart}"
INTERNAL_IP_NAME="${INTERNAL_IP_NAME:-trypr-stalwart-ip}"
MACHINE_TYPE="${MACHINE_TYPE:-e2-micro}"

if ! gcloud compute addresses describe "${INTERNAL_IP_NAME}" --project="${PROJECT_ID}" --region="${REGION}" >/dev/null 2>&1; then
  gcloud compute addresses create "${INTERNAL_IP_NAME}" \
    --project="${PROJECT_ID}" \
    --region="${REGION}" \
    --subnet="${SUBNET}" \
    --purpose=GCE_ENDPOINT
fi

INTERNAL_IP="$(gcloud compute addresses describe "${INTERNAL_IP_NAME}" \
  --project="${PROJECT_ID}" \
  --region="${REGION}" \
  --format='value(address)')"

echo "Using static internal IP: ${INTERNAL_IP}"

if ! gcloud compute instances describe "${VM_NAME}" --project="${PROJECT_ID}" --zone="${ZONE}" >/dev/null 2>&1; then
  gcloud compute instances create "${VM_NAME}" \
    --project="${PROJECT_ID}" \
    --zone="${ZONE}" \
    --machine-type="${MACHINE_TYPE}" \
    --network-interface="network=${NETWORK},subnet=${SUBNET},private-network-ip=${INTERNAL_IP},no-address" \
    --image-family="debian-12" \
    --image-project="debian-cloud" \
    --boot-disk-size="20GB" \
    --boot-disk-type="pd-balanced" \
    --tags="stalwart-internal-mail"
fi

echo "VM provisioned."
echo "Name: ${VM_NAME}"
echo "Zone: ${ZONE}"
echo "Internal IP: ${INTERNAL_IP}"
