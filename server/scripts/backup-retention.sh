#!/usr/bin/env bash

# 备份目录的安全删除、验证标记判断与保留期轮转。
# 调用方必须先 source backup-table-policy.sh；本文件本身不产生任何副作用。

# 只删除指定父目录的直接子目录；realpath 校验防止 rm 跟随路径跳出备份根。
remove_direct_child_tree() {
  local target="$1" parent="$2" target_real parent_real
  [[ -d "$target" && ! -L "$target" ]] || return 0
  target_real="$(realpath -e -- "$target")"
  parent_real="$(realpath -e -- "$parent")"
  [[ "$(dirname -- "$target_real")" == "$parent_real" ]] || {
    echo "[backup] 拒绝清理越界目录: $target" >&2
    return 1
  }
  rm -rf --one-file-system -- "$target_real"
}

cleanup_stale_partials() {
  local root="$1" candidate
  # 上次进程被 SIGKILL 时 trap 无法运行；仅清除超过一天的固定格式 partial。
  while IFS= read -r -d '' candidate; do
    remove_direct_child_tree "$candidate" "$root"
  done < <(find "$root" -mindepth 1 -maxdepth 1 -type d \
    -name '.partial-20??????T??????Z-*' -mmin +1440 -print0)
}

restore_verified_marker_is_valid() {
  local backup_directory="$1" marker="$1/RESTORE-VERIFIED" sums="$1/SHA256SUMS" metadata="$1/METADATA"
  local marker_mode marker_format marker_backup_id marker_schema marker_consistency marker_sums_hash
  local marker_verification actual_sums_hash
  local line expected_hash separator filename allowed file actual_hash
  declare -A checksum_seen=()
  [[ -f "$marker" && ! -L "$marker" && -f "$sums" && ! -L "$sums" && \
      -f "$metadata" && ! -L "$metadata" ]] || return 1
  marker_mode="$(stat -c '%a' -- "$marker")"
  [[ "$marker_mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$marker_mode & 022) == 0 )) || return 1
  marker_format="$(awk -F= '$1 == "format_version" { print $2; exit }' "$marker")"
  marker_backup_id="$(awk -F= '$1 == "backup_id" { print substr($0, index($0, "=") + 1); exit }' "$marker")"
  marker_schema="$(awk -F= '$1 == "schema_migration_version" { print substr($0, index($0, "=") + 1); exit }' "$marker")"
  marker_consistency="$(awk -F= '$1 == "consistency_mode" { print substr($0, index($0, "=") + 1); exit }' "$marker")"
  marker_sums_hash="$(awk -F= '$1 == "sha256sums_sha256" { print substr($0, index($0, "=") + 1); exit }' "$marker")"
  marker_verification="$(awk -F= '$1 == "verification" { print substr($0, index($0, "=") + 1); exit }' "$marker")"
  actual_sums_hash="$(sha256sum -- "$sums" | awk '{ print $1 }')"
  [[ "$marker_sums_hash" =~ ^[0-9a-f]{64}$ && "$actual_sums_hash" == "$marker_sums_hash" ]] || return 1

  while IFS= read -r line || [[ -n "$line" ]]; do
    ((${#line} >= 67)) || return 1
    expected_hash="${line:0:64}"
    separator="${line:64:2}"
    filename="${line:66}"
    [[ "$expected_hash" =~ ^[0-9a-fA-F]{64}$ && \
        ( "$separator" == "  " || "$separator" == " *" ) ]] || return 1
    allowed=0
    for file in "${BACKUP_CHECKSUM_FILES[@]}"; do
      [[ "$filename" == "$file" ]] && allowed=1
    done
    ((allowed == 1)) || return 1
    [[ -z "${checksum_seen[$filename]+x}" ]] || return 1
    checksum_seen["$filename"]="$expected_hash"
  done < "$sums"
  ((${#checksum_seen[@]} == ${#BACKUP_CHECKSUM_FILES[@]})) || return 1
  for file in "${BACKUP_CHECKSUM_FILES[@]}"; do
    [[ -f "$backup_directory/$file" && ! -L "$backup_directory/$file" && \
        -n "${checksum_seen[$file]+x}" ]] || return 1
    actual_hash="$(sha256sum -- "$backup_directory/$file" | awk '{ print $1 }')"
    [[ "${actual_hash,,}" == "${checksum_seen[$file],,}" ]] || return 1
  done

  [[ "$marker_backup_id" == "$(basename -- "$backup_directory")" && \
      "$marker_schema" =~ ^[1-9][0-9]*$ && \
      "$marker_consistency" =~ ^(quiesced|best_effort)$ && \
      "$(awk -F= '$1 == "backup_id" { print substr($0, index($0, "=") + 1); exit }' "$metadata")" == "$marker_backup_id" && \
      "$(awk -F= '$1 == "schema_migration_version" { print substr($0, index($0, "=") + 1); exit }' "$metadata")" == "$marker_schema" && \
      "$(awk -F= '$1 == "consistency_mode" { print substr($0, index($0, "=") + 1); exit }' "$metadata")" == "$marker_consistency" ]] || \
    return 1

  case "$marker_format" in
    1)
      # 兼容已发布的旧标记；保留它比因格式升级误删 last-known-good 更安全。
      [[ "$marker_verification" == "db_full_restore_media_sample" ]]
      ;;
    2)
      [[ "$marker_verification" == "db_full_restore_all_tables_media_sample_sequences" ]] || return 1
      marker_sequence_evidence_is_valid "$marker" "$marker_schema"
      ;;
    *)
      return 1
      ;;
  esac
}

marker_sequence_evidence_is_valid() {
  local marker="$1" schema_version="$2"
  local message_last message_called message_max sync_last sync_called sync_max evidence_version
  evidence_version="$(awk -F= '$1 == "sequence_validation_version" { print $2; exit }' "$marker")"
  message_last="$(awk -F= '$1 == "message_server_seq_seq_last_value" { print $2; exit }' "$marker")"
  message_called="$(awk -F= '$1 == "message_server_seq_seq_is_called" { print $2; exit }' "$marker")"
  message_max="$(awk -F= '$1 == "messages_server_seq_max" { print $2; exit }' "$marker")"
  sync_last="$(awk -F= '$1 == "sync_event_seq_last_value" { print $2; exit }' "$marker")"
  sync_called="$(awk -F= '$1 == "sync_event_seq_is_called" { print $2; exit }' "$marker")"
  sync_max="$(awk -F= '$1 == "sync_events_seq_max" { print $2; exit }' "$marker")"
  [[ "$evidence_version" == "1" ]] || return 1

  if ((schema_version >= 16)); then
    sequence_state_values_are_safe "$message_last" "$message_called" "$message_max" || return 1
  else
    [[ "$message_last" == "not_applicable" && "$message_called" == "not_applicable" && \
        "$message_max" == "not_applicable" ]] || return 1
  fi
  if ((schema_version >= 17)); then
    sequence_state_values_are_safe "$sync_last" "$sync_called" "$sync_max" || return 1
  else
    [[ "$sync_last" == "not_applicable" && "$sync_called" == "not_applicable" && \
        "$sync_max" == "not_applicable" ]] || return 1
  fi
}

quiesced_restore_verified_marker_is_valid() {
  local backup_directory="$1"
  restore_verified_marker_is_valid "$backup_directory" || return 1
  [[ "$(awk -F= '$1 == "consistency_mode" { print substr($0, index($0, "=") + 1); exit }' \
    "$backup_directory/RESTORE-VERIFIED")" == "quiesced" ]]
}

backup_id_started_epoch() {
  local backup_directory="$1" backup_id timestamp date_text epoch
  backup_id="$(basename -- "$backup_directory")"
  [[ "$backup_id" =~ ^(20[0-9]{6}T[0-9]{6}Z)-[A-Za-z0-9]+$ ]] || return 1
  timestamp="${BASH_REMATCH[1]}"
  date_text="${timestamp:0:4}-${timestamp:4:2}-${timestamp:6:2} ${timestamp:9:2}:${timestamp:11:2}:${timestamp:13:2} UTC"
  epoch="$(date -u -d "$date_text" +%s 2>/dev/null)" || return 1
  [[ "$epoch" =~ ^[0-9]+$ ]] || return 1
  printf '%s\n' "$epoch"
}

# 新备份尚未经过恢复校验时至少保留一份旧备份；best_effort 验证不能替代
# quiesced+RESTORE-VERIFIED，且每个轮转层最后一份后者永远不删除。
# 判龄只使用不可变 backup_id 中的 UTC 时间，写入验证标记不会延长保留期。
prune_expired() {
  local root="$1" days="$2" protected="${3:-}" candidate total_count verified_count
  local quiesced_verified_count minimum_total marker_consistency cutoff_epoch candidate_epoch
  local -a finalized=()
  declare -A verified_by_path=()
  declare -A quiesced_verified_by_path=()
  mapfile -d '' -t finalized < <(find "$root" -mindepth 1 -maxdepth 1 -type d \
    -name '20??????T??????Z-*' -print0 | LC_ALL=C sort -z)
  total_count=${#finalized[@]}
  verified_count=0
  quiesced_verified_count=0
  for candidate in "${finalized[@]}"; do
    if restore_verified_marker_is_valid "$candidate"; then
      verified_by_path["$candidate"]=1
      verified_count=$((verified_count + 1))
      marker_consistency="$(awk -F= '$1 == "consistency_mode" { print substr($0, index($0, "=") + 1); exit }' \
        "$candidate/RESTORE-VERIFIED")"
      if [[ "$marker_consistency" == "quiesced" ]]; then
        quiesced_verified_by_path["$candidate"]=1
        quiesced_verified_count=$((quiesced_verified_count + 1))
      else
        quiesced_verified_by_path["$candidate"]=0
      fi
    else
      verified_by_path["$candidate"]=0
      quiesced_verified_by_path["$candidate"]=0
    fi
  done

  minimum_total=1
  if [[ -n "$protected" && "${verified_by_path[$protected]:-0}" != "1" ]]; then
    minimum_total=2
  fi

  cutoff_epoch="$(date -u -d "$days days ago" +%s 2>/dev/null)" || {
    echo "[backup] 无法计算保留期截止时间: $days days" >&2
    return 1
  }
  for candidate in "${finalized[@]}"; do
    [[ "$candidate" != "$protected" ]] || continue
    if ! candidate_epoch="$(backup_id_started_epoch "$candidate")"; then
      echo "[backup] 无法从 backup_id 判断时间，保守跳过: $candidate" >&2
      continue
    fi
    ((candidate_epoch <= cutoff_epoch)) || continue
    ((total_count > minimum_total)) || break
    if [[ "${verified_by_path[$candidate]:-0}" == "1" ]]; then
      if [[ "${quiesced_verified_by_path[$candidate]:-0}" == "1" ]]; then
        ((quiesced_verified_count > 1)) || continue
      fi
      ((verified_count > 1)) || continue
      remove_direct_child_tree "$candidate" "$root"
      verified_count=$((verified_count - 1))
      if [[ "${quiesced_verified_by_path[$candidate]:-0}" == "1" ]]; then
        quiesced_verified_count=$((quiesced_verified_count - 1))
      fi
    else
      remove_direct_child_tree "$candidate" "$root"
    fi
    total_count=$((total_count - 1))
  done
}
