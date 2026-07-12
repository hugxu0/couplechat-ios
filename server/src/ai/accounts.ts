import { listPublicAccounts } from "../auth/accounts";

export interface AccountInfo {
  username: string;
  name: string;
}

let cachedAccounts: AccountInfo[] = [];

export async function loadAccounts(): Promise<AccountInfo[]> {
  if (!cachedAccounts.length) {
    cachedAccounts = (await listPublicAccounts()).map((account) => ({
      username: account.username,
      name: account.name,
    }));
  }
  return cachedAccounts;
}

export function accounts(): AccountInfo[] {
  return cachedAccounts;
}
