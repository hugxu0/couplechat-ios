import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { resolveRecentImageGroup, sameImageSet } from "../imageAttachment";
import { recordAgentTool, type AgentToolRun } from "./runContext";
import { jsonResult } from "./toolSupport";

/**
 * 解析频道内最近一组图片，请求 runtime 与用户问题一起多模态重跑。
 * 不再调用独立识图模型。
 */
export function registerExternalTools(server: McpServer, run: AgentToolRun): void {
  server.registerTool(
    "inspect_recent_images",
    {
      description:
        "附着当前频道最近一组图片（≤9）到主模型，与用户原问题一起看。本条/预附着图已够用时勿调用。成功后系统会多模态重跑，请在重跑中直接依据图像回答。",
      inputSchema: z.object({
        maxImages: z.number().int().min(1).max(9).optional(),
      }),
      annotations: { readOnlyHint: true, openWorldHint: false },
    },
    async (args) => jsonResult(await recordAgentTool(run, "inspect_recent_images", args, async () => {
      const maxImages = args.maxImages ?? 9;
      const already = run.identity.currentImageUrls ?? [];
      const group = await resolveRecentImageGroup({
        storedChannel: run.identity.storedChannel,
        excludeMessageId: run.identity.messageId,
        maxImages,
      });

      if (!group.urls.length) {
        return {
          found: false,
          attached: false,
          imageCount: 0,
          messageIds: [],
          note: "最近没有可附着的图片",
        };
      }

      if (sameImageSet(group.urls, already)) {
        run.usedVision = true;
        return {
          found: true,
          attached: true,
          alreadyAttached: true,
          imageCount: group.urls.length,
          messageIds: group.messageIds,
          note: "这些图片已在当前多模态输入中，请直接结合用户问题看图回答",
        };
      }

      run.pendingImageAttach = {
        urls: group.urls,
        messageIds: group.messageIds,
      };
      run.usedVision = true;
      return {
        found: true,
        attached: true,
        alreadyAttached: false,
        willRerunMultimodal: true,
        imageCount: group.urls.length,
        messageIds: group.messageIds,
        note: "已请求将图片与用户原问题一并再交给主模型；最终以重跑后的看图回答为准，不要编造未看见的图像细节",
      };
    })),
  );
}
