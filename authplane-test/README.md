# Verifying the Authplane integration

Everything needed to run and validate the integration. Cloning this fork is
enough — no other repository is required.

## One command

```bash
bash authplane-test/run-all.sh
```

Installs dependencies (first run), provisions a fresh authorization server,
starts the secured MCP server, prints the PRM document, runs the assertion
suite, runs the original-vs-secured comparison, then **tears everything back
down**. Every log is printed inline. Ends in `ALL CHECKS PASSED` or a non-zero
exit, leaving no containers, volumes, or credentials behind.

You do **not** need to create or populate any `.env` file. `.env` is copied
from `.env.example` automatically, and every secret is generated at run time
with `openssl rand`. There are no external accounts or API keys.

| Flag | Effect |
|---|---|
| *(none)* | Run everything, then clean up |
| `--keep` | Leave the servers running so you can poke at them by hand |
| `--clean-only` | Tear everything down and exit, without running |

**Requirements:** Node.js 22+, Docker running, `curl`, `python`, `git`.
First run takes a few minutes (npm install + pulling the 31 MB AS image).

## The scripts

| Script | What it does |
|---|---|
| `run-all.sh` | All of the below, in order, with full logs. **Start here.** |
| `provision.sh` | Starts the AS on `:9000` (admin `:9101`), registers the resource + 3 clients |
| `start-mcp.sh` | Builds and starts the secured server on `:8976` |
| `verify.sh` | The assertion suite |
| `compare.sh` | Runs the original (`:8977`) and secured (`:8976`) servers side by side |
| `stop.sh` | Stops both MCP servers |
| `backend-up.sh` | **Optional.** Self-hosted `morphik-core` backend — see below |

Order matters: the Authplane SDK performs AS metadata discovery and a JWKS
fetch at **module load**, so the MCP server cannot start if the AS is down.

Secrets are written to `../.secrets/` and logs to `*.log` here — both
gitignored.

## What the checks prove

| # | Assertion |
|---|---|
| 1 | No bearer → `401`. The endpoint is genuinely closed. |
| 2 | The PRM document is served and names the AS + all 5 scopes. |
| 3 | A full-scope token gets `200` and a **real tool result**, not just a handshake. |
| 4 | A read-only token on `delete-document` is refused, and the error names the missing scope. |
| 5 | Read access does not imply filesystem access — scopes are genuinely separate. |
| 6 | The same read-only token still works for what it *is* granted (no over-blocking). |
| 7 | A token lacking the base scope gets `403` from the middleware, before any MCP parsing. |
| 8 | A correctly-signed token for a *different* resource gets `401`. |
| 9–11 | Document tools against a real Morphik backend (auto-skipped if absent). |

Test 8 is the sharpest. It mints against `decoy-resource`, registered at the AS
with the **same scope string** but a different URI, so the token is genuinely
valid — only `aud` differs. That isolates audience binding from every other
check.

## The comparison

`compare.sh` fires the identical `tools/call` at both servers:

| Caller | BEFORE `:8977` | AFTER `:8976` |
|---|---|---|
| no token at all | `200` leaked the listing | `401` invalid_token |
| token **with** fs scope | `200` leaked the listing | `200` authorized |
| token **without** fs scope | `200` leaked the listing | `200` denied, missing scope |
| token without base scope | `200` leaked the listing | `403` insufficient_scope |

The BEFORE column never changes — the original server has no notion of a
caller, so it answers all four identically. It does not reject the token; it
never reads it.

Row 3 is worth pausing on: that caller holds a perfectly valid, correctly
signed token and is refused anyway. Authentication and authorization are
different questions, and the original server could answer neither.

`compare.sh` materialises the BEFORE server from `git main` into `.before/`
(gitignored). `main` **cannot be built as published** — its floating `^1.17.0`
MCP SDK range resolves to a zod-4 release while the project pins zod 3, and
`tsc` dies of heap exhaustion. `.before/` shares this branch's `node_modules`,
so the SDK pin applies and a "before" server can exist at all. That pin is not
an auth change; it is the prerequisite for having anything to secure.

## The optional Morphik backend

**Not required.** The filesystem tools call no backend, so the entire auth layer
is proven without one, and checks 9–11 skip themselves when nothing answers on
`:8000`. Scope enforcement runs *before* any outbound call to Morphik, so a
missing backend can never mask an auth result.

To exercise the document tools against a real database anyway:

```bash
bash authplane-test/backend-up.sh   # clones + starts morphik-core
bash authplane-test/verify.sh       # 9-11 now run
```

Be aware it builds a ~10 GB image and takes 20–40 minutes on a first run. The
script applies three fixes needed to make morphik-core start at all — a Redis
hostname mismatch in its own compose file, a multi-GB ColPali model download,
and its own inbound JWT requirement. All are explained in the script header and
applied via a generated override, leaving morphik-core's tree untouched.

## Ports

| Service | Port | Note |
|---|---|---|
| Authplane OAuth (public) | 9000 | the issuer; must match `AUTHPLANE_ISSUER` |
| Authplane Admin API + UI | **9101** | container listens on 9001; Windows reserves host 9001 |
| morphik-mcp (secured) | 8976 | Resource URI is `http://localhost:8976/mcp` |
| morphik-mcp (original) | 8977 | started only by `compare.sh` |
| morphik-core API | 8000 | optional |

The 9001 → 9101 remap is host-side only. It does not affect the issuer or the
Resource URI, which are the values actually bound into tokens.

## Cleaning up

`run-all.sh` cleans up after itself. To tear down a run started with `--keep`,
or after driving the scripts individually:

```bash
bash authplane-test/run-all.sh --clean-only
```

That stops both MCP servers, removes the `authplane-as` container and its
volume, and deletes `.secrets/`, `.env` and `.before/`. It leaves
`node_modules/`, `build/` and the logs so a re-run is fast and the output stays
readable. The AS image (31 MB) also stays; remove it with
`docker rmi authplane/authserver:latest`.

`provision.sh` is idempotent too — it recreates the container and volume on
every run, so you can simply re-run it instead of cleaning first.
