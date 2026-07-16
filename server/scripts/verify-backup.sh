#!/usr/bin/env bash
set -Eeuo pipefail

# 备份校验不是只做“能列目录”：本脚本会恢复到随机临时数据库、比对 migration/
# 核心表计数，并从 uploads 归档中均匀抽样媒体哈希。任何阶段失败都会尝试删库。
# VERIFY_DATABASE_URL 应指向同集群的受限 CREATEDB 账号；默认拒绝超级用户执行归档 SQL。
# 旧 format v2 只能完成降级验证，成功完成有限检查后固定退出 3，绝不以 0 冒充完整验证。

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SERVER_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
source "$SCRIPT_DIR/backup-table-policy.sh"
VERIFY_ALLOWED_PREFIX="${VERIFY_ALLOWED_PREFIX:-${BACKUP_ALLOWED_PREFIX:-/var/backups}}"
VERIFY_MEDIA_SAMPLE_SIZE="${VERIFY_MEDIA_SAMPLE_SIZE:-20}"
VERIFY_ALLOW_SUPERUSER="${VERIFY_ALLOW_SUPERUSER:-0}"
readonly VERIFY_EXIT_DEGRADED_LEGACY_V2=3

readonly -a REQUIRED_FILES=("${BACKUP_CHECKSUM_FILES[@]}")
die() {
  echo "[verify] $*" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

for command in awk basename cat chmod cmp date dirname flock grep mktemp mv node od pg_restore psql realpath rm \
  sed sha256sum stat sync tail tar tr; do
  require_command "$command"
done
[[ "$VERIFY_MEDIA_SAMPLE_SIZE" =~ ^[1-9][0-9]*$ ]] || die "VERIFY_MEDIA_SAMPLE_SIZE 必须是正整数"
[[ "$VERIFY_ALLOW_SUPERUSER" =~ ^[01]$ ]] || die "VERIFY_ALLOW_SUPERUSER 只能是 0 或 1"

backup_input="${1:-}"
[[ -n "$backup_input" ]] || die "用法: bash scripts/verify-backup.sh /允许前缀/备份目录"
[[ "$backup_input" == /* && -d "$backup_input" && ! -L "$backup_input" ]] || \
  die "备份路径必须是非符号链接的绝对目录"
[[ "$VERIFY_ALLOWED_PREFIX" == /* && "$VERIFY_ALLOWED_PREFIX" != "/" && \
    -d "$VERIFY_ALLOWED_PREFIX" && ! -L "$VERIFY_ALLOWED_PREFIX" ]] || \
  die "VERIFY_ALLOWED_PREFIX 必须是已存在、非根且非符号链接的绝对目录"

allowed_prefix="$(realpath -e -- "$VERIFY_ALLOWED_PREFIX")"
backup="$(realpath -e -- "$backup_input")"
[[ "$backup" == "$allowed_prefix/"* ]] || die "备份目录不在允许前缀 $allowed_prefix 内"
backup_tier_root="$(dirname -- "$backup")"
backup_root="$(dirname -- "$backup_tier_root")"
[[ "$(basename -- "$backup_tier_root")" =~ ^(daily|weekly)$ && "$backup_root" == "$allowed_prefix/"* ]] || \
  die "备份目录必须位于允许前缀下的 <backup-root>/{daily,weekly}/<backup-id>"
lock_file="$backup_root/.backup.lock"
[[ -f "$lock_file" && ! -L "$lock_file" ]] || die "缺少安全的备份全局锁文件"
exec 8<"$lock_file"
flock -s -n 8 || die "备份正在生成或轮转，请稍后再校验"
[[ "$(realpath -e -- "$backup_input")" == "$backup" ]] || die "获取锁期间备份路径发生变化"

# 防止低权限用户在校验前替换归档；完整性校验不等同于密码学签名。
permission_path="$backup"
while :; do
  permission_mode="$(stat -c '%a' -- "$permission_path")"
  [[ "$permission_mode" =~ ^[0-7]{3,4}$ ]] || die "无法读取路径权限: $permission_path"
  (( (8#$permission_mode & 022) == 0 )) || \
    die "备份路径链不能允许 group/other 写入: $permission_path"
  [[ "$permission_path" == "$allowed_prefix" ]] && break
  permission_path="$(dirname -- "$permission_path")"
done

for file in "${REQUIRED_FILES[@]}" SHA256SUMS; do
  [[ -f "$backup/$file" && ! -L "$backup/$file" ]] || die "缺少或不安全的备份文件: $file"
  file_mode="$(stat -c '%a' -- "$backup/$file")"
  [[ "$file_mode" =~ ^[0-7]{3,4}$ ]] || die "无法读取备份文件权限: $file"
  (( (8#$file_mode & 022) == 0 )) || die "备份文件不能允许 group/other 写入: $file"
done

# 不直接执行 sha256sum --check：先把清单限制为固定文件名，避免 ../../ 越界读取。
declare -A checksum_seen=()
while IFS= read -r line || [[ -n "$line" ]]; do
  ((${#line} >= 67)) || die "SHA256SUMS 行格式错误"
  expected_hash="${line:0:64}"
  separator="${line:64:2}"
  filename="${line:66}"
  [[ "$expected_hash" =~ ^[0-9a-fA-F]{64}$ && \
      ( "$separator" == "  " || "$separator" == " *" ) ]] || \
    die "SHA256SUMS 行格式错误"
  allowed=0
  for required in "${REQUIRED_FILES[@]}"; do
    [[ "$filename" == "$required" ]] && allowed=1
  done
  ((allowed == 1)) || die "SHA256SUMS 含未授权路径: $filename"
  [[ -z "${checksum_seen[$filename]+x}" ]] || die "SHA256SUMS 含重复项: $filename"
  checksum_seen["$filename"]="$expected_hash"
done < "$backup/SHA256SUMS"

((${#checksum_seen[@]} == ${#REQUIRED_FILES[@]})) || die "SHA256SUMS 项目数量不完整"
for file in "${REQUIRED_FILES[@]}"; do
  [[ -n "${checksum_seen[$file]+x}" ]] || die "SHA256SUMS 缺少: $file"
  actual_hash="$(sha256sum -- "$backup/$file" | awk '{ print $1 }')"
  [[ "${actual_hash,,}" == "${checksum_seen[$file],,}" ]] || die "文件哈希不匹配: $file"
done

metadata_value() {
  local key="$1"
  awk -v prefix="$key=" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }' \
    "$backup/METADATA"
}

format_version="$(metadata_value format_version)"
backup_id="$(metadata_value backup_id)"
schema_version="$(metadata_value schema_migration_version)"
schema_name="$(metadata_value schema_migration_name)"
table_policy_version="$(metadata_value table_policy_version)"
counts_file="$(metadata_value core_table_counts_file)"
manifest_file="$(metadata_value uploads_manifest_file)"
metadata_upload_count="$(metadata_value uploads_file_count)"
metadata_upload_bytes="$(metadata_value uploads_total_bytes)"
config_includes_env="$(metadata_value config_includes_plaintext_env)"
consistency_mode="$(metadata_value consistency_mode)"
git_revision="$(metadata_value git_revision)"
revision_source="$(metadata_value revision_source)"
sequence_validation_version="$(metadata_value sequence_validation_version)"
metadata_message_sequence_last="$(metadata_value message_server_seq_seq_last_value)"
metadata_message_sequence_called="$(metadata_value message_server_seq_seq_is_called)"
metadata_messages_server_seq_max="$(metadata_value messages_server_seq_max)"
metadata_sync_sequence_last="$(metadata_value sync_event_seq_last_value)"
metadata_sync_sequence_called="$(metadata_value sync_event_seq_is_called)"
metadata_sync_events_seq_max="$(metadata_value sync_events_seq_max)"

[[ "$format_version" == "2" || "$format_version" == "3" ]] || die "不支持的备份格式版本: $format_version"
[[ "$backup_id" =~ ^20[0-9]{6}T[0-9]{6}Z-[A-Za-z0-9]+$ ]] || die "METADATA backup_id 不合法"
[[ "$(basename -- "$backup")" == "$backup_id" ]] || die "目录名与 METADATA backup_id 不一致"
[[ "$schema_version" =~ ^[1-9][0-9]*$ && -n "$schema_name" ]] || die "schema migration 元数据不合法"
if [[ "$format_version" == "3" ]]; then
  [[ "$table_policy_version" == "$BACKUP_TABLE_POLICY_VERSION" ]] || \
    die "不支持的表策略版本: ${table_policy_version:-缺失}"
  [[ "$sequence_validation_version" == "1" ]] || die "缺少受支持的序列证据版本"
  case "$revision_source" in
    release|git)
      [[ "$git_revision" =~ ^[0-9a-f]{40}$ ]] || die "源码版本证据必须是完整小写 commit SHA"
      ;;
    unknown)
      [[ "$git_revision" == "unknown" ]] || die "unknown 版本来源不能携带伪 SHA"
      ;;
    *)
      die "不支持的源码版本来源: ${revision_source:-缺失}"
      ;;
  esac
fi
backup_policy_validate_schema "$schema_version" || \
  die "schema v$schema_version 超出恢复校验策略支持范围（最高 v$BACKUP_TABLE_POLICY_MAX_SCHEMA）"
if ! expected_core_tables_output="$(backup_policy_expected_tables "$schema_version")"; then
  die "schema v$schema_version 的恢复表策略无效"
fi
mapfile -t expected_core_tables <<< "$expected_core_tables_output"
((${#expected_core_tables[@]} > 0)) || die "无法生成 schema v$schema_version 的核心表策略"
[[ "$counts_file" == "core-table-counts.tsv" ]] || die "核心表计数文件名不合法"
[[ "$manifest_file" == "uploads.manifest.sha256" ]] || die "uploads manifest 文件名不合法"
[[ "$metadata_upload_count" =~ ^(0|[1-9][0-9]*)$ && \
    "$metadata_upload_bytes" =~ ^(0|[1-9][0-9]*)$ ]] || \
  die "uploads 元数据不合法"
[[ "$config_includes_env" =~ ^[01]$ ]] || die "config_includes_plaintext_env 元数据不合法"
[[ "$consistency_mode" == "quiesced" || "$consistency_mode" == "best_effort" ]] || \
  die "consistency_mode 元数据不合法"
if [[ "$format_version" == "3" ]]; then
  if ((schema_version >= 16)); then
    sequence_state_values_are_safe "$metadata_message_sequence_last" \
      "$metadata_message_sequence_called" "$metadata_messages_server_seq_max" || \
      die "METADATA 中 message_server_seq_seq 状态不安全"
  else
    [[ "$metadata_message_sequence_last" == "not_applicable" && \
        "$metadata_message_sequence_called" == "not_applicable" && \
        "$metadata_messages_server_seq_max" == "not_applicable" ]] || \
      die "schema v$schema_version 不应包含 message_server_seq_seq 证据"
  fi
  if ((schema_version >= 17)); then
    sequence_state_values_are_safe "$metadata_sync_sequence_last" \
      "$metadata_sync_sequence_called" "$metadata_sync_events_seq_max" || \
      die "METADATA 中 sync_event_seq 状态不安全"
  else
    [[ "$metadata_sync_sequence_last" == "not_applicable" && \
        "$metadata_sync_sequence_called" == "not_applicable" && \
        "$metadata_sync_events_seq_max" == "not_applicable" ]] || \
      die "schema v$schema_version 不应包含 sync_event_seq 证据"
  fi
fi

pg_restore --list "$backup/couplechat.dump" >/dev/null
cmp --silent "$backup/database.contents" <(pg_restore --list "$backup/couplechat.dump") || \
  die "database.contents 与实际 PostgreSQL 归档不一致"
tar -tzf "$backup/uploads.tar.gz" >/dev/null
tar -tzf "$backup/config.tar.gz" >/dev/null
if [[ "$config_includes_env" == "0" ]] && tar -tzf "$backup/config.tar.gz" | grep -Eq '(^|/)\.env$'; then
  die "配置归档声明不含 .env，但实际发现明文 .env"
fi

# 校验 manifest 结构，并均匀抽样验证“manifest 哈希 == tar 中实际媒体内容”。
manifest_size="$(stat -c '%s' -- "$backup/uploads.manifest.sha256")"
if ((manifest_size > 0)); then
  last_byte="$(od -An -t u1 -j $((manifest_size - 1)) -N 1 "$backup/uploads.manifest.sha256" | tr -d ' ')"
  [[ "$last_byte" == "0" ]] || die "uploads manifest 未以 NUL 正确结束"
fi

manifest_count=0
sampled_count=0
sample_stride=1
if ((metadata_upload_count > VERIFY_MEDIA_SAMPLE_SIZE)); then
  sample_stride=$(((metadata_upload_count + VERIFY_MEDIA_SAMPLE_SIZE - 1) / VERIFY_MEDIA_SAMPLE_SIZE))
fi
declare -A manifest_seen=()
while IFS= read -r -d '' record; do
  ((${#record} >= 67)) || die "uploads manifest 记录过短"
  media_hash="${record:0:64}"
  media_separator="${record:64:2}"
  media_path="${record:66}"
  [[ "$media_hash" =~ ^[0-9a-fA-F]{64}$ && \
      ( "$media_separator" == "  " || "$media_separator" == " *" ) ]] || \
    die "uploads manifest 记录格式错误"
  [[ "$media_path" =~ ^uploads/[A-Za-z0-9._/-]+$ && "$media_path" != /* && "$media_path" != *//* ]] || \
    die "uploads manifest 路径越界"
  case "/$media_path/" in
    *"/../"*|*"/./"*) die "uploads manifest 含路径穿越: $media_path" ;;
  esac
  [[ -z "${manifest_seen[$media_path]+x}" ]] || die "uploads manifest 含重复路径: $media_path"
  manifest_seen["$media_path"]=1

  if ((manifest_count % sample_stride == 0 && sampled_count < VERIFY_MEDIA_SAMPLE_SIZE)); then
    archive_hash="$(tar -xOzf "$backup/uploads.tar.gz" -- "$media_path" | sha256sum | awk '{ print $1 }')"
    [[ "${archive_hash,,}" == "${media_hash,,}" ]] || die "媒体抽样哈希不匹配: $media_path"
    sampled_count=$((sampled_count + 1))
  fi
  manifest_count=$((manifest_count + 1))
done < "$backup/uploads.manifest.sha256"
((manifest_count == metadata_upload_count)) || \
  die "uploads manifest 数量与 METADATA 不一致"

verification_url="${VERIFY_DATABASE_URL:-${DATABASE_URL:-}}"
unset VERIFY_DATABASE_URL DATABASE_URL PGPASSWORD PGHOST PGHOSTADDR PGPORT PGUSER PGDATABASE PGOPTIONS \
  PGAPPNAME PGCONNECT_TIMEOUT PGSSLMODE PGSSLCERT PGSSLKEY PGSSLROOTCERT PGSERVICE PGSERVICEFILE PGPASSFILE
if [[ -z "$verification_url" && -f "$SERVER_DIR/.env" ]]; then
  verification_url="$(sed -n 's/^DATABASE_URL=//p' "$SERVER_DIR/.env" | tail -n 1)"
  if [[ "$verification_url" == \"*\" && "$verification_url" == *\" ]]; then
    verification_url="${verification_url:1:${#verification_url}-2}"
  elif [[ "$verification_url" == \'*\' && "$verification_url" == *\' ]]; then
    verification_url="${verification_url:1:${#verification_url}-2}"
  fi
fi
[[ -n "$verification_url" ]] || die "实际恢复校验需要 VERIFY_DATABASE_URL（或 DATABASE_URL/server/.env）"

temp_parent="${TMPDIR:-/tmp}"
[[ "$temp_parent" == /* && -d "$temp_parent" && ! -L "$temp_parent" ]] || \
  die "TMPDIR 必须是已存在且非符号链接的绝对目录"
temp_parent="$(realpath -e -- "$temp_parent")"
admin_connection_dir=""
restore_connection_dir=""
temp_database=""
temp_database_created=0
marker_partial=""

remove_direct_child_tree() {
  local target="$1" parent="$2" target_real parent_real
  [[ -d "$target" && ! -L "$target" ]] || return 0
  target_real="$(realpath -e -- "$target")"
  parent_real="$(realpath -e -- "$parent")"
  [[ "$(dirname -- "$target_real")" == "$parent_real" ]] || {
    echo "[verify] 拒绝清理越界临时目录: $target" >&2
    return 1
  }
  rm -rf --one-file-system -- "$target_real"
}

admin_psql() {
  PGSERVICEFILE="$admin_connection_dir/pg_service.conf" \
  PGPASSFILE="$admin_connection_dir/.pgpass" \
  PGSERVICE="couplechat_verify_admin" \
    psql -X --no-psqlrc --no-password --set ON_ERROR_STOP=1 \
      --dbname="service=couplechat_verify_admin" "$@"
}

admin_psql_value() {
  admin_psql --tuples-only --no-align --command "$1" | tr -d '\r\n'
}

restore_psql_value() {
  PGSERVICEFILE="$restore_connection_dir/pg_service.conf" \
  PGPASSFILE="$restore_connection_dir/.pgpass" \
  PGSERVICE="couplechat_verify_restore" \
    psql -X --no-psqlrc --no-password --set ON_ERROR_STOP=1 --tuples-only --no-align \
      --dbname="service=couplechat_verify_restore" --command "$1" | tr -d '\r\n'
}

capture_restored_sequence_state() {
  local sequence_name="$1" table_name="$2" column_name="$3" exists state
  local last_value is_called data_max extra
  exists="$(restore_psql_value \
    "SELECT CASE WHEN to_regclass('public.\"$sequence_name\"') IS NULL THEN '0' ELSE '1' END;")"
  [[ "$exists" == "1" ]] || return 1
  state="$(restore_psql_value \
    "SELECT sequence_state.last_value::text || E'\\t' || sequence_state.is_called::text || E'\\t' || \
COALESCE((SELECT MAX(data.\"$column_name\") FROM public.\"$table_name\" AS data), 0)::text \
FROM public.\"$sequence_name\" AS sequence_state;")"
  IFS=$'\t' read -r last_value is_called data_max extra <<< "$state"
  [[ -z "${extra:-}" ]] || return 1
  [[ "$is_called" == "t" ]] && is_called="true"
  [[ "$is_called" == "f" ]] && is_called="false"
  sequence_state_values_are_safe "$last_value" "$is_called" "$data_max" || return 1
  printf '%s\t%s\t%s\n' "$last_value" "$is_called" "$data_max"
}

drop_temp_database() {
  ((temp_database_created == 1)) || return 0
  admin_psql --quiet --command \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$temp_database' AND pid <> pg_backend_pid();" \
    >/dev/null || return 1
  admin_psql --quiet --command "DROP DATABASE \"$temp_database\";" >/dev/null || return 1
  temp_database_created=0
}

cleanup_on_exit() {
  local status=$?
  trap - EXIT INT TERM HUP
  if ((temp_database_created == 1)); then
    if ! drop_temp_database; then
      echo "[verify] 警告：临时数据库 $temp_database 清理失败，请人工删除" >&2
      status=1
    fi
  fi
  if [[ -n "$restore_connection_dir" ]]; then
    remove_direct_child_tree "$restore_connection_dir" "$temp_parent" || status=1
  fi
  if [[ -n "$admin_connection_dir" ]]; then
    remove_direct_child_tree "$admin_connection_dir" "$temp_parent" || status=1
  fi
  if [[ -n "$marker_partial" && -f "$marker_partial" && ! -L "$marker_partial" ]]; then
    rm -f -- "$marker_partial" || status=1
  fi
  exit "$status"
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

admin_connection_dir="$(mktemp -d "$temp_parent/couplechat-verify-admin.XXXXXX")"
chmod 0700 -- "$admin_connection_dir"
COUPLECHAT_DATABASE_URL="$verification_url" \
PG_SERVICE_OUTPUT_DIR="$admin_connection_dir" \
PG_SERVICE_NAME="couplechat_verify_admin" \
  node "$SCRIPT_DIR/pg-service-from-url.mjs"

is_superuser="$(admin_psql_value \
  "SELECT rolsuper::text FROM pg_roles WHERE rolname = current_user;")"
if [[ "$is_superuser" == "true" || "$is_superuser" == "t" ]]; then
  [[ "$VERIFY_ALLOW_SUPERUSER" == "1" ]] || \
    die "为避免用超级用户执行归档 SQL，默认拒绝恢复；可用受限 CREATEDB 账号，或显式设置 VERIFY_ALLOW_SUPERUSER=1"
fi
can_create_database="$(admin_psql_value \
  "SELECT (rolcreatedb OR rolsuper)::text FROM pg_roles WHERE rolname = current_user;")"
[[ "$can_create_database" == "true" || "$can_create_database" == "t" ]] || \
  die "恢复校验账号需要 CREATEDB 权限"

temp_database="cc_verify_$(date -u +%Y%m%d%H%M%S)_$$_${RANDOM}"
[[ "$temp_database" =~ ^[a-z0-9_]{1,63}$ ]] || die "内部临时数据库名生成失败"
database_exists="$(admin_psql_value \
  "SELECT count(*)::text FROM pg_database WHERE datname = '$temp_database';")"
[[ "$database_exists" == "0" ]] || die "随机临时数据库名冲突，请重试"

admin_psql --quiet --command "CREATE DATABASE \"$temp_database\" TEMPLATE template0;" >/dev/null
temp_database_created=1

restore_connection_dir="$(mktemp -d "$temp_parent/couplechat-verify-restore.XXXXXX")"
chmod 0700 -- "$restore_connection_dir"
COUPLECHAT_DATABASE_URL="$verification_url" \
PG_SERVICE_OUTPUT_DIR="$restore_connection_dir" \
PG_SERVICE_NAME="couplechat_verify_restore" \
PG_DATABASE_OVERRIDE="$temp_database" \
  node "$SCRIPT_DIR/pg-service-from-url.mjs"
unset verification_url COUPLECHAT_DATABASE_URL

PGSERVICEFILE="$restore_connection_dir/pg_service.conf" \
PGPASSFILE="$restore_connection_dir/.pgpass" \
PGSERVICE="couplechat_verify_restore" \
  pg_restore --no-password --exit-on-error --single-transaction --no-owner --no-privileges \
    --dbname="service=couplechat_verify_restore" "$backup/couplechat.dump"

restored_schema_row="$(restore_psql_value \
  "SELECT version::text || E'\\t' || name FROM schema_migrations ORDER BY version DESC LIMIT 1;")"
restored_schema_version="${restored_schema_row%%$'\t'*}"
restored_schema_name="${restored_schema_row#*$'\t'}"
[[ "$restored_schema_version" == "$schema_version" && "$restored_schema_name" == "$schema_name" ]] || \
  die "恢复后的 schema migration 与备份元数据不一致"

if ! restored_tables_output="$(PGSERVICEFILE="$restore_connection_dir/pg_service.conf" \
  PGPASSFILE="$restore_connection_dir/.pgpass" PGSERVICE="couplechat_verify_restore" \
  psql -X --no-psqlrc --no-password --set ON_ERROR_STOP=1 --tuples-only --no-align \
    --dbname="service=couplechat_verify_restore" \
    --command "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = 'public' ORDER BY tablename;" | tr -d '\r')"; then
  die "无法读取恢复库 public 表清单"
fi
expected_tables_sorted="$(printf '%s\n' "${expected_core_tables[@]}" | LC_ALL=C sort)"
restored_tables_sorted="$(printf '%s\n' "$restored_tables_output" | sed '/^$/d' | LC_ALL=C sort)"
[[ "$restored_tables_sorted" == "$expected_tables_sorted" ]] || \
  die "恢复库 public 表清单与 schema v$schema_version 策略不一致"

declare -A expected_counts=()
while IFS=$'\t' read -r table expected_count extra || [[ -n "${table:-}" ]]; do
  [[ -n "$table" && "$expected_count" =~ ^[0-9]+$ && -z "${extra:-}" ]] || \
    die "core-table-counts.tsv 格式错误"
  allowed=0
  for core_table in "${expected_core_tables[@]}"; do
    [[ "$table" == "$core_table" ]] && allowed=1
  done
  ((allowed == 1)) || die "core-table-counts.tsv 含未知表: $table"
  [[ -z "${expected_counts[$table]+x}" ]] || die "core-table-counts.tsv 含重复表: $table"
  expected_counts["$table"]="$expected_count"
done < "$backup/core-table-counts.tsv"
if [[ "$format_version" == "3" ]]; then
  (( ${#expected_counts[@]} == ${#expected_core_tables[@]} )) || die "核心表计数清单与 schema 策略不一致"
  for table in "${expected_core_tables[@]}"; do
    [[ -n "${expected_counts[$table]+x}" ]] || die "核心表计数缺少策略要求的表: $table"
  done
else
  readonly -a legacy_required_tables=(accounts messages uploads)
  for table in "${legacy_required_tables[@]}"; do
    [[ -n "${expected_counts[$table]+x}" ]] || die "旧版核心表计数缺少最低要求表: $table"
  done
fi

for table in "${!expected_counts[@]}"; do
  restored_count="$(restore_psql_value "SELECT count(*)::text FROM public.\"$table\";")"
  [[ "$restored_count" == "${expected_counts[$table]}" ]] || \
    die "核心表计数不一致: $table（期望 ${expected_counts[$table]}，恢复后 $restored_count）"
done

restored_message_sequence_last="not_applicable"
restored_message_sequence_called="not_applicable"
restored_messages_server_seq_max="not_applicable"
restored_sync_sequence_last="not_applicable"
restored_sync_sequence_called="not_applicable"
restored_sync_events_seq_max="not_applicable"
if ((schema_version >= 16)); then
  if ! restored_message_state="$(capture_restored_sequence_state \
    message_server_seq_seq messages server_seq)"; then
    die "恢复库 message_server_seq_seq 缺失、不可读或落后于 messages.server_seq"
  fi
  IFS=$'\t' read -r restored_message_sequence_last restored_message_sequence_called \
    restored_messages_server_seq_max <<< "$restored_message_state"
fi
if ((schema_version >= 17)); then
  if ! restored_sync_state="$(capture_restored_sequence_state sync_event_seq sync_events seq)"; then
    die "恢复库 sync_event_seq 缺失、不可读或落后于 sync_events.seq"
  fi
  IFS=$'\t' read -r restored_sync_sequence_last restored_sync_sequence_called \
    restored_sync_events_seq_max <<< "$restored_sync_state"
fi
if [[ "$format_version" == "3" && "$consistency_mode" == "quiesced" ]]; then
  [[ "$restored_message_sequence_last" == "$metadata_message_sequence_last" && \
      "$restored_message_sequence_called" == "$metadata_message_sequence_called" && \
      "$restored_messages_server_seq_max" == "$metadata_messages_server_seq_max" ]] || \
    die "quiesced 备份的 message_server_seq_seq 恢复状态与 METADATA 不一致"
  [[ "$restored_sync_sequence_last" == "$metadata_sync_sequence_last" && \
      "$restored_sync_sequence_called" == "$metadata_sync_sequence_called" && \
      "$restored_sync_events_seq_max" == "$metadata_sync_events_seq_max" ]] || \
    die "quiesced 备份的 sync_event_seq 恢复状态与 METADATA 不一致"
fi

drop_temp_database || die "临时数据库清理失败: $temp_database"

if [[ "$format_version" == "2" ]]; then
  echo "[verify] 旧版 v2 备份已通过真实数据库恢复与已有计数校验，但旧格式未覆盖全部表，不写 RESTORE-VERIFIED" >&2
  echo "verification_status=degraded_legacy_v2"
  echo "[verify] schema=v$schema_version，旧版计数表=${#expected_counts[@]}，媒体抽样=$sampled_count/$manifest_count，一致性=$consistency_mode"
  exit "$VERIFY_EXIT_DEGRADED_LEGACY_V2"
fi

# 只有完成真实 restore、schema/全表计数、序列安全性、媒体抽样并成功删掉临时库后才写标记。
# 标记不参与原始归档哈希，它是供后续轮转识别“已实际恢复验证”的本机操作证明。
verified_at="$(date -u +%Y%m%dT%H%M%SZ)"
marker="$backup/RESTORE-VERIFIED"
[[ ! -e "$marker" || ( -f "$marker" && ! -L "$marker" ) ]] || die "恢复验证标记路径不安全"
sha256sums_hash="$(sha256sum -- "$backup/SHA256SUMS" | awk '{ print $1 }')"
marker_partial="$(mktemp "$backup/.restore-verified.XXXXXX")"
chmod 0600 -- "$marker_partial"
cat > "$marker_partial" <<EOF
format_version=2
backup_id=$backup_id
schema_migration_version=$schema_version
consistency_mode=$consistency_mode
sha256sums_sha256=$sha256sums_hash
sequence_validation_version=1
message_server_seq_seq_last_value=$restored_message_sequence_last
message_server_seq_seq_is_called=$restored_message_sequence_called
messages_server_seq_max=$restored_messages_server_seq_max
sync_event_seq_last_value=$restored_sync_sequence_last
sync_event_seq_is_called=$restored_sync_sequence_called
sync_events_seq_max=$restored_sync_events_seq_max
verified_at_utc=$verified_at
verification=db_full_restore_all_tables_media_sample_sequences
EOF
mv -- "$marker_partial" "$marker"
marker_partial=""
sync -f -- "$marker"
sync -f -- "$backup"
echo "[verify] 可恢复性校验通过: $backup"
echo "[verify] schema=v$schema_version，核心表=${#expected_counts[@]}，媒体抽样=$sampled_count/$manifest_count，一致性=$consistency_mode"
