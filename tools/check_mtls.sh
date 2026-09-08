#!/usr/bin/env bash
#
# Diagnose the client-certificate (mTLS) side of the HP catalog API.
#
# Background: POSTing to the old endpoint hermesws.ext.hp.com fails with
#   curl: (56) OpenSSL SSL_read: ... ssl/tls alert handshake failure
# which is a TLS-layer rejection, not an HTTP one. The usual cause is a server
# demanding a client certificate and receiving none.
#
# This script answers three questions:
#   1. Does HP actually ask for a client certificate?
#   2. Do we hold a matching certificate + private key pair?
#   3. If so, does the API accept it?
#
# Usage:  ./tools/check_mtls.sh [directory-with-certs]     (default: repo root)
#
# Private key material is never printed — only public moduli fingerprints.

set -uo pipefail

CERT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
OLD_HOST="hermesws.ext.hp.com"
OLD_URL="https://${OLD_HOST}/HermesWS/secure/v2/images"
NEW_HOST="hpit-gw.hpcloud.hp.com"
NEW_URL="https://${NEW_HOST}/generic-router/api/hermes/images"
ENV_FILE="${ENV_FILE:-/etc/hp-printer-images/app.env}"

command -v openssl >/dev/null || { echo "ERROR: openssl not installed"; exit 1; }
banner() { printf '\n\033[1m=== %s ===\033[0m\n' "$*"; }

# ---------------------------------------------------------------------------
banner "1. Does HP request a client certificate?"

probe_host() {
  local host="$1"
  echo
  echo "--- ${host} ---"
  local out
  out="$(echo | timeout 20 openssl s_client -connect "${host}:443" \
        -servername "$host" -showcerts 2>&1)"

  if grep -qi "Acceptable client certificate CA names" <<<"$out"; then
    echo "  YES — server sends a CertificateRequest. mTLS is REQUIRED."
    echo "  Acceptable CAs:"
    sed -n '/Acceptable client certificate CA names/,/^---/p' <<<"$out" \
      | grep -vE 'Acceptable client|^---' | head -12 | sed 's/^/    /'
    echo "  ^ your client certificate must be signed by one of these."
  elif grep -qi "No client certificate CA names sent" <<<"$out"; then
    echo "  Server did not request a client certificate at handshake."
    echo "  (Some gateways only demand one on specific paths.)"
  else
    echo "  Inconclusive — could not read the handshake."
  fi

  local proto cipher
  proto="$(grep -m1 -oE 'Protocol *: *\S+' <<<"$out" | awk '{print $NF}')"
  cipher="$(grep -m1 -oE 'Cipher *: *\S+' <<<"$out" | awk '{print $NF}')"
  echo "  negotiated: ${proto:-?} / ${cipher:-?}"
  grep -m1 -E 'Verify return code' <<<"$out" | sed 's/^/  /'
}

probe_host "$OLD_HOST"
probe_host "$NEW_HOST"

# ---------------------------------------------------------------------------
banner "2. Do we hold a matching certificate + key pair?"
echo "scanning: $CERT_DIR"

declare -a CERTS=() KEYS=()
while IFS= read -r f; do
  grep -q 'BEGIN CERTIFICATE' "$f" 2>/dev/null && CERTS+=("$f")
  grep -qE 'BEGIN (RSA |EC )?PRIVATE KEY' "$f" 2>/dev/null && KEYS+=("$f")
done < <(find "$CERT_DIR" -maxdepth 1 -type f \( -name '*.pem' -o -name '*.crt' -o -name '*.key' -o -name '*.txt' \) 2>/dev/null)

echo
echo "certificates found: ${#CERTS[@]}"
for c in "${CERTS[@]}"; do
  subject="$(openssl x509 -in "$c" -noout -subject 2>/dev/null | sed 's/^subject=//')"
  issuer="$(openssl x509 -in "$c" -noout -issuer 2>/dev/null | sed 's/^issuer=//')"
  enddate="$(openssl x509 -in "$c" -noout -enddate 2>/dev/null | cut -d= -f2)"
  selfsigned="no"
  [[ "$subject" == "$issuer" ]] && selfsigned="YES (self-signed)"
  echo "  $(basename "$c")"
  echo "      subject : $subject"
  echo "      issuer  : $issuer"
  echo "      expires : $enddate"
  echo "      self-signed: $selfsigned"
  if openssl x509 -in "$c" -noout -checkend 0 >/dev/null 2>&1; then
    echo "      validity: current"
  else
    echo "      validity: EXPIRED"
  fi
done

echo
echo "private keys found: ${#KEYS[@]}"
for k in "${KEYS[@]}"; do echo "  $(basename "$k")"; done

echo
echo "pairing certificates to keys (matching public modulus):"
PAIR_CERT=""; PAIR_KEY=""
for c in "${CERTS[@]}"; do
  cm="$(openssl x509 -noout -modulus -in "$c" 2>/dev/null | openssl md5 | awk '{print $NF}')"
  for k in "${KEYS[@]}"; do
    km="$(openssl rsa -noout -modulus -in "$k" 2>/dev/null | openssl md5 | awk '{print $NF}')"
    if [[ -n "$cm" && "$cm" == "$km" ]]; then
      echo "  MATCH: $(basename "$c")  <->  $(basename "$k")"
      PAIR_CERT="$c"; PAIR_KEY="$k"
    fi
  done
done

if [[ -z "$PAIR_CERT" ]]; then
  echo "  NO MATCHING PAIR."
  echo
  echo "  Every certificate here belongs to a different private key than the ones"
  echo "  present. mTLS cannot be performed with these files: TLS requires the"
  echo "  certificate and the private key to be two halves of the same keypair."
  echo
  echo "  This normally means the CSR was sent to HP and the signed certificate"
  echo "  that came back was never saved next to its key — or is on another"
  echo "  machine. Find the certificate matching one of the keys above, or"
  echo "  generate a fresh keypair and CSR and re-register it with HP."
fi

# ---------------------------------------------------------------------------
banner "3. Does the API accept the pair?"

if [[ -z "$PAIR_CERT" ]]; then
  echo "Skipped — no usable certificate/key pair (see above)."
  exit 0
fi

if [[ -r "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  set +a
else
  echo "note: $ENV_FILE not readable; sending without credentials."
fi

PRODUCT="${PRODUCT:-2Z599F}"
REQUESTER="${HP_CATALOG_REQUESTER_ID:-${HP_CATALOG_CLIENT_ID:-}}"
BODY=$(printf '{"requestContext":{"requesterId":"%s","countryCode":"%s","languageCode":"%s"},"productNumbers":["%s"],"products":[{"productNumber":"%s"}]}' \
  "$REQUESTER" "${HP_COUNTRY_CODE:-US}" "${HP_LANGUAGE_CODE:-en}" "$PRODUCT" "$PRODUCT")

for url in "$OLD_URL" "$NEW_URL"; do
  echo
  echo "--- POST $url (with client cert) ---"
  curl -sS -w '\n  HTTP %{http_code}  (tls %{ssl_verify_result})\n' \
    --cert "$PAIR_CERT" --key "$PAIR_KEY" \
    ${HP_CATALOG_CLIENT_ID:+-u "$HP_CATALOG_CLIENT_ID:$HP_CATALOG_CLIENT_SECRET"} \
    -X POST "$url" -H 'Content-Type: application/json' -d "$BODY" 2>&1 | sed 's/^/  /' | head -20
done

cat <<'EOF'

Reading the result:
  200            -> works. Set HP_CATALOG_CLIENT_CERT and HP_CATALOG_CLIENT_KEY
                    in .env to these files, re-run 01-put-secrets.sh, restart.
  401/403        -> the certificate was accepted at TLS level; the remaining
                    problem is credentials or authorisation.
  handshake fail -> this certificate is not registered with HP for this host.
EOF
