/**
 * Authplane scope catalogue for the Morphik MCP server.
 *
 * Every string below appears in four places and must match byte-for-byte:
 * this file, `POST /admin/resources`, `POST /admin/clients`, and the
 * `scope=` form parameter on `POST /oauth/token`. Drift between those four
 * is the documented cause of most `insufficient_scope` rejections.
 *
 * Enforcement happens at two different layers, and they fail differently:
 *
 *  - `MCP_ACCESS` is handed to `authplaneMcpAuth({ requiredScopes })`, so the
 *    bearer middleware rejects a token lacking it at the HTTP layer with
 *    `403 insufficient_scope` — before any MCP message is parsed.
 *  - The four capability scopes are checked inside each tool handler via
 *    `requireScope()`. A denial there surfaces as a JSON-RPC tool error
 *    carried inside `HTTP 200`, because at that point the request is already
 *    a well-formed MCP call on an authenticated connection. That status
 *    difference is intentional, not an oversight.
 */
export const SCOPES = {
  /** Required by the bearer middleware for any request to POST /mcp. */
  MCP_ACCESS: "morphik:mcp:access",
  /** Read, list, search and retrieve documents from Morphik. */
  DOCUMENTS_READ: "morphik:documents:read",
  /** Ingest new documents into Morphik. */
  DOCUMENTS_WRITE: "morphik:documents:write",
  /** Delete documents from Morphik. */
  DOCUMENTS_DELETE: "morphik:documents:delete",
  /** Browse the MCP server's own filesystem, within --allowed-dir. */
  FILESYSTEM_READ: "morphik:filesystem:read",
} as const;

/** Full catalogue, as advertised in the Protected Resource Metadata document. */
export const ALL_SCOPES: string[] = Object.values(SCOPES);

/**
 * Re-exported from the Authplane adapter so tool modules import scopes and
 * the enforcement helper from one place. Throws when the calling token's
 * `authInfo.scopes` does not include the required scope.
 */
export { requireScope } from "@authplane/mcp";
