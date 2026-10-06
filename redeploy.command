#!/usr/bin/env bash
# Double-click this file to rebuild and redeploy Trypr to Cloud Run.
cd "$(dirname "$0")"
bash scripts/redeploy_web.sh
echo ""
echo "Press any key to close this window..."
read -r -n 1
