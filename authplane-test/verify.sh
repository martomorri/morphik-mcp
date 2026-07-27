#!/usr/bin/env bash
# Assertion suite for the Authplane integration.
#
# Prereqs: provision.sh (AS up + provisioned), start-mcp.sh (server on :8976).
# Tests 9-11 additionally need a Morphik backend on :8000; they self-skip.
#
# Usage: bash authplane-test/verify.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SECRETS="$REPO/.secrets"

AS=http://localhost:9000
MCP=http://localhost:8976/mcp
RESOURCE=http://localhost:8976/mcp

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; printf '        expected: %s\n        actual:   %s\n' "$2" "$3"; FAIL=$((FAIL+1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }
head2(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

[ -f "$SECRETS/clients.env" ] || { echo "ERROR: $SECRETS/clients.env missing — run provision.sh first." >&2; exit 1; }
set -a; . "$SECRETS/clients.env"; set +a

curl -fsS -o /dev/null http://localhost:8976/health 2>/dev/null || {
  echo "ERROR: no MCP server on :8976 — run start-mcp.sh first." >&2; exit 1; }

# Mint a client_credentials token. $1=id $2=secret $3=scopes $4=resource(aud)
mint() {
  curl -sS -X POST "$AS/oauth/token" -u "$1:$2" \
    -d "grant_type=client_credentials" -d "scope=$3" \
    --data-urlencode "resource=$4" \
  | python -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))"
}

# POST a JSON-RPC tools/call. Prints "<http_code>|<body>".
call() { # $1=token (may be empty)  $2=tool  $3=json args
  local auth=(); [ -n "$1" ] && auth=(-H "Authorization: Bearer $1")
  : > /tmp/ap_body
  curl -sS -o /tmp/ap_body -w '%{http_code}' -X POST "$MCP" "${auth[@]}" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\",\"arguments\":$3}}" 2>/dev/null
  printf '|'; tr -d '\n' < /tmp/ap_body
}

ALL="morphik:mcp:access morphik:documents:read morphik:documents:write morphik:documents:delete morphik:filesystem:read"

head2 "Test 1 — no bearer token is rejected at the HTTP layer"
r=$(call "" "list-allowed-directories" '{}'); code=${r%%|*}
[ "$code" = "401" ] && ok "POST /mcp without Authorization -> 401" || bad "POST /mcp without Authorization" "401" "$code"

head2 "Test 2 — PRM document is served and is publicly readable"
prm=$(curl -sS -o /tmp/ap_prm -w '%{http_code}' "http://localhost:8976/.well-known/oauth-protected-resource/mcp")
if [ "$prm" = "200" ] && grep -q "morphik:documents:delete" /tmp/ap_prm && grep -q "localhost:9000" /tmp/ap_prm; then
  ok "PRM advertises the AS and all 5 scopes"
else
  bad "PRM document" "200 listing AS + 5 scopes" "$prm $(cat /tmp/ap_prm)"
fi

head2 "Test 3 — valid token with full scopes reaches the tools"
TOK_FULL=$(mint "$FULL_ID" "$FULL_SECRET" "$ALL" "$RESOURCE")
[ -n "$TOK_FULL" ] || { echo "could not mint full token" >&2; exit 1; }
r=$(call "$TOK_FULL" "list-allowed-directories" '{}'); code=${r%%|*}; body=${r#*|}
[ "$code" = "200" ] && [[ "$body" == *"Allowed directories"* ]] \
  && ok "list-allowed-directories -> 200 with a real result" \
  || bad "list-allowed-directories" "200 + real result" "$code $body"

DEMO_DIR="$( cd "$HERE" && { pwd -W 2>/dev/null || pwd; } )/demo-files"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) DEMO_DIR="${DEMO_DIR//\//\\\\}" ;; esac
r=$(call "$TOK_FULL" "list-directory" "{\"path\":\"$DEMO_DIR\"}"); code=${r%%|*}; body=${r#*|}
[ "$code" = "200" ] && [[ "$body" == *"customer-pii.txt"* ]] \
  && ok "list-directory -> 200, lists the demo files" \
  || bad "list-directory" "200 listing customer-pii.txt" "$code $body"

head2 "Test 4 — insufficient scope INSIDE a valid session (per-tool check)"
TOK_RO=$(mint "$READONLY_ID" "$READONLY_SECRET" "morphik:mcp:access morphik:documents:read" "$RESOURCE")
r=$(call "$TOK_RO" "delete-document" '{"documentId":"doc-123"}'); code=${r%%|*}; body=${r#*|}
[[ "$body" == *"Missing required scope: morphik:documents:delete"* ]] \
  && ok "read-only token on delete-document -> tool error naming the missing scope (HTTP $code by design)" \
  || bad "delete-document with read-only token" "tool error naming morphik:documents:delete" "$code $body"

r=$(call "$TOK_RO" "list-directory" "{\"path\":\"$DEMO_DIR\"}"); body=${r#*|}
[[ "$body" == *"Missing required scope: morphik:filesystem:read"* ]] \
  && ok "read-only token on list-directory -> denied (filesystem scope not granted)" \
  || bad "list-directory with read-only token" "tool error naming morphik:filesystem:read" "$body"

head2 "Test 5 — the same read-only token still works for what it IS allowed"
r=$(call "$TOK_RO" "list-documents" '{}'); code=${r%%|*}; body=${r#*|}
if [ "$code" = "200" ] && [[ "$body" != *"Missing required scope"* ]]; then
  ok "list-documents passes the scope gate (no over-blocking)"
else
  bad "list-documents with read-only token" "200 and no scope error" "$code $body"
fi

head2 "Test 6 — token without the base scope is rejected by the middleware with 403"
TOK_NO=$(mint "$NOACCESS_ID" "$NOACCESS_SECRET" "morphik:documents:read" "$RESOURCE")
r=$(call "$TOK_NO" "list-documents" '{}'); code=${r%%|*}; body=${r#*|}
[ "$code" = "403" ] && [[ "$body" == *"insufficient_scope"* ]] \
  && ok "token lacking morphik:mcp:access -> 403 insufficient_scope, before any MCP parsing" \
  || bad "token without base scope" "403 insufficient_scope" "$code $body"

head2 "Test 7 — audience binding: a token for a different resource is rejected"
# decoy-resource is registered with the SAME scope string but a different URI,
# so this token is genuinely valid and correctly signed — only `aud` differs.
OTHER=$(mint "$FULL_ID" "$FULL_SECRET" "morphik:mcp:access" "http://localhost:9999/mcp")
if [ -z "$OTHER" ]; then
  bad "minting a decoy-resource token" "a token bound to http://localhost:9999/mcp" "AS returned none — is decoy-resource registered?"
else
  r=$(call "$OTHER" "list-allowed-directories" '{}'); code=${r%%|*}; body=${r#*|}
  [ "$code" = "401" ] && ok "valid token whose aud is another resource -> 401 invalid_token" \
    || bad "wrong-audience token" "401" "$code $body"
fi

head2 "Test 8 — document tools against the real Morphik backend"
if curl -fsS -o /dev/null http://localhost:8000/health 2>/dev/null; then
  # A permitted write must actually reach Morphik, otherwise "the scope check
  # passed" proves nothing about the tool still working.
  r=$(call "$TOK_FULL" "ingest-text" '{"content":"Authplane verify.sh","filename":"verify.txt"}')
  code=${r%%|*}; body=${r#*|}
  [ "$code" = "200" ] && [[ "$body" == *"Successfully ingested document with ID"* ]] \
    && ok "ingest-text with write scope -> document actually created in Morphik" \
    || bad "ingest-text with full token" "200 + a real document id" "$code $body"

  r=$(call "$TOK_RO" "ingest-text" '{"content":"should be blocked","filename":"blocked.txt"}')
  body=${r#*|}
  [[ "$body" == *"Missing required scope: morphik:documents:write"* ]] \
    && ok "ingest-text with read-only token -> denied before reaching Morphik" \
    || bad "ingest-text with read-only token" "tool error naming morphik:documents:write" "$body"

  r=$(call "$TOK_RO" "list-documents" '{}'); code=${r%%|*}; body=${r#*|}
  [ "$code" = "200" ] && [[ "$body" != *"Failed to list"* ]] \
    && ok "list-documents with read-only token -> real backend result" \
    || bad "list-documents against real backend" "200 with a backend result" "$code $body"
else
  skip "Morphik backend not on :8000 — document-tool checks skipped"
  printf '        The scope gate runs before any outbound call, so tests 1-7 are unaffected.\n'
fi

printf '\n\033[1mSummary:\033[0m %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
