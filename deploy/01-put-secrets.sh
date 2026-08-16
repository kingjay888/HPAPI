#!/usr/bin/env bash
# Push the app's runtime configuration + HP credentials into AWS Secrets Manager.
#
# Reads your LOCAL .env (and optionally the client cert/key .pem files) and stores
# them as one JSON secret. Nothing sensitive is ever written to the repo or the AMI.
#
# Usage:  ./deploy/01-put-secrets.sh
# Re-run this any time a credential changes, then run 03-deploy.sh to pick it up.

set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=./config.sh
source ./deploy/config.sh

_require aws
_require python3

ENV_FILE="${ENV_FILE:-.env}"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found. Create it first." >&2; exit 1; }

# Optional mTLS material. Leave unset if you authenticate with client id/secret only.
CLIENT_CERT_FILE="${CLIENT_CERT_FILE:-}"
CLIENT_KEY_FILE="${CLIENT_KEY_FILE:-}"

_banner "Building secret payload from $ENV_FILE"

SECRET_JSON="$(
  ENV_FILE="$ENV_FILE" \
  CLIENT_CERT_FILE="$CLIENT_CERT_FILE" \
  CLIENT_KEY_FILE="$CLIENT_KEY_FILE" \
  python3 - <<'PY'
import json, os, pathlib, sys

data = {}
for raw in pathlib.Path(os.environ["ENV_FILE"]).read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    key, _, value = line.partition("=")
    key = key.strip()
    value = value.strip().strip('"').strip("'")
    if key:
        data[key] = value

# On the instance the certs are materialised at these fixed paths, so override
# whatever local paths the .env happened to contain.
for var, env_key, dest in (
    ("CLIENT_CERT_FILE", "HP_CATALOG_CLIENT_CERT", "/etc/hp-printer-images/client-cert.pem"),
    ("CLIENT_KEY_FILE", "HP_CATALOG_CLIENT_KEY", "/etc/hp-printer-images/client-key.pem"),
):
    path = os.environ.get(var, "")
    if path:
        p = pathlib.Path(path).expanduser()
        if not p.is_file():
            sys.exit(f"ERROR: {var}={path} does not exist")
        data["_" + env_key] = p.read_text()   # underscore keys hold file CONTENT
        data[env_key] = dest
    else:
        data[env_key] = ""

if not data.get("HP_CATALOG_CLIENT_ID") and not data.get("_HP_CATALOG_CLIENT_CERT"):
    print("WARNING: no HP client id/secret and no client cert — the catalog API will be unconfigured.",
          file=sys.stderr)

json.dump(data, sys.stdout)
PY
)"

_banner "Writing secret '$SECRET_NAME' in $AWS_REGION"

if aws "${AWS_CLI_ARGS[@]}" secretsmanager describe-secret --secret-id "$SECRET_NAME" >/dev/null 2>&1; then
  aws "${AWS_CLI_ARGS[@]}" secretsmanager put-secret-value \
    --secret-id "$SECRET_NAME" \
    --secret-string "$SECRET_JSON" >/dev/null
  echo "Updated existing secret: $SECRET_NAME"
else
  aws "${AWS_CLI_ARGS[@]}" secretsmanager create-secret \
    --name "$SECRET_NAME" \
    --description "Runtime env for $APP_NAME (HP Catalog API credentials)" \
    --secret-string "$SECRET_JSON" >/dev/null
  echo "Created secret: $SECRET_NAME"
fi

KEYS="$(printf '%s' "$SECRET_JSON" | python3 -c 'import json,sys; print(", ".join(sorted(json.load(sys.stdin))))')"
echo "Keys stored: $KEYS"
echo
echo "Next: ./deploy/02-provision.sh"
