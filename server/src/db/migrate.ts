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
  {
    version: 11,
    name: "hard_delete_recalled_messages",
    sql: `
    -- v10 及更早的撤回实现把原消息改写为 system tombstone。媒体消息的
    -- recalled_text 为 NULL，因此不能只依赖该列。下面的形态来自历史实现；
    -- sender='system' 的真正系统消息不会进入候选。
    CREATE TEMP TABLE recalled_message_candidates ON COMMIT DROP AS
    SELECT message.id
      FROM messages message
      JOIN accounts account ON account.username = message.sender
     WHERE message.kind = 'system'
       AND message.type = 'text'
       AND message.text = '你撤回了一条消息'
       AND message.sender <> 'system'
       AND message.url IS NULL
       AND message.reply_json IS NULL
       AND message.meta_json IS NULL
       AND message.attachments_json IS NULL;

    -- 历史数据库可能含第三方客户端写入的非法 JSON。逐行容错，不能让一条
    -- 脏 reply_json 阻断整次 destructive migration。
    DO $$
    DECLARE reply_row RECORD;
    BEGIN
      FOR reply_row IN SELECT id, reply_json FROM messages WHERE reply_json IS NOT NULL LOOP
        BEGIN
          IF EXISTS (
            SELECT 1 FROM recalled_message_candidates candidate
             WHERE candidate.id = reply_row.reply_json::jsonb ->> 'id'
          ) THEN
            UPDATE messages SET reply_json = NULL WHERE id = reply_row.id;
          END IF;
        EXCEPTION WHEN invalid_text_representation THEN
          NULL;
        END;
      END LOOP;
    END $$;

    CREATE TABLE IF NOT EXISTS file_cleanup_queue (
      id TEXT PRIMARY KEY,
      path TEXT NOT NULL,
      reason TEXT NOT NULL,
      created_at BIGINT NOT NULL,
      attempt_count INTEGER NOT NULL DEFAULT 0,
      last_error TEXT,
      completed_at BIGINT
    );
    CREATE INDEX IF NOT EXISTS file_cleanup_queue_pending_idx
      ON file_cleanup_queue(created_at) WHERE completed_at IS NULL;

    CREATE TABLE IF NOT EXISTS legacy_message_deletions (
      message_id TEXT PRIMARY KEY,
      stored_channel TEXT NOT NULL,
      deleted_by TEXT NOT NULL,
      deleted_at BIGINT NOT NULL
    );
    INSERT INTO legacy_message_deletions (message_id, stored_channel, deleted_by, deleted_at)
    SELECT message.id, message.channel, message.sender,
           (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT
      FROM messages message
      JOIN recalled_message_candidates candidate ON candidate.id = message.id
    ON CONFLICT(message_id) DO NOTHING;

    INSERT INTO file_cleanup_queue (id, path, reason, created_at)
    SELECT 'cleanup_' || upload.id, upload.path, 'legacy_recalled_message',
           (EXTRACT(EPOCH FROM clock_timestamp()) * 1000)::BIGINT
      FROM uploads upload
      JOIN recalled_message_candidates candidate ON candidate.id = upload.message_id
    ON CONFLICT(id) DO NOTHING;

    DELETE FROM ai_memory_import_candidates candidate
     WHERE EXISTS (
       SELECT 1 FROM ai_memory_import_evidence evidence
       JOIN recalled_message_candidates recalled ON recalled.id = evidence.message_id
       WHERE evidence.candidate_id = candidate.id
     );

    DELETE FROM ai_memory memory
     WHERE EXISTS (
       SELECT 1 FROM ai_memory_evidence evidence
       JOIN recalled_message_candidates recalled ON recalled.id = evidence.message_id
       WHERE evidence.memory_id = memory.id
     )
       AND NOT EXISTS (
         SELECT 1 FROM ai_memory_evidence evidence
         JOIN messages source ON source.id = evidence.message_id
         WHERE evidence.memory_id = memory.id
           AND evidence.evidence_role = 'support'
           AND source.kind = 'user'
           AND source.sender <> 'ai'
       );

    DELETE FROM uploads upload
     USING recalled_message_candidates candidate
     WHERE upload.message_id = candidate.id;

    DELETE FROM messages message
     USING recalled_message_candidates candidate
     WHERE message.id = candidate.id;
    `,
  },
  {
    version: 12,
    name: "durable_reminder_bark_delivery",
    sql: `
    CREATE TABLE IF NOT EXISTS reminder_bark_deliveries (
      reminder_id TEXT NOT NULL REFERENCES personal_items(id) ON DELETE CASCADE,
      due_at BIGINT NOT NULL,
      recipient TEXT NOT NULL,
      endpoint_key TEXT NOT NULL DEFAULT 'legacy',
      status TEXT NOT NULL CHECK (status IN ('sending', 'failed', 'delivered')),
      attempt_count INTEGER NOT NULL DEFAULT 0,
      claim_token TEXT,
      lease_until BIGINT,
      next_attempt_at BIGINT,
      last_error TEXT,
      delivered_at BIGINT,
      updated_at BIGINT NOT NULL,
      PRIMARY KEY(reminder_id, due_at, recipient, endpoint_key)
    );
    CREATE INDEX IF NOT EXISTS reminder_bark_deliveries_status_idx
      ON reminder_bark_deliveries(status, next_attempt_at, lease_until);
    `,
  },
  {
    version: 13,
    name: "identity_v2_expand",
    sql: `
    ALTER TABLE accounts ADD COLUMN IF NOT EXISTS id TEXT;
    ALTER TABLE accounts ADD COLUMN IF NOT EXISTS status TEXT NOT NULL DEFAULT 'active';
    ALTER TABLE accounts ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 0;
    UPDATE accounts SET id = 'acc_legacy_' || username WHERE id IS NULL;
    ALTER TABLE accounts ALTER COLUMN id SET NOT NULL;
    CREATE UNIQUE INDEX IF NOT EXISTS accounts_id_idx ON accounts(id);

    CREATE TABLE IF NOT EXISTS couples (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL DEFAULT '',
      status TEXT NOT NULL CHECK (status IN ('active', 'dissolved')),
      created_by_account_id TEXT NOT NULL REFERENCES accounts(id),
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL,
      version BIGINT NOT NULL DEFAULT 0
    );

    CREATE TABLE IF NOT EXISTS couple_members (
      id TEXT PRIMARY KEY,
      couple_id TEXT NOT NULL REFERENCES couples(id) ON DELETE CASCADE,
      account_id TEXT NOT NULL REFERENCES accounts(id),
      role TEXT NOT NULL CHECK (role IN ('owner', 'member')),
      state TEXT NOT NULL CHECK (state IN ('active', 'left')),
      joined_at BIGINT NOT NULL,
      left_at BIGINT,
      updated_at BIGINT NOT NULL,
      UNIQUE(couple_id, account_id)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS couple_members_one_active_idx
      ON couple_members(account_id) WHERE state = 'active';
    CREATE INDEX IF NOT EXISTS couple_members_couple_state_idx
      ON couple_members(couple_id, state);

    CREATE TABLE IF NOT EXISTS couple_invites (
      id TEXT PRIMARY KEY,
      couple_id TEXT NOT NULL REFERENCES couples(id) ON DELETE CASCADE,
      code_hash TEXT NOT NULL UNIQUE,
      created_by_member_id TEXT NOT NULL REFERENCES couple_members(id),
      expires_at BIGINT NOT NULL,
      used_at BIGINT,
      used_by_account_id TEXT REFERENCES accounts(id),
      revoked_at BIGINT,
      created_at BIGINT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS couple_invites_active_idx
      ON couple_invites(couple_id, expires_at) WHERE used_at IS NULL AND revoked_at IS NULL;

    INSERT INTO couples
      (id, name, status, created_by_account_id, created_at, updated_at, version)
    SELECT 'cpl_legacy_xusi', '小旭和小偲', 'active', xu.id,
           LEAST(xu.created_at, si.created_at), GREATEST(xu.updated_at, si.updated_at), 0
      FROM accounts xu CROSS JOIN accounts si
     WHERE xu.username = 'xu' AND si.username = 'si'
    ON CONFLICT(id) DO NOTHING;

    INSERT INTO couple_members
      (id, couple_id, account_id, role, state, joined_at, updated_at)
    SELECT 'mem_legacy_xu', 'cpl_legacy_xusi', account.id, 'owner', 'active', account.created_at, account.updated_at
      FROM accounts account
     WHERE account.username = 'xu' AND EXISTS (SELECT 1 FROM couples WHERE id = 'cpl_legacy_xusi')
    ON CONFLICT(id) DO NOTHING;

    INSERT INTO couple_members
      (id, couple_id, account_id, role, state, joined_at, updated_at)
    SELECT 'mem_legacy_si', 'cpl_legacy_xusi', account.id, 'member', 'active', account.created_at, account.updated_at
      FROM accounts account
     WHERE account.username = 'si' AND EXISTS (SELECT 1 FROM couples WHERE id = 'cpl_legacy_xusi')
    ON CONFLICT(id) DO NOTHING;
    `,
  },
  {
    version: 14,
    name: "devices_sessions_push",
    sql: `
    CREATE TABLE IF NOT EXISTS devices (
      id TEXT PRIMARY KEY,
      account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
      installation_id TEXT NOT NULL,
      platform TEXT NOT NULL CHECK (platform IN ('ios', 'ipados', 'legacy')),
      device_name TEXT NOT NULL DEFAULT '',
      app_version TEXT NOT NULL DEFAULT '',
      build_number TEXT NOT NULL DEFAULT '',
      protocol_version INTEGER NOT NULL DEFAULT 1,
      locale TEXT NOT NULL DEFAULT '',
      timezone TEXT NOT NULL DEFAULT '',
      last_seen_at BIGINT NOT NULL,
      revoked_at BIGINT,
      created_at BIGINT NOT NULL,
      UNIQUE(account_id, installation_id)
    );
    CREATE INDEX IF NOT EXISTS devices_account_active_idx
      ON devices(account_id, last_seen_at DESC) WHERE revoked_at IS NULL;

    CREATE TABLE IF NOT EXISTS auth_sessions (
      id TEXT PRIMARY KEY,
      account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
      device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
      refresh_token_hash TEXT NOT NULL,
      token_version INTEGER NOT NULL DEFAULT 1,
      created_at BIGINT NOT NULL,
      last_seen_at BIGINT NOT NULL,
      expires_at BIGINT NOT NULL,
      revoked_at BIGINT
    );
    CREATE INDEX IF NOT EXISTS auth_sessions_device_active_idx
      ON auth_sessions(device_id, expires_at DESC) WHERE revoked_at IS NULL;

    CREATE TABLE IF NOT EXISTS device_push_endpoints (
      id TEXT PRIMARY KEY,
      device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
      provider TEXT NOT NULL CHECK (provider IN ('bark')),
      secret_value TEXT NOT NULL,
      endpoint_fingerprint TEXT NOT NULL,
      enabled BOOLEAN NOT NULL DEFAULT TRUE,
      failure_count INTEGER NOT NULL DEFAULT 0,
      last_success_at BIGINT,
      disabled_at BIGINT,
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL,
      UNIQUE(device_id, provider)
    );
    CREATE INDEX IF NOT EXISTS device_push_endpoints_device_idx
      ON device_push_endpoints(device_id, enabled);

    INSERT INTO devices
      (id, account_id, installation_id, platform, device_name, protocol_version,
       last_seen_at, created_at)
    SELECT 'dev_legacy_' || account.username, account.id, 'legacy:' || account.username,
           'legacy', 'Legacy Bark', 1, account.updated_at, account.created_at
      FROM accounts account
     WHERE account.bark_key IS NOT NULL
    ON CONFLICT(account_id, installation_id) DO NOTHING;

    INSERT INTO device_push_endpoints
      (id, device_id, provider, secret_value, endpoint_fingerprint, enabled,
       created_at, updated_at)
    SELECT 'push_legacy_' || account.username, device.id, 'bark', account.bark_key,
           md5(account.bark_key), TRUE, account.created_at, account.updated_at
      FROM accounts account
      JOIN devices device ON device.account_id = account.id
                         AND device.installation_id = 'legacy:' || account.username
     WHERE account.bark_key IS NOT NULL
    ON CONFLICT(device_id, provider) DO UPDATE SET
      secret_value = excluded.secret_value,
      endpoint_fingerprint = excluded.endpoint_fingerprint,
      enabled = TRUE,
      disabled_at = NULL,
      updated_at = excluded.updated_at;
    `,
  },
  {
    version: 15,
    name: "reminder_delivery_per_endpoint",
    sql: `
    -- v12-v15 会在同一个受锁 migrator 中连续执行；下面仍兼容有人曾单独
    -- 运行过早期候选 v12 的数据库，避免已送达提醒在切换 endpoint 后重发。
    UPDATE device_push_endpoints
       SET endpoint_fingerprint = md5(secret_value);

    UPDATE reminder_bark_deliveries delivery
       SET endpoint_key = endpoint.endpoint_fingerprint
      FROM device_push_endpoints endpoint
     WHERE delivery.endpoint_key = endpoint.id;

    UPDATE reminder_bark_deliveries delivery
       SET endpoint_key = md5(account.bark_key)
      FROM accounts account
     WHERE delivery.recipient = account.username
       AND delivery.endpoint_key = 'legacy'
       AND account.bark_key IS NOT NULL;
    `,
  },
  {
    version: 16,
    name: "conversations_and_ownership",
    sql: `
    CREATE TABLE IF NOT EXISTS conversations (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL CHECK (kind IN ('couple', 'ai')),
      couple_id TEXT REFERENCES couples(id) ON DELETE CASCADE,
      owner_account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
      created_at BIGINT NOT NULL,
      archived_at BIGINT,
      CHECK (
        (kind = 'couple' AND couple_id IS NOT NULL AND owner_account_id IS NULL)
        OR (kind = 'ai' AND couple_id IS NULL AND owner_account_id IS NOT NULL)
      )
    );
    CREATE UNIQUE INDEX IF NOT EXISTS conversations_active_couple_idx
      ON conversations(couple_id) WHERE kind = 'couple' AND archived_at IS NULL;
    CREATE UNIQUE INDEX IF NOT EXISTS conversations_active_ai_idx
      ON conversations(owner_account_id) WHERE kind = 'ai' AND archived_at IS NULL;

    INSERT INTO conversations (id, kind, couple_id, created_at)
    SELECT CASE WHEN couple.id = 'cpl_legacy_xusi' THEN 'conv_legacy_couple'
                ELSE 'conv_couple_' || couple.id END,
           'couple', couple.id, couple.created_at
      FROM couples couple
    ON CONFLICT(id) DO NOTHING;

    INSERT INTO conversations (id, kind, owner_account_id, created_at)
    SELECT CASE account.username
             WHEN 'xu' THEN 'conv_legacy_ai_xu'
             WHEN 'si' THEN 'conv_legacy_ai_si'
             ELSE 'conv_ai_' || account.id
           END,
           'ai', account.id, account.created_at
      FROM accounts account
    ON CONFLICT(id) DO NOTHING;

    CREATE SEQUENCE IF NOT EXISTS message_server_seq_seq;
    ALTER TABLE messages ADD COLUMN IF NOT EXISTS conversation_id TEXT REFERENCES conversations(id);
    ALTER TABLE messages ADD COLUMN IF NOT EXISTS sender_account_id TEXT REFERENCES accounts(id);
    ALTER TABLE messages ADD COLUMN IF NOT EXISTS origin_device_id TEXT REFERENCES devices(id);
    ALTER TABLE messages ADD COLUMN IF NOT EXISTS server_seq BIGINT;

    UPDATE messages message
       SET conversation_id = conversation.id
      FROM conversations conversation
     WHERE message.conversation_id IS NULL
       AND message.channel = 'couple'
       AND conversation.kind = 'couple'
       AND conversation.couple_id = 'cpl_legacy_xusi';

    UPDATE messages message
       SET conversation_id = conversation.id
      FROM accounts account
      JOIN conversations conversation ON conversation.owner_account_id = account.id
     WHERE message.conversation_id IS NULL
       AND message.channel = 'ai:' || account.username
       AND conversation.kind = 'ai';

    UPDATE messages message
       SET sender_account_id = account.id
      FROM accounts account
     WHERE message.sender_account_id IS NULL AND message.sender = account.username;
    UPDATE messages SET server_seq = nextval('message_server_seq_seq') WHERE server_seq IS NULL;
    ALTER TABLE messages ALTER COLUMN server_seq SET DEFAULT nextval('message_server_seq_seq');
    CREATE UNIQUE INDEX IF NOT EXISTS messages_conversation_server_seq_idx
      ON messages(conversation_id, server_seq) WHERE conversation_id IS NOT NULL;
    CREATE INDEX IF NOT EXISTS messages_conversation_ts_id_idx
      ON messages(conversation_id, ts, id) WHERE conversation_id IS NOT NULL;
    CREATE UNIQUE INDEX IF NOT EXISTS messages_v2_idempotency_idx
      ON messages(conversation_id, sender_account_id, origin_device_id, client_id)
      WHERE conversation_id IS NOT NULL AND sender_account_id IS NOT NULL
        AND origin_device_id IS NOT NULL AND client_id IS NOT NULL;

    CREATE TABLE IF NOT EXISTS conversation_reads (
      conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
      account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
      last_read_message_id TEXT,
      last_read_server_seq BIGINT NOT NULL DEFAULT 0,
      updated_by_device_id TEXT REFERENCES devices(id),
      updated_at BIGINT NOT NULL,
      PRIMARY KEY(conversation_id, account_id)
    );
    INSERT INTO conversation_reads
      (conversation_id, account_id, last_read_message_id, last_read_server_seq, updated_at)
    SELECT conversation.id, account.id,
           (SELECT candidate.id FROM messages candidate
             WHERE candidate.conversation_id = conversation.id AND candidate.ts <= receipt.ts
             ORDER BY candidate.ts DESC, candidate.id DESC LIMIT 1),
           COALESCE((SELECT MAX(candidate.server_seq) FROM messages candidate
             WHERE candidate.conversation_id = conversation.id AND candidate.ts <= receipt.ts), 0),
           receipt.updated_at
      FROM read_receipts receipt
      JOIN accounts account ON account.username = receipt.username
      JOIN conversations conversation
        ON (receipt.channel = 'couple' AND conversation.couple_id = 'cpl_legacy_xusi')
        OR (receipt.channel = 'ai:' || account.username AND conversation.owner_account_id = account.id)
    ON CONFLICT(conversation_id, account_id) DO UPDATE SET
      last_read_message_id = excluded.last_read_message_id,
      last_read_server_seq = GREATEST(conversation_reads.last_read_server_seq, excluded.last_read_server_seq),
      updated_at = GREATEST(conversation_reads.updated_at, excluded.updated_at);

    ALTER TABLE personal_items ADD COLUMN IF NOT EXISTS owner_account_id TEXT REFERENCES accounts(id);
    ALTER TABLE personal_items ADD COLUMN IF NOT EXISTS couple_id TEXT REFERENCES couples(id);
    ALTER TABLE personal_items ADD COLUMN IF NOT EXISTS created_by_account_id TEXT REFERENCES accounts(id);
    ALTER TABLE personal_items ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 0;
    ALTER TABLE personal_items ADD COLUMN IF NOT EXISTS deleted_at BIGINT;
    UPDATE personal_items item SET owner_account_id = account.id, created_by_account_id = account.id
      FROM accounts account WHERE item.owner = account.username;
    UPDATE personal_items item SET couple_id = member.couple_id, owner_account_id = NULL
      FROM accounts account
      JOIN couple_members member ON member.account_id = account.id AND member.state = 'active'
     WHERE item.owner = account.username AND item.scope = 'shared';
    CREATE INDEX IF NOT EXISTS personal_items_couple_kind_idx
      ON personal_items(couple_id, kind, updated_at DESC) WHERE deleted_at IS NULL;
    CREATE INDEX IF NOT EXISTS personal_items_account_kind_idx
      ON personal_items(owner_account_id, kind, updated_at DESC) WHERE deleted_at IS NULL;

    ALTER TABLE uploads ADD COLUMN IF NOT EXISTS created_by_account_id TEXT REFERENCES accounts(id);
    ALTER TABLE uploads ADD COLUMN IF NOT EXISTS couple_id TEXT REFERENCES couples(id);
    ALTER TABLE uploads ADD COLUMN IF NOT EXISTS access_scope TEXT NOT NULL DEFAULT 'personal';
    UPDATE uploads upload SET created_by_account_id = account.id
      FROM accounts account WHERE upload.owner = account.username;
    UPDATE uploads upload SET couple_id = conversation.couple_id, access_scope = 'couple'
      FROM messages message
      JOIN conversations conversation ON conversation.id = message.conversation_id
     WHERE upload.message_id = message.id AND conversation.kind = 'couple';
    `,
  },
  {
    version: 17,
    name: "sync_v2_core",
    sql: `
    CREATE SEQUENCE IF NOT EXISTS sync_event_seq;
    CREATE TABLE IF NOT EXISTS sync_events (
      seq BIGINT PRIMARY KEY DEFAULT nextval('sync_event_seq'),
      couple_id TEXT REFERENCES couples(id) ON DELETE CASCADE,
      account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
      entity_type TEXT NOT NULL,
      entity_id TEXT NOT NULL,
      operation TEXT NOT NULL CHECK (operation IN ('upsert', 'delete')),
      entity_version BIGINT NOT NULL,
      payload_json TEXT NOT NULL,
      actor_account_id TEXT REFERENCES accounts(id),
      actor_device_id TEXT REFERENCES devices(id),
      mutation_id TEXT,
      created_at BIGINT NOT NULL,
      CHECK ((couple_id IS NOT NULL AND account_id IS NULL)
          OR (couple_id IS NULL AND account_id IS NOT NULL))
    );
    CREATE INDEX IF NOT EXISTS sync_events_couple_seq_idx ON sync_events(couple_id, seq);
    CREATE INDEX IF NOT EXISTS sync_events_account_seq_idx ON sync_events(account_id, seq);
    CREATE INDEX IF NOT EXISTS sync_events_entity_idx ON sync_events(entity_type, entity_id, seq DESC);

    CREATE TABLE IF NOT EXISTS client_mutations (
      account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
      device_id TEXT NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
      mutation_id TEXT NOT NULL,
      response_json TEXT NOT NULL,
      event_seq BIGINT,
      created_at BIGINT NOT NULL,
      PRIMARY KEY(account_id, device_id, mutation_id)
    );
    CREATE TABLE IF NOT EXISTS device_sync_cursors (
      device_id TEXT PRIMARY KEY REFERENCES devices(id) ON DELETE CASCADE,
      last_ack_seq BIGINT NOT NULL DEFAULT 0,
      updated_at BIGINT NOT NULL
    );

    WITH legacy AS (
      SELECT deletion.*,
             CASE WHEN deletion.stored_channel = 'couple' THEN couple.id END AS couple_id,
             CASE WHEN deletion.stored_channel LIKE 'ai:%' THEN account.id END AS account_id,
             actor.id AS actor_account_id,
             nextval('sync_event_seq') AS allocated_seq
        FROM legacy_message_deletions deletion
        LEFT JOIN couples couple ON couple.id = 'cpl_legacy_xusi'
        LEFT JOIN accounts account ON deletion.stored_channel = 'ai:' || account.username
        LEFT JOIN accounts actor ON actor.username = deletion.deleted_by
    )
    INSERT INTO sync_events
      (seq, couple_id, account_id, entity_type, entity_id, operation, entity_version,
       payload_json, actor_account_id, created_at)
    SELECT allocated_seq, couple_id, account_id, 'message', message_id, 'delete', allocated_seq,
           json_build_object('id', message_id,
             'channel', CASE WHEN stored_channel LIKE 'ai:%' THEN 'ai' ELSE 'couple' END)::TEXT,
           actor_account_id, deleted_at
      FROM legacy
     WHERE couple_id IS NOT NULL OR account_id IS NOT NULL
    ON CONFLICT(seq) DO NOTHING;
    `,
  },
  {
    version: 18,
    name: "tenant_memory_and_settings",
    sql: `
    CREATE TABLE IF NOT EXISTS couple_settings (
      couple_id TEXT NOT NULL REFERENCES couples(id) ON DELETE CASCADE,
      key TEXT NOT NULL,
      value_json TEXT NOT NULL,
      updated_by_account_id TEXT REFERENCES accounts(id),
      updated_by_username TEXT NOT NULL,
      updated_at BIGINT NOT NULL,
      version BIGINT NOT NULL DEFAULT 0,
      PRIMARY KEY(couple_id, key)
    );
    INSERT INTO couple_settings
      (couple_id, key, value_json, updated_by_account_id, updated_by_username, updated_at, version)
    SELECT 'cpl_legacy_xusi', item.key, item.value_json, account.id, item.updated_by,
           item.updated_at, 0
      FROM shared_items item
      LEFT JOIN accounts account ON account.username = item.updated_by
     WHERE EXISTS (SELECT 1 FROM couples WHERE id = 'cpl_legacy_xusi')
    ON CONFLICT(couple_id, key) DO NOTHING;

    ALTER TABLE ai_memory ADD COLUMN IF NOT EXISTS couple_id TEXT REFERENCES couples(id);
    ALTER TABLE ai_memory ADD COLUMN IF NOT EXISTS owner_account_id TEXT REFERENCES accounts(id);
    ALTER TABLE ai_memory ADD COLUMN IF NOT EXISTS version BIGINT NOT NULL DEFAULT 0;
    UPDATE ai_memory SET couple_id = 'cpl_legacy_xusi'
     WHERE scope = 'couple' AND couple_id IS NULL
       AND EXISTS (SELECT 1 FROM couples WHERE id = 'cpl_legacy_xusi');
    UPDATE ai_memory memory SET owner_account_id = account.id
      FROM accounts account
     WHERE memory.scope = 'ai:' || account.username AND memory.owner_account_id IS NULL;
    CREATE INDEX IF NOT EXISTS ai_memory_couple_control_idx
      ON ai_memory(couple_id, status, updated_at DESC, id DESC);
    CREATE INDEX IF NOT EXISTS ai_memory_account_control_idx
      ON ai_memory(owner_account_id, status, updated_at DESC, id DESC);

    CREATE TABLE IF NOT EXISTS ai_memory_exclusions (
      id TEXT PRIMARY KEY,
      couple_id TEXT REFERENCES couples(id) ON DELETE CASCADE,
      account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
      memory_key TEXT NOT NULL,
      source_message_id TEXT,
      created_by_account_id TEXT NOT NULL REFERENCES accounts(id),
      created_at BIGINT NOT NULL,
      CHECK ((couple_id IS NOT NULL AND account_id IS NULL)
          OR (couple_id IS NULL AND account_id IS NOT NULL)),
      UNIQUE(couple_id, account_id, memory_key, source_message_id)
    );
    CREATE UNIQUE INDEX IF NOT EXISTS ai_memory_exclusions_identity_idx
      ON ai_memory_exclusions(
        COALESCE(couple_id, ''), COALESCE(account_id, ''), memory_key,
        COALESCE(source_message_id, '')
      );
    `,
  },
  {
    version: 19,
    name: "voice_transcription",
    sql: `
    CREATE TABLE IF NOT EXISTS message_transcripts (
      message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
      conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
      couple_id TEXT REFERENCES couples(id) ON DELETE CASCADE,
      owner_account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
      status TEXT NOT NULL CHECK (status IN ('pending', 'processing', 'completed', 'failed', 'unavailable')),
      provider TEXT,
      language TEXT,
      text TEXT NOT NULL DEFAULT '',
      corrected_text TEXT,
      corrected_by_account_id TEXT REFERENCES accounts(id),
      corrected_at BIGINT,
      last_error TEXT,
      version BIGINT NOT NULL DEFAULT 0,
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL,
      CHECK ((couple_id IS NOT NULL AND owner_account_id IS NULL)
          OR (couple_id IS NULL AND owner_account_id IS NOT NULL))
    );
    CREATE INDEX IF NOT EXISTS message_transcripts_couple_status_idx
      ON message_transcripts(couple_id, status, updated_at DESC);
    CREATE INDEX IF NOT EXISTS message_transcripts_account_status_idx
      ON message_transcripts(owner_account_id, status, updated_at DESC);

    CREATE TABLE IF NOT EXISTS transcript_jobs (
      id TEXT PRIMARY KEY,
      message_id TEXT NOT NULL UNIQUE REFERENCES messages(id) ON DELETE CASCADE,
      status TEXT NOT NULL CHECK (status IN ('queued', 'processing', 'failed', 'completed', 'unavailable')),
      provider TEXT,
      attempt_count INTEGER NOT NULL DEFAULT 0,
      available_at BIGINT NOT NULL,
      lease_until BIGINT,
      last_error TEXT,
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL,
      completed_at BIGINT
    );
    CREATE INDEX IF NOT EXISTS transcript_jobs_ready_idx
      ON transcript_jobs(status, available_at, lease_until);
    `,
  },
  {
    version: 20,
    name: "shared_albums",
    sql: `
    CREATE TABLE IF NOT EXISTS media_assets (
      id TEXT PRIMARY KEY,
      couple_id TEXT NOT NULL REFERENCES couples(id) ON DELETE CASCADE,
      source_upload_id TEXT NOT NULL REFERENCES uploads(id) ON DELETE CASCADE,
      source_message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
      created_by_account_id TEXT NOT NULL REFERENCES accounts(id),
      kind TEXT NOT NULL CHECK (kind IN ('image', 'video', 'audio', 'file')),
      mime_type TEXT NOT NULL,
      url TEXT NOT NULL,
      size BIGINT NOT NULL,
      taken_at BIGINT NOT NULL,
      created_at BIGINT NOT NULL,
      version BIGINT NOT NULL DEFAULT 0,
      UNIQUE(couple_id, source_upload_id)
    );
    CREATE INDEX IF NOT EXISTS media_assets_couple_taken_idx
      ON media_assets(couple_id, taken_at DESC, id DESC);

    CREATE TABLE IF NOT EXISTS albums (
      id TEXT PRIMARY KEY,
      couple_id TEXT NOT NULL REFERENCES couples(id) ON DELETE CASCADE,
      title TEXT NOT NULL,
      summary TEXT NOT NULL DEFAULT '',
      cover_asset_id TEXT REFERENCES media_assets(id) ON DELETE SET NULL,
      created_by_account_id TEXT NOT NULL REFERENCES accounts(id),
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL,
      version BIGINT NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS albums_couple_updated_idx
      ON albums(couple_id, updated_at DESC, id DESC);

    CREATE TABLE IF NOT EXISTS album_items (
      id TEXT PRIMARY KEY,
      album_id TEXT NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
      asset_id TEXT NOT NULL REFERENCES media_assets(id) ON DELETE CASCADE,
      added_by_account_id TEXT NOT NULL REFERENCES accounts(id),
      added_at BIGINT NOT NULL,
      sort_order BIGINT NOT NULL,
      UNIQUE(album_id, asset_id)
    );
    CREATE INDEX IF NOT EXISTS album_items_page_idx
      ON album_items(album_id, sort_order DESC, id DESC);

    CREATE TABLE IF NOT EXISTS media_notes (
      id TEXT PRIMARY KEY,
      asset_id TEXT NOT NULL UNIQUE REFERENCES media_assets(id) ON DELETE CASCADE,
      couple_id TEXT NOT NULL REFERENCES couples(id) ON DELETE CASCADE,
      text TEXT NOT NULL,
      updated_by_account_id TEXT NOT NULL REFERENCES accounts(id),
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL,
      version BIGINT NOT NULL DEFAULT 0
    );
    `,
  },
  {
    version: 21,
    name: "shared_calendar",
    sql: `
    CREATE TABLE IF NOT EXISTS calendar_events (
      id TEXT PRIMARY KEY,
      couple_id TEXT REFERENCES couples(id) ON DELETE CASCADE,
      owner_account_id TEXT REFERENCES accounts(id) ON DELETE CASCADE,
      created_by_account_id TEXT NOT NULL REFERENCES accounts(id),
      scope TEXT NOT NULL CHECK (scope IN ('shared', 'private')),
      title TEXT NOT NULL,
      notes TEXT NOT NULL DEFAULT '',
      start_at BIGINT NOT NULL,
      end_at BIGINT NOT NULL,
      timezone TEXT NOT NULL,
      all_day BOOLEAN NOT NULL DEFAULT FALSE,
      status TEXT NOT NULL CHECK (status IN ('scheduled', 'completed')),
      completed_at BIGINT,
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL,
      version BIGINT NOT NULL DEFAULT 0,
      CHECK (end_at > start_at),
      CHECK ((scope = 'shared' AND couple_id IS NOT NULL AND owner_account_id IS NULL)
          OR (scope = 'private' AND couple_id IS NULL AND owner_account_id IS NOT NULL))
    );
    CREATE INDEX IF NOT EXISTS calendar_events_couple_time_idx
      ON calendar_events(couple_id, start_at, id) WHERE scope = 'shared';
    CREATE INDEX IF NOT EXISTS calendar_events_owner_time_idx
      ON calendar_events(owner_account_id, start_at, id) WHERE scope = 'private';

    CREATE TABLE IF NOT EXISTS calendar_event_participants (
      event_id TEXT NOT NULL REFERENCES calendar_events(id) ON DELETE CASCADE,
      account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
      participation_status TEXT NOT NULL DEFAULT 'accepted'
        CHECK (participation_status IN ('accepted', 'declined')),
      updated_at BIGINT NOT NULL,
      PRIMARY KEY(event_id, account_id)
    );
    CREATE INDEX IF NOT EXISTS calendar_participants_account_idx
      ON calendar_event_participants(account_id, event_id);
    `,
  },
  {
    version: 22,
    name: "shared_pet",
    sql: `
    CREATE TABLE IF NOT EXISTS pets (
      id TEXT PRIMARY KEY,
      couple_id TEXT NOT NULL UNIQUE REFERENCES couples(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      level INTEGER NOT NULL DEFAULT 1,
      experience INTEGER NOT NULL DEFAULT 0,
      mood INTEGER NOT NULL DEFAULT 80,
      coins INTEGER NOT NULL DEFAULT 0,
      timezone TEXT NOT NULL DEFAULT 'Asia/Shanghai',
      version BIGINT NOT NULL DEFAULT 0,
      created_at BIGINT NOT NULL,
      updated_at BIGINT NOT NULL
    );

    CREATE TABLE IF NOT EXISTS pet_prompt_instances (
      id TEXT PRIMARY KEY,
      pet_id TEXT NOT NULL REFERENCES pets(id) ON DELETE CASCADE,
      local_date TEXT NOT NULL,
      prompt TEXT NOT NULL,
      response_type TEXT NOT NULL DEFAULT 'text' CHECK (response_type IN ('text')),
      status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'settled')),
      reward_json TEXT,
      settled_at BIGINT,
      created_at BIGINT NOT NULL,
      UNIQUE(pet_id, local_date)
    );

    CREATE TABLE IF NOT EXISTS pet_prompt_responses (
      id TEXT PRIMARY KEY,
      prompt_id TEXT NOT NULL REFERENCES pet_prompt_instances(id) ON DELETE CASCADE,
      account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
      text TEXT NOT NULL,
      idempotency_key TEXT NOT NULL,
      responded_at BIGINT NOT NULL,
      UNIQUE(prompt_id, account_id),
      UNIQUE(account_id, idempotency_key)
    );

    CREATE TABLE IF NOT EXISTS pet_inventory (
      id TEXT PRIMARY KEY,
      pet_id TEXT NOT NULL REFERENCES pets(id) ON DELETE CASCADE,
      item_key TEXT NOT NULL,
      name TEXT NOT NULL,
      kind TEXT NOT NULL,
      symbol_name TEXT NOT NULL,
      quantity INTEGER NOT NULL DEFAULT 1,
      unlocked_at BIGINT NOT NULL,
      UNIQUE(pet_id, item_key)
    );

    CREATE TABLE IF NOT EXISTS pet_scene_items (
      pet_id TEXT NOT NULL REFERENCES pets(id) ON DELETE CASCADE,
      inventory_item_id TEXT NOT NULL REFERENCES pet_inventory(id) ON DELETE CASCADE,
      sort_order INTEGER NOT NULL,
      placed_at BIGINT NOT NULL,
      PRIMARY KEY(pet_id, inventory_item_id)
    );

    CREATE TABLE IF NOT EXISTS pet_actions (
      id TEXT PRIMARY KEY,
      pet_id TEXT NOT NULL REFERENCES pets(id) ON DELETE CASCADE,
      account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
      kind TEXT NOT NULL CHECK (kind IN ('stroke', 'high_five', 'teaser')),
      idempotency_key TEXT NOT NULL,
      reward_json TEXT NOT NULL,
      created_at BIGINT NOT NULL,
      UNIQUE(account_id, idempotency_key)
    );
    CREATE INDEX IF NOT EXISTS pet_actions_pet_time_idx
      ON pet_actions(pet_id, created_at DESC);

    CREATE TABLE IF NOT EXISTS pet_moments (
      id TEXT PRIMARY KEY,
      pet_id TEXT NOT NULL REFERENCES pets(id) ON DELETE CASCADE,
      prompt_id TEXT REFERENCES pet_prompt_instances(id) ON DELETE SET NULL,
      title TEXT NOT NULL,
      detail TEXT NOT NULL,
      created_at BIGINT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS pet_moments_pet_time_idx
      ON pet_moments(pet_id, created_at DESC);
    `,
  },
  {
    version: 23,
    name: "pet_care_state",
    sql: `
    ALTER TABLE pets ADD COLUMN IF NOT EXISTS satiety INTEGER NOT NULL DEFAULT 80;
    ALTER TABLE pets ADD COLUMN IF NOT EXISTS cleanliness INTEGER NOT NULL DEFAULT 80;
    ALTER TABLE pets ADD COLUMN IF NOT EXISTS energy INTEGER NOT NULL DEFAULT 100;
    ALTER TABLE pets ADD COLUMN IF NOT EXISTS state_updated_at BIGINT NOT NULL DEFAULT 0;
    UPDATE pets SET state_updated_at = updated_at WHERE state_updated_at = 0;

    ALTER TABLE pets DROP CONSTRAINT IF EXISTS pets_satiety_check;
    ALTER TABLE pets ADD CONSTRAINT pets_satiety_check CHECK (satiety BETWEEN 0 AND 100);
    ALTER TABLE pets DROP CONSTRAINT IF EXISTS pets_cleanliness_check;
    ALTER TABLE pets ADD CONSTRAINT pets_cleanliness_check CHECK (cleanliness BETWEEN 0 AND 100);
    ALTER TABLE pets DROP CONSTRAINT IF EXISTS pets_mood_check;
    ALTER TABLE pets ADD CONSTRAINT pets_mood_check CHECK (mood BETWEEN 0 AND 100);
    ALTER TABLE pets DROP CONSTRAINT IF EXISTS pets_energy_check;
    ALTER TABLE pets ADD CONSTRAINT pets_energy_check CHECK (energy BETWEEN 0 AND 100);

    ALTER TABLE pet_actions DROP CONSTRAINT IF EXISTS pet_actions_kind_check;
    ALTER TABLE pet_actions ADD CONSTRAINT pet_actions_kind_check
      CHECK (kind IN ('feed', 'bathe', 'play', 'stroke', 'sleep', 'high_five', 'teaser'));

    ALTER TABLE media_assets ALTER COLUMN source_message_id DROP NOT NULL;
    `,
  },
  {
    version: 24,
    name: "remove_public_registration_invites",
    sql: `
    UPDATE auth_sessions session
       SET revoked_at = COALESCE(session.revoked_at, (EXTRACT(EPOCH FROM NOW()) * 1000)::BIGINT)
      FROM accounts account
     WHERE session.account_id = account.id
       AND account.username NOT IN ('xu', 'si');
    UPDATE accounts
       SET status = 'disabled', updated_at = (EXTRACT(EPOCH FROM NOW()) * 1000)::BIGINT
     WHERE username NOT IN ('xu', 'si') AND status = 'active';
    DROP TABLE IF EXISTS couple_invites;
    `,
  },
  {
    version: 25,
    name: "album_timeline_posts",
    sql: `
    ALTER TABLE album_items ADD COLUMN IF NOT EXISTS post_id TEXT;
    CREATE INDEX IF NOT EXISTS album_items_post_idx
      ON album_items(album_id, post_id, sort_order DESC);
    `,
  },
];

export async function migrate(
  database: Pool,
  throughVersion = schemaMigrations.at(-1)?.version ?? 0,
): Promise<void> {
  const lockClient = await database.connect();
  try {
    await lockClient.query("SELECT pg_advisory_lock(hashtext('couplechat:schema-migrations'))");
    await lockClient.query(`
      CREATE TABLE IF NOT EXISTS schema_migrations (
        version INTEGER PRIMARY KEY,
        name TEXT NOT NULL,
        applied_at BIGINT NOT NULL
      );
    `);

    const appliedResult = await lockClient.query<{ version: number }>("SELECT version FROM schema_migrations");
    const appliedVersions = new Set(appliedResult.rows.map((row) => row.version));

    for (const migration of schemaMigrations) {
      if (migration.version > throughVersion) continue;
      if (appliedVersions.has(migration.version)) continue;
      try {
        await lockClient.query("BEGIN");
        await lockClient.query(migration.sql);
        await lockClient.query(
          "INSERT INTO schema_migrations (version, name, applied_at) VALUES ($1, $2, $3)",
          [migration.version, migration.name, Date.now()],
        );
        await lockClient.query("COMMIT");
        console.info(`[db] 已应用迁移 v${migration.version}: ${migration.name}`);
      } catch (error) {
        await lockClient.query("ROLLBACK").catch(() => undefined);
        throw new Error(
          `[db] 迁移 v${migration.version} (${migration.name}) 失败: ${error instanceof Error ? error.message : String(error)}`,
        );
      }
    }
  } finally {
    await lockClient.query("SELECT pg_advisory_unlock(hashtext('couplechat:schema-migrations'))").catch(() => undefined);
    lockClient.release();
  }
}
