#!/usr/bin/env bash
# Create all AWS resources and launch the EC2 instance.
#
#   IAM role + instance profile  (read only the one secret)
#   security group               (SSH from your IP, HTTP from HTTP_CIDR)
#   key pair                     (saved to $KEY_FILE)
#   EC2 instance                 (Amazon Linux 2023, bootstrapped via user-data)
#
# Safe to re-run: every resource is created only if missing. It will NOT launch a
# second instance if one is already running under this app name.
#
# Usage:  ./deploy/02-provision.sh

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=./config.sh
source ./deploy/config.sh

_require aws
_require curl

ACCOUNT_ID="$(aws "${AWS_CLI_ARGS[@]}" sts get-caller-identity --query Account --output text)"
SECRET_ARN="$(aws "${AWS_CLI_ARGS[@]}" secretsmanager describe-secret \
  --secret-id "$SECRET_NAME" --query ARN --output text 2>/dev/null || true)"

if [[ -z "$SECRET_ARN" || "$SECRET_ARN" == "None" ]]; then
  echo "ERROR: secret '$SECRET_NAME' not found. Run ./deploy/01-put-secrets.sh first." >&2
  exit 1
fi

echo "Account:  $ACCOUNT_ID"
echo "Region:   $AWS_REGION"
echo "Secret:   $SECRET_ARN"

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

# Least privilege: read exactly one secret, nothing else.
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
echo "attached inline policy ${APP_NAME}-read-secret"

# Lets you use Session Manager instead of SSH if you prefer.
aws "${AWS_CLI_ARGS[@]}" iam attach-role-policy \
  --role-name "$IAM_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore >/dev/null

if ! aws "${AWS_CLI_ARGS[@]}" iam get-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null 2>&1; then
  aws "${AWS_CLI_ARGS[@]}" iam create-instance-profile --instance-profile-name "$INSTANCE_PROFILE_NAME" >/dev/null
  aws "${AWS_CLI_ARGS[@]}" iam add-role-to-instance-profile \
    --instance-profile-name "$INSTANCE_PROFILE_NAME" --role-name "$IAM_ROLE_NAME"
  echo "created instance profile $INSTANCE_PROFILE_NAME (waiting 15s for IAM propagation)"
  sleep 15
else
  echo "instance profile $INSTANCE_PROFILE_NAME already exists"
fi

# --------------------------------------------------------- security group ----
_banner "Security group"
VPC_ID="$(aws "${AWS_CLI_ARGS[@]}" ec2 describe-vpcs \
  --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)"
[[ "$VPC_ID" != "None" ]] || { echo "ERROR: no default VPC in $AWS_REGION. Set one up or edit this script." >&2; exit 1; }
echo "VPC: $VPC_ID"

SG_ID="$(aws "${AWS_CLI_ARGS[@]}" ec2 describe-security-groups \
  --filters "Name=group-name,Values=$SG_NAME" "Name=vpc-id,Values=$VPC_ID" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || echo None)"

if [[ "$SG_ID" == "None" || -z "$SG_ID" ]]; then
  SG_ID="$(aws "${AWS_CLI_ARGS[@]}" ec2 create-security-group \
    --group-name "$SG_NAME" --description "$APP_NAME web + ssh" --vpc-id "$VPC_ID" \
    --query GroupId --output text)"
  echo "created security group $SG_ID"
else
  echo "security group $SG_ID already exists"
fi

if [[ "$SSH_CIDR" == "auto" ]]; then
  MY_IP="$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')"
  SSH_CIDR="${MY_IP}/32"
fi
echo "SSH allowed from:  $SSH_CIDR"
echo "HTTP allowed from: $HTTP_CIDR"

# `|| true` because re-running with an existing rule returns Duplicate.
aws "${AWS_CLI_ARGS[@]}" ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" --protocol tcp --port 22 --cidr "$SSH_CIDR" >/dev/null 2>&1 || true
aws "${AWS_CLI_ARGS[@]}" ec2 authorize-security-group-ingress \
  --group-id "$SG_ID" --protocol tcp --port 80 --cidr "$HTTP_CIDR" >/dev/null 2>&1 || true

# ---------------------------------------------------------------- key pair ----
_banner "Key pair"
if aws "${AWS_CLI_ARGS[@]}" ec2 describe-key-pairs --key-names "$KEY_NAME" >/dev/null 2>&1; then
  echo "key pair $KEY_NAME already exists in AWS"
  [[ -f "$KEY_FILE" ]] || { echo "ERROR: $KEY_FILE missing locally and AWS will not re-issue it. Delete the AWS key pair or point KEY_FILE at your copy." >&2; exit 1; }
else
  mkdir -p "$(dirname "$KEY_FILE")"
  aws "${AWS_CLI_ARGS[@]}" ec2 create-key-pair --key-name "$KEY_NAME" \
    --query KeyMaterial --output text > "$KEY_FILE"
  chmod 400 "$KEY_FILE"
  echo "created key pair, private key saved to $KEY_FILE"
fi

# ---------------------------------------------------------------- instance ----
_banner "EC2 instance"
EXISTING="$(aws "${AWS_CLI_ARGS[@]}" ec2 describe-instances \
  --filters "Name=tag:Name,Values=$APP_NAME" "Name=instance-state-name,Values=pending,running" \
  --query 'Reservations[].Instances[0].InstanceId' --output text)"

if [[ -n "$EXISTING" && "$EXISTING" != "None" ]]; then
  INSTANCE_ID="$EXISTING"
  echo "instance already running: $INSTANCE_ID (skipping launch — use 03-deploy.sh to update code)"
else
  AMI_ID="$(aws "${AWS_CLI_ARGS[@]}" ssm get-parameters \
    --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query 'Parameters[0].Value' --output text)"
  echo "AMI: $AMI_ID (Amazon Linux 2023)"

  USER_DATA_FILE="$(mktemp)"
  trap 'rm -f "$USER_DATA_FILE"' EXIT
  sed \
    -e "s|@@APP_NAME@@|${APP_NAME}|g" \
    -e "s|@@REPO_URL@@|${REPO_URL}|g" \
    -e "s|@@REPO_BRANCH@@|${REPO_BRANCH}|g" \
    -e "s|@@SECRET_NAME@@|${SECRET_NAME}|g" \
    -e "s|@@AWS_REGION@@|${AWS_REGION}|g" \
    ./deploy/user-data.sh > "$USER_DATA_FILE"
  if grep -qE '@@[A-Z_]+@@' "$USER_DATA_FILE"; then
    echo "ERROR: unsubstituted placeholder in user-data:" >&2
    grep -nE '@@[A-Z_]+@@' "$USER_DATA_FILE" >&2
    exit 1
  fi

  INSTANCE_ID="$(aws "${AWS_CLI_ARGS[@]}" ec2 run-instances \
    --image-id "$AMI_ID" \
    --instance-type "$INSTANCE_TYPE" \
    --key-name "$KEY_NAME" \
    --security-group-ids "$SG_ID" \
    --iam-instance-profile "Name=$INSTANCE_PROFILE_NAME" \
    --metadata-options "HttpTokens=required,HttpEndpoint=enabled" \
    --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=20,VolumeType=gp3,Encrypted=true,DeleteOnTermination=true}' \
    --user-data "file://$USER_DATA_FILE" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$APP_NAME}]" \
    --query 'Instances[0].InstanceId' --output text)"
  echo "launched $INSTANCE_ID — waiting for it to reach running state..."
  aws "${AWS_CLI_ARGS[@]}" ec2 wait instance-running --instance-ids "$INSTANCE_ID"
fi

PUBLIC_IP="$(aws "${AWS_CLI_ARGS[@]}" ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

cat > ./deploy/.instance <<EOF
INSTANCE_ID=$INSTANCE_ID
PUBLIC_IP=$PUBLIC_IP
EOF

_banner "Done"
cat <<EOF
Instance:  $INSTANCE_ID
Public IP: $PUBLIC_IP
App URL:   http://$PUBLIC_IP/

The bootstrap (package install, clone, pip install) takes roughly 3-5 minutes
after the instance reaches 'running'. Watch it with:

  ssh -i $KEY_FILE ec2-user@$PUBLIC_IP 'sudo tail -f /var/log/${APP_NAME}-bootstrap.log'

Then check health:

  curl http://$PUBLIC_IP/api/health
EOF
