import type { FastifyInstance } from "fastify";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { createCoupleChatMcpServer } from "./server";
import { resolveAgentToolRun } from "./runContext";

export async function registerAiMcpRoutes(app: FastifyInstance): Promise<void> {
  app.post("/api/ai-mcp", async (request, reply) => {
    const token = String(request.headers["x-couplechat-ai-run"] ?? "");
    const run = resolveAgentToolRun(token);
    if (!run) return reply.code(401).send({ error: "invalid_agent_run" });

    const server = createCoupleChatMcpServer(run);
    const transport = new StreamableHTTPServerTransport({
      sessionIdGenerator: undefined,
      enableJsonResponse: true,
    });
    reply.hijack();
    try {
      await server.connect(transport);
      await transport.handleRequest(request.raw, reply.raw, request.body);
    } catch (error) {
      request.log.warn({ error }, "AI MCP request failed");
      if (!reply.raw.headersSent) {
        reply.raw.writeHead(500, { "content-type": "application/json" });
        reply.raw.end(JSON.stringify({ jsonrpc: "2.0", error: { code: -32603, message: "Internal error" }, id: null }));
      }
    } finally {
      await transport.close().catch(() => {});
      await server.close().catch(() => {});
    }
  });

  app.get("/api/ai-mcp", async (_request, reply) => reply.code(405).send({ error: "method_not_allowed" }));
  app.delete("/api/ai-mcp", async (_request, reply) => reply.code(405).send({ error: "method_not_allowed" }));
}
