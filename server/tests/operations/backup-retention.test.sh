#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SERVER_DIR="$(cd -- "$TEST_DIR/../.." && pwd -P)"
source "$SERVER_DIR/scripts/backup-table-policy.sh"
source "$SERVER_DIR/scripts/backup-retention.sh"

fixture_root="$(mktemp -d)"
trap 'rm -rf --one-file-system -- "$fixture_root"' EXIT
umask 077

fail() {
  echo "[backup-retention-test] $*" >&2
  exit 1
}

assert_exists() {
  [[ -d "$1" ]] || fail "应保留但已删除: $1"
}

assert_missing() {
  [[ ! -e "$1" ]] || fail "应删除但仍存在: $1"
}

create_backup() {
  local root="$1" backup_id="$2" consistency="$3" verified="$4" directory="$1/$2" file sums_hash
  mkdir -p -- "$directory"
  for file in "${BACKUP_CHECKSUM_FILES[@]}"; do
    if [[ "$file" == "METADATA" ]]; then
      printf '%s\n' \
        'format_version=3' \
        "backup_id=$backup_id" \
        'schema_migration_version=31' \
        "consistency_mode=$consistency" \
        'sequence_validation_version=1' \
        'message_server_seq_seq_last_value=42' \
        'message_server_seq_seq_is_called=true' \
        'messages_server_seq_max=42' \
        'sync_event_seq_last_value=81' \
        'sync_event_seq_is_called=true' \
        'sync_events_seq_max=80' > "$directory/$file"
    else
      printf '%s:%s\n' "$backup_id" "$file" > "$directory/$file"
    fi
  done
  (cd -- "$directory" && sha256sum -- "${BACKUP_CHECKSUM_FILES[@]}" > SHA256SUMS)

  if [[ "$verified" == "1" ]]; then
    sums_hash="$(sha256sum -- "$directory/SHA256SUMS" | awk '{ print $1 }')"
    printf '%s\n' \
      'format_version=2' \
      "backup_id=$backup_id" \
      'schema_migration_version=31' \
      "consistency_mode=$consistency" \
      "sha256sums_sha256=$sums_hash" \
      'sequence_validation_version=1' \
      'message_server_seq_seq_last_value=42' \
      'message_server_seq_seq_is_called=true' \
      'messages_server_seq_max=42' \
      'sync_event_seq_last_value=81' \
      'sync_event_seq_is_called=true' \
      'sync_events_seq_max=80' \
      'verified_at_utc=20260716T000000Z' \
      'verification=db_full_restore_all_tables_media_sample_sequences' > "$directory/RESTORE-VERIFIED"
    chmod 0600 -- "$directory/RESTORE-VERIFIED"
  fi
}

mark_expired() {
  touch -d '4 days ago' -- "$1"
}

# 新 daily 未恢复验证时，即使保留期为 0，也必须保留一份旧成品。
case_one="$fixture_root/case-one"
mkdir -p -- "$case_one"
create_backup "$case_one" 20200101T000000Z-old quiesced 0
create_backup "$case_one" 20990101T000000Z-new quiesced 0
prune_expired "$case_one" 0 "$case_one/20990101T000000Z-new"
assert_exists "$case_one/20200101T000000Z-old"
assert_exists "$case_one/20990101T000000Z-new"

# 多个旧成品时可删除未验证旧副本，但必须保留最后一个有效 verified 与本次新副本。
case_two="$fixture_root/case-two"
mkdir -p -- "$case_two"
create_backup "$case_two" 20200101T000000Z-unverified quiesced 0
create_backup "$case_two" 20210101T000000Z-verified quiesced 1
create_backup "$case_two" 20990101T000000Z-new quiesced 0
prune_expired "$case_two" 0 "$case_two/20990101T000000Z-new"
assert_missing "$case_two/20200101T000000Z-unverified"
assert_exists "$case_two/20210101T000000Z-verified"
assert_exists "$case_two/20990101T000000Z-new"

# 两份 quiesced verified 按 backup_id 从旧到新轮转，只删除较旧者。
# create_backup 刚写过 RESTORE-VERIFIED，目录 mtime 是当前时间；仍必须按 backup_id 判龄。
case_three="$fixture_root/case-three"
mkdir -p -- "$case_three"
create_backup "$case_three" 20200101T000000Z-verified quiesced 1
create_backup "$case_three" 20210101T000000Z-verified quiesced 1
create_backup "$case_three" 20990101T000000Z-new quiesced 0
touch -- "$case_three/20200101T000000Z-verified"
prune_expired "$case_three" 0 "$case_three/20990101T000000Z-new"
assert_missing "$case_three/20200101T000000Z-verified"
assert_exists "$case_three/20210101T000000Z-verified"

# 标记必须绑定当前归档内容；篡改任何受清单保护的文件后不能再算 verified。
case_four="$fixture_root/case-four"
mkdir -p -- "$case_four"
create_backup "$case_four" 20200101T000000Z-tampered quiesced 1
create_backup "$case_four" 20210101T000000Z-verified quiesced 1
create_backup "$case_four" 20990101T000000Z-new quiesced 0
printf 'tampered\n' >> "$case_four/20200101T000000Z-tampered/couplechat.dump"
restore_verified_marker_is_valid "$case_four/20200101T000000Z-tampered" && \
  fail "内容篡改后验证标记仍被接受"
prune_expired "$case_four" 0 "$case_four/20990101T000000Z-new"
assert_missing "$case_four/20200101T000000Z-tampered"
assert_exists "$case_four/20210101T000000Z-verified"

# A=旧 quiesced+verified，B=较新 best_effort+verified，C=本次未验证：
# B 不能替代 A；轮转应删除 B 并永远保护最后一份 quiesced 恢复验证。
case_five="$fixture_root/case-five"
mkdir -p -- "$case_five"
create_backup "$case_five" 20200101T000000Z-a quiesced 1
create_backup "$case_five" 20210101T000000Z-b best_effort 1
create_backup "$case_five" 20990101T000000Z-c quiesced 0
restore_verified_marker_is_valid "$case_five/20210101T000000Z-b" || \
  fail "best_effort 完整恢复标记应可识别为普通 verified"
quiesced_restore_verified_marker_is_valid "$case_five/20210101T000000Z-b" && \
  fail "best_effort verified 被错误识别为 quiesced verified"
prune_expired "$case_five" 0 "$case_five/20990101T000000Z-c"
assert_exists "$case_five/20200101T000000Z-a"
assert_missing "$case_five/20210101T000000Z-b"
assert_exists "$case_five/20990101T000000Z-c"

# 只清理超过一天的固定格式 partial，不影响成品或新 partial。
case_six="$fixture_root/case-six"
mkdir -p -- "$case_six/.partial-20200101T000000Z-old" \
  "$case_six/.partial-20990101T000000Z-new" "$case_six/20200101T000000Z-final"
mark_expired "$case_six/.partial-20200101T000000Z-old"
cleanup_stale_partials "$case_six"
assert_missing "$case_six/.partial-20200101T000000Z-old"
assert_exists "$case_six/.partial-20990101T000000Z-new"
assert_exists "$case_six/20200101T000000Z-final"

# 序列证据落后于数据时，标记不能算作有效恢复验证。
case_seven="$fixture_root/case-seven"
mkdir -p -- "$case_seven"
create_backup "$case_seven" 20200101T000000Z-sequence quiesced 1
sed -i 's/message_server_seq_seq_last_value=42/message_server_seq_seq_last_value=41/' \
  "$case_seven/20200101T000000Z-sequence/RESTORE-VERIFIED"
restore_verified_marker_is_valid "$case_seven/20200101T000000Z-sequence" && \
  fail "落后于 messages.server_seq 的序列证据仍被接受"

echo "[backup-retention-test] all cases passed"
