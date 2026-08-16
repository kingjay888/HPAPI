#!/usr/bin/env bash
# Shared settings for all deploy scripts. Edit values here, then source this file.
# Nothing secret belongs in this file — secrets live in AWS Secrets Manager.

# --- AWS ---
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_PROFILE="${AWS_PROFILE:-default}"

# --- Naming (used as a prefix for every resource created) ---
export APP_NAME="${APP_NAME:-hp-printer-images}"

# --- EC2 ---
# t3.small = 2 vCPU / 2 GB. t3.micro (1 GB) also works but is tight during pip install.
export INSTANCE_TYPE="${INSTANCE_TYPE:-t3.small}"
export KEY_NAME="${KEY_NAME:-${APP_NAME}-key}"
export KEY_FILE="${KEY_FILE:-$HOME/.ssh/${KEY_NAME}.pem}"
export SG_NAME="${SG_NAME:-${APP_NAME}-sg}"
export IAM_ROLE_NAME="${IAM_ROLE_NAME:-${APP_NAME}-role}"
export INSTANCE_PROFILE_NAME="${INSTANCE_PROFILE_NAME:-${APP_NAME}-profile}"

# --- Source repo (public, so the instance can clone it without credentials) ---
export REPO_URL="${REPO_URL:-https://github.com/kingjay888/HPAPI.git}"
export REPO_BRANCH="${REPO_BRANCH:-main}"

# --- Secrets Manager ---
export SECRET_NAME="${SECRET_NAME:-${APP_NAME}/env}"

# --- Access ---
# CIDR allowed to reach SSH (port 22). Defaults to your current public IP.
# Set to a fixed CIDR (e.g. "203.0.113.4/32") if your IP is stable.
export SSH_CIDR="${SSH_CIDR:-auto}"
# CIDR allowed to reach the app over HTTP (port 80).
# 0.0.0.0/0 = open to the internet. Narrow this if the app should stay private.
export HTTP_CIDR="${HTTP_CIDR:-0.0.0.0/0}"

# --- Derived ---
export AWS_CLI_ARGS=(--region "$AWS_REGION" --profile "$AWS_PROFILE")

_require() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' is not installed or not on PATH." >&2; exit 1; }
}

_banner() { printf '\n=== %s ===\n' "$*"; }
