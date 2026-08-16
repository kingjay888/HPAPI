#!/usr/bin/env bash
# Tear everything down so you stop paying for it.
# Prompts before doing anything destructive.
#
# Usage:  ./deploy/99-destroy.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=./config.sh
source ./deploy/config.sh

_require aws

echo "This will delete the following in $AWS_REGION (account $(aws "${AWS_CLI_ARGS[@]}" sts get-caller-identity --query Account --output text)):"
echo "  - EC2 instances tagged Name=$APP_NAME"
echo "  - security group $SG_NAME"
echo "  - key pair $KEY_NAME"
echo "  - IAM role $IAM_ROLE_NAME and instance profile $INSTANCE_PROFILE_NAME"
echo "  - secret $SECRET_NAME (scheduled for deletion, 7-day recovery window)"
read -r -p "Type the app name to confirm: " CONFIRM
[[ "$CONFIRM" == "$APP_NAME" ]] || { echo "Aborted."; exit 1; }

IDS="$(aws "${AWS_CLI_ARGS[@]}" ec2 describe-instances \
  --filters "Name=tag:Name,Values=$APP_NAME" "Name=instance-state-name,Values=pending,running,stopped" \
  --query 'Reservations[].Instances[].InstanceId' --output text)"
if [[ -n "$IDS" && "$IDS" != "None" ]]; then
  # shellcheck disable=SC2086
  aws "${AWS_CLI_ARGS[@]}" ec2 terminate-instances --instance-ids $IDS >/dev/null
  echo "terminating: $IDS (waiting)"
  # shellcheck disable=SC2086
  aws "${AWS_CLI_ARGS[@]}" ec2 wait instance-terminated --instance-ids $IDS
fi

aws "${AWS_CLI_ARGS[@]}" ec2 delete-key-pair --key-name "$KEY_NAME" >/dev/null 2>&1 && echo "deleted key pair" || true

VPC_ID="$(aws "${AWS_CLI_ARGS[@]}" ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
SG_ID="$(aws "${AWS_CLI_ARGS[@]}" ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)"
[[ "$SG_ID" != "None" ]] && aws "${AWS_CLI_ARGS[@]}" ec2 delete-security-group --group-id "$SG_ID" && echo "deleted security group" || true

aws "${AWS_CLI_ARGS[@]}" iam remove-role-from-instance-profile \
  --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1 || true
aws "${AWS_CLI_ARGS[@]}" iam delete-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1 || true
aws "${AWS_CLI_ARGS[@]}" iam delete-role-policy --role-name "$IAM_ROLE_NAME" --policy-name "${APP_NAME}-read-secret" >/dev/null 2>&1 || true
aws "${AWS_CLI_ARGS[@]}" iam detach-role-policy --role-name "$IAM_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null 2>&1 || true
aws "${AWS_CLI_ARGS[@]}" iam delete-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1 && echo "deleted IAM role" || true

aws "${AWS_CLI_ARGS[@]}" secretsmanager delete-secret --secret-id "$SECRET_NAME" \
  --recovery-window-in-days 7 >/dev/null 2>&1 && echo "secret scheduled for deletion (7-day window)" || true

rm -f ./deploy/.instance
echo "Done."
