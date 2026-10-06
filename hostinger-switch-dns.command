#!/usr/bin/env bash
# Opens Hostinger hPanel so you can find your server IP and update DNS.
set -euo pipefail

echo "══════════════════════════════════════════════"
echo "  Switch tryprtravel.com DNS to Hostinger"
echo "══════════════════════════════════════════════"
echo ""
echo "Current A record: 199.36.158.100 (Firebase / Google)"
echo ""
echo "STEP 1 — Find your Hostinger server IP:"
echo "  Opening hPanel now..."
echo ""
open "https://hpanel.hostinger.com/hosting"
sleep 2

echo "  → Go to your hosting plan → click Manage"
echo "  → Your server IP is shown on the overview page"
echo "     (looks like: 185.x.x.x or 31.x.x.x)"
echo ""
echo "STEP 2 — Update your DNS A record:"
echo "  Opening DNS Zone editor now..."
echo ""
open "https://hpanel.hostinger.com/domain/tryprtravel.com/dns"
sleep 1

echo "  → Find the A record for @ (or tryprtravel.com)"
echo "  → Change the value from 199.36.158.100 to your Hostinger server IP"
echo "  → Save changes"
echo ""
echo "STEP 3 — Upload frontend/dist to public_html:"
echo "  Opening File Manager now..."
echo ""
open "https://hpanel.hostinger.com/files/file-manager"
sleep 1

echo "  → Navigate to public_html"
echo "  → Delete old files (or upload to overwrite)"
echo "  → Upload ALL contents of frontend/dist (including .htaccess)"
echo "     TIP: zip the frontend/dist folder, upload the zip, then extract in place"
echo ""
echo "DNS propagation: usually under 1 hour, up to 24h."
echo "You can check progress at: https://dnschecker.org/#A/tryprtravel.com"
echo ""
echo "══════════════════════════════════════════════"
echo ""
echo "Press any key to close..."
read -r -n 1
