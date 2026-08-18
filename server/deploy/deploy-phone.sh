#!/usr/bin/env bash
set -Eeuo pipefail

trap 'rc=$?; echo "[deploy-phone] failed line=$LINENO rc=$rc" >&2' ERR

# Deploy the CoupleChat server to the Mi 10 phone (Ubuntu chroot, no Docker).
# Usage:
#   deploy-phone.sh <package.tar.gz> <sha256> <40-hex-commit> [--with-migrations]
#
# The app is supervised by 48-mi10-couplechat.sh. This script swaps the
# release symlink and lets the watchdog restart the process. It never runs
# migrations unless --with-migrations is passed; a pre-migration pg_dump is
# always taken in that case.

APP_DIR="${COUPLECHAT_APP_DIR:-/home/server/apps/couplechat}"
RELEASES_DIR="$APP_DIR/releases"
INCOMING_DIR="$APP_DIR/incoming"
BACKUP_DIR="$APP_DIR/backups"
NODE22="${NODE22_BIN:-/usr/local/node22/bin/node}"
NPM22="${NPM22_BIN:-/usr/local/node22/bin/npm}"
PORT="${COUPLECHAT_PORT:-3000}"
DB_NAME="${COUPLECHAT_DB_NAME:-couplechat}"
LOCK_FILE="$APP_DIR/.deploy.lock"
PUBLIC_BASE_URL="${COUPLECHAT_PUBLIC_BASE_URL:-}"
WATCHDOG_WAIT_SECONDS="${COUPLECHAT_WATCHDOG_WAIT_SECONDS:-120}"
APP_LOG="${COUPLECHAT_APP_LOG:-/home/server/logs/couplechat.log}"
PGBIN="${PGBIN:-/usr/local/pg16/bin}"
PGDATA="${PGDATA:-/var/lib/postgresql/16/main}"
PGLOG="${PGLOG:-/tmp/postgresql-16-main.log}"
PG_SHIM="${PG_SHIM:-/usr/local/pg16/lib/shm-shim.so}"
export PATH="$PGBIN:$PATH"
WITH_MIGRATIONS=0

usage() {
  echo "用法: deploy-phone.sh <tar.gz> <sha256> <40位commit> [--with-migrations]" >&2
  exit 2
}

die() {
  echo "[deploy-phone] $*" >&2
  exit 2
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

[[ $# -ge 3 && $# -le 4 ]] || usage
package_input="$1"
expected_hash="${2,,}"
target_sha="${3,,}"
[[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] || die "SHA-256 格式无效"
[[ "$target_sha" =~ ^[0-9a-f]{40}$ ]] || die "commit 必须是完整小写 SHA"
if [[ $# -eq 4 ]]; then
  [[ "$4" == "--with-migrations" ]] || usage
  WITH_MIGRATIONS=1
fi

for command in awk curl date dirname env flock install kill ln mkdir mv pg_isready pgrep printf readlink rm sed seq setsid sha256sum sleep stat sudo tar test tr; do
  require_command "$command"
done

# --- 函数 ----------------------------------------------------------------
stop_current_app() {
  local pattern="node --env-file=$APP_DIR/.env dist/server.js"
  local pid="" app_pids=""

  # PID 文件指向 setsid/chroot 包装进程，不一定等于 node 本身；
  # 先礼貌终止包装进程，再用精确 cmdline 匹配真正的 node 进程。
  if [[ -f /run/couplechat.pid ]]; then
    pid="$(tr -d '[:space:]' < /run/couplechat.pid 2>/dev/null || true)"
  fi
  if [[ -n "$pid" ]] && [[ -r "/proc/$pid/cmdline" ]]; then
    kill -TERM "$pid" 2>/dev/null || true
  fi

  app_pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
  if [[ -n "$app_pids" ]]; then
    kill -TERM $app_pids 2>/dev/null || true
    for i in $(seq 1 15); do
      pgrep -f "$pattern" >/dev/null 2>&1 || break
      sleep 1
    done
    app_pids="$(pgrep -f "$pattern" 2>/dev/null || true)"
    if [[ -n "$app_pids" ]]; then
      kill -KILL $app_pids 2>/dev/null || true
    fi
  fi
}

ensure_app_running() {
  # 看护进程（Android service.d 48 号）不在时直接拉起，保证首次发布可用；
  # 看护在时由它负责在 10s 内重启（部署只停不启）。
  if ! pgrep -f "48-mi10-couplechat.sh --watch" >/dev/null 2>&1; then
    echo "[deploy-phone] watchdog not running; starting app directly" >&2
    install -d -m 0755 "$(dirname "$APP_LOG")"
    setsid env NODE_ENV=production HOST=127.0.0.1 PORT="$PORT" \
      "$NODE22" --env-file="$APP_DIR/.env" dist/server.js \
      </dev/null >>"$APP_LOG" 2>&1 &
  fi
}

wait_local_health() {
  local attempt
  for attempt in $(seq 1 "$WATCHDOG_WAIT_SECONDS"); do
    if curl -fsS "http://127.0.0.1:$PORT/live" >/dev/null 2>&1 && \
       curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && \
       curl -fsS "http://127.0.0.1:$PORT/ready" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

verify_business() {
  local accounts socket_response
  accounts="$(curl -fsS "http://127.0.0.1:$PORT/api/accounts")"
  printf '%s' "$accounts" | "$NODE22" -e '
    let body = "";
    process.stdin.on("data", (c) => (body += c));
    process.stdin.on("end", () => {
      const names = JSON.parse(body).map((x) => x.username).join(",");
      if (names !== "xu,si") process.exit(1);
    });
  '
  socket_response="$(curl -fsS "http://127.0.0.1:$PORT/socket.io/?EIO=4&transport=polling&t=$(date +%s)")"
  [[ "$socket_response" == 0\{* ]] || die "socket.io 握手失败"
}

verify_public() {
  local path accounts socket_response
  for path in live health ready; do
    curl -fsS "$PUBLIC_BASE_URL/$path" >/dev/null
  done
  accounts="$(curl -fsS "$PUBLIC_BASE_URL/api/accounts")"
  printf '%s' "$accounts" | "$NODE22" -e '
    let body = "";
    process.stdin.on("data", (c) => (body += c));
    process.stdin.on("end", () => {
      const names = JSON.parse(body).map((x) => x.username).join(",");
      if (names !== "xu,si") process.exit(1);
    });
  '
  socket_response="$(curl -fsS "$PUBLIC_BASE_URL/socket.io/?EIO=4&transport=polling&t=$(date +%s)")"
  [[ "$socket_response" == 0\{* ]] || die "公网 socket.io 握手失败"
}
install -d -m 0755 "$INCOMING_DIR" "$BACKUP_DIR"
exec 9>"$LOCK_FILE"
flock -n 9 || die "另一个部署正在运行"

# --- 包校验 ---------------------------------------------------------------
[[ -f "$package_input" && ! -L "$package_input" ]] || die "发布包必须是普通文件"
[[ "$(stat -c '%U:%G' -- "$package_input")" == "server:server" ]] || die "发布包必须由 server:server 拥有"
package_mode="$(stat -c '%a' -- "$package_input")"
if (( (8#$package_mode & 022) != 0 )); then
  die "发布包不能允许 group/other 写入"
fi
actual_hash="$(sha256sum -- "$package_input" | awk '{print $1}')"
[[ "$actual_hash" == "$expected_hash" ]] || die "发布包 SHA-256 不匹配"

[[ -f "$APP_DIR/.env" && ! -L "$APP_DIR/.env" ]] || die "$APP_DIR/.env 缺失或不是普通文件"
[[ -d "$APP_DIR/uploads" && -d "$APP_DIR/.data" ]] || die "uploads/.data 目录缺失（先按迁移文档初始化）"

# --- 数据库必须可用 -------------------------------------------------------
if ! "$PGBIN/pg_isready" -h 127.0.0.1 -p 5432 -q; then
  echo "[deploy-phone] postgres not ready; starting cluster"
  sudo -u postgres env LD_PRELOAD="$PG_SHIM" "$PGBIN/pg_ctl" -D "$PGDATA" -l "$PGLOG" -o "-p 5432" start
  for i in $(seq 1 30); do
    "$PGBIN/pg_isready" -h 127.0.0.1 -p 5432 -q && break
    sleep 1
  done
  "$PGBIN/pg_isready" -h 127.0.0.1 -p 5432 -q || die "postgres 启动失败"
fi

"$NODE22" --version 2>/dev/null | grep -q '^v22\.' || die "需要 Node.js 22（$NODE22）"

# --- 解包与构建 -----------------------------------------------------------
release_dir="$RELEASES_DIR/$target_sha"
if [[ -e "$release_dir" ]]; then
  die "该 commit 已存在: $release_dir（如需重发先手工移除）"
fi
install -d -m 0755 "$release_dir"
tar -xzf "$package_input" -C "$release_dir"
[[ -f "$release_dir/package.json" ]] || die "发布包不是 server 目录归档"
chown -R server:server "$release_dir"

cd "$release_dir"
export PATH="$(dirname "$NODE22"):$PATH"
"$NPM22" ci --no-audit --no-fund
"$NPM22" run build
"$NPM22" prune --omit=dev
[[ -f "$release_dir/dist/server.js" ]] || die "构建未产出 dist/server.js"

# --- 可选：带 migration 发布 ---------------------------------------------
if [[ "$WITH_MIGRATIONS" -eq 1 ]]; then
  backup_file="$BACKUP_DIR/pre-${target_sha}-$(date +%Y%m%d-%H%M%S).dump"
  sudo -n -u postgres env PATH="$PGBIN:$PATH" pg_dump -h /var/run/postgresql -Fc "$DB_NAME" > "$backup_file"
  [[ -s "$backup_file" ]] || die "迁移前备份失败"
  echo "[deploy-phone] pre-migration dump: $backup_file"
  # .env 在 APP_DIR（release 目录外），用 --env-file 直调受控 migrator
  "$NODE22" --env-file="$APP_DIR/.env" dist/migrate.js
fi

# --- 切换与重启 -----------------------------------------------------------
previous_target="$(readlink "$APP_DIR/server" 2>/dev/null || true)"
ln -sfn "$release_dir" "$APP_DIR/server"
stop_current_app
ensure_app_running
printf '%s\n' "$target_sha" > "$APP_DIR/RELEASE.tmp"
chown server:server "$APP_DIR/RELEASE.tmp"
mv -f "$APP_DIR/RELEASE.tmp" "$APP_DIR/RELEASE"

if ! wait_local_health; then
  echo "[deploy-phone] 健康检查失败；回滚到 $previous_target" >&2
  if [[ -n "$previous_target" ]]; then
    ln -sfn "$previous_target" "$APP_DIR/server"
  fi
  stop_current_app
  ensure_app_running
  sleep 2
  wait_local_health || echo "[deploy-phone] 回滚后健康仍未恢复，请检查 couplechat.log" >&2
  exit 2
fi

# --- 业务层校验 -----------------------------------------------------------
verify_business

if [[ -n "$PUBLIC_BASE_URL" ]]; then
  verify_public
fi

echo "[deploy-phone] release=$target_sha ok"

