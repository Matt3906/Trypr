#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
KEY="$DIR/hostinger_upload_key"
SSH_HOST="82.29.157.250"
SSH_PORT="65002"
SSH_USER="u957880581"

chmod 600 "$KEY"

echo "══════════════════════════════════════════════"
echo "  Fixing permissions on Hostinger"
echo "══════════════════════════════════════════════"
echo ""

ssh -i "$KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no "$SSH_USER@$SSH_HOST" bash <<'REMOTE'
set -e

# Find tryprtravel.com public_html
if [ -d "$HOME/domains/tryprtravel.com/public_html" ]; then
  DIR="$HOME/domains/tryprtravel.com/public_html"
elif [ -d "$HOME/public_html" ]; then
  DIR="$HOME/public_html"
fi

echo "Target: $DIR"
echo ""

# Fix directory permissions (755) and file permissions (644)
find "$DIR" -type d -exec chmod 755 {} \;
find "$DIR" -type f -exec chmod 644 {} \;

echo "Permissions fixed."
echo ""
echo "Files in public_html:"
ls -la "$DIR" | head -20
REMOTE

echo ""
echo "══════════════════════════════════════════════"
echo "✓ Done. Try visiting tryprtravel.com now."
echo "══════════════════════════════════════════════"
echo ""
echo "Press any key to close..."
read -r -n 1
