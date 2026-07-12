import { all, type AccountRow } from "../db";
import type { ClientMessage } from "../types";
import { isAvailable } from "../socket/presence";
import { sendBarkPush } from "./bark";
import { config } from "../config";

export async function pushCoupleMessageToUnavailableRecipients(message: ClientMessage) {
  if (!config.pushEnabled) return;
  const recipients = await all<AccountRow>("SELECT * FROM accounts WHERE username != ?", [message.sender]);

  await Promise.allSettled(
    recipients
      .filter((recipient) => recipient.bark_key && !isAvailable(recipient.username))
      .map((recipient) =>
        sendBarkPush(recipient.bark_key!, message.senderName, "收到一条新的悄悄话"),
      ),
  );
}
