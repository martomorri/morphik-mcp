#!/usr/bin/env bash
# Side-by-side: the ORIGINAL morphik-mcp vs. the Authplane-secured one.
#
#   BEFORE  (:8977)  the unmodified `main` branch, materialised from git
#   AFTER   (:8976)  this branch, with Authplane wired in
#
# Both get the identical request. Prereq: provision.sh.
#
# Usage: bash authplane-test/compare.sh

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
SECRETS="$REPO/.secrets"
AS=http://localhost:9000
BEFORE=http://localhost:8977/mcp
AFTER=http://localhost:8976/mcp

DEMO_DIR="$( cd "$HERE" && { pwd -W 2>/dev/null || pwd; } )/demo-files"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) DEMO_ARG="${DEMO_DIR//\//\\}" ;; *) DEMO_ARG="$DEMO_DIR" ;; esac

b()  { printf '\033[1m%s\033[0m\n' "$1"; }
dim(){ printf '\033[2m%s\033[0m\n' "$1"; }

curl -fsS -o /dev/null "$AS/.well-known/oauth-authorization-server" 2>/dev/null || {
  echo "ERROR: authorization server not reachable at $AS — run provision.sh first." >&2; exit 1; }
[ -f "$SECRETS/clients.env" ] || { echo "ERROR: $SECRETS/clients.env missing — run provision.sh first." >&2; exit 1; }

# ---------------------------------------------------------------------------
# Build the BEFORE server straight from git `main`.
#
# It is materialised into .before/ inside the repo so it resolves the same
# node_modules. That matters: `main` does NOT compile as published — its
# floating "@modelcontextprotocol/sdk": "^1.17.0" resolves to a zod-4 release
# while the project pins zod 3, and tsc dies of heap exhaustion. Sharing
# node_modules means this branch's SDK pin applies, which is the only reason a
# "before" server can be built at all. That pin is not an auth change; it is
# the prerequisite for having anything to secure.
# ---------------------------------------------------------------------------
b "==> materialising the original server from git main"
cd "$REPO"
rm -rf .before && mkdir -p .before
git archive main src | tar -x -C .before/
NODE_OPTIONS=--max-old-space-size=4096 npx tsc \
  --outDir .before/build --rootDir .before/src \
  --target ES2022 --module Node16 --moduleResolution Node16 \
  --esModuleInterop --skipLibCheck .before/src/index_http.ts >/dev/null 2>&1
[ -f .before/build/index_http.js ] || { echo "ERROR: could not build the original server" >&2; exit 1; }
dim "    built .before/build/index_http.js"

b "==> building the secured server"
NODE_OPTIONS=--max-old-space-size=4096 npx tsc >/dev/null 2>&1 || true
[ -f build/index_http.js ] || { echo "ERROR: could not build the secured server" >&2; exit 1; }

bash "$HERE/stop.sh" >/dev/null 2>&1 || true
sleep 1

[ -f .env ] || cp .env.example .env
set -a; . ./.env; set +a

wait_healthy() { # $1=port $2=label $3=logfile
  for _ in $(seq 1 30); do
    sleep 1
    curl -fsS -o /dev/null "http://localhost:$1/health" 2>/dev/null && return 0
  done
  echo >&2
  echo "ERROR: the $2 server never became healthy on :$1." >&2
  tail -12 "$3" >&2
  return 1
}

# Start the SECURED server first and wait for it before launching the other.
# authplaneMcpAuth() fetches AS metadata + JWKS at module load and throws on
# timeout, so it must not compete for CPU with a second Node boot. Starting
# both at once is exactly how this fails, and a bogus table is worse than an
# error.
b "==> starting the secured server (:8976)"
PORT=8976 nohup node build/index_http.js "--allowed-dir=$DEMO_ARG" > "$HERE/mcp-server.log" 2>&1 &
wait_healthy 8976 "secured" "$HERE/mcp-server.log" || exit 1

b "==> starting the original server (:8977)"
PORT=8977 nohup node .before/build/index_http.js "--allowed-dir=$DEMO_ARG" > "$HERE/before-server.log" 2>&1 &
wait_healthy 8977 "original" "$HERE/before-server.log" || exit 1

dim "    BEFORE :8977 (no auth)   AFTER :8976 (Authplane)"

case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) REQ_DIR="${DEMO_DIR//\//\\}" ;; *) REQ_DIR="$DEMO_DIR" ;; esac
REQ_DIR="$REQ_DIR" python -c "
import json, os
print(json.dumps({'jsonrpc':'2.0','id':1,'method':'tools/call',
 'params':{'name':'list-directory','arguments':{'path':os.environ['REQ_DIR']}}}))
" > /tmp/ap_cmp_req.json

set -a; . "$SECRETS/clients.env"; set +a
mint() {
  curl -sS -X POST "$AS/oauth/token" -u "$1:$2" -d "grant_type=client_credentials" \
    -d "scope=$3" --data-urlencode "resource=http://localhost:8976/mcp" \
  | python -c "import json,sys; print(json.load(sys.stdin).get('access_token',''))"
}

fire() { # $1=url $2=token(optional) -> "CODE|summary"
  local auth=(); [ -n "${2:-}" ] && auth=(-H "Authorization: Bearer $2")
  # Truncate first: on a connection failure curl leaves the file untouched and
  # the previous response would be misread as this one's.
  : > /tmp/ap_cmp_body
  local code; code=$(curl -sS -o /tmp/ap_cmp_body -w '%{http_code}' -X POST "$1" "${auth[@]}" \
    -H "Content-Type: application/json" -H "Accept: application/json, text/event-stream" \
    --data-binary @/tmp/ap_cmp_req.json 2>/dev/null)
  local body; body=$(tr -d '\n' < /tmp/ap_cmp_body)
  [ "$code" = "000" ] && { printf '000|server unreachable'; return; }
  # The same successful listing means opposite things on the two servers: on
  # BEFORE nobody was asked for credentials, on AFTER the caller earned it.
  local granted="returned listing (authorized)"
  [ "$1" = "$BEFORE" ] && granted="LEAKED the file listing"
  local note="?"
  case "$body" in
    *customer-pii.txt*)          note="$granted" ;;
    *"Missing required scope"*)  note="denied — missing scope" ;;
    *insufficient_scope*)        note="denied — insufficient_scope" ;;
    *invalid_token*)             note="denied — invalid_token" ;;
    *)                           note="$(printf '%.60s' "$body")" ;;
  esac
  printf '%s|%s' "$code" "$note"
}

row() { printf '  %-26s  %-34s  %s\n' "$1" "$2" "$3"; }

echo
b "The same tools/call (list-directory over demo-files), against both servers"
echo
row "CALLER" "BEFORE (:8977, original)" "AFTER (:8976, Authplane)"
row "--------------------------" "----------------------------------" "----------------------------------"

r1=$(fire "$BEFORE" ""); r2=$(fire "$AFTER" "")
row "no token at all" "HTTP ${r1%%|*}  ${r1#*|}" "HTTP ${r2%%|*}  ${r2#*|}"

TOK_FULL=$(mint "$FULL_ID" "$FULL_SECRET" "morphik:mcp:access morphik:filesystem:read")
r1=$(fire "$BEFORE" "$TOK_FULL"); r2=$(fire "$AFTER" "$TOK_FULL")
row "token WITH fs scope" "HTTP ${r1%%|*}  ${r1#*|}" "HTTP ${r2%%|*}  ${r2#*|}"

TOK_RO=$(mint "$READONLY_ID" "$READONLY_SECRET" "morphik:mcp:access morphik:documents:read")
r1=$(fire "$BEFORE" "$TOK_RO"); r2=$(fire "$AFTER" "$TOK_RO")
row "token WITHOUT fs scope" "HTTP ${r1%%|*}  ${r1#*|}" "HTTP ${r2%%|*}  ${r2#*|}"

TOK_NO=$(mint "$NOACCESS_ID" "$NOACCESS_SECRET" "morphik:documents:read")
r1=$(fire "$BEFORE" "$TOK_NO"); r2=$(fire "$AFTER" "$TOK_NO")
row "token w/o base scope" "HTTP ${r1%%|*}  ${r1#*|}" "HTTP ${r2%%|*}  ${r2#*|}"

cat <<'EOF'

Reading the table:

  The BEFORE column is identical in every row — the original server has no
  notion of a caller. It cannot tell an anonymous request from a scoped one,
  so it hands back the same directory listing to all four. The token is not
  rejected; it is simply never looked at.

  The AFTER column separates the four callers: no token is turned away at the
  door, a token without the base scope never reaches MCP parsing, a token with
  the wrong capability scope is refused by the tool itself, and only the
  correctly scoped caller gets data.

  Row 3 is the one worth pausing on: that caller holds a perfectly valid,
  correctly signed token and is refused anyway, because authentication and
  authorization are different questions.

EOF
