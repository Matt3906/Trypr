#!/usr/bin/env bash
# Step 1 of domain setup: open Google domain verification for tryprtravel.com
set -euo pipefail

echo "Opening Google domain verification in your browser..."
echo ""
echo "When the browser opens:"
echo "  1. Click 'Add property' → enter: tryprtravel.com"
echo "  2. Choose 'Domain' type, click Continue"
echo "  3. Copy the TXT record value shown (looks like: google-site-verification=xxxx)"
echo "  4. Go to Hostinger DNS for tryprtravel.com"
echo "  5. Add a TXT record: Name=@ Value=<the verification string>"
echo "  6. Wait 1-5 min, then click Verify in Search Console"
echo "  7. Once verified, run domain-mapping.command again"
echo ""
gcloud domains verify tryprtravel.com

echo ""
echo "Press any key to close..."
read -r -n 1
