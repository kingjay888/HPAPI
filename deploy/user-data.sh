#!/usr/bin/env bash
# EC2 user-data: runs once, as root, on first boot.
# Placeholder tokens below are substituted by 02-provision.sh before launch.
set -euxo pipefail

APP_NAME="@@APP_NAME@@"
REPO_URL="@@REPO_URL@@"
REPO_BRANCH="@@REPO_BRANCH@@"
SECRET_NAME="@@SECRET_NAME@@"
REGION="@@AWS_REGION@@"

APP_DIR="/opt/${APP_NAME}"
CONF_DIR="/etc/${APP_NAME}"
APP_USER="appsvc"

exec > >(tee -a "/var/log/${APP_NAME}-bootstrap.log") 2>&1
echo "=== bootstrap started $(date -Is) ==="

# ---------------------------------------------------------------- packages ---
dnf -y update
dnf -y install git nginx jq python3.11 python3.11-pip
command -v aws >/dev/null 2>&1 || dnf -y install awscli-2

PY=python3.11
command -v "$PY" >/dev/null 2>&1 || PY=python3
"$PY" -m venv --help >/dev/null 2>&1 || { echo "FATAL: $PY has no venv module"; exit 1; }

# ------------------------------------------------------------------- user ----
id -u "$APP_USER" >/dev/null 2>&1 || useradd --system --create-home --shell /sbin/nologin "$APP_USER"
install -d -o "$APP_USER" -g "$APP_USER" -m 0750 "$APP_DIR"
install -d -o root      -g "$APP_USER" -m 0750 "$CONF_DIR"

# ---------------------------------------------------- fetcher configuration --
# Written as a separate file so the fetcher script itself needs no templating.
cat > "${CONF_DIR}/fetch.conf" <<CONF
SECRET_NAME="${SECRET_NAME}"
AWS_DEFAULT_REGION="${REGION}"
CONF_DIR="${CONF_DIR}"
APP_USER="${APP_USER}"
CONF
chmod 0644 "${CONF_DIR}/fetch.conf"

# -------------------------------------------------------- secret fetcher -----
# Runs as root before every service start, so `systemctl restart` picks up
# rotated credentials with no redeploy.
cat > "/usr/local/bin/${APP_NAME}-fetch-secrets" <<'FETCH'
#!/usr/bin/env bash
set -euo pipefail
CONF_FILE="${1:?usage: $0 /etc/<app>/fetch.conf}"
# shellcheck disable=SC1090
source "$CONF_FILE"
export AWS_DEFAULT_REGION

payload="$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_NAME" \
  --query SecretString --output text)"

umask 077

# Keys starting with "_" hold file CONTENT (PEM material).
# Everything else becomes a KEY=value line in the systemd EnvironmentFile.
# @json quotes and escapes each value, so a secret containing spaces, quotes or
# newlines can't break the file format. systemd understands double-quoted values.
printf '%s' "$payload" \
  | jq -r 'to_entries[] | select(.key | startswith("_") | not) | "\(.key)=\(.value | tostring | @json)"' \
  > "${CONF_DIR}/app.env"
chown root:"$APP_USER" "${CONF_DIR}/app.env"
chmod 0640 "${CONF_DIR}/app.env"

write_pem() {
  local key="$1" dest="$2" content
  content="$(printf '%s' "$payload" | jq -r --arg k "$key" '.[$k] // empty')"
  if [[ -n "$content" ]]; then
    printf '%s' "$content" > "$dest"
    chown root:"$APP_USER" "$dest"
    chmod 0640 "$dest"
  else
    rm -f "$dest"
  fi
}
write_pem "_HP_CATALOG_CLIENT_CERT" "${CONF_DIR}/client-cert.pem"
write_pem "_HP_CATALOG_CLIENT_KEY"  "${CONF_DIR}/client-key.pem"

echo "secrets refreshed from ${SECRET_NAME}"
FETCH
chmod 0755 "/usr/local/bin/${APP_NAME}-fetch-secrets"
"/usr/local/bin/${APP_NAME}-fetch-secrets" "${CONF_DIR}/fetch.conf"

# ------------------------------------------------------------------- code ----
sudo -u "$APP_USER" -H git clone --branch "$REPO_BRANCH" --depth 1 "$REPO_URL" "$APP_DIR"
sudo -u "$APP_USER" -H "$PY" -m venv "$APP_DIR/.venv"
sudo -u "$APP_USER" -H "$APP_DIR/.venv/bin/pip" install --upgrade pip
sudo -u "$APP_USER" -H "$APP_DIR/.venv/bin/pip" install -r "$APP_DIR/requirements.txt"

# ---------------------------------------------------------------- systemd ----
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
Description=${APP_NAME} (FastAPI / uvicorn)
After=network-online.target ${APP_NAME}-secrets.service
Wants=network-online.target
Requires=${APP_NAME}-secrets.service

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_DIR}
EnvironmentFile=${CONF_DIR}/app.env
ExecStart=${APP_DIR}/.venv/bin/uvicorn backend.main:app --host 127.0.0.1 --port 8000
Restart=always
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now "${APP_NAME}-secrets.service"
systemctl enable --now "${APP_NAME}.service"

# ------------------------------------------------------------------ nginx ----
# Replace the stock config wholesale so there is exactly one server on :80.
cat > /etc/nginx/nginx.conf <<'NGINXMAIN'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log notice;
pid /run/nginx.pid;

events { worker_connections 1024; }

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    access_log    /var/log/nginx/access.log;
    sendfile      on;
    keepalive_timeout 65;
    server_tokens off;
    include /etc/nginx/conf.d/*.conf;
}
NGINXMAIN

rm -f /etc/nginx/conf.d/*.conf
cat > "/etc/nginx/conf.d/${APP_NAME}.conf" <<'NGINXSITE'
server {
    listen 80 default_server;
    server_name _;
    client_max_body_size 25m;

    location / {
        proxy_pass http://127.0.0.1:8000;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
    }
}
NGINXSITE

nginx -t
systemctl enable --now nginx
systemctl restart nginx

echo "=== bootstrap finished $(date -Is) ==="
