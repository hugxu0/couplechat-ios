#!/usr/bin/env bash
set -Eeuo pipefail

# Fast production deploy for ordinary code changes. This script never runs a
# migration and never creates or restores a backup.

ACTIVE_DIR="${COUPLECHAT_SERVER_DIR:-/opt/couplechat-ios/server}"
DEPLOY_ROOT="${COUPLECHAT_DEPLOY_ROOT:-/opt/couplechat}"
INCOMING_DIR="$DEPLOY_ROOT/incoming"
RELEASES_DIR="$DEPLOY_ROOT/releases"
BIN_DIR="$DEPLOY_ROOT/bin"
BACKUP_ROOT="${COUPLECHAT_BACKUP_ROOT:-/var/backups/couplechat}"
LOCK_FILE="${COUPLECHAT_DEPLOY_LOCK:-/run/lock/couplechat-deploy.lock}"
PUBLIC_BASE_URL="${COUPLECHAT_PUBLIC_BASE_URL:-https://hoo66.top}"
ORIGIN_BASE_URL="${COUPLECHAT_ORIGIN_BASE_URL:-https://chat.huhuhu.top}"
IMAGE_REPOSITORY="couplechat-server"
COMPOSE_OVERRIDE="compose.release.override.yml"
umask 077

die() {
  echo "[deploy] $*" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

usage() {
  echo "用法: deploy-server /opt/couplechat/incoming/server.tar.gz <sha256> <40位commit>" >&2
  exit 2
}

[[ $# -eq 3 ]] || usage
[[ $EUID -eq 0 ]] || die "必须以 root 执行"
package_input="$1"
expected_hash="${2,,}"
target_sha="${3,,}"
[[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || die "SHA-256 格式无效"
[[ "$target_sha" =~ ^[0-9a-f]{40}$ ]] || die "commit 必须是完整小写 SHA"

for command in awk basename chmod chown cp curl date df dirname docker find flock grep head install mkdir mktemp mv node realpath rm sed seq sha256sum sleep sort stat tar touch tr; do
  require_command "$command"
done

install -d -m 0700 -o root -g root "$INCOMING_DIR" "$RELEASES_DIR"
install -d -m 0755 -o root -g root "$BIN_DIR"
touch "$LOCK_FILE"
chmod 0600 "$LOCK_FILE"
exec 9>"$LOCK_FILE"
flock -n 9 || die "另一个发布正在运行"

incoming_real="$(realpath -e -- "$INCOMING_DIR")"
package="$(realpath -e -- "$package_input")"
[[ "$package" == "$incoming_real/"* ]] || die "发布包必须位于 $INCOMING_DIR"
[[ -f "$package" && ! -L "$package" ]] || die "发布包必须是普通文件"
[[ "$(stat -c '%U:%G' -- "$package")" == "root:root" ]] || die "发布包必须由 root 拥有"
package_mode="$(stat -c '%a' -- "$package")"
(( (8#$package_mode & 022) == 0 )) || die "发布包不能允许 group/other 写入"
actual_hash="$(sha256sum -- "$package" | awk '{print $1}')"
[[ "$actual_hash" == "$expected_hash" ]] || die "发布包 SHA-256 不匹配"

active_real="$(realpath -e -- "$ACTIVE_DIR")"
[[ "$active_real" == "/opt/couplechat-ios/server" ]] || die "生产目录不符合固定边界"
[[ -f "$ACTIVE_DIR/.env" && ! -L "$ACTIVE_DIR/.env" ]] || die ".env 缺失或不是普通文件"
[[ "$(stat -c '%a %U:%G' -- "$ACTIVE_DIR/.env")" == "600 root:root" ]] || die ".env 必须为 0600 root:root"
for state_path in uploads .data; do
  [[ -d "$ACTIVE_DIR/$state_path" && ! -L "$ACTIVE_DIR/$state_path" ]] || die "$state_path 缺失或不安全"
done
[[ -f "$ACTIVE_DIR/RELEASE" && ! -L "$ACTIVE_DIR/RELEASE" ]] || die "RELEASE 缺失或不安全"
current_sha="$(tr -d '\r\n' < "$ACTIVE_DIR/RELEASE")"
[[ "$current_sha" =~ ^[0-9a-f]{40}$ ]] || die "当前 RELEASE 不是完整 SHA"
docker inspect couplechat-server >/dev/null 2>&1 || die "当前容器不存在"
[[ "$(docker inspect couplechat-server --format '{{.State.Status}}')" == "running" ]] || die "当前容器未运行"
find "$BACKUP_ROOT" -maxdepth 3 -name RESTORE-VERIFIED -type f -print -quit 2>/dev/null | grep -q . || \
  die "现行恢复验证基线不存在"
available_kb="$(df -Pk "$DEPLOY_ROOT" | awk 'NR==2 {print $4}')"
(( available_kb >= 1048576 )) || die "部署目录可用空间不足 1 GiB"

schema_version() {
  docker exec couplechat-server node -e '
    const {Client}=require("pg");
    (async()=>{const c=new Client({connectionString:process.env.DATABASE_URL});
    await c.connect();const r=await c.query("select max(version)::text from schema_migrations");
    process.stdout.write(r.rows[0].max);await c.end()})().catch(()=>process.exit(2));'
}

wait_local_health() {
  local attempt
  for attempt in $(seq 1 45); do
    if curl -fsS http://127.0.0.1:3000/live >/dev/null 2>&1 && \
       curl -fsS http://127.0.0.1:3000/health >/dev/null 2>&1 && \
       curl -fsS http://127.0.0.1:3000/ready >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

proxy_key="$(
  grep -Rhs 'http_x_couplechat_proxy_key' /etc/nginx/sites-enabled 2>/dev/null \
    | sed -nE 's/.*http_x_couplechat_proxy_key[[:space:]]*!=[[:space:]]*"([^"]+)".*/\1/p' \
    | head -n1
)"
[[ -n "$proxy_key" ]] || die "无法从 root-only Nginx 配置读取 origin 校验值"

check_external_health() {
  local path status accounts socket_response
  for path in live health ready; do
    curl -fsS "$PUBLIC_BASE_URL/$path" >/dev/null
  done
  curl -fsS "$ORIGIN_BASE_URL/health" -H "X-CoupleChat-Proxy-Key: $proxy_key" >/dev/null
  status="$(curl -sS -o /dev/null -w '%{http_code}' "$ORIGIN_BASE_URL/health")"
  [[ "$status" == "403" ]] || return 1
  accounts="$(curl -fsS "$PUBLIC_BASE_URL/api/accounts")"
  printf '%s' "$accounts" | node -e '
    let body="";process.stdin.on("data",c=>body+=c).on("end",()=>{
    const names=JSON.parse(body).map(x=>x.username).join(",");
    if(names!=="xu,si")process.exit(1);});'
  socket_response="$(curl -fsS "$PUBLIC_BASE_URL/socket.io/?EIO=4&transport=polling&t=$(date +%s)")"
  [[ "$socket_response" == 0\{* ]]
}

wait_local_health || die "发布前本机健康检查失败"
schema_before="$(schema_version)"
check_external_health || die "发布前三层健康检查失败"

if [[ "$current_sha" == "$target_sha" ]]; then
  rm -f -- "$package"
  echo "[deploy] release=$target_sha schema=$schema_before deploy_seconds=0 already_current=true"
  exit 0
fi

work_dir="$(mktemp -d "$RELEASES_DIR/.deploy-${target_sha:0:12}-XXXXXX")"
candidate="$work_dir/candidate"
source_backup="$work_dir/active-source.tar.gz"
previous_override="$work_dir/previous-override.yml"
mkdir -m 0700 "$candidate"
switched=0
source_sync_started=0
had_previous_override=0
success=0
start_epoch="$(date +%s)"

clear_active_source() {
  local item name
  while IFS= read -r -d '' item; do
    name="$(basename -- "$item")"
    case "$name" in
      .env|uploads|.data) continue ;;
    esac
    rm -rf -- "$item"
  done < <(find "$ACTIVE_DIR" -mindepth 1 -maxdepth 1 -print0)
}

rollback() {
  echo "[deploy] 候选失败，恢复 $current_sha" >&2
  if (( source_sync_started == 1 )); then
    clear_active_source
    tar -xzf "$source_backup" -C "$ACTIVE_DIR"
  elif (( had_previous_override == 1 )); then
    cp -a -- "$previous_override" "$ACTIVE_DIR/$COMPOSE_OVERRIDE"
  else
    rm -f -- "$ACTIVE_DIR/$COMPOSE_OVERRIDE"
  fi
  docker compose -f "$ACTIVE_DIR/compose.production.yml" -f "$ACTIVE_DIR/$COMPOSE_OVERRIDE" \
    --project-directory "$ACTIVE_DIR" up -d --no-build --force-recreate >/dev/null 2>&1 || true
  wait_local_health || echo "[deploy] 回滚后本机健康检查仍失败" >&2
}

finish() {
  local rc=$?
  trap - EXIT
  set +e
  if (( rc != 0 && switched == 1 && success == 0 )); then
    rollback
  fi
  [[ ! -e "$work_dir" || "$(realpath -m -- "$work_dir")" == "$RELEASES_DIR/"* ]] && rm -rf -- "$work_dir"
  [[ ! -e "$package" || "$package" == "$incoming_real/"* ]] && rm -f -- "$package"
  exit "$rc"
}
trap finish EXIT

while IFS= read -r archive_entry; do
  entry="${archive_entry#./}"
  [[ -n "$entry" ]] || continue
  [[ "$entry" != /* && "$entry" != *$'\n'* && "$entry" != *$'\r'* ]] || die "发布包包含不安全路径"
  case "/$entry/" in *"/../"*|*"/./"*) die "发布包包含路径穿越" ;; esac
  top="${entry%%/*}"
  top="${top%/}"
  case "$top" in .env|.data|uploads|RELEASE|.release-commit|compose.release.override.yml) die "发布包包含保留路径: $top" ;; esac
done < <(tar -tzf "$package")

tar -xzf "$package" -C "$candidate" --no-same-owner
unsafe_entry="$(find "$candidate" \( -type l -o \( ! -type f ! -type d \) \) -print -quit)"
[[ -z "$unsafe_entry" ]] || die "候选目录包含符号链接或特殊文件"
for required in Dockerfile compose.production.yml package.json package-lock.json src assets deploy/deploy-server.sh; do
  [[ -e "$candidate/$required" ]] || die "候选缺少 $required"
done

new_image="$IMAGE_REPOSITORY:$target_sha"
current_image_id="$(docker inspect couplechat-server --format '{{.Image}}')"
rollback_image="$IMAGE_REPOSITORY:rollback-$current_sha"

echo "[deploy] build=$target_sha"
DOCKER_BUILDKIT=1 docker build --pull=false --label "couplechat.release=$target_sha" -t "$new_image" "$candidate"
docker image inspect "$new_image" >/dev/null
docker tag "$current_image_id" "$rollback_image"

tar --exclude='./.env' --exclude='./uploads' --exclude='./.data' -czf "$source_backup" -C "$ACTIVE_DIR" .
if [[ -f "$ACTIVE_DIR/$COMPOSE_OVERRIDE" ]]; then
  cp -a -- "$ACTIVE_DIR/$COMPOSE_OVERRIDE" "$previous_override"
  had_previous_override=1
fi

override_tmp="$ACTIVE_DIR/.${COMPOSE_OVERRIDE}.tmp"
printf 'services:\n  couplechat-server:\n    image: %s\n    environment:\n      RUN_MIGRATIONS: "false"\n' "$new_image" > "$override_tmp"
chmod 0600 "$override_tmp"
switched=1
mv -f -- "$override_tmp" "$ACTIVE_DIR/$COMPOSE_OVERRIDE"
docker compose -f "$ACTIVE_DIR/compose.production.yml" -f "$ACTIVE_DIR/$COMPOSE_OVERRIDE" \
  --project-directory "$ACTIVE_DIR" up -d --no-build --force-recreate

wait_local_health || die "候选本机健康检查失败"
schema_after="$(schema_version)"
[[ "$schema_after" == "$schema_before" ]] || die "普通发布改变了 schema"
check_external_health || die "候选三层健康检查失败"

source_sync_started=1
clear_active_source
cp -a -- "$candidate"/. "$ACTIVE_DIR"/
printf 'services:\n  couplechat-server:\n    image: %s\n    environment:\n      RUN_MIGRATIONS: "false"\n' "$new_image" > "$ACTIVE_DIR/$COMPOSE_OVERRIDE"
printf '%s\n' "$target_sha" > "$ACTIVE_DIR/.release-commit"
printf '%s\n' "$target_sha" > "$ACTIVE_DIR/RELEASE"
chmod 0600 "$ACTIVE_DIR/$COMPOSE_OVERRIDE" "$ACTIVE_DIR/.release-commit" "$ACTIVE_DIR/RELEASE"
install -m 0750 -o root -g root "$candidate/deploy/deploy-server.sh" "$BIN_DIR/deploy-server"

docker tag "$new_image" "$IMAGE_REPOSITORY:local"
while IFS= read -r image_ref; do
  case "$image_ref" in
    "$new_image"|"$IMAGE_REPOSITORY:local"|"$rollback_image") continue ;;
    "$IMAGE_REPOSITORY:"*) docker image rm "$image_ref" >/dev/null 2>&1 || true ;;
  esac
done < <(docker image ls --format '{{.Repository}}:{{.Tag}}' | LC_ALL=C sort -u)

success=1
elapsed="$(( $(date +%s) - start_epoch ))"
echo "[deploy] release=$target_sha previous=$current_sha schema=$schema_after deploy_seconds=$elapsed"
