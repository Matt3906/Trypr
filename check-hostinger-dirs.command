#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
KEY="$DIR/hostinger_upload_key"
SSH_HOST="82.29.157.250"
SSH_PORT="65002"
SSH_USER="u957880581"

chmod 600 "$KEY"

echo "══════════════════════════════════════════════"
echo "  Checking Hostinger directory structure"
echo "══════════════════════════════════════════════"
echo ""

ssh -i "$KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no "$SSH_USER@$SSH_HOST" bash <<'REMOTE'
echo "=== HOME ==="
ls -la ~/ | head -30
echo ""
echo "=== ~/domains/ ==="
ls -la ~/domains/ 2>/dev/null || echo "(no domains dir)"
echo ""
echo "=== ~/public_html/ ==="
ls ~/public_html/ 2>/dev/null | head -5 || echo "(no public_html dir)"
echo ""
echo "=== First file in each domain dir ==="
for d in ~/domains/*/public_html; do
  echo "$d:"
  ls "$d" 2>/dev/null | head -3 || echo "  (empty)"
done
REMOTE

echo ""
echo "Press any key to close..."
read -r -n 1
