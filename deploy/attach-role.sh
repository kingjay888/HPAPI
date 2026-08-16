#!/usr/bin/env bash
#
# Run this on YOUR MAC (not the instance).
#
# Creates a least-privilege IAM role that can read exactly one Secrets Manager
# secret, and attaches it to your already-running EC2 instance. Without this the
# instance has no way to read the secret and the app falls back to its local .env.
#
# Usage:
#     ./deploy/attach-role.sh                    # auto-detects a single running instance
#     INSTANCE_ID=i-0abc123 ./deploy/attach-role.sh
#
# Safe to re-run.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=./config.sh
source ./deploy/config.sh

_require aws

INSTANCE_ID="${INSTANCE_ID:-}"

if [[ -z "$INSTANCE_ID" ]]; then
  _banner "Finding your running instances"
  aws "${AWS_CLI_ARGS[@]}" ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running" \
    --query 'Reservations[].Instances[].{ID:InstanceId,Name:Tags[?Key==`Name`]|[0].Value,IP:PublicIpAddress,Type:InstanceType}' \
    --output table

  COUNT="$(aws "${AWS_CLI_ARGS[@]}" ec2 describe-instances \
    --filters "Name=instance-state-name,Values=running" \
    --query 'length(Reservations[].Instances[])' --output text)"

  if [[ "$COUNT" == "1" ]]; then
    INSTANCE_ID="$(aws "${AWS_CLI_ARGS[@]}" ec2 describe-instances \
      --filters "Name=instance-state-name,Values=running" \
      --query 'Reservations[0].Instances[0].InstanceId' --output text)"
    echo "Using the only running instance: $INSTANCE_ID"
  else
    echo
    echo "Found $COUNT running instances. Re-run with the one you want:" >&2
    echo "  INSTANCE_ID=i-xxxxxxxx $0" >&2
    exit 1
  fi
fi

SECRET_ARN="$(aws "${AWS_CLI_ARGS[@]}" secretsmanager describe-secret \
  --secret-id "$SECRET_NAME" --query ARN --output text 2>/dev/null || true)"
if [[ -z "$SECRET_ARN" || "$SECRET_ARN" == "None" ]]; then
  echo "ERROR: secret '$SECRET_NAME' not found in $AWS_REGION." >&2
  echo "Run ./deploy/01-put-secrets.sh first." >&2
  exit 1
fi
echo "Secret: $SECRET_ARN"

# --------------------------------------------------------------- IAM role ----
_banner "IAM role"
if ! aws "${AWS_CLI_ARGS[@]}" iam get-role --role-name "$IAM_ROLE_NAME" >/dev/null 2>&1; then
  aws "${AWS_CLI_ARGS[@]}" iam create-role \
    --role-name "$IAM_ROLE_NAME" \
    --description "EC2 role for $APP_NAME" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
    }' >/dev/null
  echo "created role $IAM_ROLE_NAME"
else
  echo "role $IAM_ROLE_NAME already exists"
fi

aws "${AWS_CLI_ARGS[@]}" iam put-role-policy \
  --role-name "$IAM_ROLE_NAME" \
  --policy-name "${APP_NAME}-read-secret" \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[{
      \"Effect\":\"Allow\",
      \"Action\":[\"secretsmanager:GetSecretValue\",\"secretsmanager:DescribeSecret\"],
      \"Resource\":\"${SECRET_ARN}\"
    }]
  }"
echo "policy scoped to that one secret only"

aws "${AWS_CLI_ARGS[@]}" iam attach-role-policy \
  --role-name "$IAM_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null

if ! aws "${AWS_CLI_ARGS[@]}" iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  aws "${AWS_CLI_ARGS[@]}" iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null
  aws "${AWS_CLI_ARGS[@]}" iam add-role-to-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$IAM_ROLE_NAME"
  echo "created instance profile (waiting 15s for IAM to propagate)"
  sleep 15
else
  echo "instance profile already exists"
fi

# ------------------------------------------------- attach to the instance ----
_banner "Attaching to $INSTANCE_ID"
ASSOC="$(aws "${AWS_CLI_ARGS[@]}" ec2 describe-iam-instance-profile-associations \
  --filters "Name=instance-id,Values=$INSTANCE_ID" \
  --query 'IamInstanceProfileAssociations[?State!=`disassociated`].[AssociationId,IamInstanceProfile.Arn]' \
  --output text)"

if [[ -n "$ASSOC" ]]; then
  ASSOC_ID="$(echo "$ASSOC" | awk '{print $1}')"
  CURRENT_ARN="$(echo "$ASSOC" | awk '{print $2}')"
  if [[ "$CURRENT_ARN" == *"/${INSTANCE_PROFILE_NAME}" ]]; then
    echo "instance already has $INSTANCE_PROFILE_NAME attached — nothing to do"
  else
    echo "replacing existing profile: $CURRENT_ARN"
    aws "${AWS_CLI_ARGS[@]}" ec2 replace-iam-instance-profile-association \
      --association-id "$ASSOC_ID" \
      --iam-instance-profile "Name=$INSTANCE_PROFILE_NAME" >/dev/null
    echo "replaced"
  fi
else
  aws "${AWS_CLI_ARGS[@]}" ec2 associate-iam-instance-profile \
    --instance-id "$INSTANCE_ID" \
    --iam-instance-profile "Name=$INSTANCE_PROFILE_NAME" >/dev/null
  echo "attached"
fi

PUBLIC_IP="$(aws "${AWS_CLI_ARGS[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
printf 'INSTANCE_ID=%s\nPUBLIC_IP=%s\n' "$INSTANCE_ID" "$PUBLIC_IP" > ./deploy/.instance

_banner "Done"
cat <<EOF
Instance:  $INSTANCE_ID ($PUBLIC_IP)
Role:      $IAM_ROLE_NAME  ->  read-only on $SECRET_NAME

Credentials take up to a minute to appear on the instance. Then, on the box:

  sudo systemctl restart ${APP_NAME}-secrets ${APP_NAME}
  sudo journalctl -u ${APP_NAME}-secrets -n 20 --no-pager

You want to see "secrets loaded from Secrets Manager", not the fallback warning.
EOF
