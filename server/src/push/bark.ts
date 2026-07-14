import { config } from "../config";

export interface BarkPushOptions {
  group?: string;
  badge?: number;
  url?: string;
  level?: "active" | "timeSensitive" | "passive";
}

export async function sendBarkPush(
  barkKey: string,
  title: string,
  body: string,
  options: BarkPushOptions = {},
) {
  const url = new URL(`https://api.day.app/${encodeURIComponent(barkKey)}/${encodeURIComponent(title)}/${encodeURIComponent(body)}`);
  url.searchParams.set("url", options.url ?? config.appDeepLinkScheme);
  if (options.group) url.searchParams.set("group", options.group);
  if (options.badge !== undefined) url.searchParams.set("badge", String(Math.max(0, options.badge)));
  if (options.level) url.searchParams.set("level", options.level);

  const response = await fetch(url, { signal: AbortSignal.timeout(10_000) });
  if (!response.ok) {
    throw new Error(`Bark push failed: ${response.status}`);
  }
}
