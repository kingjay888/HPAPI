#!/usr/bin/env bash
#
# Run this ON the Ubuntu EC2 instance, with sudo:
#
#     cd ~/HPAPI && git pull && sudo ./deploy/ubuntu-setup.sh
#
# It adopts the checkout you already have (default /home/ubuntu/HPAPI) and:
#   - rebuilds the virtualenv properly (installs python3-venv first)
#   - installs nginx as a reverse proxy on :80 -> uvicorn on :8000
#   - wires AWS Secrets Manager so credentials never sit in a file in the repo
#   - installs systemd units so the app survives logout and reboot
#
# Safe to re-run. It does not delete your code or your .env.

set -euo pipefail

# ----------------------------------------------------------------- settings --
# APP_NAME must match APP_NAME in deploy/config.sh — the IAM role, instance
# profile and secret are all named from it.
APP_NAME="${APP_NAME:-hp-printer-images}"
APP_USER="${APP_USER:-ubuntu}"
APP_DIR="${APP_DIR:-/home/${APP_USER}/HPAPI}"
CONF_DIR="/etc/${APP_NAME}"
SECRET_NAME="${SECRET_NAME:-hp-printer-images/env}"
APP_PORT="${APP_PORT:-8000}"

[[ $EUID -eq 0 ]] || { echo "ERROR: run with sudo — 'sudo $0'" >&2; exit 1; }
[[ -d "$APP_DIR" ]] || { echo "ERROR: APP_DIR $APP_DIR does not exist. Set APP_DIR=... and re-run." >&2; exit 1; }
id -u "$APP_USER" >/dev/null 2>&1 || { echo "ERROR: user $APP_USER does not exist." >&2; exit 1; }

banner() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }
echo "app dir:  $APP_DIR"
echo "run as:   $APP_USER"
echo "secret:   $SECRET_NAME"

# ----------------------------------------------------------------- packages --
banner "Installing packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq

# Match the venv package to whatever python3 actually is on this release.
PY_VER="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
echo "system python: $PY_VER"
apt-get install -y -qq nginx jq curl unzip "python3-venv" "python3-pip" \
  || apt-get install -y -qq nginx jq curl unzip "python${PY_VER}-venv" "python3-pip"

# python3-venv is a metapackage on some releases and doesn't pull the versioned
# one; install it explicitly and don't fail if it's already satisfied.
apt-get install -y -qq "python${PY_VER}-venv" || true

if ! command -v aws >/dev/null 2>&1; then
  banner "Installing AWS CLI v2"
  TMP="$(mktemp -d)"
  ARCH="$(uname -m)"   # x86_64 or aarch64 — both are valid in the URL
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}.zip" -o "$TMP/awscliv2.zip"
  unzip -q "$TMP/awscliv2.zip" -d "$TMP"
  "$TMP/aws/install" --update
  rm -rf "$TMP"
fi
aws --version

# ------------------------------------------------------------------- venv ----
banner "Rebuilding virtualenv"
# A half-built venv (the usual cause of "No such file or directory" on
# .venv/bin/python3) can't be repaired in place — replace it.
if [[ -e "$APP_DIR/.venv" && ! -x "$APP_DIR/.venv/bin/python3" ]]; then
  echo "existing .venv is broken — removing"
  rm -rf "$APP_DIR/.venv"
fi

if [[ ! -x "$APP_DIR/.venv/bin/python3" ]]; then
  sudo -u "$APP_USER" -H python3 -m venv "$APP_DIR/.venv"
  echo "created $APP_DIR/.venv"
else
  echo ".venv already healthy — keeping it"
fi

sudo -u "$APP_USER" -H "$APP_DIR/.venv/bin/pip" install --upgrade -q pip
sudo -u "$APP_USER" -H "$APP_DIR/.venv/bin/pip" install -q -r "$APP_DIR/requirements.txt"
"$APP_DIR/.venv/bin/python3" --version
"$APP_DIR/.venv/bin/python3" -c 'import fastapi, uvicorn, httpx, openpyxl; print("dependencies import OK")'

# ---------------------------------------------------------------- secrets ----
banner "Configuring Secrets Manager"
install -d -o root -g "$APP_USER" -m 0750 "$CONF_DIR"

# Region: prefer an explicit env var, else ask the instance metadata service.
if [[ -z "${AWS_REGION:-}" ]]; then
  TOKEN="$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null || true)"
  AWS_REGION="$(curl -fsS -H "X-aws-ec2-metadata-token: ${TOKEN}" \
    "http://169.254.169.254/latest/meta-data/placement/region" 2>/dev/null || true)"
fi
: "${AWS_REGION:=us-east-1}"
echo "region: $AWS_REGION"

cat > "${CONF_DIR}/fetch.conf" <<CONF
SECRET_NAME="${SECRET_NAME}"
AWS_DEFAULT_REGION="${AWS_REGION}"
CONF_DIR="${CONF_DIR}"
APP_USER="${APP_USER}"
FALLBACK_ENV="${APP_DIR}/.env"
CONF
chmod 0644 "${CONF_DIR}/fetch.conf"

cat > "/usr/local/bin/${APP_NAME}-fetch-secrets" <<'FETCH'
#!/usr/bin/env bash
# Writes /etc/<app>/app.env for systemd to read. Runs as root before the app starts.
set -euo pipefail
CONF_FILE="${1:?usage: $0 /etc/<app>/fetch.conf}"
# shellcheck disable=SC1090
source "$CONF_FILE"
export AWS_DEFAULT_REGION
umask 077

if payload="$(aws secretsmanager get-secret-value \
      --secret-id "$SECRET_NAME" --query SecretString --output text 2>/dev/null)"; then

  # Keys starting with "_" hold PEM file CONTENT; the rest become env vars.
  # @json quotes and escapes each value so odd characters can't break the file.
  printf '%s' "$payload" \
    | jq -r 'to_entries[] | select(.key | startswith("_") | not) | "\(.key)=\(.value | tostring | @json)"' \
    > "${CONF_DIR}/app.env"

  write_pem() {
    local key="$1" dest="$2" content
    content="$(printf '%s' "$payload" | jq -r --arg k "$key" '.[$k] // empty')"
    if [[ -n "$content" ]]; then
      printf '%s' "$content" > "$dest"
      chown root:"$APP_USER" "$dest"; chmod 0640 "$dest"
    else
      rm -f "$dest"
    fi
  }
  write_pem "_HP_CATALOG_CLIENT_CERT" "${CONF_DIR}/client-cert.pem"
  write_pem "_HP_CATALOG_CLIENT_KEY"  "${CONF_DIR}/client-key.pem"
  echo "secrets loaded from Secrets Manager (${SECRET_NAME})"

elif [[ -n "${FALLBACK_ENV:-}" && -f "$FALLBACK_ENV" ]]; then
  # Secrets Manager unreachable (no IAM role yet, or secret not created).
  # Fall back to the local .env so the app still starts.
  echo "WARNING: could not read ${SECRET_NAME} — falling back to ${FALLBACK_ENV}" >&2
  grep -vE '^\s*(#|$)' "$FALLBACK_ENV" > "${CONF_DIR}/app.env"

else
  echo "ERROR: no secret and no fallback env file (${FALLBACK_ENV:-unset})" >&2
  exit 1
fi

chown root:"$APP_USER" "${CONF_DIR}/app.env"
chmod 0640 "${CONF_DIR}/app.env"
FETCH
chmod 0755 "/usr/local/bin/${APP_NAME}-fetch-secrets"
"/usr/local/bin/${APP_NAME}-fetch-secrets" "${CONF_DIR}/fetch.conf" || true

# ------------------------------------------------------------ update helper --
cat > "/usr/local/bin/${APP_NAME}-update" <<UPDATE
#!/usr/bin/env bash
# Pull latest code, reinstall deps, refresh secrets, restart. Run with sudo.
set -euo pipefail
sudo -u ${APP_USER} -H git -C ${APP_DIR} pull --ff-only
sudo -u ${APP_USER} -H ${APP_DIR}/.venv/bin/pip install -q -r ${APP_DIR}/requirements.txt
systemctl restart ${APP_NAME}-secrets.service
systemctl restart ${APP_NAME}.service
sleep 2
systemctl is-active ${APP_NAME}.service
curl -fsS "http://127.0.0.1:${APP_PORT}/api/health" && echo
UPDATE
chmod 0755 "/usr/local/bin/${APP_NAME}-update"

# ---------------------------------------------------------------- systemd ----
banner "Installing systemd units"
cat > "/etc/systemd/system/${APP_NAME}-secrets.service" <<SECUNIT
[Unit]
Description=Fetch ${APP_NAME} secrets from AWS Secrets Manager
After=network-online.target
Wants=network-online.target
Before=${APP_NAME}.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/${APP_NAME}-fetch-secrets ${CONF_DIR}/fetch.conf

[Install]
WantedBy=multi-user.target
SECUNIT

cat > "/etc/systemd/system/${APP_NAME}.service" <<UNIT
[Unit]
Description=${APP_NAME} — HP Printer Image Fetcher (FastAPI/uvicorn)
After=network-online.target ${APP_NAME}-secrets.service
Wants=network-online.target
Requires=${APP_NAME}-secrets.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${CONF_DIR}/app.env
ExecStart=${APP_DIR}/.venv/bin/uvicorn backend.main:app --host 127.0.0.1 --port ${APP_PORT}
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now "${APP_NAME}-secrets.service"
systemctl restart "${APP_NAME}.service"
systemctl enable "${APP_NAME}.service" >/dev/null

# ------------------------------------------------------------------ nginx ----
banner "Configuring nginx"
cat > "/etc/nginx/sites-available/${APP_NAME}" <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    client_max_body_size 25m;

    location / {
        proxy_pass http://127.0.0.1:${APP_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host              \$host;
        proxy_set_header X-Real-IP         \$remote_addr;
        proxy_set_header X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 120s;
    }
}
NGINX

rm -f /etc/nginx/sites-enabled/default
ln -sf "/etc/nginx/sites-available/${APP_NAME}" "/etc/nginx/sites-enabled/${APP_NAME}"
nginx -t
systemctl enable nginx >/dev/null
systemctl restart nginx

# ----------------------------------------------------------------- verify ----
banner "Verifying"
sleep 3
systemctl --no-pager --lines=0 status "${APP_NAME}.service" || true

if curl -fsS --max-time 10 "http://127.0.0.1:${APP_PORT}/api/health"; then
  echo; echo "app is healthy on :${APP_PORT}"
else
  echo; echo "app did not answer. Logs:"; journalctl -u "${APP_NAME}" -n 40 --no-pager; exit 1
fi

if curl -fsS --max-time 10 "http://127.0.0.1/api/health" >/dev/null; then
  echo "nginx proxy on :80 is working"
else
  echo "WARNING: nginx proxy not answering on :80"
fi

TOKEN="$(curl -fsS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300" 2>/dev/null || true)"
PUBIP="$(curl -fsS -H "X-aws-ec2-metadata-token: ${TOKEN}" \
  "http://169.254.169.254/latest/meta-data/public-ipv4" 2>/dev/null || echo "<your-ip>")"

banner "Done"
cat <<EOF
App URL:      http://${PUBIP}/
Logs:         sudo journalctl -u ${APP_NAME} -f
Restart:      sudo systemctl restart ${APP_NAME}
Update code:  sudo ${APP_NAME}-update

Make sure the instance security group allows inbound TCP 80.
EOF
