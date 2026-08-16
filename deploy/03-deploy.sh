#!/usr/bin/env bash
# Redeploy: pull the latest code from GitHub onto the running instance,
# reinstall dependencies, refresh secrets, restart the service.
#
# Run this after every `git push`. Takes ~20 seconds.
#
# Usage:  ./deploy/03-deploy.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=./config.sh
source ./deploy/config.sh

_require aws
_require ssh

if [[ -f ./deploy/.instance ]]; then
  # shellcheck disable=SC1091
  source ./deploy/.instance
fi

# Always re-resolve the IP — it changes on stop/start unless you attach an Elastic IP.
INSTANCE_ID="$(aws "${AWS_CLI_ARGS[@]}" ec2 describe-instances \
  --filters "Name=tag:Name,Values=$APP_NAME" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[0].InstanceId' --output text)"
[[ -n "$INSTANCE_ID" && "$INSTANCE_ID" != "None" ]] || {
  echo "ERROR: no running instance tagged '$APP_NAME'. Run ./deploy/02-provision.sh first." >&2; exit 1; }

PUBLIC_IP="$(aws "${AWS_CLI_ARGS[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

printf 'INSTANCE_ID=%s\nPUBLIC_IP=%s\n' "$INSTANCE_ID" "$PUBLIC_IP" > ./deploy/.instance
_banner "Deploying to $INSTANCE_ID ($PUBLIC_IP)"

ssh -i "$KEY_FILE" -o StrictHostKeyChecking=accept-new "ec2-user@$PUBLIC_IP" \
  APP_NAME="$APP_NAME" REPO_BRANCH="$REPO_BRANCH" 'bash -seuo pipefail' <<'REMOTE'
APP_DIR="/opt/${APP_NAME}"
APP_USER="appsvc"

echo "--- pulling ${REPO_BRANCH} ---"
sudo -u "$APP_USER" -H git -C "$APP_DIR" fetch --depth 1 origin "$REPO_BRANCH"
sudo -u "$APP_USER" -H git -C "$APP_DIR" reset --hard "origin/${REPO_BRANCH}"
sudo -u "$APP_USER" -H git -C "$APP_DIR" --no-pager log --oneline -1

echo "--- installing dependencies ---"
sudo -u "$APP_USER" -H "$APP_DIR/.venv/bin/pip" install -q -r "$APP_DIR/requirements.txt"

echo "--- refreshing secrets + restarting ---"
sudo systemctl restart "${APP_NAME}-secrets.service"
sudo systemctl restart "${APP_NAME}.service"
sleep 3
sudo systemctl is-active "${APP_NAME}.service"
sudo systemctl --no-pager --lines=15 status "${APP_NAME}.service" || true
REMOTE

_banner "Health check"
sleep 2
if curl -fsS --max-time 15 "http://${PUBLIC_IP}/api/health"; then
  printf '\n\nDeployed: http://%s/\n' "$PUBLIC_IP"
else
  printf '\nHealth check failed. Inspect logs with:\n  ssh -i %s ec2-user@%s "sudo journalctl -u %s -n 100 --no-pager"\n' \
    "$KEY_FILE" "$PUBLIC_IP" "$APP_NAME"
  exit 1
fi
