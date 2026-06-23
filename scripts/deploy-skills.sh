#!/usr/bin/env bash
# Deploy skills from this repo to Hermes on Hostinger.
# Usage: bash scripts/deploy-skills.sh
#
# Prerequisites:
#   - SSH access configured in ~/.ssh/config as "hermes-paley"
#   - Or set HERMES_SSH env var: user@host
#
# To set up SSH alias, add to ~/.ssh/config:
#   Host hermes-paley
#     HostName <your-hostinger-server-ip>
#     User <your-hostinger-username>
#     Port 22

set -euo pipefail

REMOTE="${HERMES_SSH:-hermes-paley}"
REMOTE_PATH="/data/skills/crm-ops"
LOCAL_PATH="$(dirname "$0")/../skills/"

echo "Deploying skills to $REMOTE:$REMOTE_PATH ..."
rsync -avz --delete "$LOCAL_PATH" "$REMOTE:$REMOTE_PATH"
echo "Done."
