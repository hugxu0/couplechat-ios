import type { ClientMessage } from "../types";
import { isAvailable } from "../socket/presence";
import { sendBarkPush } from "./bark";
import { config } from "../config";
import { listCoupleBarkRecipients } from "./recipients";

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
        sendBarkPush(recipient.barkKey, message.senderName, "收到一条新的悄悄话"),
      ),
  );
}
