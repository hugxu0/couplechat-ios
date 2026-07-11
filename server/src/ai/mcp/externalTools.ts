import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { latestImage, recentMessages } from "../conversation/log";
import { GEN } from "../settings";
import { describeImage, webSearch } from "../provider";
import { recordAgentTool, type AgentToolRun } from "./runContext";
import { jsonResult } from "./toolSupport";

export function registerExternalTools(server: McpServer, run: AgentToolRun): void {
  server.registerTool(
    "inspect_recent_image",
    {
      description: "识别当前消息图片或当前频道最近图片。用户提到‘这张图、这个、刚才图片’时调用。",
      inputSchema: z.object({ prompt: z.string().min(1).max(500).optional() }),
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    async (args) => jsonResult(await recordAgentTool(run, "inspect_recent_image", args, async () => {
      let imageUrl = run.identity.currentImageUrl;
      if (!imageUrl) imageUrl = latestImage(await recentMessages(run.identity.storedChannel, 50))?.url ?? undefined;
      if (!imageUrl) return { found: false, description: "" };
      const description = await describeImage(
        imageUrl,
        GEN.describeImage,
        args.prompt || "描述图片中对当前对话有用的内容，不能确定的细节要明确说明。",
      );
      run.usedVision = Boolean(description);
      return { found: true, description: description ?? "图片识别失败" };
    })),
  );

  server.registerTool(
    "web_search",
    {
      description: "搜索互联网最新或外部信息。私人聊天记忆、普通闲聊和可以从本地数据回答的问题不要联网。",
      inputSchema: z.object({ query: z.string().min(1).max(500) }),
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    async (args) => jsonResult(await recordAgentTool(run, "web_search", args, async () => {
      const result = await webSearch(args.query, GEN.search);
      if (result?.annotations?.length) {
        for (const citation of result.annotations) {
          if (!run.citations.some((existing) => existing.url === citation.url)) run.citations.push(citation);
        }
      }
      return result ?? { content: "", annotations: [], unavailable: true };
    })),
  );
}
