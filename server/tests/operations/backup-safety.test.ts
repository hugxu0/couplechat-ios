import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import path from "node:path";
import test from "node:test";
import { fileURLToPath } from "node:url";

const testDirectory = path.dirname(fileURLToPath(import.meta.url));
const serverDirectory = path.resolve(testDirectory, "../..");

function read(relativePath: string): string {
  return readFileSync(path.join(serverDirectory, relativePath), "utf8");
}

test("backup table policy exactly follows every migration schema", () => {
  const migrationSource = read("src/db/migrate.ts").split("export async function migrate", 1)[0];
  const policySource = read("scripts/backup-table-policy.sh");

  const maxSchemaMatch = policySource.match(/BACKUP_TABLE_POLICY_MAX_SCHEMA=(\d+)/);
  assert.ok(maxSchemaMatch, "backup policy must declare its maximum schema");
  const maxSchema = Number(maxSchemaMatch[1]);

  const policyRules = [...policySource.matchAll(/^\s*'([a-z][a-z0-9_]*)\|(\d+)\|(\d+)'\s*$/gm)].map(
    ([, table, minSchema, maxTableSchema]) => ({
      table,
      minSchema: Number(minSchema),
      maxSchema: Number(maxTableSchema),
    }),
  );
  assert.ok(policyRules.length > 0, "backup policy must contain table rules");
  assert.equal(new Set(policyRules.map(({ table }) => table)).size, policyRules.length, "table rules must be unique");

  const tables = new Set<string>(["schema_migrations"]);
  const migrationSnapshots = new Map<number, Set<string>>();
  let currentVersion = 0;
  for (const line of migrationSource.split(/\r?\n/)) {
    const versionMatch = line.match(/^\s+version:\s+(\d+),/);
    if (versionMatch) {
      if (currentVersion > 0) migrationSnapshots.set(currentVersion, new Set(tables));
      currentVersion = Number(versionMatch[1]);
      continue;
    }
    if (currentVersion === 0) continue;

    const createMatch = line.match(/CREATE TABLE IF NOT EXISTS\s+([a-z][a-z0-9_]*)/);
    if (createMatch) tables.add(createMatch[1]);

    const renameMatch = line.match(/ALTER TABLE\s+([a-z][a-z0-9_]*)\s+RENAME TO\s+([a-z][a-z0-9_]*)/);
    if (renameMatch) {
      assert.ok(tables.delete(renameMatch[1]), `migration v${currentVersion} renames an unknown table`);
      tables.add(renameMatch[2]);
    }

    const dropMatch = line.match(/DROP TABLE IF EXISTS\s+([a-z][a-z0-9_]*)/);
    if (dropMatch) tables.delete(dropMatch[1]);
  }
  migrationSnapshots.set(currentVersion, new Set(tables));
  assert.equal(currentVersion, maxSchema, "new migrations must update BACKUP_TABLE_POLICY_MAX_SCHEMA");

  for (let schema = 1; schema <= maxSchema; schema += 1) {
    const migratedTables = [...(migrationSnapshots.get(schema) ?? [])].sort();
    const policyTables = policyRules
      .filter(({ minSchema, maxSchema: tableMax }) => schema >= minSchema && (tableMax === 0 || schema <= tableMax))
      .map(({ table }) => table)
      .sort();
    assert.deepEqual(policyTables, migratedTables, `backup table policy drifted at schema v${schema}`);
  }
});

test("published backups are pruned only after the new daily and weekly copies exist", () => {
  const source = read("scripts/backup-production.sh");
  const retentionSource = read("scripts/backup-retention.sh");
  const pruneFunction = retentionSource.slice(retentionSource.indexOf("prune_expired()"));
  const dailyPublish = source.indexOf('mv -- "$partial" "$destination"');
  const weeklyPublish = source.indexOf('mv -- "$weekly_partial" "$weekly_destination"');
  const dailyPrune = source.lastIndexOf('prune_expired "$daily_root"');
  const weeklyPrune = source.lastIndexOf('prune_expired "$weekly_root"');

  assert.ok(dailyPublish >= 0 && weeklyPublish > dailyPublish, "both backup tiers must be atomically published");
  assert.ok(dailyPrune > weeklyPublish, "daily pruning must happen after a successful weekly publish on Sundays");
  assert.ok(weeklyPrune > dailyPrune, "weekly pruning must happen at the end of a successful backup run");
  assert.equal(source.match(/prune_expired "\$weekly_root"/g)?.length, 1, "weekly is pruned only after a new weekly copy");
  assert.match(retentionSource, /minimum_total=2/, "an unverified new backup must retain one older backup");
  assert.match(retentionSource, /verified_count > 1/, "the last restore-verified backup must be protected");
  assert.match(
    retentionSource,
    /quiesced_verified_count > 1/,
    "best_effort verification must never replace the last quiesced restore-verified backup",
  );
  assert.match(retentionSource, /backup_id_started_epoch/, "finalized backup age must come from immutable backup_id");
  assert.doesNotMatch(pruneFunction, /-mtime/, "RESTORE-VERIFIED writes must not extend finalized retention");
  assert.match(retentionSource, /LC_ALL=C sort -z/, "expired backups must be processed oldest first");
});

test("restore verification writes its marker only after the temporary database is dropped", () => {
  const source = read("scripts/verify-backup.sh");
  const finalDrop = source.lastIndexOf('drop_temp_database || die');
  const markerWrite = source.lastIndexOf('marker="$backup/RESTORE-VERIFIED"');

  assert.ok(finalDrop >= 0 && markerWrite > finalDrop, "RESTORE-VERIFIED must mean a full restore completed and cleaned up");
  assert.match(source, /format_version=2[\s\S]*verification=db_full_restore_all_tables_media_sample_sequences/);
  assert.match(source, /sha256sums_sha256=\$sha256sums_hash/);
  assert.match(source, /message_server_seq_seq[\s\S]*messages[\s\S]*server_seq/);
  assert.match(source, /sync_event_seq[\s\S]*sync_events[\s\S]*seq/);
  assert.match(source, /format_version" == "2"[\s\S]*不写 RESTORE-VERIFIED[\s\S]*exit "\$VERIFY_EXIT_DEGRADED_LEGACY_V2"/);
  assert.match(source, /VERIFY_EXIT_DEGRADED_LEGACY_V2=3/);
  assert.match(source, /verification_status=degraded_legacy_v2/);
});

test("backup metadata is portable and records release plus sequence evidence", () => {
  const source = read("scripts/backup-production.sh");
  const migrationSource = read("src/db/migrate.ts");

  assert.match(source, /compose\.production\.yml \.env\.production\.example Dockerfile/);
  assert.doesNotMatch(source, /for candidate in compose\.production\.yml \.env\.example/);
  assert.doesNotMatch(source, /for command in[^\n]*\bgit\b/, "git must not be a required backup dependency");
  assert.match(source, /release_file="\$SERVER_DIR\/RELEASE"/);
  assert.match(source, /RELEASE 必须只包含完整 40 位 commit SHA/);
  assert.match(source, /elif command -v git/);
  assert.doesNotMatch(source, /rev-parse --short/);
  assert.match(source, /revision_source=\$revision_source/);
  assert.match(read("scripts/verify-backup.sh"), /release\|git[\s\S]*完整小写 commit SHA/);

  assert.match(migrationSource, /CREATE SEQUENCE IF NOT EXISTS message_server_seq_seq/);
  assert.match(migrationSource, /ALTER TABLE messages ADD COLUMN IF NOT EXISTS server_seq BIGINT/);
  assert.match(migrationSource, /CREATE SEQUENCE IF NOT EXISTS sync_event_seq/);
  assert.match(migrationSource, /seq BIGINT PRIMARY KEY DEFAULT nextval\('sync_event_seq'\)/);
  assert.match(source, /capture_live_sequence_state\s+\\?\s*message_server_seq_seq messages server_seq/);
  assert.match(source, /capture_live_sequence_state sync_event_seq sync_events seq/);
  assert.match(source, /sequence_validation_version=1/);
  assert.match(source, /message_server_seq_seq_last_value=\$message_sequence_last_value/);
  assert.match(source, /sync_event_seq_last_value=\$sync_sequence_last_value/);
});

test("ordinary deployment is fixed-SHA, migration-free, health-gated, and rollback-capable", () => {
  const source = read("deploy/deploy-server.sh");
  const publisher = read("deploy/publish-server.ps1");

  assert.match(source, /flock -n 9/, "deployments must be serialized");
  assert.match(source, /sha256sum -- "\$package"/, "the uploaded server-only package must be verified");
  assert.match(source, /RUN_MIGRATIONS: \"false\"/, "ordinary deployment must explicitly disable migrations");
  assert.doesNotMatch(source, /npm run migrate|scripts\/backup-production\.sh|scripts\/verify-backup\.sh/);
  assert.match(source, /schema_after[\s\S]*schema_before/, "schema drift must fail the deployment");
  assert.match(source, /function|rollback\(\)/, "a failed candidate must have an application rollback path");
  assert.match(source, /hoo66\.top[\s\S]*socket\.io/, "public HTTP and Socket.IO must be checked");
  assert.match(source, /install -m 0750[\s\S]*deploy-server/, "a successful release must update the installed entrypoint");

  assert.match(publisher, /git status --porcelain/, "the local publisher must reject a dirty worktree");
  assert.match(publisher, /origin\/main/, "only the exact pushed main commit may deploy");
  assert.match(publisher, /npm[\s\S]*run[\s\S]*check/, "validation must run exactly once before packaging");
  assert.match(publisher, /\$\{commitSha\}:server/, "the package must contain only the server subtree");
  assert.match(publisher, /Get-FileHash -Algorithm SHA256/, "the publisher must bind the package to a hash");
});
