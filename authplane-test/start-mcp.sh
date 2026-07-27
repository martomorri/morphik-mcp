#!/usr/bin/env bash
# Build and start morphik-mcp with Authplane auth enabled, on :8976.
#
# The Authplane adapter performs AS metadata discovery + a JWKS fetch at module
# load, so the authorization server must already be up. Run provision.sh first.
#
# Usage: bash authplane-test/start-mcp.sh

set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
LOG="$HERE/mcp-server.log"

# morphik resolves tool paths with Node's path module, and its allow-list check
# is a case-sensitive startsWith (src/core/security.ts), so on Windows the
# casing of the drive letter must match what callers send. `pwd -W` emits the
# native form; plain `pwd` is correct everywhere else.
DEMO_DIR="$( cd "$HERE" && { pwd -W 2>/dev/null || pwd; } )/demo-files"
case "$(uname -s)" in MINGW*|MSYS*|CYGWIN*) DEMO_DIR="${DEMO_DIR//\//\\}" ;; esac

if ! curl -fsS -o /dev/null http://localhost:9000/.well-known/oauth-authorization-server 2>/dev/null; then
  echo "ERROR: authorization server is not reachable at http://localhost:9000" >&2
  echo "       run 'bash authplane-test/provision.sh' first — the SDK throws at import if the AS is down." >&2
  exit 1
fi

echo "==> freeing port 8976 if held"
bash "$HERE/stop.sh" >/dev/null 2>&1 || true
sleep 1

cd "$REPO"
[ -f .env ] || cp .env.example .env

echo "==> building"
NODE_OPTIONS=--max-old-space-size=4096 npx tsc

echo "==> starting on :8976"
echo "    allowed-dir: $DEMO_DIR"
set -a; . ./.env; set +a
nohup node build/index_http.js "--allowed-dir=$DEMO_DIR" > "$LOG" 2>&1 &

for _ in $(seq 1 30); do
  sleep 1
  if curl -fsS -o /dev/null http://localhost:8976/health 2>/dev/null; then
    echo "==> up. logs: $LOG"
    exit 0
  fi
done

echo "ERROR: server did not become healthy; last log lines:" >&2
tail -20 "$LOG" >&2
exit 1
