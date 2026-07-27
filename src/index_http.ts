#!/usr/bin/env node

import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import express, { Request, Response } from "express";
import cors from "cors";
import { parseConfig } from "./core/config.js";
import { createMcpServer } from "./core/server.js";
import { ALL_SCOPES, SCOPES } from "./core/authplane.js";

// === Authplane integration =================================================
// `authplaneMcpAuth()` performs RFC 8414 metadata discovery and a JWKS fetch
// at module load, so the authorization server must already be reachable at
// AUTHPLANE_ISSUER when this file is imported — start the AS first.
// `requiredScopes` is narrower than `scopes`: the middleware only demands the
// base access scope, and each tool checks its own capability scope. Without
// this split the middleware would demand all five scopes on every call.
// `devMode: true` relaxes the SDK's SSRF guard to allow an http:// localhost
// issuer; it must be off in production.
// authplane:begin
import { authplaneMcpAuth } from "@authplane/mcp";
const auth = await authplaneMcpAuth({
  issuer: process.env.AUTHPLANE_ISSUER!,
  resource: process.env.AUTHPLANE_RESOURCE!,
  scopes: ALL_SCOPES, requiredScopes: [SCOPES.MCP_ACCESS], devMode: true,
});
// authplane:end

// HTTP server configuration
const PORT = process.env.PORT || 8976;

async function main() {
  // Parse configuration from command line arguments
  const config = parseConfig();
  
  // Create Express app for HTTP server
  const app = express();
  
  // Add CORS middleware
  app.use(cors());
  
  // Add JSON parsing middleware
  app.use(express.json({ limit: '50mb' }));
  
  // Add URL encoded parsing middleware
  app.use(express.urlencoded({ extended: true, limit: '50mb' }));
  
  // RFC 9728 Protected Resource Metadata — tells MCP clients which
  // authorization server to use and which scopes this server understands.
  // Deliberately unauthenticated: a client needs it *before* it has a token.
  app.get(auth.protectedResourceMetadataPath, auth.protectedResourceMetadataHandler);

  // Health check endpoint
  app.get('/health', (_req: Request, res: Response) => {
    res.json({ 
      status: 'healthy',
      timestamp: new Date().toISOString(),
      morphikApiBase: config.apiBase,
      hasAuthToken: !!config.authToken,
      allowedDirectories: config.allowedDirectories.length
    });
  });
  
  // MCP endpoint for stateless mode
  app.post('/mcp', auth.bearerAuth, async (req: Request, res: Response) => {
    try {
      // Create new server and transport for each request (stateless)
      const server = createMcpServer(config);
      const transport = new StreamableHTTPServerTransport({
        sessionIdGenerator: undefined, // undefined = stateless mode
      });

      await server.connect(transport);
      await transport.handleRequest(req, res, req.body);

      // Clean up after request
      req.on('close', () => {
        transport.close();
        server.close();
      });

    } catch (error) {
      console.error('Error handling MCP request:', error);
      if (!res.headersSent) {
        res.status(500).json({
          jsonrpc: "2.0",
          error: {
            code: -32603,
            message: "Internal server error",
          },
          id: null,
        });
      }
    }
  });
  
  // Start the HTTP server and return a promise to keep main() alive
  return new Promise<void>((resolve, reject) => {
    const httpServer = app.listen(PORT, () => {
      console.error(`Morphik MCP Server running on HTTP port ${PORT}`);
      console.error(`File operations enabled: ${config.allowedDirectories.length} allowed ${config.allowedDirectories.length === 1 ? 'directory' : 'directories'}`);
      console.error(`Use --allowed-dir=dir1,dir2,... to specify allowed directories for file operations`);
      console.error(`Endpoints:`);
      console.error(`  - GET  /health - Health check`);
      console.error(`  - POST /mcp    - MCP requests (stateless mode)`);
    });

    httpServer.on('error', (error) => {
      console.error('Server error:', error);
      reject(error);
    });

    // Handle graceful shutdown
    process.on('SIGINT', () => {
      console.error('\nShutting down server...');
      httpServer.close(() => {
        console.error('Server shut down successfully');
        resolve();
      });
    });

    process.on('SIGTERM', () => {
      console.error('\nShutting down server...');
      httpServer.close(() => {
        console.error('Server shut down successfully');
        resolve();
      });
    });
  });
}

main().catch((error) => {
  console.error("Fatal error in main():", error);
  process.exit(1);
});