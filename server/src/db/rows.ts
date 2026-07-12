export interface AccountRow {
  id: string;
  username: string;
  display_name: string;
  password_hash: string;
  avatar: string;
  bark_key: string | null;
  status: string;
  version: number;
  created_at: number;
  updated_at: number;
}

export interface MessageRow {
  id: string;
  channel: string;
  sender: string;
  sender_name: string;
  kind: string;
  type: string;
  text: string;
  url: string | null;
  reply_json: string | null;
  meta_json: string | null;
  attachments_json: string | null;
  recalled_text: string | null;
  ts: number;
  client_id: string | null;
  conversation_id?: string | null;
  sender_account_id?: string | null;
  origin_device_id?: string | null;
  server_seq?: number | null;
  transcript_status?: string | null;
  transcript_text?: string | null;
  transcript_raw_text?: string | null;
  transcript_corrected?: boolean | null;
  transcript_language?: string | null;
  transcript_version?: number | null;
}

export interface ReadReceiptRow {
  channel: string;
  username: string;
  ts: number;
  updated_at: number;
}

export interface SharedItemRow {
  key: string;
  value_json: string;
  updated_by: string;
  updated_at: number;
}

export interface PersonalItemRow {
  id: string;
  owner: string;
  kind: string;
  scope: string;
  title: string;
  body_markdown: string;
  due_at: number | null;
  is_done: number;
  created_at: number;
  updated_at: number;
  owner_account_id?: string | null;
  couple_id?: string | null;
  created_by_account_id?: string | null;
  version?: number;
  deleted_at?: number | null;
}

export interface UploadRow {
  id: string;
  owner: string;
  path: string;
  url: string;
  mime_type: string;
  size: number;
  created_at: number;
  message_id: string | null;
  purpose: string;
}

export interface AiMemoryRow {
  id: string;
  layer: string;
  scope: string;
  memory_key: string;
  subjects_json: string;
  speakers_json: string;
  content: string;
  category: string;
  confidence: number;
  importance: number;
  occurred_at: number | null;
  occurred_end_at: number | null;
  valid_from: number | null;
  valid_until: number | null;
  status: string;
  supersedes_id: string | null;
  metadata_json: string;
  embedding: Uint8Array | null;
  created_at: number;
  updated_at: number;
  couple_id?: string | null;
  owner_account_id?: string | null;
  version?: number;
}

export interface AiMemoryEvidenceRow {
  memory_id: string;
  message_id: string;
  channel: string;
  sender: string;
  message_ts: number;
  excerpt: string;
  evidence_role: string;
  created_at: number;
}
