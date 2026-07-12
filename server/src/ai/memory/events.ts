import { domainEvents } from "../../events/domainEvents";
import { invalidateMemoriesForRecalledMessage } from "./store";

export function subscribeMemoryDomainEvents(): () => void {
  return domainEvents.subscribe("message.recalled", async ({ messageId }) => {
    await invalidateMemoriesForRecalledMessage(messageId);
  });
}
