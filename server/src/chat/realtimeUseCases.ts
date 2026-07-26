import type { Server } from "socket.io";
import { handleUserMessage } from "../ai";
import { pushCoupleMessageToUnavailableRecipients } from "../push/pushService";
import type { SendMessagePayload } from "../contracts/realtime";
import type { AuthUser } from "../types";
import {
  createMessageWithStatus,
  recallMessage,
  type CreateMessageResult,
} from "./messageService";
import { errorCodeFor } from "../errors/errorCodes";
import { startOperation } from "../observability/operationLog";

interface RealtimeMessageDependencies {
  createMessage(
    user: AuthUser,
    input: SendMessagePayload,
  ): Promise<CreateMessageResult>;
  pushCoupleMessage: typeof pushCoupleMessageToUnavailableRecipients;
  handleUserMessage: typeof handleUserMessage;
}

const defaultDependencies: RealtimeMessageDependencies = {
  createMessage: createMessageWithStatus,
  pushCoupleMessage: pushCoupleMessageToUnavailableRecipients,
  handleUserMessage,
};

function reportOptionalFailure(operation: string, error: unknown): void {
  console.warn(
    `[${operation}] 后台任务失败: ${error instanceof Error ? error.message : String(error)}`,
  );
}

export function createRealtimeMessageUseCases(
  io: Server,
  dependencies: RealtimeMessageDependencies = defaultDependencies,
) {
  return {
    async send(user: AuthUser, input: SendMessagePayload, requestId: string) {
      const operation = startOperation("message.send", {
        requestId,
        clientId: input.clientId,
        channel: input.channel,
        messageType: input.type,
      });
      try {
        const result = await dependencies.createMessage(user, input);
        if (result.created) {
          if (input.channel === "couple") {
            void dependencies.pushCoupleMessage(result.message, user.coupleId)
              .catch((error) => reportOptionalFailure("push.couple_message", error));
          }
          try {
            dependencies.handleUserMessage(io, user, result.message);
          } catch (error) {
            reportOptionalFailure("ai.dispatch", error);
          }
        }
        operation.success({ messageId: result.message.id, created: result.created });
        return result;
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
