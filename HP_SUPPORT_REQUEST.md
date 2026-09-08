# Request to HP: authentication for the Hermes catalog gateway

Draft message for HP's API/partner contact. Fill in the two bracketed spots and
send. Everything else is measured, not assumed.

---

**Subject:** Hermes catalog API via hpit-gw — which IdP issues the required JWT?

Hi [name],

We're integrating the Hermes product-content API through the gateway at
`https://hpit-gw.hpcloud.hp.com/generic-router/api/hermes/` and are blocked on
authentication. Our client ID and secret are rejected, and the gateway doesn't
expose a token endpoint we can use, so we can't tell whether we're using the
wrong scheme or the wrong credentials.

Our account/partner ID is [account or partner ID]. Client ID begins `Vh3P`.

**What we observe**

Requests to `/generic-router/api/hermes/images` and
`/generic-router/api/hermes/productcontent` both behave identically:

| Request | Response |
|---|---|
| `Authorization: Basic <client_id:client_secret>` | `401 {"error": "Invalid token."}` |
| `Authorization: Bearer <client_secret>` | `401 {"error": "Invalid token."}` |
| `Authorization: Bearer <client_id>` | `401 {"error": "Invalid token."}` |
| `x-api-key`, `apikey`, or `client_id`/`client_secret` headers | `400 {"error": "JWT Token is required."}` |
| No credentials at all | `400 {"error": "JWT Token is required."}` |

The 401 responses carry `WWW-Authenticate: Bearer` with no realm or error_uri.

Since sending API-key style headers produces exactly the same response as
sending no credentials at all, the gateway appears to read only a bearer JWT in
the `Authorization` header. We take this to mean our client ID and secret are
credentials to be exchanged for a JWT rather than the token itself.

**Why we can't get that JWT**

We can't find the token endpoint. On the gateway host, all of these 404:

```
/oauth/token
/oauth2/token
/oauth2/v1/token
/v1/oauth/token
/token
/.well-known/openid-configuration
/.well-known/oauth-authorization-server
```

`/generic-router/api/oauth/token` returns
`404 {"status": "Requested API not found in records"}`, which suggests
`generic-router/api/<name>` resolves against a registry where `hermes` is
registered but no OAuth service is. So we assume the issuer is a separate
identity provider we haven't been told about.

**A second, possibly related problem: client certificates**

Calling the older endpoint `https://hermesws.ext.hp.com/HermesWS/secure/v2/images`
with the same credentials fails at the TLS layer, before any HTTP exchange:

```
curl: (56) OpenSSL SSL_read: error:0A000410 ... ssl/tls alert handshake failure
```

which we read as that endpoint requiring a client certificate we aren't
presenting. We hold a private key and a self-signed certificate from our original
registration, but they are not a matching pair — the certificate's public modulus
does not correspond to either private key we have, so we cannot complete an mTLS
handshake with them. It looks like the signed certificate returned by HP after
our CSR was never stored alongside its key.

**What we need**

1. Which identity provider issues the JWT for this gateway, and its token URL.
2. The required `audience` (and `scope`, if any) for the Hermes API.
3. The grant type you expect — `client_credentials`, or something else.
4. Whether our existing client ID and secret are provisioned for **this**
   gateway. They were issued for the older `hermesws.ext.hp.com/HermesWS/secure/v2`
   endpoint, which accepted HTTP Basic. If they weren't migrated, we likely need
   new credentials rather than a different auth scheme.
5. Whether client-certificate mTLS and IP allow-listing still apply on the new
   gateway as they did on the old one. If so, our egress addresses are
   [your Elastic IP / NAT addresses].
6. A re-issue of our client certificate, or the CSR/registration process to
   obtain a new one, since we can no longer assemble a valid certificate and key
   pair from what we hold.

A working `curl` example for a single product number would answer all of this at
once, if you have one.

Thanks,
Duana

---

## Notes for us, not for HP

- **The most likely answer is item 4.** The credentials predate this gateway.
  If HP confirms they were never migrated, no code change helps and we need new
  ones.
- Before sending, run the old-endpoint test (below). If the old endpoint accepts
  these credentials, that's near-proof, and worth stating in the message.
- Once HP answers, this is configuration only — no code change. Set in `.env`:
  - OAuth2: `HP_CATALOG_AUTH_MODE=oauth2`, `HP_CATALOG_TOKEN_URL=...`,
    optionally `HP_CATALOG_OAUTH_SCOPE=...`
  - Static token: `HP_CATALOG_AUTH_MODE=bearer`, `HP_CATALOG_API_KEY_VALUE=...`
  - Then `./deploy/01-put-secrets.sh` and restart the service.

### Old-endpoint test

Run on the instance. If this returns anything other than 401, the credentials
belong to the old gateway and simply weren't migrated:

```bash
set -a; . /etc/hp-printer-images/app.env; set +a
curl -sS -w '\nHTTP %{http_code}\n' \
  -u "$HP_CATALOG_CLIENT_ID:$HP_CATALOG_CLIENT_SECRET" \
  -X POST https://hermesws.ext.hp.com/HermesWS/secure/v2/images \
  -H 'Content-Type: application/json' \
  -d "{\"requestContext\":{\"requesterId\":\"$HP_CATALOG_CLIENT_ID\",\"countryCode\":\"US\",\"languageCode\":\"en\"},\"productNumbers\":[\"2Z599F\"],\"products\":[{\"productNumber\":\"2Z599F\"}]}"
```

Interpreting it:

- **200** — credentials are fine, they're just for the old endpoint. Point
  `HP_CATALOG_BASE_URL` back at it and you're unblocked today.
- **403, or a TLS/certificate error** — credentials recognised, but the old
  endpoint's mTLS and IP allow-listing are biting. Still tells us the account
  lives there.
- **401** — credentials aren't valid on either gateway. Ask HP to reissue.
- **Timeout** — the old host may also block AWS ranges; inconclusive, retry from
  a laptop.
