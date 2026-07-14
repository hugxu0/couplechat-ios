import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { latestImageGroup, recentMessages } from "../conversation/log";
import { GEN } from "../settings";
import { describeImages } from "../provider";
import { extractWebPages, routedWebSearch } from "../search/router";
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

  server.registerTool(
    "fallback_web_search",
    {
      description: "原生 web_search 结果不足或不可用时的联网兜底。根据完整语义选择国内、国际、交叉核实或自动；服务端负责 MiMo/Tavily 主备与合并。",
      inputSchema: z.object({
        query: z.string().min(1).max(500),
        source: z.enum(["domestic", "global", "crosscheck", "auto"]).optional(),
      }),
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    async (args) => jsonResult(await recordAgentTool(run, "fallback_web_search", args, async () => {
      const result = await routedWebSearch(args.query, args.source ?? "auto", GEN.search);
      if (result?.annotations?.length) {
        for (const citation of result.annotations) {
          if (!run.citations.some((existing) => existing.url === citation.url)) run.citations.push(citation);
        }
      }
      return result ?? { content: "", annotations: [], unavailable: true };
    })),
  );

  server.registerTool(
    "web_extract",
    {
      description: "读取主人明确指定的网页正文，用于总结或提取信息。最多读取 3 个 URL；普通搜索应先用原生 web_search。",
      inputSchema: z.object({
        urls: z.array(z.string().url()).min(1).max(3),
        query: z.string().max(300).optional(),
      }),
      annotations: { readOnlyHint: true, openWorldHint: true },
    },
    async (args) => jsonResult(await recordAgentTool(run, "web_extract", args, async () => {
      const result = await extractWebPages(args.urls, args.query);
      for (const page of result.pages) {
        if (!run.citations.some((existing) => existing.url === page.url)) {
          run.citations.push({ url: page.url, title: page.title || page.url, summary: page.content.slice(0, 500) });
        }
      }
      return result;
    })),
  );
}
