#!/usr/bin/env bash
# ONE COMMAND that validates the whole integration end to end.
#
#     bash authplane-test/run-all.sh
#
# It provisions a fresh authorization server, starts the secured MCP server,
# runs the assertion suite, runs the original-vs-secured comparison, and then
# tears everything back down. Every log is printed along the way, so nothing
# is hidden and nothing is left running.
#
#     --keep        leave the servers up afterwards to poke at them by hand
#     --clean-only  tear everything down and exit (no run)
#
# Requirements: Node.js 22+, Docker (running), curl, python, git.
# A Morphik backend is NOT required — see the note printed at the end.

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
STEP=0
KEEP=0
CLEAN_ONLY=0

for arg in "$@"; do
  case "$arg" in
    --keep)       KEEP=1 ;;
    --clean-only) CLEAN_ONLY=1 ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \?//'
      printf '\nFlags:\n  --keep        leave the servers running after the run\n'
      printf '  --clean-only  tear everything down and exit\n'
      exit 0 ;;
    *) echo "unknown flag: $arg (try --help)" >&2; exit 2 ;;
  esac
done

banner() {
  STEP=$((STEP+1))
  printf '\n\033[1;36m%s\033[0m\n' "════════════════════════════════════════════════════════════════════════"
  printf '\033[1;36m  STEP %d — %s\033[0m\n' "$STEP" "$1"
  printf '\033[1;36m%s\033[0m\n\n' "════════════════════════════════════════════════════════════════════════"
}
fail() { printf '\n\033[1;31mFAILED at step %d: %s\033[0m\n' "$STEP" "$1" >&2; exit 1; }

# Everything this run created, removed in reverse order. Each line says what
# actually happened rather than assuming, so a partial run still reports truly.
teardown() {
  printf '  MCP servers:\n'
  bash "$HERE/stop.sh" 2>/dev/null | sed 's/^/    /'

  printf '  Authorization server:\n'
  if docker rm -f authplane-as >/dev/null 2>&1; then
    printf '    removed container authplane-as\n'
  else
    printf '    no authplane-as container to remove\n'
  fi
  if docker volume rm authplane-as-data >/dev/null 2>&1; then
    printf '    removed volume authplane-as-data (AS database + signing keys)\n'
  else
    printf '    no authplane-as-data volume to remove\n'
  fi

  printf '  Generated files:\n'
  rm -rf "$REPO/.before"  && printf '    removed .before/          (the materialised original server)\n'
  rm -rf "$REPO/.secrets" && printf '    removed .secrets/         (AS admin key + client secrets)\n'
  rm -f  "$REPO/.env"     && printf '    removed .env              (regenerated from .env.example)\n'

  printf '  Left in place on purpose:\n'
  printf '    node_modules/             so a re-run is fast\n'
  printf '    build/                    compiled output\n'
  printf '    authplane-test/*.log      so you can read what happened\n'
  printf '    the authplane/authserver image (31 MB) — remove with:\n'
  printf '      docker rmi authplane/authserver:latest\n'
}

if [ "$CLEAN_ONLY" = "1" ]; then
  printf '\033[1mTearing everything down\033[0m\n\n'
  teardown
  printf '\n\033[1;32mClean.\033[0m\n'
  exit 0
fi

printf '\033[1mAuthplane × morphik-mcp — full verification\033[0m\n'
printf 'repo: %s\n' "$REPO"
[ "$KEEP" = "1" ] && printf 'mode: --keep (servers will be left running)\n'

# ---------------------------------------------------------------------------
banner "Preflight — required tooling"
for c in node npm docker curl git python; do
  if command -v "$c" >/dev/null 2>&1; then printf '  ok    %-8s %s\n' "$c" "$(command -v "$c")"
  else printf '  MISS  %s\n' "$c"; fail "missing required tool: $c"; fi
done
NODE_MAJOR=$(node -p "process.versions.node.split('.')[0]")
printf '  node version: %s' "$(node -v)"
[ "$NODE_MAJOR" -ge 22 ] && printf '  (ok, >=22)\n' || { printf '  (TOO OLD)\n'; fail "Node.js 22+ required"; }
docker info >/dev/null 2>&1 || fail "the Docker daemon is not reachable — start Docker and retry"
printf '  docker daemon: reachable\n'

# ---------------------------------------------------------------------------
banner "Dependencies"
cd "$REPO"
if [ -d node_modules/@authplane/mcp ] && [ -d node_modules/sharp/build/Release ]; then
  printf '  node_modules already present, skipping install\n'
else
  # A plain install on purpose. Two things depend on lifecycle scripts running:
  # this project's `prepare` hook (which runs tsc), and `sharp`, which fetches
  # its native binary in a postinstall step. Using --ignore-scripts here leaves
  # sharp without sharp-win32-x64.node and the server dies at import — a failure
  # that only shows up on a clean clone. Both work now that the MCP SDK is
  # pinned; before the pin, `prepare` could not complete at all (see § 7).
  printf '  running npm install (first run only)...\n'
  npm install --no-audit --no-fund 2>&1 | tail -6 || fail "npm install failed"
fi
printf '  @modelcontextprotocol/sdk : %s  (pinned; see AUTHPLANE_INTEGRATION.md §7)\n' \
  "$(node -p "require('./node_modules/@modelcontextprotocol/sdk/package.json').version")"
printf '  @authplane/mcp            : %s\n' \
  "$(node -p "require('./node_modules/@authplane/mcp/package.json').version")"

# ---------------------------------------------------------------------------
banner "Provision the authorization server"
bash "$HERE/provision.sh" || fail "provision.sh"

# ---------------------------------------------------------------------------
banner "Start the secured MCP server"
bash "$HERE/start-mcp.sh" || { echo "--- mcp-server.log ---"; cat "$HERE/mcp-server.log"; fail "start-mcp.sh"; }
printf '\n\033[2m--- mcp-server.log ---\033[0m\n'
cat "$HERE/mcp-server.log"

# ---------------------------------------------------------------------------
banner "Protected Resource Metadata (RFC 9728)"
printf 'This document is intentionally unauthenticated: a client needs it BEFORE\n'
printf 'it has a token, to discover which authorization server to ask.\n\n'
curl -sS http://localhost:8976/.well-known/oauth-protected-resource/mcp \
  | python -m json.tool || fail "PRM document"

# ---------------------------------------------------------------------------
banner "Assertion suite"
VERIFY_RC=0
bash "$HERE/verify.sh" || VERIFY_RC=$?

# ---------------------------------------------------------------------------
banner "Original vs. secured, side by side"
COMPARE_RC=0
bash "$HERE/compare.sh" || COMPARE_RC=$?

# ---------------------------------------------------------------------------
banner "Teardown"
if [ "$KEEP" = "1" ]; then
  printf '  --keep given: leaving everything running.\n\n'
  printf '  Authorization server : http://localhost:9000  (admin UI :9101/admin/ui/)\n'
  printf '  Secured MCP server   : http://localhost:8976/mcp\n'
  printf '  Original MCP server  : http://localhost:8977/mcp\n\n'
  printf '  Tear down later with: bash authplane-test/run-all.sh --clean-only\n'
else
  teardown
fi

# ---------------------------------------------------------------------------
banner "Result"
if [ "$VERIFY_RC" -eq 0 ] && [ "$COMPARE_RC" -eq 0 ]; then
  printf '\033[1;32m  ALL CHECKS PASSED\033[0m\n'
else
  printf '\033[1;31m  FAILURES: verify.sh rc=%d, compare.sh rc=%d\033[0m\n' "$VERIFY_RC" "$COMPARE_RC"
fi

cat <<EOF

  Logs kept for inspection:
    $HERE/mcp-server.log      the secured server
    $HERE/before-server.log   the original server

  About the Morphik backend: it is NOT required. The filesystem tools need no
  backend, so the entire auth layer is proven without one, and the document-tool
  checks self-skip when nothing answers on :8000. Scope enforcement runs before
  any outbound call to Morphik, so a missing backend can never mask an auth
  result. To exercise the document tools too, see AUTHPLANE_INTEGRATION.md § 5.

EOF

[ "$VERIFY_RC" -eq 0 ] && [ "$COMPARE_RC" -eq 0 ] || exit 1
