import type { Server } from "socket.io";
import { handleUserMessage } from "../ai";
import { pushCoupleMessageToUnavailableRecipients } from "../push/pushService";
import type { SendMessagePayload } from "../contracts/realtime";
import type { AuthUser } from "../types";
import { createMessage, recallMessage } from "./messageService";

export function createRealtimeMessageUseCases(io: Server) {
  return {
    async send(user: AuthUser, input: SendMessagePayload) {
      const message = await createMessage(user, input);
      if (input.channel === "couple") void pushCoupleMessageToUnavailableRecipients(message);
      handleUserMessage(io, user, message);
      return message;
    },
    recall(user: AuthUser, id: string) {
      return recallMessage(user, id);
    },
  };
}
