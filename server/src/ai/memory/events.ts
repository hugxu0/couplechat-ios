import { domainEvents } from "../../events/domainEvents";
import { reconcileMemoryLifecycle } from "./store";

export function subscribeMemoryDomainEvents(): () => void {
  return domainEvents.subscribe("message.recalled", async () => {
    // 撤回事务已经删除证据及失去全部证据的 Memory；这里负责清理历史遗留孤儿。
    await reconcileMemoryLifecycle();
  });
}
