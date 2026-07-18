import { ZodError } from "zod";

export const errorCodes = {
  invalidRequest: "invalid_request",
  unauthorized: "unauthorized",
  invalidCredentials: "invalid_credentials",
  rateLimited: "rate_limited",
  notFound: "not_found",
  recallWindowExpired: "recall_window_expired",
  uploadDisabled: "uploads_disabled",
  fileRequired: "file_required",
  unsupportedMediaType: "unsupported_media_type",
  fileSignatureMismatch: "file_signature_mismatch",
  uploadNotFound: "upload_not_found",
  uploadAlreadyAttached: "upload_already_attached",
  uploadURLMismatch: "upload_url_mismatch",
  attachmentPhotoTypeMismatch: "attachment_photo_type_mismatch",
  attachmentVideoTypeMismatch: "attachment_video_type_mismatch",
  internal: "internal_error",
} as const;

export type ErrorCode = typeof errorCodes[keyof typeof errorCodes];
const knownCodes = new Set<string>(Object.values(errorCodes));

export function errorCodeFor(error: unknown): ErrorCode {
  if (error instanceof ZodError) return errorCodes.invalidRequest;
  if (error instanceof Error && knownCodes.has(error.message)) return error.message as ErrorCode;
  return errorCodes.internal;
}
