#!/usr/bin/env bash
# Deploy the React web build (frontend/dist) to Firebase Hosting
set -euo pipefail

cd "$(dirname "$0")"

[[ -f frontend/dist/index.html ]] || bash tool/build_web.sh

echo "▶ Deploying frontend/dist to Firebase Hosting..."
firebase deploy --only hosting

echo ""
echo "✓ Firebase Hosting deploy complete."
echo "  tryprtravel.com should be live within a minute."
echo ""
echo "Press any key to close..."
read -r -n 1
