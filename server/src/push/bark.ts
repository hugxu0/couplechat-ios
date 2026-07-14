import { config } from "../config";

export interface BarkPushOptions {
  group?: string;
  badge?: number;
  url?: string;
  icon?: string;
  level?: "active" | "timeSensitive" | "passive";
}

export function buildBarkPushURL(
  barkKey: string,
  title: string,
  body: string,
  options: BarkPushOptions = {},
) {
  const url = new URL(`https://api.day.app/${encodeURIComponent(barkKey)}/${encodeURIComponent(title)}/${encodeURIComponent(body)}`);
  url.searchParams.set("url", options.url ?? config.appDeepLinkScheme);
  url.searchParams.set("icon", options.icon ?? config.barkIconURL);
  if (options.group) url.searchParams.set("group", options.group);
  if (options.badge !== undefined) url.searchParams.set("badge", String(Math.max(0, options.badge)));
  if (options.level) url.searchParams.set("level", options.level);
  return url;
}

export async function sendBarkPush(
  barkKey: string,
  title: string,
  body: string,
  options: BarkPushOptions = {},
) {
  const url = buildBarkPushURL(barkKey, title, body, options);

  const response = await fetch(url, { signal: AbortSignal.timeout(10_000) });
  if (!response.ok) {
    throw new Error(`Bark push failed: ${response.status}`);
  }
}
