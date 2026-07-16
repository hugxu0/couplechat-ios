#!/usr/bin/env bash
set -Eeuo pipefail

# CoupleChat 轻量生产备份：PostgreSQL 自定义归档 + uploads + 非敏感部署配置。
# 设计目标是“失败时不留下可见的半成品”，并把恢复所需的校验信息一起封存。
# BACKUP_QUIESCE_HOOK 必须是绝对可执行文件，调用约定为：
#   hook begin <backup_id> 进入短暂停写；hook end <backup_id> 恢复服务。
# 生产环境建议同时设置 BACKUP_REQUIRE_QUIESCE=1，让 hook 缺失时直接失败。

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SERVER_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
source "$SCRIPT_DIR/backup-table-policy.sh"
source "$SCRIPT_DIR/backup-retention.sh"
BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/couplechat}"
BACKUP_ALLOWED_PREFIX="${BACKUP_ALLOWED_PREFIX:-/var/backups}"
KEEP_DAILY_DAYS="${KEEP_DAILY_DAYS:-7}"
KEEP_WEEKLY_DAYS="${KEEP_WEEKLY_DAYS:-35}"
BACKUP_MIN_FREE_BYTES="${BACKUP_MIN_FREE_BYTES:-268435456}"
BACKUP_SIZE_MULTIPLIER_PERCENT="${BACKUP_SIZE_MULTIPLIER_PERCENT:-130}"
BACKUP_REQUIRE_QUIESCE="${BACKUP_REQUIRE_QUIESCE:-0}"
BACKUP_QUIESCE_HOOK="${BACKUP_QUIESCE_HOOK:-}"
BACKUP_QUIESCE_TIMEOUT_SECONDS="${BACKUP_QUIESCE_TIMEOUT_SECONDS:-45}"
BACKUP_INCLUDE_ENV="${BACKUP_INCLUDE_ENV:-0}"
umask 077

die() {
  echo "[backup] $*" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

require_unsigned_integer() {
  local name="$1" value="$2"
  [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || die "$name 必须是无前导零的非负整数"
}

require_positive_integer() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[1-9][0-9]*$ ]] || die "$name 必须是正整数"
}

for command in awk basename cat chmod cp date df dirname du find flock hostname mkdir mktemp mv \
  node pg_dump pg_restore psql realpath rm sed sha256sum sort stat sync tail tar timeout tr wc xargs; do
  require_command "$command"
done
require_unsigned_integer KEEP_DAILY_DAYS "$KEEP_DAILY_DAYS"
require_unsigned_integer KEEP_WEEKLY_DAYS "$KEEP_WEEKLY_DAYS"
require_unsigned_integer BACKUP_MIN_FREE_BYTES "$BACKUP_MIN_FREE_BYTES"
require_positive_integer BACKUP_SIZE_MULTIPLIER_PERCENT "$BACKUP_SIZE_MULTIPLIER_PERCENT"
require_positive_integer BACKUP_QUIESCE_TIMEOUT_SECONDS "$BACKUP_QUIESCE_TIMEOUT_SECONDS"
[[ "$BACKUP_REQUIRE_QUIESCE" =~ ^[01]$ ]] || die "BACKUP_REQUIRE_QUIESCE 只能是 0 或 1"
[[ "$BACKUP_INCLUDE_ENV" =~ ^[01]$ ]] || die "BACKUP_INCLUDE_ENV 只能是 0 或 1"

[[ "$BACKUP_ALLOWED_PREFIX" == /* && "$BACKUP_ALLOWED_PREFIX" != "/" ]] || \
  die "BACKUP_ALLOWED_PREFIX 必须是非根目录的绝对路径"
[[ "$BACKUP_ROOT" == /* && "$BACKUP_ROOT" != "/" ]] || \
  die "BACKUP_ROOT 必须是非根目录的绝对路径"
[[ ! -L "$BACKUP_ALLOWED_PREFIX" ]] || die "BACKUP_ALLOWED_PREFIX 不能是符号链接"
mkdir -p -- "$BACKUP_ALLOWED_PREFIX"
allowed_prefix="$(realpath -e -- "$BACKUP_ALLOWED_PREFIX")"
allowed_mode="$(stat -c '%a' -- "$allowed_prefix")"
[[ "$allowed_mode" =~ ^[0-7]{3,4}$ ]] || die "无法读取 BACKUP_ALLOWED_PREFIX 权限"
(( (8#$allowed_mode & 022) == 0 )) || die "BACKUP_ALLOWED_PREFIX 不能允许 group/other 写入"
root_candidate="$(realpath -m -- "$BACKUP_ROOT")"
[[ "$root_candidate" == "$allowed_prefix/"* ]] || \
  die "BACKUP_ROOT 必须位于允许前缀 $allowed_prefix 内"
[[ ! -L "$BACKUP_ROOT" ]] || die "BACKUP_ROOT 不能是符号链接"

mkdir -p -- "$BACKUP_ROOT"
backup_root="$(realpath -e -- "$BACKUP_ROOT")"
[[ "$backup_root" == "$root_candidate" ]] || die "BACKUP_ROOT 在创建过程中发生了路径跳转"
chmod 0700 -- "$backup_root"

daily_root="$backup_root/daily"
weekly_root="$backup_root/weekly"
for directory in "$daily_root" "$weekly_root"; do
  [[ ! -L "$directory" ]] || die "备份子目录不能是符号链接: $directory"
  mkdir -p -- "$directory"
  [[ "$(realpath -e -- "$directory")" == "$directory" ]] || die "备份子目录路径不安全: $directory"
  chmod 0700 -- "$directory"
done

lock_file="$backup_root/.backup.lock"
[[ ! -L "$lock_file" ]] || die "锁文件不能是符号链接"
[[ ! -e "$lock_file" || -f "$lock_file" ]] || die "锁路径不是普通文件"
exec 9>"$lock_file"
flock -n 9 || die "另一个备份进程正在运行"

# partial 不是有效备份，可以在新备份开始前清除；已发布备份只能在本次成功后轮转。
cleanup_stale_partials "$daily_root"
cleanup_stale_partials "$weekly_root"

connection_parent=""
connection_dir=""
partial=""
weekly_partial=""
weekly_destination=""
backup_id=""
quiesce_active=0

run_quiesce_end() {
  ((quiesce_active == 1)) || return 0
  if timeout --signal=TERM --kill-after=5s "${BACKUP_QUIESCE_TIMEOUT_SECONDS}s" \
    "$BACKUP_QUIESCE_HOOK" end "$backup_id"; then
    quiesce_active=0
    return 0
  fi
  return 1
}

cleanup_on_exit() {
  local status=$?
  trap - EXIT INT TERM HUP
  if ((quiesce_active == 1)); then
    if ! run_quiesce_end; then
      # end hook 失败时保留明确告警；trap 已关闭，不会递归执行。
      quiesce_active=0
      echo "[backup] 警告：退出 maintenance/quiesce 失败，请立即人工处理" >&2
      status=1
    fi
  fi
  if [[ -n "$weekly_partial" ]]; then
    remove_direct_child_tree "$weekly_partial" "$weekly_root" || status=1
  fi
  if [[ -n "$partial" ]]; then
    remove_direct_child_tree "$partial" "$daily_root" || status=1
  fi
  if [[ -n "$connection_dir" ]]; then
    remove_direct_child_tree "$connection_dir" "$connection_parent" || status=1
  fi
  exit "$status"
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

database_url="${DATABASE_URL:-}"
unset DATABASE_URL PGPASSWORD PGHOST PGHOSTADDR PGPORT PGUSER PGDATABASE PGOPTIONS \
  PGAPPNAME PGCONNECT_TIMEOUT PGSSLMODE PGSSLCERT PGSSLKEY PGSSLROOTCERT PGSERVICE PGSERVICEFILE PGPASSFILE
if [[ -z "$database_url" && -f "$SERVER_DIR/.env" ]]; then
  database_url="$(sed -n 's/^DATABASE_URL=//p' "$SERVER_DIR/.env" | tail -n 1)"
  if [[ "$database_url" == \"*\" && "$database_url" == *\" ]]; then
    database_url="${database_url:1:${#database_url}-2}"
  elif [[ "$database_url" == \'*\' && "$database_url" == *\' ]]; then
    database_url="${database_url:1:${#database_url}-2}"
  fi
fi
[[ -n "$database_url" ]] || die "需要通过环境变量或 server/.env 提供 DATABASE_URL"

connection_parent="${TMPDIR:-/tmp}"
[[ "$connection_parent" == /* && -d "$connection_parent" && ! -L "$connection_parent" ]] || \
  die "TMPDIR 必须是已存在且非符号链接的绝对目录"
connection_parent="$(realpath -e -- "$connection_parent")"
connection_dir="$(mktemp -d "$connection_parent/couplechat-backup-db.XXXXXX")"
chmod 0700 -- "$connection_dir"
COUPLECHAT_DATABASE_URL="$database_url" \
PG_SERVICE_OUTPUT_DIR="$connection_dir" \
PG_SERVICE_NAME="couplechat_backup" \
  node "$SCRIPT_DIR/pg-service-from-url.mjs"
unset database_url COUPLECHAT_DATABASE_URL

export PGSERVICEFILE="$connection_dir/pg_service.conf"
export PGPASSFILE="$connection_dir/.pgpass"
export PGSERVICE="couplechat_backup"

psql_value() {
  psql -X --no-psqlrc --no-password --set ON_ERROR_STOP=1 --tuples-only --no-align \
    --dbname="service=couplechat_backup" --command "$1" | tr -d '\r\n'
}

capture_live_sequence_state() {
  local sequence_name="$1" table_name="$2" column_name="$3" exists state
  local last_value is_called data_max extra
  exists="$(psql_value \
    "SELECT CASE WHEN to_regclass('public.\"$sequence_name\"') IS NULL THEN '0' ELSE '1' END;")"
  [[ "$exists" == "1" ]] || return 1
  state="$(psql_value \
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

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
random_token="$(node -e 'process.stdout.write(require("node:crypto").randomBytes(6).toString("hex"))')"
backup_id="${timestamp}-${random_token}"
destination="$daily_root/$backup_id"

if [[ -n "$BACKUP_QUIESCE_HOOK" ]]; then
  [[ "$BACKUP_QUIESCE_HOOK" == /* && -f "$BACKUP_QUIESCE_HOOK" && \
      ! -L "$BACKUP_QUIESCE_HOOK" && -x "$BACKUP_QUIESCE_HOOK" ]] || \
    die "BACKUP_QUIESCE_HOOK 必须是非符号链接的绝对可执行文件"
elif [[ "$BACKUP_REQUIRE_QUIESCE" == "1" ]]; then
  die "BACKUP_REQUIRE_QUIESCE=1 时必须配置 BACKUP_QUIESCE_HOOK"
fi

database_size="$(psql_value 'SELECT pg_database_size(current_database())::text;')"
[[ "$database_size" =~ ^[0-9]+$ ]] || die "无法读取数据库大小"
uploads_estimated_bytes=0
if [[ -d "$SERVER_DIR/uploads" ]]; then
  [[ ! -L "$SERVER_DIR/uploads" ]] || die "uploads 根目录不能是符号链接"
  uploads_estimated_bytes="$(( $(du -sk -- "$SERVER_DIR/uploads" | awk '{print $1}') * 1024 ))"
fi
config_estimated_bytes=0
for candidate in compose.production.yml .env.production.example Dockerfile package.json package-lock.json; do
  [[ -f "$SERVER_DIR/$candidate" && ! -L "$SERVER_DIR/$candidate" ]] || continue
  config_estimated_bytes=$((config_estimated_bytes + $(stat -c '%s' -- "$SERVER_DIR/$candidate")))
done
snapshot_estimate=$((database_size + uploads_estimated_bytes + config_estimated_bytes + 67108864))
snapshot_estimate=$(((snapshot_estimate * BACKUP_SIZE_MULTIPLIER_PERCENT + 99) / 100))

available_bytes() {
  df -Pk -- "$1" | awk 'NR == 2 { printf "%.0f\n", $4 * 1024 }'
}

today_is_sunday=0
[[ "$(date -u +%u)" == "7" ]] && today_is_sunday=1
daily_device="$(stat -c '%d' -- "$daily_root")"
weekly_device="$(stat -c '%d' -- "$weekly_root")"
daily_required=$((snapshot_estimate + BACKUP_MIN_FREE_BYTES))
weekly_required=0
if ((today_is_sunday == 1)); then
  if [[ "$daily_device" == "$weekly_device" ]]; then
    daily_required=$((snapshot_estimate * 2 + BACKUP_MIN_FREE_BYTES))
  else
    weekly_required=$((snapshot_estimate + BACKUP_MIN_FREE_BYTES))
  fi
fi
daily_available="$(available_bytes "$daily_root")"
[[ "$daily_available" =~ ^[0-9]+$ ]] || die "无法读取 daily 分区剩余容量"
((daily_available >= daily_required)) || \
  die "daily 分区容量不足：需要至少 $daily_required 字节，当前 $daily_available 字节"
if ((weekly_required > 0)); then
  weekly_available="$(available_bytes "$weekly_root")"
  [[ "$weekly_available" =~ ^[0-9]+$ ]] || die "无法读取 weekly 分区剩余容量"
  ((weekly_available >= weekly_required)) || \
    die "weekly 分区容量不足：需要至少 $weekly_required 字节，当前 $weekly_available 字节"
fi

# 容量确认后才在备份分区创建本次唯一 partial；最终目录不会复用或覆盖。
[[ ! -e "$destination" ]] || die "目标备份目录已存在: $destination"
partial="$(mktemp -d "$daily_root/.partial-${backup_id}-XXXXXX")"

consistency_mode="best_effort"
if [[ -n "$BACKUP_QUIESCE_HOOK" ]]; then
  quiesce_active=1
  timeout --signal=TERM --kill-after=5s "${BACKUP_QUIESCE_TIMEOUT_SECONDS}s" \
    "$BACKUP_QUIESCE_HOOK" begin "$backup_id"
  consistency_mode="quiesced"
fi

schema_row="$(psql_value \
  "SELECT version::text || E'\\t' || name FROM schema_migrations ORDER BY version DESC LIMIT 1;")"
schema_version="${schema_row%%$'\t'*}"
schema_name="${schema_row#*$'\t'}"
[[ "$schema_version" =~ ^[0-9]+$ && -n "$schema_name" && "$schema_name" != "$schema_row" ]] || \
  die "无法读取最新 schema migration"
backup_policy_validate_schema "$schema_version" || \
  die "schema v$schema_version 超出备份表策略支持范围（最高 v$BACKUP_TABLE_POLICY_MAX_SCHEMA），请先更新 backup-table-policy.sh"
if ! expected_core_tables_output="$(backup_policy_expected_tables "$schema_version")"; then
  die "schema v$schema_version 的备份表策略无效"
fi
mapfile -t expected_core_tables <<< "$expected_core_tables_output"
((${#expected_core_tables[@]} > 0)) || die "无法生成 schema v$schema_version 的核心表策略"

if ! actual_tables_output="$(psql -X --no-psqlrc --no-password --set ON_ERROR_STOP=1 \
  --tuples-only --no-align --dbname="service=couplechat_backup" \
  --command "SELECT tablename FROM pg_catalog.pg_tables WHERE schemaname = 'public' ORDER BY tablename;" | tr -d '\r')"; then
  die "无法读取 public 表清单"
fi
expected_tables_sorted="$(printf '%s\n' "${expected_core_tables[@]}" | LC_ALL=C sort)"
actual_tables_sorted="$(printf '%s\n' "$actual_tables_output" | sed '/^$/d' | LC_ALL=C sort)"
[[ "$actual_tables_sorted" == "$expected_tables_sorted" ]] || \
  die "public 表清单与 schema v$schema_version 策略不一致；请先修正 migration 或 backup-table-policy.sh"

message_sequence_last_value="not_applicable"
message_sequence_is_called="not_applicable"
messages_server_seq_max="not_applicable"
sync_sequence_last_value="not_applicable"
sync_sequence_is_called="not_applicable"
sync_events_seq_max="not_applicable"
if ((schema_version >= 16)); then
  if ! message_sequence_state="$(capture_live_sequence_state \
    message_server_seq_seq messages server_seq)"; then
    die "message_server_seq_seq 缺失、不可读或落后于 messages.server_seq"
  fi
  IFS=$'\t' read -r message_sequence_last_value message_sequence_is_called \
    messages_server_seq_max <<< "$message_sequence_state"
fi
if ((schema_version >= 17)); then
  if ! sync_sequence_state="$(capture_live_sequence_state sync_event_seq sync_events seq)"; then
    die "sync_event_seq 缺失、不可读或落后于 sync_events.seq"
  fi
  IFS=$'\t' read -r sync_sequence_last_value sync_sequence_is_called \
    sync_events_seq_max <<< "$sync_sequence_state"
fi

# 命令行只出现无敏感信息的 service 别名；密码仅存在 0600 的临时 .pgpass。
pg_dump --no-password --format=custom --compress=6 --no-owner --no-privileges \
  --dbname="service=couplechat_backup" --file="$partial/couplechat.dump"
pg_restore --list "$partial/couplechat.dump" > "$partial/database.contents"

: > "$partial/core-table-counts.tsv"
for table in "${expected_core_tables[@]}"; do
  exists="$(psql_value "SELECT CASE WHEN to_regclass('public.\"$table\"') IS NULL THEN '0' ELSE '1' END;")"
  [[ "$exists" != "0" ]] || die "schema v$schema_version 缺少策略要求的表: $table"
  [[ "$exists" == "1" ]] || die "无法判断核心表是否存在: $table"
  count="$(psql_value "SELECT count(*)::text FROM public.\"$table\";")"
  [[ "$count" =~ ^[0-9]+$ ]] || die "无法读取核心表计数: $table"
  printf '%s\t%s\n' "$table" "$count" >> "$partial/core-table-counts.tsv"
done

: > "$partial/uploads.manifest.sha256"
uploads_file_count=0
uploads_total_bytes=0
if [[ -d "$SERVER_DIR/uploads" ]]; then
  unsafe_upload="$(find "$SERVER_DIR/uploads" -mindepth 1 \( -type l -o \( ! -type f ! -type d \) \) -print -quit)"
  [[ -z "$unsafe_upload" ]] || die "uploads 含符号链接或特殊文件，拒绝备份: $unsafe_upload"
  while IFS= read -r -d '' upload_file; do
    relative_upload="${upload_file#"$SERVER_DIR/"}"
    [[ "$relative_upload" =~ ^uploads/[A-Za-z0-9._/-]+$ && "$relative_upload" != *//* ]] || \
      die "uploads 含不安全文件名，拒绝备份: $relative_upload"
    [[ "$relative_upload" != uploads/.*.uploading ]] || \
      die "检测到尚未完成的媒体上传，拒绝生成不一致备份: $relative_upload"
    case "/$relative_upload/" in
      *"/../"*|*"/./"*) die "uploads 含路径穿越片段: $relative_upload" ;;
    esac
  done < <(find "$SERVER_DIR/uploads" -type f -print0)
  (
    cd -- "$SERVER_DIR"
    find uploads -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum -z --
  ) > "$partial/uploads.manifest.sha256"
  uploads_file_count="$(tr -cd '\000' < "$partial/uploads.manifest.sha256" | wc -c | tr -d ' ')"
  uploads_total_bytes="$(find "$SERVER_DIR/uploads" -type f -printf '%s\n' | \
    awk '{ total += $1 } END { printf "%.0f\n", total + 0 }')"
  tar -czf "$partial/uploads.tar.gz" --format=pax -C "$SERVER_DIR" uploads
else
  tar -czf "$partial/uploads.tar.gz" --files-from /dev/null
fi

# DB dump、媒体 manifest 和媒体归档完成后立即退出 maintenance，缩短停写窗口。
run_quiesce_end || die "退出 maintenance/quiesce 失败，请人工确认服务状态"

config_files=()
for candidate in compose.production.yml .env.production.example Dockerfile package.json package-lock.json; do
  if [[ -e "$SERVER_DIR/$candidate" ]]; then
    [[ -f "$SERVER_DIR/$candidate" && ! -L "$SERVER_DIR/$candidate" ]] || \
      die "配置备份候选必须是普通文件: $candidate"
    config_files+=("$candidate")
  fi
done
if [[ "$BACKUP_INCLUDE_ENV" == "1" && -e "$SERVER_DIR/.env" ]]; then
  [[ -f "$SERVER_DIR/.env" && ! -L "$SERVER_DIR/.env" ]] || die ".env 必须是普通文件"
  config_files+=(".env")
fi
if ((${#config_files[@]})); then
  tar -czf "$partial/config.tar.gz" --format=pax -C "$SERVER_DIR" "${config_files[@]}"
else
  tar -czf "$partial/config.tar.gz" --files-from /dev/null
fi

host_name="$(hostname | tr -d '\r\n')"
git_revision="unknown"
revision_source="unknown"
release_file="$SERVER_DIR/RELEASE"
if [[ -e "$release_file" || -L "$release_file" ]]; then
  [[ -f "$release_file" && ! -L "$release_file" ]] || die "RELEASE 必须是非符号链接的普通文件"
  release_uid="$(stat -c '%u' -- "$release_file")"
  release_mode="$(stat -c '%a' -- "$release_file")"
  [[ "$release_uid" == "0" && "$release_mode" =~ ^0?(400|600)$ ]] || \
    die "RELEASE 必须由 root 拥有且权限为 0400 或 0600"
  if ! release_revision="$(tr -d '\r' < "$release_file")"; then
    die "无法读取 root-only RELEASE"
  fi
  [[ "$release_revision" =~ ^[0-9a-fA-F]{40}$ ]] || die "RELEASE 必须只包含完整 40 位 commit SHA"
  git_revision="${release_revision,,}"
  revision_source="release"
elif command -v git >/dev/null 2>&1; then
  git_candidate="$(git -C "$SERVER_DIR" rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)"
  if [[ "$git_candidate" =~ ^[0-9a-fA-F]{40}$ ]]; then
    git_revision="${git_candidate,,}"
    revision_source="git"
  fi
fi
completed_at="$(date -u +%Y%m%dT%H%M%SZ)"
cat > "$partial/METADATA" <<EOF
format_version=3
backup_id=$backup_id
started_at_utc=$timestamp
snapshot_completed_at_utc=$completed_at
hostname=$host_name
git_revision=$git_revision
revision_source=$revision_source
schema_migration_version=$schema_version
schema_migration_name=$schema_name
table_policy_version=$BACKUP_TABLE_POLICY_VERSION
sequence_validation_version=1
message_server_seq_seq_last_value=$message_sequence_last_value
message_server_seq_seq_is_called=$message_sequence_is_called
messages_server_seq_max=$messages_server_seq_max
sync_event_seq_last_value=$sync_sequence_last_value
sync_event_seq_is_called=$sync_sequence_is_called
sync_events_seq_max=$sync_events_seq_max
core_table_counts_file=core-table-counts.tsv
uploads_manifest_file=uploads.manifest.sha256
uploads_file_count=$uploads_file_count
uploads_total_bytes=$uploads_total_bytes
database_estimated_bytes=$database_size
consistency_mode=$consistency_mode
quiesce_required=$BACKUP_REQUIRE_QUIESCE
config_includes_plaintext_env=$BACKUP_INCLUDE_ENV
EOF

(
  cd -- "$partial"
  sha256sum -- "${BACKUP_CHECKSUM_FILES[@]}" > SHA256SUMS
  sha256sum --check --strict SHA256SUMS >/dev/null
  pg_restore --list couplechat.dump >/dev/null
  tar -tzf uploads.tar.gz >/dev/null
  tar -tzf config.tar.gz >/dev/null
)

mv -- "$partial" "$destination"
partial=""
sync -f -- "$destination"
sync -f -- "$daily_root"

if ((today_is_sunday == 1)); then
  weekly_partial="$(mktemp -d "$weekly_root/.partial-${backup_id}-XXXXXX")"
  cp -a -- "$destination/." "$weekly_partial/"
  (cd -- "$weekly_partial" && sha256sum --check --strict SHA256SUMS >/dev/null)
  weekly_destination="$weekly_root/$backup_id"
  [[ ! -e "$weekly_destination" ]] || die "周备份目录已存在: $weekly_destination"
  mv -- "$weekly_partial" "$weekly_destination"
  weekly_partial=""
  sync -f -- "$weekly_destination"
  sync -f -- "$weekly_root"
fi

# 新 daily（以及周日的 weekly）均已校验并原子发布后，才允许删除过期成品。
prune_expired "$daily_root" "$KEEP_DAILY_DAYS" "$destination"
if ((today_is_sunday == 1)); then
  prune_expired "$weekly_root" "$KEEP_WEEKLY_DAYS" "$weekly_destination"
fi

echo "[backup] 备份已原子发布: $destination"
if [[ "$consistency_mode" != "quiesced" ]]; then
  echo "[backup] 提示：未配置 quiesce hook，本次 DB/uploads 一致性为 best_effort" >&2
fi
