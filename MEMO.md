# Securing morphik-mcp with Authplane

**Repo:** [`morphik-org/morphik-mcp`](https://github.com/morphik-org/morphik-mcp) · **Branch:** `authplane-auth-integration`

To run and validate everything, one command: `bash authplane-test/run-all.sh`

For the deeper technical write-up, see [`AUTHPLANE_INTEGRATION.md`](AUTHPLANE_INTEGRATION.md).

---

## Repository selected, and why

I picked `morphik-mcp` because it exposes tools that manage a database. A
database is where the sensitive information lives — the users' data and the
system's own. Publishing an MCP server whose tools run DML against that
database, with no authentication barrier in front, is a critical exposure.

What makes it worse is who calls these tools. An agent decides on its own which
tool to invoke, and the operator does not always control that choice. A model
could reach for `delete-document` and wipe data without asking anyone's
permission — silently. Security matters more, not less, as we hand tool
selection to systems we do not fully supervise.

## Current authentication and security posture

There is none, and the project says so itself. Its `streamable_https.md` states
in the quick start: *"Run with default localhost:8000 (no authentication)"*. You
start the server and call it with no key of any kind, so any agent that reaches
the port can drive all 17 tools — including document deletion and browsing the
host's filesystem, which defaults to the user's entire home directory when
`--allowed-dir` is omitted.

One clarification, because it is easy to conflate two things. The server does
handle a credential: the `--uri=morphik://owner:token@host` flag, whose token
authenticates *the wrapper to Morphik* on outbound calls. That says nothing
about *who is calling the wrapper*. Authplane fills the missing inbound layer
and leaves the existing outbound one untouched.

## Files changed

| File | Change |
|---|---|
| `src/index_http.ts` | Auth setup block, PRM handler, bearer middleware on `/mcp` |
| `src/core/authplane.ts` | **New.** The 5-scope catalogue |
| `src/tools/morphik-tools.ts` | One scope check in each of 10 handlers |
| `src/tools/file-tools.ts` | One scope check in each of 7 handlers |
| `.env.example` | **New.** Documents the two required variables |
| `package.json` | Adds the Authplane SDK; pins the MCP SDK (see below) |

The auth-enabling code is 6 lines. The rest is the per-tool scope map.

## How the integration works

Two layers. The middleware validates the JWT on every request to `/mcp` —
signature, expiry, issuer, and audience — and requires a base scope
(`morphik:mcp:access`). No token gets `401`; a token without the base scope
gets `403` before anything else happens.

Above that, each of the 17 tools declares the capability scope it needs:
`documents:read`, `documents:write`, `documents:delete`, or `filesystem:read`.
A read-only client holding a perfectly valid token still cannot call
`delete-document`. That is the part I actually care about — authentication alone
would have been a blank cheque.

The server also publishes a Protected Resource Metadata document so an MCP
client can discover which authorization server to use on its own, instead of
being configured by hand.

## Setup and test instructions

```bash
git clone <this fork> && cd morphik-mcp
git checkout authplane-auth-integration
bash authplane-test/run-all.sh
```

Requirements are Node 22+ and Docker. Nothing else — no `.env` to fill in, no
external accounts, no API keys. Every secret is generated at run time.

The script installs dependencies, starts the authorization server, provisions
the resource and three clients with different scope sets, runs the checks, and
then tears everything back down. It ends in `ALL CHECKS PASSED`.

It also runs both versions of the server side by side and fires the same
request at each. That table is the clearest thing in the submission: the
original answers all four callers identically with the file listing, because it
has no notion of a caller at all. The secured one separates them — `401`,
authorized, denied by scope, `403`.

A Morphik backend is optional. The filesystem tools need no backend, and the
document-tool checks skip themselves if one is not running.

## What was easy, what was difficult

**Easy: the Authplane side, start to finish.** Bringing up the authorization
server was a single `docker run`. There is enough documentation, and it is clear
enough, that I knew what to run almost immediately instead of piecing it
together. The integration itself was equally direct — with the SDK it came down
to adding one line to each tool and registering the corresponding scopes to
delimit each client's permissions.

**Difficult: deployment, and specifically the MCP server's, not Authplane's.**
`morphik-mcp` failed on the very first build, because of an inconsistency
between its own dependencies. It declares a floating range for the MCP SDK,
which now resolves to a version expecting a newer `zod` than the one the project
pins. TypeScript never finishes compiling — it exhausted 4 GB of heap and died.
Pinning the SDK to the last compatible version fixes it in seconds, and that pin
is part of this branch, because without it there is nothing to secure.

That inconsistency is a worse security problem than the build break itself. An
unpinned range means the code running in production is whatever the registry
served the day of the last install. The maintainers did not choose that version;
npm did. Here it was severe enough to break the build outright, which at least
made it visible — a change that silently altered behaviour would not have been.

## What would need to change before production

Turn off `devMode` in the SDK, which today relaxes an SSRF guard so a local
`http://` issuer works. Move the issuer to HTTPS. Replace the AS's SQLite
storage with PostgreSQL and its auto-generated signing keys with a real key
manager. Move secrets out of generated files into a secret manager.

Two things I would add rather than change. DPoP, so a stolen token is not
usable on its own — I left it out deliberately because it is a separate concern
from access control, not because it does not matter. And a bounded retry around
the SDK's startup, since it fetches AS metadata at module load and refuses to
start if the AS is briefly unreachable. That one bit me during testing, so it is
not theoretical.

## Observations on Authplane's developer experience

The documentation is clear. It did not make any part of the integration
complex, and it did not complicate the implementation. With documentation at
this level, someone with no prior exposure to Authplane can work out how to
integrate quickly — that was my experience, and I was never blocked on
understanding the product.

It does assume some prior knowledge, which is worth naming. You need to be
comfortable with Docker — basic enough in systems work, but not nothing. And
you need to know which requests to send to the Admin API to register the
clients and the scopes. That is the step where a newcomer is most likely to
pause: the endpoints are documented, but going from "I have an MCP server" to "I
have a resource and three clients provisioned" means composing several calls
yourself. The provisioning script in this submission exists precisely because I
wanted that sequence captured as one runnable thing.

## Original vs. secured

| Dimension | Before | After |
|---|---|---|
| **Authentication** | None. Any caller invokes any of 17 tools. | OAuth 2.1 Bearer JWT, validated against the AS, bound to this server's URI. |
| **Authorization** | None. | 5 scopes: one at the middleware, four enforced per tool. |
| **Developer effort** | — | 6 lines of auth + one line per tool. Most of the time went to the pre-existing build break, not the integration. |
| **Security posture** | Unauthenticated document read/delete and host filesystem access. | Every call authenticated and scope-checked; least privilege is enforceable. |
| **Deployment** | One process. | Two services, plus a startup ordering dependency. This is the one row that gets worse. |
| **Documentation** | README contradicts itself on the port. | `.env.example`, this memo, and three runnable scripts. |
| **Auditability** | None — no caller identity exists. | Every call carries a client id and scope; the AS logs each issuance. |
| **Known limitations** | — | No DPoP. Morphik's own credential still lives in the process. Dev-grade AS. MCP SDK pinned pending a `zod` upgrade. |

Six rows improve and one gets worse. For a server that can delete documents and
read the host filesystem, that trade is clearly worth making — but it is a
judgement about this server's blast radius, not a universal rule.
