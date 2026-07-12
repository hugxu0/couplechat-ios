import type { Pool } from "pg";

export interface SchemaMigration {
  version: number;
  name: string;
  sql: string;
}

// Published migration SQL is append-only. Existing versions must never be edited.
export const schemaMigrations: readonly SchemaMigration[] = [
  {
    version: 1,
    name: "initial_schema",
    sql: `
    CREATE TABLE IF NOT EXISTS accounts (
      username TEXT PRIMARY KEY,
      display_name TEXT NOT NULL,
      password_hash TEXT NOT NULL,
      avatar TEXT NOT NULL DEFAULT '',
      bark_key TEXT,
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS messages (
      id TEXT PRIMARY KEY,
      channel TEXT NOT NULL,
      sender TEXT NOT NULL,
      sender_name TEXT NOT NULL,
      kind TEXT NOT NULL,
      type TEXT NOT NULL,
      text TEXT NOT NULL DEFAULT '',
      url TEXT,
      reply_json TEXT,
      meta_json TEXT,
      ts BIGINT NOT NULL,
      client_id TEXT
    );

    CREATE UNIQUE INDEX IF NOT EXISTS messages_sender_client_id_idx
      ON messages(sender, client_id)
      WHERE client_id IS NOT NULL;
    CREATE INDEX IF NOT EXISTS messages_channel_ts_idx ON messages(channel, ts);

    CREATE TABLE IF NOT EXISTS read_receipts (
      channel TEXT NOT NULL,
      username TEXT NOT NULL,
      ts BIGINT NOT NULL,
      updated_at BIGINT NOT NULL
    );
    CREATE UNIQUE INDEX IF NOT EXISTS read_receipts_channel_user_idx
      ON read_receipts(channel, username);

    CREATE TABLE IF NOT EXISTS shared_items (
      key TEXT PRIMARY KEY,
      value_json TEXT NOT NULL,
      updated_by TEXT NOT NULL,
      updated_at BIGINT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS personal_items (
      id TEXT PRIMARY KEY,
      owner TEXT NOT NULL,
      kind TEXT NOT NULL,
      scope TEXT NOT NULL DEFAULT 'personal',
      title TEXT NOT NULL,
      body_markdown TEXT NOT NULL DEFAULT '',
      due_at BIGINT,
      is_done INTEGER NOT NULL DEFAULT 0,
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS personal_items_owner_kind_updated_idx
      ON personal_items(owner, kind, scope, updated_at DESC);
    CREATE INDEX IF NOT EXISTS personal_items_owner_due_idx
      ON personal_items(owner, due_at);

    CREATE TABLE IF NOT EXISTS uploads (
      id TEXT PRIMARY KEY,
      owner TEXT NOT NULL,
      path TEXT NOT NULL,
      url TEXT NOT NULL,
      mime_type TEXT NOT NULL,
      size BIGINT NOT NULL,
      created_at BIGINT NOT NULL
    );

    -- ── AI 记忆系统 ──────────────────────────────────────────────
    -- 长期事实库：一行 = 一条稳定事实，随行携带归一化 embedding，
    -- 问答时按话题向量召回。status: fresh（白天新提取）→ active（夜间收口转正）。
    CREATE TABLE IF NOT EXISTS ai_facts (
      id TEXT PRIMARY KEY,
      subject TEXT NOT NULL,
      category TEXT NOT NULL,
      text TEXT NOT NULL,
      importance INTEGER NOT NULL DEFAULT 3,
      status TEXT NOT NULL DEFAULT 'fresh',
      embedding BYTEA,
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL,
      last_seen_at BIGINT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS ai_facts_status_idx ON ai_facts(status);

    -- 事件卡片：每天把聊天按话题切成卡，独立向量化供语义召回
    CREATE TABLE IF NOT EXISTS ai_episodes (
      id TEXT PRIMARY KEY,
      channel TEXT NOT NULL,
      date TEXT NOT NULL,
      title TEXT NOT NULL,
      summary TEXT NOT NULL DEFAULT '',
      key_points_json TEXT,
      mood TEXT,
      conclusion TEXT,
      keywords TEXT,
      embedding BYTEA,
      created_at BIGINT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS ai_episodes_channel_date_idx ON ai_episodes(channel, date);

    -- AI 文档 KV：人物卡/关系卡/短期记忆/每日日记/心情/滚动摘要/任务完成标记
    CREATE TABLE IF NOT EXISTS ai_docs (
      key TEXT PRIMARY KEY,
      text TEXT NOT NULL,
      updated_at BIGINT NOT NULL
    );

    ALTER TABLE personal_items ADD COLUMN IF NOT EXISTS scope TEXT NOT NULL DEFAULT 'personal';
    `,
  },
  {
    version: 2,
    name: "bind_uploads_to_messages",
    sql: `
    ALTER TABLE uploads ADD COLUMN IF NOT EXISTS message_id TEXT;
    CREATE UNIQUE INDEX IF NOT EXISTS uploads_message_id_idx
      ON uploads(message_id)
      WHERE message_id IS NOT NULL;
    CREATE INDEX IF NOT EXISTS uploads_owner_created_at_idx
      ON uploads(owner, created_at);
    `,
  },
  {
    version: 3,
    name: "classify_upload_purpose",
    sql: `
    ALTER TABLE uploads ADD COLUMN IF NOT EXISTS purpose TEXT NOT NULL DEFAULT 'legacy';
    UPDATE uploads u
       SET message_id = (
         SELECT m.id FROM messages m WHERE m.url = u.url ORDER BY m.ts ASC LIMIT 1
       ), purpose = 'message'
     WHERE u.message_id IS NULL
       AND EXISTS (SELECT 1 FROM messages m WHERE m.url = u.url);
    CREATE INDEX IF NOT EXISTS uploads_cleanup_idx
      ON uploads(purpose, created_at)
      WHERE message_id IS NULL;
    `,
  },
  {
    version: 4,
    name: "preserve_recalled_text",
    sql: `
    ALTER TABLE messages ADD COLUMN IF NOT EXISTS recalled_text TEXT;
    `,
  },
  {
    version: 5,
    name: "message_attachments",
    sql: `
    DROP INDEX IF EXISTS uploads_message_id_idx;
    CREATE INDEX IF NOT EXISTS uploads_message_id_idx ON uploads(message_id)
      WHERE message_id IS NOT NULL;
    ALTER TABLE messages ADD COLUMN IF NOT EXISTS attachments_json TEXT;
    CREATE TABLE IF NOT EXISTS message_attachments (
      id TEXT PRIMARY KEY,
      message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
      upload_id TEXT NOT NULL UNIQUE REFERENCES uploads(id) ON DELETE CASCADE,
      asset_id TEXT NOT NULL,
      role TEXT NOT NULL,
      sort_order INTEGER NOT NULL
    );
    CREATE INDEX IF NOT EXISTS message_attachments_message_idx
      ON message_attachments(message_id, sort_order);
    `,
  },
  {
    version: 6,
    name: "memory_v2",
    sql: `
    CREATE TABLE IF NOT EXISTS ai_memory_v2 (
      id TEXT PRIMARY KEY,
      layer TEXT NOT NULL CHECK (layer IN ('fact','event','plan','state','relationship','insight')),
      scope TEXT NOT NULL,
      memory_key TEXT NOT NULL,
      subjects_json TEXT NOT NULL DEFAULT '[]',
      speakers_json TEXT NOT NULL DEFAULT '[]',
      content TEXT NOT NULL,
      category TEXT NOT NULL DEFAULT '',
      confidence DOUBLE PRECISION NOT NULL DEFAULT 0.5,
      importance INTEGER NOT NULL DEFAULT 3,
      occurred_at BIGINT,
      occurred_end_at BIGINT,
      valid_from BIGINT,
      valid_until BIGINT,
      status TEXT NOT NULL DEFAULT 'active',
      supersedes_id TEXT,
      metadata_json TEXT NOT NULL DEFAULT '{}',
      embedding BYTEA,
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS ai_memory_v2_layer_scope_status_idx
      ON ai_memory_v2(layer, scope, status, updated_at DESC);
    CREATE INDEX IF NOT EXISTS ai_memory_v2_key_idx
      ON ai_memory_v2(scope, layer, memory_key, status);
    CREATE INDEX IF NOT EXISTS ai_memory_v2_time_idx
      ON ai_memory_v2(scope, occurred_at DESC);

    CREATE TABLE IF NOT EXISTS ai_memory_evidence_v2 (
      memory_id TEXT NOT NULL REFERENCES ai_memory_v2(id) ON DELETE CASCADE,
      message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
      channel TEXT NOT NULL,
      sender TEXT NOT NULL,
      message_ts BIGINT NOT NULL,
      excerpt TEXT NOT NULL DEFAULT '',
      evidence_role TEXT NOT NULL DEFAULT 'support',
      created_at BIGINT NOT NULL,
      PRIMARY KEY(memory_id, message_id)
    );
    CREATE INDEX IF NOT EXISTS ai_memory_evidence_v2_message_idx
      ON ai_memory_evidence_v2(message_id);

    CREATE TABLE IF NOT EXISTS ai_memory_cursor_v2 (
      channel TEXT PRIMARY KEY,
      cursor_ts BIGINT NOT NULL,
      initialized_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL
    );
    `,
  },
  {
    version: 7,
    name: "canonical_memory_names",
    sql: `
    ALTER TABLE ai_memory_v2 RENAME TO ai_memory;
    ALTER TABLE ai_memory_evidence_v2 RENAME TO ai_memory_evidence;
    ALTER TABLE ai_memory_cursor_v2 RENAME TO ai_memory_cursor;
    ALTER INDEX ai_memory_v2_layer_scope_status_idx RENAME TO ai_memory_layer_scope_status_idx;
    ALTER INDEX ai_memory_v2_key_idx RENAME TO ai_memory_key_idx;
    ALTER INDEX ai_memory_v2_time_idx RENAME TO ai_memory_time_idx;
    ALTER INDEX ai_memory_evidence_v2_message_idx RENAME TO ai_memory_evidence_message_idx;
    CREATE TABLE IF NOT EXISTS ai_runtime_state (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL,
      updated_at BIGINT NOT NULL
    );
    `,
  },
  {
    version: 8,
    name: "ensure_ai_runtime_state",
    sql: `
    CREATE TABLE IF NOT EXISTS ai_runtime_state (
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL,
      updated_at BIGINT NOT NULL
    );
    `,
  },
  {
    version: 9,
    name: "memory_import_staging",
    sql: `
    CREATE TABLE IF NOT EXISTS ai_memory_import_runs (
      id TEXT PRIMARY KEY,
      source TEXT NOT NULL,
      model TEXT NOT NULL,
      status TEXT NOT NULL,
      options_json TEXT NOT NULL DEFAULT '{}',
      processed_count INTEGER NOT NULL DEFAULT 0,
      candidate_count INTEGER NOT NULL DEFAULT 0,
      error_count INTEGER NOT NULL DEFAULT 0,
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL,
      finished_at BIGINT
    );

    CREATE TABLE IF NOT EXISTS ai_memory_import_candidates (
      id TEXT PRIMARY KEY,
      run_id TEXT NOT NULL REFERENCES ai_memory_import_runs(id) ON DELETE CASCADE,
      source_table TEXT NOT NULL,
      source_id TEXT NOT NULL,
      source_hash TEXT NOT NULL,
      layer TEXT NOT NULL CHECK (layer IN ('fact','event','plan','state','relationship','insight')),
      scope TEXT NOT NULL,
      memory_key TEXT NOT NULL,
      subjects_json TEXT NOT NULL DEFAULT '[]',
      speakers_json TEXT NOT NULL DEFAULT '[]',
      content TEXT NOT NULL,
      category TEXT NOT NULL DEFAULT '',
      confidence DOUBLE PRECISION NOT NULL DEFAULT 0.5,
      importance INTEGER NOT NULL DEFAULT 3,
      occurred_at BIGINT,
      occurred_end_at BIGINT,
      valid_from BIGINT,
      valid_until BIGINT,
      status TEXT NOT NULL,
      review_reason TEXT NOT NULL DEFAULT '',
      model_output_json TEXT NOT NULL DEFAULT '{}',
      published_memory_id TEXT,
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL,
      UNIQUE(source_table, source_id, source_hash)
    );
    CREATE INDEX IF NOT EXISTS ai_memory_import_candidates_status_idx
      ON ai_memory_import_candidates(status, source_table, updated_at DESC);

    CREATE TABLE IF NOT EXISTS ai_memory_import_evidence (
      candidate_id TEXT NOT NULL REFERENCES ai_memory_import_candidates(id) ON DELETE CASCADE,
      message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
      evidence_role TEXT NOT NULL DEFAULT 'support',
      created_at BIGINT NOT NULL,
      PRIMARY KEY(candidate_id, message_id)
    );
    `,
  },
  {
    version: 10,
    name: "memory_cursor_tie_breaker",
    sql: `
    ALTER TABLE ai_memory_cursor ADD COLUMN IF NOT EXISTS cursor_id TEXT NOT NULL DEFAULT '';
    CREATE INDEX IF NOT EXISTS messages_channel_ts_id_idx ON messages(channel, ts, id);
    `,
  },
];

export async function migrate(database: Pool): Promise<void> {
  await database.query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      version INTEGER PRIMARY KEY,
      name TEXT NOT NULL,
      applied_at BIGINT NOT NULL
    );
  `);

  const appliedResult = await database.query<{ version: number }>("SELECT version FROM schema_migrations");
  const appliedVersions = new Set(appliedResult.rows.map((row) => row.version));

  for (const migration of schemaMigrations) {
    if (appliedVersions.has(migration.version)) continue;
    const client = await database.connect();
    try {
      await client.query("BEGIN");
      await client.query(migration.sql);
      await client.query(
        "INSERT INTO schema_migrations (version, name, applied_at) VALUES ($1, $2, $3)",
        [migration.version, migration.name, Date.now()],
      );
      await client.query("COMMIT");
      console.info(`[db] 已应用迁移 v${migration.version}: ${migration.name}`);
    } catch (error) {
      await client.query("ROLLBACK").catch(() => undefined);
      throw new Error(
        `[db] 迁移 v${migration.version} (${migration.name}) 失败: ${error instanceof Error ? error.message : String(error)}`,
      );
    } finally {
      client.release();
    }
  }
}
