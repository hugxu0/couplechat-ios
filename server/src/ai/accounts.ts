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

export function resolveUsername(value: string | undefined): string | undefined {
  if (!value) return undefined;
  return cachedAccounts.find((account) => account.username === value || account.name === value)?.username ?? value;
}
