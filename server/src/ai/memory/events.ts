import { domainEvents } from "../../events/domainEvents";
import { reconcileMemoryLifecycle } from "./store";

export function subscribeMemoryDomainEvents(): () => void {
  return domainEvents.subscribe("message.recalled", async () => {
    // 记忆不再绑定原始消息；这里只维护有效期和失去基础来源的派生卡。
    await reconcileMemoryLifecycle();
  });
}
