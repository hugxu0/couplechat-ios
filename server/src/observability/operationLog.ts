import type { ErrorCode } from "../errors/errorCodes";

type FieldValue = string | number | boolean | null | undefined;
export type OperationFields = Record<string, FieldValue>;
const sensitiveKeys = new Set(["body", "message", "password", "question", "secret", "text", "token"]);

function safeFields(fields: OperationFields): OperationFields {
  return Object.fromEntries(
    Object.entries(fields).filter(([key]) => !sensitiveKeys.has(key.toLowerCase())),
  );
}

export function startOperation(operation: string, fields: OperationFields = {}) {
  const startedAt = Date.now();
  const finish = (status: "ok" | "error" | "timeout", extra: OperationFields = {}) => {
    console.info(JSON.stringify({
      type: "operation",
      operation,
      status,
      ...safeFields(fields),
      ...safeFields(extra),
      durationMs: Date.now() - startedAt,
    }));
  };
  return {
    success: (extra?: OperationFields) => finish("ok", extra),
    failure: (errorCode: ErrorCode, extra?: OperationFields) => finish("error", { errorCode, ...extra }),
    timeout: (extra?: OperationFields) => finish("timeout", extra),
  };
}
