const baseURL = process.argv[2] || process.env.PUBLIC_BASE_URL || 'http://localhost:8080';

async function main() {
  const health = await fetch(new URL('/health', baseURL));
  if (!health.ok) throw new Error(`health failed: ${health.status}`);
  const ready = await fetch(new URL('/ready', baseURL));
  if (!ready.ok) throw new Error(`readiness failed: ${ready.status}`);
  const accounts = await fetch(new URL('/api/accounts', baseURL));
  if (!accounts.ok) throw new Error(`accounts failed: ${accounts.status}`);
  const list = await accounts.json();
  const usernames = list.map((account) => account.username).join(',');
  if (usernames !== 'xu,si') {
    throw new Error(`unexpected accounts: ${usernames}`);
  }
  console.log(`ok ${baseURL} accounts=${usernames}`);
}

main().catch((error) => {
  console.error(error.message || error);
  process.exit(1);
});
