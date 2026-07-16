import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { latestImageGroup, recentMessages } from "../conversation/log";
import { GEN } from "../settings";
import { describeImages } from "../provider";
import { recordAgentTool, type AgentToolRun } from "./runContext";
import { jsonResult } from "./toolSupport";

export function registerExternalTools(server: McpServer, run: AgentToolRun): void {
  server.registerTool(
    "inspect_recent_images",
    {
      description: "联合识别当前频道最近一组图片，最多9张，并保留图片顺序。当前消息图片已直接提供给主模型，不要重复调用；只有文字问题明显指代前面一张或多张图片，或主模型无法读取当前图片时调用。",
      inputSchema: z.object({
        prompt: z.string().min(1).max(500).optional(),
        maxImages: z.number().int().min(1).max(9).optional(),
      }),
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    async (args) => jsonResult(await recordAgentTool(run, "inspect_recent_images", args, async () => {
      const limit = args.maxImages ?? 9;
      let imageUrls = (run.identity.currentImageUrls?.length
        ? run.identity.currentImageUrls
        : run.identity.currentImageUrl
          ? [run.identity.currentImageUrl]
          : []).slice(0, limit);
      let messageIds: string[] = run.identity.messageId ? [run.identity.messageId] : [];
      if (!imageUrls.length) {
        const recent = (await recentMessages(run.identity.storedChannel, 50))
          .filter((message) => message.id !== run.identity.messageId);
        const group = latestImageGroup(recent, limit);
        imageUrls = group.urls;
        messageIds = group.messages.map((message) => message.id);
      }
      if (!imageUrls.length) return { found: false, imageCount: 0, messageIds: [], description: "" };
      const description = await describeImages(
        imageUrls,
        GEN.describeImage,
        args.prompt || `按图片1到图片${imageUrls.length}的顺序联合分析，描述与当前对话有关的内容；需要时比较图片之间的异同，不能确定的细节要明确说明。`,
      );
      run.usedVision = Boolean(description);
      return {
        found: Boolean(description),
        imageCount: imageUrls.length,
        messageIds,
        description: description ?? "图片识别失败",
      };
    })),
  );

}
