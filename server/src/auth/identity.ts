import { get, type DatabaseTransaction } from "../db";
import type { AuthUser, ClientChannel } from "../types";

export interface ActiveIdentity {
  accountId: string;
  coupleId: string | null;
  memberId: string | null;
}

export interface ConversationIdentity extends ActiveIdentity {
  conversationId: string;
  storedChannel: string;
}

type Getter = Pick<DatabaseTransaction, "get">;

async function activeIdentityWith(
  getter: Getter,
  user: AuthUser,
): Promise<ActiveIdentity | null> {
  const row = await getter.get<{
    account_id: string;
    couple_id: string | null;
    member_id: string | null;
  }>(
    `SELECT account.id AS account_id, member.couple_id, member.id AS member_id
       FROM accounts account
       LEFT JOIN couple_members member ON member.account_id = account.id AND member.state = 'active'
      WHERE account.username = ? AND account.status = 'active'`,
    [user.username],
  );
  return row ? {
    accountId: row.account_id,
    coupleId: row.couple_id,
    memberId: row.member_id,
  } : null;
}

export async function activeIdentity(user: AuthUser): Promise<ActiveIdentity | null> {
  return activeIdentityWith({ get }, user);
}

export async function activeIdentityIn(
  db: DatabaseTransaction,
  user: AuthUser,
): Promise<ActiveIdentity | null> {
  return activeIdentityWith(db, user);
}

async function conversationWith(
  getter: Getter,
  user: AuthUser,
  channel: ClientChannel,
): Promise<ConversationIdentity | null> {
  const identity = await activeIdentityWith(getter, user);
  if (!identity) return null;
  if (channel === "couple") {
    if (!identity.coupleId) return null;
    const conversation = await getter.get<{ id: string }>(
      `SELECT id FROM conversations
       WHERE kind = 'couple' AND couple_id = ? AND archived_at IS NULL`,
      [identity.coupleId],
    );
    return conversation ? {
      ...identity,
      conversationId: conversation.id,
      storedChannel: "couple",
    } : null;
  }
  const conversation = await getter.get<{ id: string }>(
    `SELECT id FROM conversations
     WHERE kind = 'ai' AND owner_account_id = ? AND archived_at IS NULL`,
    [identity.accountId],
  );
  return conversation ? {
    ...identity,
    conversationId: conversation.id,
    storedChannel: `ai:${user.username}`,
  } : null;
}

export async function conversationIdentity(
  user: AuthUser,
  channel: ClientChannel,
): Promise<ConversationIdentity | null> {
  return conversationWith({ get }, user, channel);
}

export async function conversationIdentityIn(
  db: DatabaseTransaction,
  user: AuthUser,
  channel: ClientChannel,
): Promise<ConversationIdentity | null> {
  return conversationWith(db, user, channel);
}
