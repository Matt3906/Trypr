#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KEY="$DIR/hostinger_upload_key"
chmod 600 "$KEY"

ssh -i "$KEY" -p 65002 -o StrictHostKeyChecking=no u957880581@82.29.157.250 bash <<'REMOTE'
echo "=== All public_html directories ==="
find ~ -maxdepth 5 -name 'public_html' -type d 2>/dev/null

echo ""
echo "=== Home directory listing ==="
ls -la ~/

echo ""
echo "=== ~/domains/ ==="
ls -la ~/domains/ 2>/dev/null || echo "(no ~/domains/)"

echo ""
echo "=== Index files found ==="
find ~ -maxdepth 6 -name 'index.html' 2>/dev/null | head -10
REMOTE

echo ""
echo "Press any key to close..."
read -r -n 1
