import { config } from "../config";

export async function sendBarkPush(barkKey: string, title: string, body: string) {
  const url = new URL(`https://api.day.app/${encodeURIComponent(barkKey)}/${encodeURIComponent(title)}/${encodeURIComponent(body)}`);
  url.searchParams.set("url", config.appDeepLinkScheme);

  const response = await fetch(url, { signal: AbortSignal.timeout(10_000) });
  if (!response.ok) {
    throw new Error(`Bark push failed: ${response.status}`);
  }
}
