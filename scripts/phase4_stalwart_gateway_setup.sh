#!/usr/bin/env bash
set -euo pipefail

# One-command setup for internal Stalwart email gateway.
# Runs VM provisioning and Stalwart deployment.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

bash "${SCRIPT_DIR}/provision_stalwart_vm.sh"
bash "${SCRIPT_DIR}/deploy_stalwart_on_vm.sh"
