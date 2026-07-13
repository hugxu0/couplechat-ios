export type CursorValidator<T> = (value: unknown) => value is T;

export function encodeCursor(value: unknown): string {
  return Buffer.from(JSON.stringify(value)).toString("base64url");
}

export function decodeCursor<T>(
  cursor: string | undefined,
  validate: CursorValidator<T>,
): T | null {
  if (!cursor) return null;
  try {
    const value: unknown = JSON.parse(Buffer.from(cursor, "base64url").toString("utf8"));
    return validate(value) ? value : null;
  } catch {
    return null;
  }
}

export function isNumberStringCursor(value: unknown): value is [number, string] {
  return Array.isArray(value)
    && value.length === 2
    && typeof value[0] === "number"
    && Number.isFinite(value[0])
    && typeof value[1] === "string";
}
