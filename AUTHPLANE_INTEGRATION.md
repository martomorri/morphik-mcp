# Securing morphik-mcp with Authplane

A minimal OAuth 2.1 authentication and per-tool authorization layer added to
[`morphik-org/morphik-mcp`](https://github.com/morphik-org/morphik-mcp) using
[Authplane](https://github.com/authplane/authserver).

Branch: `authplane-auth-integration`.

---

## 1. Repository selected, and why

I picked `morphik-mcp` because it exposes tools that **manage a database**. A
database is where the sensitive information lives — both the users' data and the
system's own. Publishing an MCP server whose tools run DML against that database
with no authentication barrier in front of it is, to me, a critical exposure
rather than a theoretical one.

What sharpens it is *who* calls these tools. An agent decides on its own which
tool to invoke, and the operator does not always control that choice. A model
could reach for `delete-document` and destroy data without asking anyone's
permission — silently, and with nothing to stop it. Security matters more, not
less, as we hand tool selection to systems we do not fully supervise.

Its 17 tools span three separately dangerous capabilities:

- **Document retrieval** over a private corpus (`retrieve-chunks`, `search-documents`, `get-document`, …)
- **Destructive writes** (`delete-document`, and four ingestion tools)
- **Local filesystem browsing** on the machine running the server
  (`list-directory`, `search-files`, `get-file-info`, `list-allowed-directories`)

The filesystem group compounds the problem: the process reads its own host's
filesystem, bounded only by a `--allowed-dir` flag that defaults to **the user's
entire home directory** when omitted (`src/core/config.ts:92`).

## 2. Authentication posture before the change

`src/index_http.ts:40` mounted the endpoint as:

```ts
app.post('/mcp', async (req: Request, res: Response) => {
```

No middleware. No token check. `app.use(cors())` with no origin restriction.
Anyone who can reach the port can call any of the 17 tools.

**Why I say it does not enforce authentication: its own documentation says so.**
`streamable_https.md` states it in the quick start — *"Run with default
localhost:8000 (no authentication)"*. You can start the server and call it with
no key of any kind, so any agent that can reach the port can drive every tool.

**The important distinction — two different auth layers.** `morphik-mcp` does
handle a credential: the `--uri=morphik://owner:token@host` flag, whose token
becomes an `Authorization: Bearer` header on **outbound** calls to the Morphik
backend. That authenticates *the wrapper to Morphik*. It says nothing about
*who is calling the wrapper*. Those are orthogonal, and Authplane fills the
missing inbound layer without touching the existing outbound one.

> A note on scoping this correctly: an earlier draft of my plan claimed the
> server also accepted an optional `apiKey` argument on four tools, which would
> have meant a secret travelling inside JSON-RPC payloads. Checking the source
> disproved it — `apiKey` appears only in commented-out code in `src/test.ts`.
> No tool schema declares it. I mention it because "verify the claim against the
> code before building the argument on it" was the single most useful habit in
> this exercise.

## 3. Files changed

| File | Change | Lines |
|---|---|---|
| `src/index_http.ts` | Auth setup block, PRM handler, `bearerAuth` on `/mcp` | +26 |
| `src/core/authplane.ts` | **New.** Scope catalogue + `requireScope` re-export | +38 |
| `src/tools/morphik-tools.ts` | `requireScope()` in 10 handlers | +31 |
| `src/tools/file-tools.ts` | `requireScope()` in 7 handlers | +22 |
| `.env.example` | **New.** Issuer / Resource URI documentation | +26 |
| `package.json` | Add `@authplane/mcp`, `@authplane/sdk`; **pin the MCP SDK** (see §7) | +4 |

The auth-enabling code between the `// authplane:begin` / `// authplane:end`
markers is **6 lines**. Everything else is the per-tool scope map.

## 4. How it works

Two enforcement layers, deliberately distinct:

**Layer 1 — bearer middleware (HTTP).** `authplaneMcpAuth()` discovers AS
metadata (RFC 8414), fetches JWKS, and returns `auth.bearerAuth`, which wraps
`POST /mcp`. It validates signature, expiry, issuer, and the `aud` claim against
the Resource URI. `requiredScopes: [SCOPES.MCP_ACCESS]` means a token missing the
base scope is rejected with **403 `insufficient_scope`** before any MCP message
is parsed. No token at all → **401** with a `WWW-Authenticate` header pointing at
the PRM document.

**Layer 2 — per-tool scopes (JSON-RPC).** Each of the 17 handlers opens with
`requireScope(SCOPES.X, extra.authInfo)`. The MCP SDK propagates the validated
`req.auth` into each handler as `extra.authInfo`.

```
morphik:mcp:access        middleware        any call to /mcp
morphik:documents:read    8 tools           retrieve/search/list/get
morphik:documents:write   4 tools           the ingestion tools
morphik:documents:delete  1 tool            delete-document
morphik:filesystem:read   4 tools           the filesystem tools
```

A third piece, `app.get(auth.protectedResourceMetadataPath, …)`, serves the
RFC 9728 Protected Resource Metadata document so a compliant MCP client can
discover *which* authorization server to use. It is intentionally
unauthenticated — a client needs it before it has a token.

**Why the two layers fail differently, and why that is correct.** A missing base
scope is an HTTP-layer verdict: the caller has no business reaching the endpoint,
so it gets a 403 and no MCP processing happens. A missing *capability* scope is
discovered after the request has been accepted, parsed, and routed to a tool —
at which point the correct MCP answer is a JSON-RPC tool error carried inside
HTTP 200, not an HTTP status that would describe the transport rather than the
call. My original plan expected 403 for both; the SDK's design is right and the
plan was wrong. Both behaviours are asserted in `test-workspace/verify.sh`.

## 5. Setup and test

Requires Node 22+, Docker running, `curl`, `python`, `git`. **Cloning this fork
is enough — no other repository is needed.**

```bash
bash authplane-test/run-all.sh
```

That single command installs dependencies, provisions a fresh authorization
server, starts the secured MCP server, prints the PRM document, runs the
assertion suite, and finishes with the original-vs-secured comparison — logs
printed inline throughout. It ends in `ALL CHECKS PASSED` or exits non-zero.

The individual steps, if you prefer to drive them yourself:

```bash
bash authplane-test/provision.sh   # AS + resource + 3 clients
bash authplane-test/start-mcp.sh   # secured server on :8976
bash authplane-test/verify.sh      # the assertion suite
bash authplane-test/compare.sh     # original :8977 vs secured :8976
bash authplane-test/stop.sh        # stop both MCP servers
bash authplane-test/backend-up.sh  # OPTIONAL self-hosted morphik-core
```

`compare.sh` is the fastest way to see what changed. It materialises the
unmodified `main` branch into `.before/`, runs it on `:8977` next to the secured
server on `:8976`, and fires the same `tools/call` at both:

```
CALLER                    BEFORE (:8977)                AFTER (:8976)
no token at all           200  LEAKED the listing       401  invalid_token
token WITH fs scope       200  LEAKED the listing       200  authorized
token WITHOUT fs scope    200  LEAKED the listing       200  denied, missing scope
token w/o base scope      200  LEAKED the listing       403  insufficient_scope
```

The BEFORE column is constant: the original server has no notion of a caller,
so all four get the same directory listing. It does not reject the token — it
never reads it. Row 3 is the interesting one: that caller holds a valid,
correctly signed token and is refused anyway, because authentication and
authorization are separate questions.

`verify.sh` asserts twelve behaviours and currently passes all of them
(`Summary: 12 passed, 0 failed`):

| # | Assertion | Result |
|---|---|---|
| 1 | No bearer → `401` | ✅ |
| 2 | PRM document served, lists AS + all 5 scopes | ✅ |
| 3 | Full-scope token → `200` with a real tool result (×2 tools) | ✅ |
| 4 | Read-only token on `delete-document` → tool error naming the missing scope | ✅ |
| 5 | Read-only token on `list-directory` → denied (filesystem scope absent) | ✅ |
| 6 | Read-only token on `list-documents` → passes the scope gate | ✅ |
| 7 | Token without `morphik:mcp:access` → `403 insufficient_scope` | ✅ |
| 8 | Valid token whose `aud` is another resource → `401 invalid_token` | ✅ |
| 9 | `ingest-text` with write scope → **document actually created in Morphik** | ✅ |
| 10 | `ingest-text` with read-only token → denied before any outbound call | ✅ |
| 11 | `list-documents` with read-only token → real backend result | ✅ |

Test 8 mints against a second registered resource (`decoy-resource`) with the
*same scope string* but a different URI, so the token is genuinely valid and
correctly signed — only the audience differs. That isolates audience binding
from every other check.

Tests 9–11 run against a self-hosted `morphik-core` (Postgres + pgvector +
Redis) and are **skipped automatically** when it is not on `:8000`. They matter
because a passing scope check proves nothing on its own — test 9 confirms an
*allowed* write reaches Morphik and returns a real document id, while test 10
confirms the identical call from a read-only client is stopped before the
outbound request happens.

The backend is optional by design: the filesystem tools call nothing external,
and scope enforcement runs *before* any outbound request, so a missing backend
can never mask an auth result. `authplane-test/backend-up.sh` clones and
configures `morphik-core` for anyone who wants tests 9–11 to run, applying the
three fixes needed to make it start at all — a Redis hostname mismatch in its
own compose file, a multi-GB ColPali model download, and its own inbound JWT
requirement (morphik-mcp cannot satisfy that one over local HTTP, because the
`morphik://` URI form hardcodes `https://` in `src/core/config.ts`).

## 6. What was easy

**The Authplane side, start to finish.** Bringing up the authorization server
was a single `docker run`. There is enough documentation, and it is clear
enough, that I knew what to run almost immediately rather than piecing it
together.

The integration itself was equally direct: with the SDK it came down to adding
one line to each tool and registering the corresponding scopes to delimit each
client's permissions and access. That is genuinely the whole shape of it.

Better than expected: `@authplane/mcp` exports `requireScope(scope, authInfo)`
for Express. My plan had assumed per-tool scoping was FastMCP-only and budgeted
time to hand-roll it from the FastMCP example. It wasn't needed.

`AGENTS.md` is the most useful artifact in the repo: it predicted the
issuer-vs-resource-URI trap precisely enough that I never hit it.

## 7. What was difficult

**Deployment — and specifically the MCP server's, not Authplane's.**
`morphik-mcp` failed on the very first build, and the cause was an
inconsistency between its own dependencies.

Its `"@modelcontextprotocol/sdk": "^1.17.0"` floating range now resolves to
**1.30.0**, which expects **zod 4**, while the project pins **zod 3.24.2**. The
mismatch sends TypeScript into pathological inference: `tsc` exhausted a 4 GB
heap after 457 seconds and died. Pinning the MCP SDK to `1.21.2` — the last
release contemporary with zod 3 — makes it compile in seconds. That one-line pin
is part of this branch, because without it there is nothing to secure.

**And that inconsistency is itself a more serious security problem than the
build break.** An unpinned `^` range means the code that actually runs in
production is whatever the registry served on the day of the last install. The
maintainers did not choose 1.30.0; npm did. A dependency that can change under
you without review is a supply-chain exposure, and here it was severe enough to
break the build outright — which at least made it visible. A change that
silently altered behaviour instead would not have been.

It also had a second-order effect worth recording. While the build was broken I
installed with `npm install --ignore-scripts` to get past the failing `prepare`
hook. That works, but `--ignore-scripts` also suppresses `sharp`'s postinstall
step, so its native binary is never fetched and the server dies at import with
`Cannot find module '../build/Release/sharp-win32-x64.node'`. My own machine hid
this, because an earlier install had already produced the binary. It only
surfaced when I wiped `node_modules` and ran the whole thing as a reviewer
would. Once the SDK is pinned, `prepare` completes and a plain `npm install` is
correct — but it is a good illustration of how one broken dependency pushes you
toward a workaround that quietly breaks something unrelated, and of why the
verification script has to be exercised from a clean clone rather than from the
environment that built it.

This has a side effect worth stating: `@authplane/mcp@0.2.0` itself depends on
`@modelcontextprotocol/sdk ^1.29.0`, so npm installs a nested 1.30.0 for the
adapter while the server runs 1.21.2. This is safe here — the adapter only
writes `req.auth`, and 1.21.2's `StreamableHTTPServerTransport` propagates it to
`extra.authInfo` (`streamableHttp.js:297`) — and the `AuthInfo` interface is
byte-identical between the two versions. But it is a coincidence of this version
pair, not a guarantee.

**Mapping 17 tools to scopes** was the real labour: mechanical, but it is the
part where a mistake is silent. Getting `delete-document` into the read bucket
would not fail any test that only checks "authenticated calls work".

**The Broker was cut, and this is the most interesting finding.** My plan called
for RFC 8693 Token Exchange so the Morphik credential would be vaulted at the AS.
It cannot work as designed. `docs/guides/upstream-providers/token-exchange-grant.md`
§ Scenario D states that a `client_credentials` token presented against a Broker
resource fails `invalid_grant` **by design** — `broker_grants` are keyed on
`user_id`, and a machine token's `sub` is a `client_id`. The supported path is
the service-account-user pattern: create a user, complete a browser consent flow
as that user, then obtain user-scoped tokens via `jwt-bearer` or a stored refresh
token. That is a different front-door model, not an add-on, so I cut it and
documented it rather than ship something half-wired.

Two smaller notes: Authplane's `api_key` broker protocol
(`internal/adapters/brokerproto/apikey/`) would have fit Morphik's static token
well, which makes the `client_credentials` incompatibility the *only* thing
blocking that design. And the real blocker is worth naming precisely: the Broker
was never the main event. Bearer + per-tool scopes is what closes the actual
exposure. The Broker would only have added credential rotation without restart.

## 8. Before production

| Item | Now | Production |
|---|---|---|
| `devMode: true` | on (relaxes the SDK's SSRF guard for `http://localhost`) | **off** |
| Issuer | `http://localhost:9000` | `https://` real hostname |
| `AUTHPLANE_SESSION_SECURE` | unset | `true` (required for non-localhost issuers) |
| AS storage | SQLite in a Docker volume | PostgreSQL |
| Signing keys | auto-generated in `/data/keys` | Vault Transit |
| DPoP | not enabled | consider — bearer tokens are bearer tokens |
| Secrets | `openssl rand -hex 32`, on disk in `.secrets/` | a real secret manager |

DPoP is the one security control consciously left out. It is orthogonal
(sender-constraining, not access control) and `AUTHPLANE_DPOP_ENABLED` plus an
`inboundDPoP` option is most of the work.

## 9. Observations on Authplane's developer experience

**The documentation is clear.** It did not make any part of the integration
complex, and it did not complicate the implementation. I would say that with
documentation at this level, someone with no prior exposure to Authplane can
work out how to integrate with the service quickly. That was my experience here:
I was not blocked on understanding the product at any point.

**It does assume some prior knowledge**, and it is worth naming:

- **Docker.** You need to be comfortable running a container — basic enough in
  systems work, but it is a real prerequisite, not a zero.
- **Knowing which requests to make to the Admin API** to register the clients and
  the scopes. This is the step where a newcomer is most likely to pause. The
  endpoints are documented, but going from "I have an MCP server" to "I have a
  resource and three clients provisioned" means composing several calls yourself.
  The `provision.sh` in this submission exists precisely because I wanted that
  sequence captured as one runnable thing.

**The `AGENTS.md` rule about not inferring names paid for itself.** My plan had
guessed an env var called `AUTHPLANE_AES_MASTER_KEY`; the real names are
`AUTHPLANE_DATA_ENCRYPTION_DRIVER` + `AUTHPLANE_DATA_ENCRYPTION_KEY_ENV`. The
rule caught my own error before it reached a command line.

**Two smaller notes, offered as reproducibility details rather than complaints:**

- `AGENTS.md` pins `@authplane/mcp@0.2.0`; npm `latest` is `0.3.0`. I used the
  pinned version, per the hard rule. Worth knowing when following the docs
  against the current registry.
- The only per-tool scope example in TypeScript is
  `03-mcp-server-fastmcp-dpop`, which uses FastMCP and bundles DPoP. For the
  Express + MCP-SDK stack, `requireScope` is found in the type definitions. An
  Express-flavoured example would have shortened that lookup.

**For contrast on documentation quality**, `morphik-mcp`'s own
`streamable_https.md` contradicts itself on the port — `8000` in the quick
start, `8976` in "How It Works". Against that, Authplane's generated-reference
discipline stands out.

## 10. Original vs. secured

| Dimension | Before | After |
|---|---|---|
| **Authentication model** | None. Any caller reaching the port invokes any of 17 tools. | OAuth 2.1 Bearer JWT (`client_credentials`), validated against the AS's JWKS, audience-bound to `http://localhost:8976/mcp`. |
| **Authorization** | None. | 5 scopes; base scope at the middleware, 4 capability scopes per tool. Read-only clients cannot delete or read the filesystem. |
| **Developer effort** | — | 6-line auth block + 17 one-line scope guards + 1 new 38-line file. ~83 changed lines across 4 files. Most of the elapsed time went to the pre-existing build break, not the integration. |
| **Security posture** | Unauthenticated document read/delete and host filesystem browsing. | Every call authenticated and scope-checked. Least privilege is expressible and enforced. Morphik's own credential is untouched (still process-level). |
| **Deployment complexity** | One process. | Two processes (AS + MCP server), 2 env vars, 1 resource + N clients registered. AS **must** start first — the SDK throws at module load if it can't reach it. |
| **Documentation** | README with a self-contradicting port. | `.env.example` documenting the byte-for-byte rules, this memo, and a runnable `provision.sh` / `start-mcp.sh` / `verify.sh` trio. |
| **Auditability** | None. No caller identity exists. | Every call carries `client_id`, `sub`, and `scope`. AS-side issuance log (`GET /admin/issuances`) and audit events. |
| **Known limitations** | — | No DPoP (bearer tokens are replayable if stolen). No Broker — the Morphik credential still lives in the process. Dev-grade AS (SQLite, `http://`, `devMode: true`). MCP SDK pinned to 1.21.2 pending a zod 4 migration. |

**What the table costs, not just what it buys.** The honest read is that six of
these rows improve and one gets worse: deployment. A single self-contained
process becomes two services with a startup ordering dependency — the MCP server
cannot even boot if the AS is unreachable, because discovery happens at module
load. In exchange you get an identity on every call and an audit trail where
there was none.

For a server that can delete documents and read the host filesystem, that trade
is clearly worth making. For a read-only server behind a private network it
might not be, and it is worth being explicit that this is a judgement about
*this* server's blast radius rather than a universal rule.

Two operational notes that follow from it: the AS becomes a dependency of every
deployment, so it needs the availability budget of the services behind it
(runtime is more forgiving than startup — JWKS and metadata are cached, so a
brief AS outage does not immediately fail in-flight validation). And the audit
row is arguably the most undersold: going from "no caller identity exists" to a
per-call `client_id` is what makes an incident investigable at all.

## 11. Out of scope, but found along the way

`src/core/security.ts:15` gates filesystem access with:

```ts
const isAllowed = allowedDirectories.some(dir => normalizedRequested.startsWith(dir));
```

Two pre-existing problems, both independent of this integration:

1. **No path-boundary check.** A `--allowed-dir=/data/reports` also permits
   `/data/reports-private` — `startsWith` does not stop at a separator.
2. **Case-sensitive comparison on a case-insensitive filesystem.** On Windows,
   `C:\Users\…` and `c:\Users\…` are the same directory but compare unequal.
   This surfaced as a spurious "Access denied" during testing.

I did not fix these — they are unrelated to auth and would muddy the diff. But
(1) is a real traversal-adjacent weakness, and it is now guarded by
`morphik:filesystem:read`, which limits *who* can reach it but not *what* it
allows once reached. Worth a separate issue upstream.
