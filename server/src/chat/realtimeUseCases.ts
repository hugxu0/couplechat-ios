import type { Server } from "socket.io";
import { handleUserMessage } from "../ai";
import { pushCoupleMessageToUnavailableRecipients } from "../push/pushService";
import type { SendMessagePayload } from "../contracts/realtime";
import type { AuthUser } from "../types";
import { createMessage, recallMessage } from "./messageService";
import { errorCodeFor } from "../errors/errorCodes";
import { startOperation } from "../observability/operationLog";

export function createRealtimeMessageUseCases(io: Server) {
  return {
    async send(user: AuthUser, input: SendMessagePayload, requestId: string) {
      const operation = startOperation("message.send", {
        requestId,
        clientId: input.clientId,
        channel: input.channel,
        messageType: input.type,
      });
      try {
        const message = await createMessage(user, input);
        if (input.channel === "couple") void pushCoupleMessageToUnavailableRecipients(message);
        handleUserMessage(io, user, message);
        operation.success({ messageId: message.id });
        return message;
      } catch (error) {
        operation.failure(errorCodeFor(error));
        throw error;
      }
    },
    recall(user: AuthUser, id: string) {
      return recallMessage(user, id);
    },
  };
}
