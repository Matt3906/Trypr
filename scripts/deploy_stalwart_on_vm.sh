#!/usr/bin/env bash
set -euo pipefail

# Install Docker and run Stalwart mail server on internal VM.
# Optional env vars:
#   PROJECT_ID (default: trypr-5ee47)
#   ZONE (default: northamerica-northeast1-a)
#   VM_NAME (default: trypr-stalwart)
#   STALWART_TAG (default: latest, currently informational)

PROJECT_ID="${PROJECT_ID:-trypr-5ee47}"
ZONE="${ZONE:-northamerica-northeast1-a}"
VM_NAME="${VM_NAME:-trypr-stalwart}"
STALWART_TAG="${STALWART_TAG:-latest}"

read -r -d '' REMOTE_SCRIPT <<'EOF' || true
set -euo pipefail
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor --yes --batch -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
sudo apt-get update -y
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable docker
sudo systemctl start docker
sudo systemctl stop exim4 postfix sendmail 2>/dev/null || true
sudo systemctl disable exim4 postfix sendmail 2>/dev/null || true
sudo mkdir -p /opt/stalwart-mail
sudo docker rm -f stalwart-mail >/dev/null 2>&1 || true
sudo docker run -d \
  --name stalwart-mail \
  --restart unless-stopped \
  -p 25:25 \
  -p 587:587 \
  -p 465:465 \
  -p 143:143 \
  -p 993:993 \
  -p 4190:4190 \
  -p 8080:8080 \
  -v /opt/stalwart-mail:/opt/stalwart-mail \
  ghcr.io/stalwartlabs/stalwart:latest
EOF

gcloud compute ssh "${VM_NAME}" \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --tunnel-through-iap \
  --command "bash -lc '$REMOTE_SCRIPT'"

echo "Stalwart deployed on ${VM_NAME}."
