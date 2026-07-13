export type Username = string;

export interface AuthUser {
  username: string;
  name: string;
  accountId?: string;
  deviceId?: string;
  sessionId?: string;
  tokenVersion?: number;
  coupleId?: string;
  memberId?: string;
}
