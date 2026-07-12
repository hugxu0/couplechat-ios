export interface DomainEventMap {
  "message.recalled": { messageId: string };
}

type DomainEventName = keyof DomainEventMap;
type Handler<Name extends DomainEventName> = (payload: DomainEventMap[Name]) => void | Promise<void>;

class DomainEventBus {
  private readonly handlers = new Map<DomainEventName, Set<Handler<any>>>();

  subscribe<Name extends DomainEventName>(name: Name, handler: Handler<Name>): () => void {
    const handlers = this.handlers.get(name) ?? new Set<Handler<any>>();
    handlers.add(handler);
    this.handlers.set(name, handlers);
    return () => handlers.delete(handler);
  }

  async publish<Name extends DomainEventName>(name: Name, payload: DomainEventMap[Name]): Promise<void> {
    const handlers = [...(this.handlers.get(name) ?? [])];
    const results = await Promise.allSettled(handlers.map((handler) => handler(payload)));
    for (const result of results) {
      if (result.status === "rejected") {
        const message = result.reason instanceof Error ? result.reason.message : String(result.reason);
        console.warn(`[event] handler failed event=${name}: ${message}`);
      }
    }
  }
}

export const domainEvents = new DomainEventBus();
