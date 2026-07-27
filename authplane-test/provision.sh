#!/usr/bin/env bash
# Bring up the Authplane authorization server and provision everything this
# integration needs: one Mint resource, three clients, and a decoy resource
# used only to prove audience binding.
#
# Idempotent: recreates the AS container AND its data volume, so every run
# starts from a known-empty authorization server. Client secrets are shown once
# by the AS, so they are regenerated each time into ../.secrets/clients.env.
#
# This DELETES the `authplane-as-data` volume. Intentional — everything the AS
# holds here is reproducible from this script.
#
# Usage: bash authplane-test/provision.sh

set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS="$REPO/.secrets"
mkdir -p "$SECRETS"

AS=http://localhost:9000
RESOURCE_URI="http://localhost:8976/mcp"

# The AS serves its admin API on :9001 inside the container. Windows reserves
# host port 9001 (netsh excludedportrange), so it is published on 9101 here.
# Host-side mapping only — it does not affect the issuer or the Resource URI,
# which are the values actually bound into tokens.
ADMIN=http://localhost:9101

echo "==> generating AS secrets"
if [ ! -f "$SECRETS/as.env" ]; then
  printf 'AUTHPLANE_ADMIN_API_KEY=%s\nAUTHPLANE_SESSION_SECRET=%s\n' \
    "$(openssl rand -hex 32)" "$(openssl rand -hex 32)" > "$SECRETS/as.env"
fi
set -a; . "$SECRETS/as.env"; set +a

echo "==> starting the authorization server (fresh state)"
docker rm -f authplane-as >/dev/null 2>&1 || true
docker volume rm authplane-as-data >/dev/null 2>&1 || true
docker run -d --name authplane-as \
  -p 9000:9000 -p 9101:9001 \
  -e AUTHPLANE_SERVER_ISSUER=http://localhost:9000 \
  -e AUTHPLANE_ADMIN_API_KEY \
  -e AUTHPLANE_SESSION_SECRET \
  -e AUTHPLANE_CLIENT_CREDENTIALS_ENABLED=true \
  -v authplane-as-data:/data \
  authplane/authserver:latest serve >/dev/null

echo -n "==> waiting for discovery "
until curl -fsS -o /dev/null "$AS/.well-known/oauth-authorization-server" 2>/dev/null; do
  echo -n "."; sleep 1
done
echo " ready"

echo "==> registering the morphik-mcp resource (backend_kind=mint)"
curl -fsS -X POST "$ADMIN/admin/resources" \
  -H "Authorization: Bearer $AUTHPLANE_ADMIN_API_KEY" -H "Content-Type: application/json" \
  -d "{
    \"slug\": \"morphik-mcp\",
    \"display_name\": \"Morphik MCP Server\",
    \"backend_kind\": \"mint\",
    \"uri\": \"$RESOURCE_URI\",
    \"scopes\": [
      {\"name\":\"morphik:mcp:access\",\"description\":\"Base scope required to reach the MCP endpoint at all\"},
      {\"name\":\"morphik:documents:read\",\"description\":\"Read, list, search and retrieve documents\"},
      {\"name\":\"morphik:documents:write\",\"description\":\"Ingest documents into Morphik\"},
      {\"name\":\"morphik:documents:delete\",\"description\":\"Delete documents from Morphik\"},
      {\"name\":\"morphik:filesystem:read\",\"description\":\"Browse the MCP server local filesystem\"}
    ]
  }" >/dev/null
echo "    ok — 5 scopes registered"

echo "==> registering the decoy resource (audience-mismatch test only)"
curl -fsS -X POST "$ADMIN/admin/resources" \
  -H "Authorization: Bearer $AUTHPLANE_ADMIN_API_KEY" -H "Content-Type: application/json" \
  -d '{
    "slug":"decoy-resource","display_name":"Decoy resource (audience-mismatch test)",
    "backend_kind":"mint","uri":"http://localhost:9999/mcp",
    "scopes":[{"name":"morphik:mcp:access","description":"Same scope string, different resource"}]
  }' >/dev/null
echo "    ok"

echo "==> registering clients"
: > "$SECRETS/clients.env"
register_client() { # $1=name $2=scope-string $3=env-var-prefix
  resp=$(curl -fsS -X POST "$ADMIN/admin/clients" \
    -H "Authorization: Bearer $AUTHPLANE_ADMIN_API_KEY" -H "Content-Type: application/json" \
    -d "{\"client_name\":\"$1\",\"grant_types\":[\"client_credentials\"],\"token_endpoint_auth_method\":\"client_secret_basic\",\"scope\":\"$2\"}")
  RESP="$resp" PREFIX="$3" python -c "
import json, os
d = json.loads(os.environ['RESP']); p = os.environ['PREFIX']
print('%s_ID=%s' % (p, d['client_id']))
print('%s_SECRET=%s' % (p, d['client_secret']))
" >> "$SECRETS/clients.env"
  echo "    $1"
}

# -full     : every scope — the happy path.
# -readonly : base + read only — proves per-tool denial for write/delete/filesystem.
# -noaccess : deliberately WITHOUT the base scope — proves the middleware 403.
register_client "morphik-mcp-client-full" \
  "morphik:mcp:access morphik:documents:read morphik:documents:write morphik:documents:delete morphik:filesystem:read" FULL
register_client "morphik-mcp-client-readonly" \
  "morphik:mcp:access morphik:documents:read" READONLY
register_client "morphik-mcp-client-noaccess" \
  "morphik:documents:read" NOACCESS

echo
echo "Provisioned. Credentials in .secrets/ (gitignored)."
echo "Admin UI: $ADMIN/admin/ui/  (log in with AUTHPLANE_ADMIN_API_KEY)"
