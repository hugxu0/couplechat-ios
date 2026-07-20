#!/usr/bin/env bash

# PostgreSQL 持久化表的版本策略，供备份和恢复校验共同使用。
# 每项格式：表名|min schema|max schema；max=0 表示当前仍存在。
# 新 migration 若新增、删除或重命名表，必须同时更新本文件和最大版本。

readonly BACKUP_TABLE_POLICY_VERSION=1
readonly BACKUP_TABLE_POLICY_MAX_SCHEMA=33
readonly -a BACKUP_CHECKSUM_FILES=(
  couplechat.dump
  database.contents
  core-table-counts.tsv
  uploads.manifest.sha256
  uploads.tar.gz
  config.tar.gz
  METADATA
)
readonly -a BACKUP_TABLE_RULES=(
  'schema_migrations|1|0'
  'accounts|1|0'
  'messages|1|0'
  'read_receipts|1|0'
  'shared_items|1|0'
  'personal_items|1|0'
  'uploads|1|0'
  'ai_facts|1|0'
  'ai_episodes|1|0'
  'ai_docs|1|0'
  'message_attachments|5|0'
  'ai_memory_v2|6|6'
  'ai_memory_evidence_v2|6|6'
  'ai_memory_cursor_v2|6|6'
  'ai_memory|7|0'
  'ai_memory_evidence|7|0'
  'ai_memory_cursor|7|0'
  'ai_runtime_state|7|0'
  'ai_memory_import_runs|9|0'
  'ai_memory_import_candidates|9|0'
  'ai_memory_import_evidence|9|0'
  'file_cleanup_queue|11|0'
  'legacy_message_deletions|11|0'
  'reminder_bark_deliveries|12|0'
  'couples|13|0'
  'couple_members|13|0'
  'couple_invites|13|23'
  'devices|14|0'
  'auth_sessions|14|0'
  'device_push_endpoints|14|0'
  'conversations|16|0'
  'conversation_reads|16|0'
  'sync_events|17|0'
  'client_mutations|17|0'
  'device_sync_cursors|17|0'
  'couple_settings|18|0'
  'ai_memory_exclusions|18|0'
  'message_transcripts|19|0'
  'transcript_jobs|19|0'
  'media_assets|20|0'
  'albums|20|0'
  'album_items|20|0'
  'media_notes|20|0'
  'calendar_events|21|0'
  'calendar_event_participants|21|0'
  'pets|22|0'
  'pet_prompt_instances|22|0'
  'pet_prompt_responses|22|0'
  'pet_inventory|22|0'
  'pet_scene_items|22|0'
  'pet_actions|22|0'
  'pet_moments|22|0'
  'ai_memory_dependencies|26|0'
  'recommendations|29|0'
  'recommendation_user_state|29|0'
  'ai_daily_diaries|32|0'
  'card_game_daily_draws|33|0'
  'card_game_draws|33|0'
  'card_game_inventory|33|0'
  'card_game_effects|33|0'
)

backup_policy_validate_schema() {
  local schema_version="$1"
  [[ "$schema_version" =~ ^[1-9][0-9]*$ ]] || return 1
  ((schema_version <= BACKUP_TABLE_POLICY_MAX_SCHEMA)) || return 1
}

sequence_state_values_are_safe() {
  local last_value="$1" is_called="$2" data_max="$3"
  [[ "$last_value" =~ ^(0|[1-9][0-9]*)$ && "$data_max" =~ ^(0|[1-9][0-9]*)$ && \
      "$is_called" =~ ^(true|false)$ ]] || return 1
  ((last_value >= data_max)) || return 1
  # is_called=false 时下次 nextval 会返回 last_value 本身，必须严格大于已有数据。
  [[ "$is_called" != "false" ]] || ((last_value > data_max))
}

backup_policy_validate_rules() {
  local rule table min_schema max_schema
  declare -A seen_tables=()
  ((${#BACKUP_TABLE_RULES[@]} > 0)) || return 1

  for rule in "${BACKUP_TABLE_RULES[@]}"; do
    IFS='|' read -r table min_schema max_schema <<< "$rule"
    [[ "$table" =~ ^[a-z][a-z0-9_]*$ && "$min_schema" =~ ^[1-9][0-9]*$ && \
        "$max_schema" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    [[ -z "${seen_tables[$table]+x}" ]] || return 1
    ((min_schema <= BACKUP_TABLE_POLICY_MAX_SCHEMA)) || return 1
    ((max_schema == 0 || (max_schema >= min_schema && max_schema <= BACKUP_TABLE_POLICY_MAX_SCHEMA))) || return 1
    seen_tables["$table"]=1
  done
}

backup_policy_expected_tables() {
  local schema_version="$1" rule table min_schema max_schema
  backup_policy_validate_schema "$schema_version" || return 1
  backup_policy_validate_rules || return 1

  for rule in "${BACKUP_TABLE_RULES[@]}"; do
    IFS='|' read -r table min_schema max_schema <<< "$rule"
    if ((schema_version >= min_schema && (max_schema == 0 || schema_version <= max_schema))); then
      printf '%s\n' "$table"
    fi
  done
}
