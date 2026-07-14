import type { ClientMessage } from "../types";
import { isAvailable } from "../socket/presence";
import { sendBarkPush } from "./bark";
import { config } from "../config";
import { listBarkRecipients, listCoupleBarkRecipients } from "./recipients";

export async function pushCoupleMessageToUnavailableRecipients(message: ClientMessage, coupleId?: string) {
  if (!config.pushEnabled) return;
  if (!coupleId) return;
  const recipients = await listCoupleBarkRecipients(coupleId);
  const seen = new Set<string>();

  await Promise.allSettled(
    recipients
      .filter((recipient) => {
        if (recipient.username === message.sender || isAvailable(recipient.username)) return false;
        if (seen.has(recipient.barkKey)) return false;
        seen.add(recipient.barkKey);
        return true;
      })
      .map((recipient) =>
        sendBarkPush(recipient.barkKey, message.senderName, "收到一条新的悄悄话", {
          group: "CoupleChat · 公聊",
          badge: 1,
          url: `${config.appDeepLinkScheme}chat/couple`,
        }),
      ),
  );
}

export async function pushPrivateAiMessageToUnavailableRecipient(
  message: ClientMessage,
  username?: string,
) {
  if (!config.pushEnabled || !username || isAvailable(username)) return;
  const recipients = await listBarkRecipients([username]);
  await Promise.allSettled(recipients.map((recipient) => sendBarkPush(
    recipient.barkKey,
    "大橘回你啦",
    message.text.slice(0, 160) || "收到一条新的私聊回复",
    {
      group: "CoupleChat · 大橘私聊",
      badge: 1,
      url: `${config.appDeepLinkScheme}chat/ai`,
    },
  )));
}
