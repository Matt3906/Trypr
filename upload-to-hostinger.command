#!/usr/bin/env bash
# Upload the rebuilt Flutter web app to Hostinger via SFTP.
# The SSH key was already added to your Hostinger account.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
KEY="$DIR/hostinger_upload_key"
ZIP="$DIR/trypr-hostinger.zip"
SSH_HOST="82.29.157.250"
SSH_PORT="65002"
SSH_USER="u957880581"

echo "══════════════════════════════════════════════"
echo "  Uploading to Hostinger via SFTP"
echo "══════════════════════════════════════════════"
echo ""

if [[ ! -f "$KEY" ]]; then
  echo "ERROR: SSH key not found at $KEY" >&2
  exit 1
fi
if [[ ! -f "$ZIP" ]]; then
  echo "ERROR: Zip not found at $ZIP" >&2
  exit 1
fi

chmod 600 "$KEY"

# Detect the correct public_html path
echo "▶ Detecting public_html path on server..."
REMOTE_DIR=$(ssh -i "$KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no "$SSH_USER@$SSH_HOST" bash <<'DETECT'
# Try addon domain path first, then primary domain path
if [ -d "$HOME/domains/tryprtravel.com/public_html" ]; then
  echo "$HOME/domains/tryprtravel.com/public_html"
elif [ -d "$HOME/public_html" ]; then
  echo "$HOME/public_html"
else
  # Create the addon domain path
  mkdir -p "$HOME/domains/tryprtravel.com/public_html"
  echo "$HOME/domains/tryprtravel.com/public_html"
fi
DETECT
)
echo "  → Using: $REMOTE_DIR"

echo ""
echo "▶ Uploading trypr-hostinger.zip (80MB)..."
sftp -i "$KEY" -P "$SSH_PORT" -o StrictHostKeyChecking=no "$SSH_USER@$SSH_HOST" <<EOF
put "$ZIP" $REMOTE_DIR/trypr-hostinger.zip
EOF

echo ""
echo "▶ Extracting on server..."
ssh -i "$KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no "$SSH_USER@$SSH_HOST" bash <<REMOTE
set -e
cd "$REMOTE_DIR"
echo "Removing old files..."
find . -mindepth 1 -not -name 'trypr-hostinger.zip' -delete 2>/dev/null || true
echo "Extracting zip..."
unzip -o trypr-hostinger.zip
rm trypr-hostinger.zip
echo "Done. Files in $REMOTE_DIR:"
ls -la | head -20
REMOTE

echo ""
echo "══════════════════════════════════════════════"
echo "✓ Upload complete! tryprtravel.com is on Hostinger."
echo ""
echo "DNS propagation is in progress (usually < 1 hour)."
echo "Check: https://dnschecker.org/#A/tryprtravel.com"
echo "══════════════════════════════════════════════"
echo ""
echo "Press any key to close..."
read -r -n 1
