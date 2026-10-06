#!/usr/bin/env bash
# Rebuild the React web app (frontend/) with Firebase Function URLs baked in.
# Run this before uploading to Hostinger.
set -euo pipefail

cd "$(dirname "$0")"

# Firebase Function URLs (routeProxy and overpassProxy, deployed to us-central1)
ROUTE_URL="https://us-central1-trypr-5ee47.cloudfunctions.net/routeProxy"
OVERPASS_URL="https://us-central1-trypr-5ee47.cloudfunctions.net/overpassProxy"

echo "══════════════════════════════════════════════"
echo "  Rebuilding web app for Hostinger"
echo "══════════════════════════════════════════════"
echo ""
echo "  VITE_ROUTING_PROXY_URL  = $ROUTE_URL"
echo "  VITE_OVERPASS_PROXY_URL = $OVERPASS_URL"
echo ""
echo "  Google Maps key is read from frontend/.env.local (VITE_GOOGLE_MAPS_API_KEY)."
echo ""

VITE_ROUTING_PROXY_URL="$ROUTE_URL" \
VITE_OVERPASS_PROXY_URL="$OVERPASS_URL" \
SKIP_TOURNAMENT_PLANNER_BUILD="${SKIP_TOURNAMENT_PLANNER_BUILD:-0}" \
bash tool/build_web.sh

echo ""
echo "══════════════════════════════════════════════"
echo "✓ Build complete — frontend/dist is ready."
echo ""
echo "NEXT STEPS:"
echo ""
echo "1. Upload frontend/dist contents to Hostinger public_html"
echo "   (include .htaccess — it handles SPA routing)"
echo ""
echo "2. Find your Hostinger server IP:"
echo "   hPanel → Hosting → Manage → copy the IP shown on the dashboard"
echo ""
echo "3. In Hostinger DNS Zone:"
echo "   Change the A record for @ from 199.36.158.100 to your Hostinger server IP"
echo "   (propagation takes up to 24h, usually under 1h)"
echo ""
echo "4. Once DNS propagates, tryprtravel.com will be served by Hostinger."
echo "══════════════════════════════════════════════"
echo ""
echo "Press any key to close..."
read -r -n 1
