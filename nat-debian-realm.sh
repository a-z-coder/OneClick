#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  fi
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache bash || exit 1
    exec bash "$0" "$@"
  fi
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update || exit 1
    DEBIAN_FRONTEND=noninteractive apt-get install -y bash || exit 1
    exec bash "$0" "$@"
  fi
  echo "[失败] 当前系统没有 Bash，也找不到 apk 或 apt-get" >&2
  exit 1
fi

set -Eeuo pipefail
umask 077

SCRIPT_VERSION="1.0.2"
SERVICE_NAME="nat-debian-realm"
INSTALL_ROOT="/etc/realm/nat-debian-realm"
CONFIG_PATH="$INSTALL_ROOT/config.toml"
STATE_PATH="$INSTALL_ROOT/state.conf"
MANIFEST_PATH="$INSTALL_ROOT/managed-by-nat-debian-realm"
REALM_BIN="/usr/local/bin/nat-debian-realm"
SYSTEMD_UNIT="/etc/systemd/system/${SERVICE_NAME}.service"
OPENRC_UNIT="/etc/init.d/${SERVICE_NAME}"
PID_FILE="/run/${SERVICE_NAME}.pid"
LOG_FILE="/var/log/${SERVICE_NAME}.log"
ERROR_LOG_FILE="/var/log/${SERVICE_NAME}.err"
BACKUP_ROOT="$INSTALL_ROOT/backups"

TMP_DIR=""
SERVICE_MODE=""
PACKAGE_MANAGER=""
CONFIG_INPUT=""
ENTRY_ADDRESS=""
ENTRY_PORT=""
LISTEN_MODE="DUAL"
REMOTE_ADDRESS=""
REMOTE_PORT=""
REALM_VERSION=""
LISTEN_ENDPOINT=""
STAGED_REALM_BIN=""
ROLLBACK_DIR=""
TRANSACTION_ACTIVE=0
HAD_INSTALL=0
ROOT_EXISTED=0
WAS_ACTIVE=0
WAS_ENABLED=0
KEEP_TMP=0
CREATED_REALM_PARENT=0

MANAGED_PATHS=("$CONFIG_PATH" "$STATE_PATH" "$REALM_BIN" "$SYSTEMD_UNIT" "$OPENRC_UNIT" "$MANIFEST_PATH")
BACKUP_NAMES=(config.toml state.conf realm-bin systemd.service openrc managed-marker)

cleanup() {
  local result=$?
  trap - EXIT HUP INT TERM
  if (( TRANSACTION_ACTIVE == 1 )); then
    warn "部署未完成，开始恢复修改前的文件和服务状态"
    if restore_existing_deployment; then
      ok "已恢复修改前的部署状态"
    else
      KEEP_TMP=1
      warn "恢复未完成，备份保留在：$ROLLBACK_DIR；请检查服务状态"
    fi
    (( result != 0 )) || result=1
  fi
  if (( KEEP_TMP == 0 )) && [[ "$TMP_DIR" == /tmp/nat-debian-realm.* && -d "$TMP_DIR" && ! -L "$TMP_DIR" ]]; then
    rm -rf -- "$TMP_DIR" || result=1
  fi
  exit "$result"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

die() { printf '[失败] %s\n' "$*" >&2; exit 1; }
info() { printf '[信息] %s\n' "$*"; }
ok() { printf '[成功] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

trim_value() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "$value"
}

normalize_host() {
  local value="$1"
  if [[ "$value" == \[*\] ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

validate_port() {
  local label="$1" value="$2"
  [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] || die "$label 必须是 1 到 65535 的十进制整数"
  (( value <= 65535 )) || die "$label 超出范围：$value"
}

validate_ipv4() {
  local value="$1" octet
  local -a octets=()
  [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r -a octets <<< "$value"
  for octet in "${octets[@]}"; do
    [[ "$octet" == 0 || "$octet" != 0* ]] || return 1
    (( 10#$octet <= 255 )) || return 1
  done
  return 0
}

validate_ipv6() {
  local value="$1" rest group ipv4_tail count=0
  if [[ "$value" == *.* ]]; then
    ipv4_tail="${value##*:}"
    validate_ipv4 "$ipv4_tail" || return 1
    # An embedded IPv4 address occupies two IPv6 groups.
    value="${value%:*}:0:0"
  fi
  [[ "$value" == *:* && "$value" =~ ^[0-9A-Fa-f:]+$ && "$value" != *:::* ]] || return 1
  [[ "$value" != :* || "$value" == ::* ]] || return 1
  [[ "$value" != *: || "$value" == *:: ]] || return 1
  [[ "$value" != *::* || "${value#*::}" != *::* ]] || return 1
  rest="$value"
  while [[ -n "$rest" ]]; do
    if [[ "$rest" == *:* ]]; then
      group="${rest%%:*}"
      rest="${rest#*:}"
    else
      group="$rest"
      rest=""
    fi
    if [[ -n "$group" ]]; then
      [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
      count=$((count + 1))
    fi
  done
  if [[ "$value" == *::* ]]; then
    (( count < 8 ))
  else
    (( count == 8 ))
  fi
}

validate_hostname() {
  local value="$1" part
  local -a parts=()
  value="${value%.}"
  (( ${#value} >= 1 && ${#value} <= 253 )) || return 1
  # Do not let invalid numeric IPv4 addresses fall through as hostnames.
  [[ ! "$value" =~ ^[0-9.]+$ ]] || return 1
  [[ "$value" == *.* ]] || return 1
  [[ "$value" != *..* && "$value" != .* && "$value" != *. ]] || return 1
  IFS='.' read -r -a parts <<< "$value"
  for part in "${parts[@]}"; do
    (( ${#part} >= 1 && ${#part} <= 63 )) || return 1
    [[ "$part" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
  done
  return 0
}

validate_host() {
  local label="$1" value
  value="$(normalize_host "$2")"
  [[ -n "$value" ]] || die "$label 不能为空"
  if [[ "$2" == *\[* || "$2" == *\]* ]]; then
    [[ "$2" == \[*\] ]] && validate_ipv6 "$value" || die "$label 的方括号只能包裹 IPv6 地址"
    return 0
  fi
  if validate_ipv4 "$value" || validate_ipv6 "$value" || validate_hostname "$value"; then
    return
  fi
  die "$label 必须是 IPv4、IPv6 或完整域名：$2"
}

format_host_port() {
  local host
  host="$(normalize_host "$1")"
  if validate_ipv6 "$host"; then
    printf '[%s]:%s' "$host" "$2"
  else
    printf '%s:%s' "$host" "$2"
  fi
}

detect_platform() {
  if command_exists systemctl && [[ -d /run/systemd/system ]]; then
    SERVICE_MODE="systemd"
  elif command_exists rc-service && command_exists rc-update; then
    SERVICE_MODE="openrc"
  else
    die "未找到可用的 systemd 或 OpenRC 服务管理器"
  fi

  if command_exists apk; then
    PACKAGE_MANAGER="apk"
  elif command_exists apt-get; then
    PACKAGE_MANAGER="apt"
  else
    die "未找到支持的 apk 或 apt-get 软件包管理器"
  fi
}

install_dependencies() {
  local missing=0 tool
  for tool in curl jq tar sha256sum install readlink env ss; do
    command_exists "$tool" || missing=1
  done
  [[ -s /etc/ssl/certs/ca-certificates.crt ]] || missing=1
  if (( missing == 0 )); then
    return 0
  fi

  info "安装 Realm 部署所需的基础工具"
  if [[ "$PACKAGE_MANAGER" == apk ]]; then
    apk add --no-cache curl ca-certificates jq tar coreutils iproute2-ss || die "Alpine 依赖安装失败"
  else
    apt-get update || die "APT 软件源更新失败"
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends curl ca-certificates jq tar coreutils iproute2 || die "Debian 依赖安装失败"
  fi
  for tool in curl jq tar sha256sum install readlink env ss; do
    command_exists "$tool" || die "依赖安装后仍缺少必需工具：$tool"
  done
  return 0
}

read_config() {
  local line key value
  declare -A values=()
  printf '请一次性粘贴完整的 Realm 配置块：\n' >&2
  CONFIG_INPUT="$(awk '
    { sub(/\r$/, "") }
    $0 == "YIjian_REALM_CONFIG_BEGIN" { started=1; next }
    $0 == "YIjian_REALM_CONFIG_END" { if (started) finished=1; exit }
    started && $0 != "```" { print }
    END { if (!started || !finished) exit 1 }
  ')" || die "配置必须包含 YIjian_REALM_CONFIG_BEGIN 和 YIjian_REALM_CONFIG_END"
  [[ -n "$CONFIG_INPUT" ]] || die "配置不能为空"

  while IFS= read -r line; do
    line="$(trim_value "$line")"
    [[ -z "$line" || "$line" == \#* ]] && continue
    [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]] || die "无法识别的配置行：$line"
    key="${BASH_REMATCH[1]}"
    value="$(trim_value "${BASH_REMATCH[2]}")"
    case "$key" in
      ENTRY_ADDRESS|ENTRY_PORT|LISTEN_MODE|REMOTE_ADDRESS|REMOTE_PORT) ;;
      *) die "未知配置项：$key" ;;
    esac
    [[ -z "${values[$key]+x}" ]] || die "配置项重复：$key"
    values["$key"]="$value"
  done <<< "$CONFIG_INPUT"

  ENTRY_ADDRESS="${values[ENTRY_ADDRESS]:-}"
  ENTRY_PORT="${values[ENTRY_PORT]:-}"
  LISTEN_MODE="${values[LISTEN_MODE]:-DUAL}"
  REMOTE_ADDRESS="${values[REMOTE_ADDRESS]:-}"
  REMOTE_PORT="${values[REMOTE_PORT]:-}"
  LISTEN_MODE="${LISTEN_MODE^^}"

  [[ -n "$ENTRY_ADDRESS" ]] || die "缺少 ENTRY_ADDRESS（线路机入口地址）"
  [[ -n "$ENTRY_PORT" ]] || die "缺少 ENTRY_PORT（线路机入口端口）"
  [[ -n "$REMOTE_ADDRESS" ]] || die "缺少 REMOTE_ADDRESS（落地机地址）"
  [[ -n "$REMOTE_PORT" ]] || die "缺少 REMOTE_PORT（落地机端口）"
}

validate_config() {
  validate_host "线路机入口地址 ENTRY_ADDRESS" "$ENTRY_ADDRESS"
  validate_port "线路机入口端口 ENTRY_PORT" "$ENTRY_PORT"
  validate_host "落地机地址 REMOTE_ADDRESS" "$REMOTE_ADDRESS"
  validate_port "落地机端口 REMOTE_PORT" "$REMOTE_PORT"
  case "$LISTEN_MODE" in
    IPV4|IPV6|DUAL) ;;
    *) die "LISTEN_MODE 只能是 IPV4、IPV6 或 DUAL" ;;
  esac
  if [[ "$LISTEN_MODE" == IPV6 ]] && ! ipv6_available; then
    die "LISTEN_MODE=IPV6，但当前系统未启用 IPv6 或没有 IPv6 地址记录"
  fi
  if [[ "$LISTEN_MODE" == DUAL ]] && ! ipv6_available; then
    warn "当前系统未启用 IPv6 或没有 IPv6 地址记录，DUAL 将使用 IPv4 监听"
  fi
  LISTEN_ENDPOINT="$(listen_endpoint)"
  return 0
}

ensure_install_ownership() {
  local path marker contents
  command_exists readlink || die "缺少 readlink，无法安全核对服务和进程归属"
  [[ ! -L /etc/realm && ! -L "$INSTALL_ROOT" && ! -L "$BACKUP_ROOT" ]] || die "管理目录不能是符号链接"
  [[ ! -e "$INSTALL_ROOT" || -d "$INSTALL_ROOT" ]] || die "$INSTALL_ROOT 不是目录"
  [[ ! -e "$BACKUP_ROOT" || -d "$BACKUP_ROOT" ]] || die "$BACKUP_ROOT 不是目录"
  for path in "${MANAGED_PATHS[@]}" "$PID_FILE" "$LOG_FILE" "$ERROR_LOG_FILE"; do
    [[ ! -L "$path" ]] || die "拒绝操作符号链接：$path"
    [[ ! -e "$path" || -f "$path" ]] || die "目标不是普通文件：$path"
  done
  HAD_INSTALL=0
  ROOT_EXISTED=0
  if [[ -d "$INSTALL_ROOT" ]]; then ROOT_EXISTED=1; fi
  if [[ -f "$MANIFEST_PATH" ]]; then
    marker="$(< "$MANIFEST_PATH")"
    [[ "$marker" =~ ^nat-debian-realm\ [0-9]+\.[0-9]+\.[0-9]+$ ]] || die "管理标记内容无效，拒绝覆盖或卸载"
    HAD_INSTALL=1
  else
    for path in "${MANAGED_PATHS[@]}" "$PID_FILE" "$LOG_FILE" "$ERROR_LOG_FILE"; do
      [[ ! -e "$path" ]] || die "$path 已存在且不属于本脚本"
    done
    if [[ -d "$INSTALL_ROOT" ]]; then
      contents="$(find "$INSTALL_ROOT" -mindepth 1 -print -quit)" || die "无法检查管理目录，拒绝覆盖"
      [[ -z "$contents" ]] || die "$INSTALL_ROOT 已存在且不属于本脚本"
    fi
  fi
  if [[ -f "$SYSTEMD_UNIT" ]]; then
    grep -Fxq "Description=nat-debian-realm TCP relay" "$SYSTEMD_UNIT" &&
      grep -Fxq "ExecStart=$REALM_BIN -c $CONFIG_PATH" "$SYSTEMD_UNIT" || die "systemd 服务文件不属于本脚本"
  fi
  if [[ -f "$OPENRC_UNIT" ]]; then
    grep -Fxq "command=\"$REALM_BIN\"" "$OPENRC_UNIT" &&
      grep -Fxq "command_args=\"-c $CONFIG_PATH\"" "$OPENRC_UNIT" || die "OpenRC 服务文件不属于本脚本"
  fi
  check_autostart_links || die "存在指向其他服务的同名自启动文件"
  return 0
}

install_realm() {
  local arch libc release_json asset_name asset_url asset_digest
  local archive extract_dir actual_digest realm_file

  case "$(uname -m)" in
    x86_64|amd64) arch="x86_64" ;;
    aarch64|arm64) arch="aarch64" ;;
    *) die "当前架构不受支持：$(uname -m)，目前支持 x86_64 和 aarch64" ;;
  esac
  if [[ -f /etc/alpine-release ]]; then
    libc="musl"
  else
    libc="gnu-glibc2.28"
  fi

  release_json="$(curl -fsSL --connect-timeout 10 --max-time 30 -H 'Accept: application/vnd.github+json' 'https://api.github.com/repos/zhboner/realm/releases/latest')" || die "无法读取 Realm 官方 Release 信息"
  REALM_VERSION="$(printf '%s' "$release_json" | jq -r '.tag_name // empty')"
  [[ "$REALM_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Realm Release 版本信息无效"

  asset_name="realm-slim-${arch}-unknown-linux-${libc}.tar.gz"
  asset_url="$(printf '%s' "$release_json" | jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .browser_download_url' | head -n 1)"
  asset_digest="$(printf '%s' "$release_json" | jq -r --arg name "$asset_name" '.assets[] | select(.name == $name) | .digest' | head -n 1)"
  [[ "$asset_url" == https://* ]] || die "Realm Release 中没有找到：$asset_name"
  [[ "$asset_digest" == sha256:* ]] || die "Realm Release 没有提供 $asset_name 的 SHA-256 摘要"
  asset_digest="${asset_digest#sha256:}"
  [[ "$asset_digest" =~ ^[A-Fa-f0-9]{64}$ ]] || die "Realm SHA-256 摘要格式无效"

  archive="$TMP_DIR/$asset_name"
  extract_dir="$TMP_DIR/realm-extract"
  mkdir -p -- "$extract_dir"
  info "下载 Realm $REALM_VERSION：$asset_name"
  curl -fLsS --connect-timeout 10 --max-time 120 "$asset_url" -o "$archive" || die "下载 Realm 失败"
  actual_digest="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "$actual_digest" == "$asset_digest" ]] || die "Realm 文件 SHA-256 校验失败"
  tar -xzf "$archive" -C "$extract_dir" || die "解压 Realm 失败"
  # Official slim archives contain realm-slim; also accept the realm filename.
  realm_file="$(find "$extract_dir" -type f \( -name realm-slim -o -name realm \) -print -quit)" || die "无法查找解压后的 Realm 可执行文件"
  [[ -n "$realm_file" && -f "$realm_file" ]] || die "解压 $asset_name 后没有找到 realm-slim 或 realm 可执行文件"
  STAGED_REALM_BIN="$TMP_DIR/realm.new"
  install -m 755 "$realm_file" "$STAGED_REALM_BIN" || die "准备 Realm 二进制失败"
  env -u REALM_CONF "$STAGED_REALM_BIN" --version >/dev/null 2>&1 || die "下载的 Realm 无法运行"
}

ensure_realm_binary() {
  if [[ -x "$REALM_BIN" ]]; then
    if REALM_VERSION="$(env -u REALM_CONF "$REALM_BIN" --version 2>/dev/null)" && [[ -n "$REALM_VERSION" ]]; then
      REALM_VERSION="${REALM_VERSION%%$'\n'*}"
      STAGED_REALM_BIN="$REALM_BIN"
      return 0
    fi
  fi
  install_realm
}

ipv6_available() {
  local first_line="" disabled=""
  [[ -r /proc/net/if_inet6 && -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] || return 1
  IFS= read -r first_line < /proc/net/if_inet6 || return 1
  IFS= read -r disabled < /proc/sys/net/ipv6/conf/all/disable_ipv6 || return 1
  [[ -n "$first_line" && "$disabled" == 0 ]]
}

listen_endpoint() {
  case "$LISTEN_MODE" in
    IPV4) printf '0.0.0.0:%s' "$ENTRY_PORT" ;;
    IPV6) printf '[::]:%s' "$ENTRY_PORT" ;;
    DUAL)
      if ipv6_available; then
        printf '[::]:%s' "$ENTRY_PORT"
      else
        printf '0.0.0.0:%s' "$ENTRY_PORT"
      fi
      ;;
  esac
}

write_config() {
  local listen remote ipv6_only config_tmp state_tmp
  listen="$LISTEN_ENDPOINT"
  remote="$(format_host_port "$REMOTE_ADDRESS" "$REMOTE_PORT")"
  ipv6_only=false
  [[ "$LISTEN_MODE" == IPV6 ]] && ipv6_only=true
  config_tmp="$TMP_DIR/config.toml.new"
  state_tmp="$TMP_DIR/state.conf.new"

  cat > "$config_tmp" <<EOF
# Managed by nat-debian-realm.sh.
[log]
level = "warn"

[dns]
max_ttl = 300
cache_size = 16

[network]
no_tcp = false
use_udp = false
ipv6_only = $ipv6_only
tcp_timeout = 5
tcp_keepalive = 15
tcp_keepalive_probe = 3

[[endpoints]]
listen = "$listen"
remote = "$remote"
EOF

  cat > "$state_tmp" <<EOF
ENTRY_ADDRESS=$ENTRY_ADDRESS
ENTRY_PORT=$ENTRY_PORT
LISTEN_MODE=$LISTEN_MODE
LISTEN_ENDPOINT=$LISTEN_ENDPOINT
REMOTE_ADDRESS=$REMOTE_ADDRESS
REMOTE_PORT=$REMOTE_PORT
REALM_VERSION=$REALM_VERSION
CREATED_REALM_PARENT=$CREATED_REALM_PARENT
EOF
  install -m 600 "$config_tmp" "$CONFIG_PATH"
  install -m 600 "$state_tmp" "$STATE_PATH"
}

write_service() {
  if [[ "$SERVICE_MODE" == systemd ]]; then
    cat > "$SYSTEMD_UNIT" <<EOF
# Managed by nat-debian-realm.sh.
[Unit]
Description=nat-debian-realm TCP relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$REALM_BIN -c $CONFIG_PATH
Restart=no
Environment=TOKIO_WORKER_THREADS=1
UnsetEnvironment=REALM_CONF
LimitNOFILE=65535
NoNewPrivileges=true
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$SYSTEMD_UNIT"
    systemctl daemon-reload || die "systemd 配置加载失败"
  else
    cat > "$OPENRC_UNIT" <<EOF
#!/sbin/openrc-run
# Managed by nat-debian-realm.sh.
description="nat-debian-realm TCP relay"
command="$REALM_BIN"
command_args="-c $CONFIG_PATH"
command_background="yes"
pidfile="$PID_FILE"
output_log="$LOG_FILE"
error_log="$ERROR_LOG_FILE"
export TOKIO_WORKER_THREADS=1
unset REALM_CONF

depend() {
  need net
}
EOF
    chmod 755 "$OPENRC_UNIT"
  fi
}

service_active() {
  if [[ "$SERVICE_MODE" == systemd ]]; then
    systemctl is-active --quiet "$SERVICE_NAME.service"
  else
    rc-service "$SERVICE_NAME" status >/dev/null 2>&1
  fi
}

check_autostart_links() {
  local link target
  for link in /etc/runlevels/*/"$SERVICE_NAME" /etc/systemd/system/*.wants/"$SERVICE_NAME.service" /etc/systemd/system/*.requires/"$SERVICE_NAME.service"; do
    [[ -e "$link" || -L "$link" ]] || continue
    [[ -L "$link" ]] || return 1
    target="$(readlink -f -- "$link")" || return 1
    case "$link" in
      /etc/runlevels/*) [[ "$target" == "$OPENRC_UNIT" ]] || return 1 ;;
      *) [[ "$target" == "$SYSTEMD_UNIT" ]] || return 1 ;;
    esac
    (( HAD_INSTALL == 1 )) || return 1
  done
  return 0
}

remove_autostart_links() {
  local link
  check_autostart_links || return 1
  for link in /etc/runlevels/*/"$SERVICE_NAME" /etc/systemd/system/*.wants/"$SERVICE_NAME.service" /etc/systemd/system/*.requires/"$SERVICE_NAME.service"; do
    [[ -L "$link" ]] || continue
    rm -f -- "$link" || return 1
  done
  return 0
}

service_enabled() {
  if [[ "$SERVICE_MODE" == systemd ]]; then
    systemctl is-enabled --quiet "$SERVICE_NAME.service" 2>/dev/null
  else
    [[ -L "/etc/runlevels/default/$SERVICE_NAME" ]]
  fi
}

set_service_enabled() {
  local enabled="$1"
  if (( enabled == 1 )); then
    if service_enabled; then return 0; fi
    if [[ "$SERVICE_MODE" == systemd ]]; then
      systemctl enable "$SERVICE_NAME.service" >/dev/null || return 1
    else
      rc-update add "$SERVICE_NAME" default >/dev/null || return 1
    fi
  else
    if ! service_enabled; then return 0; fi
    if [[ "$SERVICE_MODE" == systemd ]]; then
      systemctl disable "$SERVICE_NAME.service" >/dev/null || return 1
    else
      rc-update del "$SERVICE_NAME" default >/dev/null || return 1
    fi
  fi
  return 0
}

managed_pid_matches() {
  local pid="$1" executable
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  executable="$(readlink -- "/proc/$pid/exe" 2>/dev/null)" || return 1
  [[ "$executable" == "$REALM_BIN" || "$executable" == "$REALM_BIN (deleted)" ]]
}

managed_process_pids() {
  local process_dir pid
  [[ -d /proc/1 && -L /proc/self/exe ]] || return 1
  for process_dir in /proc/[0-9]*; do
    [[ -d "$process_dir" ]] || continue
    pid="${process_dir##*/}"
    if managed_pid_matches "$pid"; then printf '%s\n' "$pid"; fi
  done
  return 0
}

stop_service() {
  local pids pid unit
  unit="$SYSTEMD_UNIT"
  if [[ "$SERVICE_MODE" == openrc ]]; then unit="$OPENRC_UNIT"; fi
  if [[ -f "$unit" ]] || service_active; then
    if [[ "$SERVICE_MODE" == systemd ]]; then
      if ! systemctl stop "$SERVICE_NAME.service"; then
        warn "服务管理器停止失败，将核对并停止本脚本的专用进程"
      fi
    elif ! rc-service "$SERVICE_NAME" stop; then
      warn "服务管理器停止失败，将核对并停止本脚本的专用进程"
    fi
  fi
  pids="$(managed_process_pids)" || return 1
  if [[ -n "$pids" ]]; then
    for pid in $pids; do
      if managed_pid_matches "$pid"; then
        if ! kill -TERM "$pid"; then
          if managed_pid_matches "$pid"; then return 1; fi
        fi
      fi
    done
    sleep 1
    pids="$(managed_process_pids)" || return 1
    if [[ -n "$pids" ]]; then
      warn "专用进程未响应退出信号，执行强制停止"
      for pid in $pids; do
        if managed_pid_matches "$pid"; then
          if ! kill -KILL "$pid"; then
            if managed_pid_matches "$pid"; then return 1; fi
          fi
        fi
      done
      sleep 1
    fi
  fi
  pids="$(managed_process_pids)" || return 1
  [[ -z "$pids" ]] || return 1
  if service_active; then
    if [[ "$SERVICE_MODE" == openrc ]]; then
      rc-service "$SERVICE_NAME" zap >/dev/null || return 1
    else
      return 1
    fi
  fi
  return 0
}

start_service() {
  if [[ "$SERVICE_MODE" == systemd ]]; then
    systemctl reset-failed "$SERVICE_NAME.service" || return 1
    systemctl start "$SERVICE_NAME.service" || return 1
  else
    rc-service "$SERVICE_NAME" start || return 1
  fi
  return 0
}

verify_started() {
  local pid sockets family="-4"
  # Check once after startup; do not loop or retry a failed start.
  sleep 2
  service_active || return 1
  pid="$(service_pid)" || return 1
  [[ -n "$pid" ]] && managed_pid_matches "$pid" || return 1
  if [[ "$LISTEN_ENDPOINT" == \[* ]]; then family="-6"; fi
  sockets="$(ss "$family" -H -lntp "sport = :$ENTRY_PORT")" || return 1
  printf '%s\n' "$sockets" | awk -v pid="$pid" '
    index($0, "pid=" pid ",") { found=1 }
    END { exit !found }
  '
}

enable_and_start_service() {
  set_service_enabled 1 || return 1
  start_service || return 1
  verify_started
}

backup_existing_deployment() {
  local index snapshot persistent_backup
  snapshot="$TMP_DIR/previous"
  mkdir -m 700 -- "$snapshot" || return 1
  WAS_ACTIVE=0
  WAS_ENABLED=0
  if service_active; then WAS_ACTIVE=1; fi
  if service_enabled; then WAS_ENABLED=1; fi
  for index in "${!MANAGED_PATHS[@]}"; do
    if [[ -f "${MANAGED_PATHS[$index]}" ]]; then
      cp -p -- "${MANAGED_PATHS[$index]}" "$snapshot/${BACKUP_NAMES[$index]}" || return 1
    fi
  done
  printf 'SCRIPT_VERSION=%s\nSERVICE_MODE=%s\nWAS_ACTIVE=%s\nWAS_ENABLED=%s\n' \
    "$SCRIPT_VERSION" "$SERVICE_MODE" "$WAS_ACTIVE" "$WAS_ENABLED" > "$snapshot/service-state.txt" || return 1
  ROLLBACK_DIR="$snapshot"
  if (( HAD_INSTALL == 1 )); then
    mkdir -p -m 700 -- "$BACKUP_ROOT" || return 1
    chmod 700 "$BACKUP_ROOT" || return 1
    persistent_backup="$(mktemp -d "$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX")" || return 1
    chmod 700 "$persistent_backup" || return 1
    cp -a -- "$snapshot/." "$persistent_backup/" || return 1
    ROLLBACK_DIR="$persistent_backup"
    info "修改前的部署已备份：$ROLLBACK_DIR"
  fi
  return 0
}

remove_empty_managed_parent() {
  local contents
  if [[ "$CREATED_REALM_PARENT" == 1 && -d /etc/realm && ! -L /etc/realm ]]; then
    contents="$(find /etc/realm -mindepth 1 -print -quit)" || return 1
    if [[ -z "$contents" ]]; then rmdir -- /etc/realm || return 1; fi
  fi
  return 0
}

restore_existing_deployment() {
  local index
  [[ -d "$ROLLBACK_DIR" ]] || return 1
  stop_service || return 1
  set_service_enabled 0 || return 1
  for index in "${!MANAGED_PATHS[@]}"; do
    if [[ -f "$ROLLBACK_DIR/${BACKUP_NAMES[$index]}" ]]; then
      cp -p -- "$ROLLBACK_DIR/${BACKUP_NAMES[$index]}" "${MANAGED_PATHS[$index]}" || return 1
    else
      rm -f -- "${MANAGED_PATHS[$index]}" || return 1
    fi
  done
  if [[ "$SERVICE_MODE" == systemd ]]; then
    systemctl daemon-reload || return 1
    # A failed unit can remain cached after a fresh installation is removed.
    if [[ -f "$SYSTEMD_UNIT" ]]; then
      systemctl reset-failed "$SERVICE_NAME.service" || return 1
    else
      systemctl reset-failed "$SERVICE_NAME.service" >/dev/null 2>&1 || true
    fi
  fi
  if (( HAD_INSTALL == 0 )); then
    rm -f -- "$PID_FILE" "$LOG_FILE" "$ERROR_LOG_FILE" || return 1
    if (( ROOT_EXISTED == 0 )) && [[ -d "$INSTALL_ROOT" ]]; then
      rmdir -- "$INSTALL_ROOT" || return 1
    fi
    remove_empty_managed_parent || return 1
  fi
  set_service_enabled "$WAS_ENABLED" || return 1
  if (( WAS_ACTIVE == 1 )); then
    load_state || return 1
    start_service || return 1
    verify_started || return 1
  fi
  return 0
}

load_state() {
  local key="" value="" listen_from_config
  [[ -f "$STATE_PATH" && -f "$CONFIG_PATH" ]] || return 1
  ENTRY_ADDRESS=""
  ENTRY_PORT=""
  REMOTE_ADDRESS=""
  REMOTE_PORT=""
  LISTEN_MODE=""
  REALM_VERSION=""
  LISTEN_ENDPOINT=""
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    value="${value%$'\r'}"
    case "$key" in
      ENTRY_ADDRESS) ENTRY_ADDRESS="$value" ;;
      ENTRY_PORT) ENTRY_PORT="$value" ;;
      LISTEN_MODE) LISTEN_MODE="$value" ;;
      REMOTE_ADDRESS) REMOTE_ADDRESS="$value" ;;
      REMOTE_PORT) REMOTE_PORT="$value" ;;
      REALM_VERSION) REALM_VERSION="$value" ;;
      LISTEN_ENDPOINT) LISTEN_ENDPOINT="$value" ;;
    esac
  done < "$STATE_PATH"
  [[ -n "$ENTRY_ADDRESS" && -n "$REMOTE_ADDRESS" && -n "$REALM_VERSION" ]] || return 1
  [[ "$ENTRY_PORT" =~ ^[1-9][0-9]{0,4}$ && "$REMOTE_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
  (( ENTRY_PORT <= 65535 && REMOTE_PORT <= 65535 )) || return 1
  case "$LISTEN_MODE" in IPV4|IPV6|DUAL) ;; *) return 1 ;; esac
  # Read the deployed endpoint instead of recomputing it from today's IPv6 state.
  listen_from_config="$(sed -n 's/^[[:space:]]*listen[[:space:]]*=[[:space:]]*"\([^"]*\)"[[:space:]]*$/\1/p' "$CONFIG_PATH")" || return 1
  [[ "$listen_from_config" == "0.0.0.0:$ENTRY_PORT" || "$listen_from_config" == "[::]:$ENTRY_PORT" ]] || return 1
  LISTEN_ENDPOINT="$listen_from_config"
  return 0
}

service_pid() {
  local pid=""
  if [[ "$SERVICE_MODE" == systemd ]]; then
    pid="$(systemctl show -p MainPID --value "$SERVICE_NAME.service" 2>/dev/null || true)"
  elif [[ -f "$PID_FILE" ]]; then
    pid="$(sed -n '1p' "$PID_FILE" 2>/dev/null || true)"
  fi
  if managed_pid_matches "$pid"; then printf '%s' "$pid"; fi
  return 0
}

show_memory() {
  local pid rss
  pid="$(service_pid)"
  if [[ -n "$pid" && -r "/proc/$pid/status" ]]; then
    rss="$(awk '/^VmRSS:/ {print $2; exit}' "/proc/$pid/status" 2>/dev/null)" || rss=""
    if [[ "$rss" =~ ^[0-9]+$ ]]; then
      awk -v kb="$rss" 'BEGIN {printf "运行内存：%.1f MiB\n", kb / 1024}'
      return
    fi
  fi
  printf '运行内存：无法读取\n'
}

show_deployment() {
  [[ "$(id -u)" -eq 0 ]] || die "请使用 root 查看配置、进程内存和日志"
  detect_platform
  ensure_install_ownership
  (( HAD_INSTALL == 1 )) || die "尚未部署 nat-debian-realm"
  load_state || die "部署状态或配置不完整，无法显示"
  printf '脚本版本：%s\n' "$SCRIPT_VERSION"
  printf 'Realm 版本：%s\n' "$REALM_VERSION"
  printf '服务管理：%s\n' "$SERVICE_MODE"
  printf '客户端入口：%s\n' "$(format_host_port "$ENTRY_ADDRESS" "$ENTRY_PORT")"
  printf '本机监听模式：%s\n' "$LISTEN_MODE"
  printf '配置中的本机监听：%s\n' "$LISTEN_ENDPOINT"
  printf '转发目标：%s\n' "$(format_host_port "$REMOTE_ADDRESS" "$REMOTE_PORT")"
  if service_active; then
    printf '服务状态：运行中\n'
    show_memory
  else
    printf '服务状态：未运行\n'
  fi
  if command_exists ss; then
    printf '\n监听端口：\n'
    ss -lntp "sport = :$ENTRY_PORT" 2>/dev/null || true
  fi
  if [[ "$SERVICE_MODE" == systemd ]]; then
    printf '\n最近日志：\n'
    journalctl -u "$SERVICE_NAME.service" -n 20 --no-pager 2>/dev/null || true
  elif [[ -f "$ERROR_LOG_FILE" ]]; then
    printf '\n最近错误日志：\n'
    tail -n 20 "$ERROR_LOG_FILE" 2>/dev/null || true
  fi
}

deploy() {
  local parent_flag=""
  [[ "$(id -u)" -eq 0 ]] || die "请使用 root 运行此脚本"
  detect_platform
  read_config
  validate_config
  TMP_DIR="$(mktemp -d /tmp/nat-debian-realm.XXXXXX)" || die "无法创建临时目录"
  install_dependencies
  ensure_install_ownership
  ensure_realm_binary
  backup_existing_deployment || die "备份失败，原部署未修改"
  CREATED_REALM_PARENT=0
  if [[ ! -d /etc/realm ]]; then
    CREATED_REALM_PARENT=1
  elif [[ -f "$STATE_PATH" ]]; then
    parent_flag="$(sed -n 's/^CREATED_REALM_PARENT=//p' "$STATE_PATH")"
    if [[ "$parent_flag" == 1 ]]; then CREATED_REALM_PARENT=1; fi
  fi
  stop_service || die "未能停止专用服务，原文件保留，部署终止"
  TRANSACTION_ACTIVE=1
  mkdir -p -- "$INSTALL_ROOT" /usr/local/bin
  chmod 700 "$INSTALL_ROOT"
  printf 'nat-debian-realm %s\n' "$SCRIPT_VERSION" > "$MANIFEST_PATH"
  chmod 600 "$MANIFEST_PATH"
  if [[ "$STAGED_REALM_BIN" != "$REALM_BIN" ]]; then
    install -m 755 "$STAGED_REALM_BIN" "$REALM_BIN"
  fi
  write_config
  write_service
  if ! enable_and_start_service; then
    die "服务启动或监听验证失败，将恢复修改前的部署状态"
  fi
  TRANSACTION_ACTIVE=0
  ok "Realm TCP 转发已部署"
  printf '客户端入口：%s\n' "$(format_host_port "$ENTRY_ADDRESS" "$ENTRY_PORT")"
  printf '本机监听：%s\n' "$LISTEN_ENDPOINT"
  printf '转发目标：%s\n' "$(format_host_port "$REMOTE_ADDRESS" "$REMOTE_PORT")"
  printf '配置文件：%s\n' "$CONFIG_PATH"
  printf '服务名称：%s\n' "$SERVICE_NAME"
  show_memory
}

restart_service() {
  [[ "$(id -u)" -eq 0 ]] || die "请使用 root 运行此脚本"
  detect_platform
  ensure_install_ownership
  (( HAD_INSTALL == 1 )) || die "尚未部署 nat-debian-realm"
  load_state || die "部署状态或配置不完整，无法重启"
  command_exists ss || die "缺少 ss，请重新运行安装命令补齐依赖"
  stop_service || die "停止原服务失败，重启终止"
  enable_and_start_service || die "Realm 服务重启失败"
  ok "Realm 服务已重启"
}

uninstall() {
  local assume_yes="${1:-}" confirmation="" path link parent_flag="" pids
  [[ "$(id -u)" -eq 0 ]] || die "请使用 root 运行此脚本"
  detect_platform
  ensure_install_ownership
  (( HAD_INSTALL == 1 )) || die "未找到本脚本的管理标记，拒绝删除任何文件"
  if [[ "$assume_yes" != --yes ]]; then
    printf '将删除 nat-debian-realm 创建的服务、配置、状态、日志和专用二进制。\n'
    printf '系统共享依赖、Xray、其他 Realm 服务和防火墙规则不会删除。\n'
    printf '确认卸载请输入 YES：'
    read -r confirmation
    [[ "$confirmation" == YES ]] || die "已取消卸载"
  fi

  if [[ -f "$STATE_PATH" ]]; then
    parent_flag="$(sed -n 's/^CREATED_REALM_PARENT=//p' "$STATE_PATH")"
  fi
  stop_service || die "专用进程或服务仍在运行，保留文件，卸载终止"
  set_service_enabled 0 || die "取消自启动失败，保留文件，卸载终止"
  remove_autostart_links || die "自启动文件清理失败，卸载终止"
  rm -f -- "$SYSTEMD_UNIT" "$OPENRC_UNIT" || die "服务文件删除失败"
  if [[ "$SERVICE_MODE" == systemd ]]; then
    systemctl daemon-reload || die "systemd 配置刷新失败，保留其余文件"
    systemctl reset-failed "$SERVICE_NAME.service" >/dev/null 2>&1 || true
  fi
  rm -f -- "$REALM_BIN" "$PID_FILE" "$LOG_FILE" "$ERROR_LOG_FILE" || die "二进制、日志或 PID 文件删除失败"
  rm -rf -- "$INSTALL_ROOT" || die "管理目录删除失败"
  CREATED_REALM_PARENT="$parent_flag"
  remove_empty_managed_parent || die "空的专用父目录删除失败"
  for path in "${MANAGED_PATHS[@]}" "$PID_FILE" "$LOG_FILE" "$ERROR_LOG_FILE" "$INSTALL_ROOT"; do
    [[ ! -e "$path" && ! -L "$path" ]] || die "卸载后仍有残留：$path"
  done
  for link in /etc/runlevels/*/"$SERVICE_NAME" /etc/systemd/system/*.wants/"$SERVICE_NAME.service" /etc/systemd/system/*.requires/"$SERVICE_NAME.service"; do
    [[ ! -e "$link" && ! -L "$link" ]] || die "卸载后仍有自启动残留：$link"
  done
  pids="$(managed_process_pids)" || die "无法核对卸载后的进程状态"
  [[ -z "$pids" ]] || die "卸载后仍有专用进程，请检查服务状态"
  ok "nat-debian-realm 已卸载，专用进程、文件和自启动项已核对清理"
}

main() {
  (( BASH_VERSINFO[0] >= 4 )) || die "需要 Bash 4 或更新版本"
  (( $# <= 2 )) || die "参数过多"
  [[ "${1:-}" == uninstall || $# -le 1 ]] || die "此命令不支持第二个参数"
  case "${1:-}" in
    "") deploy ;;
    show|status) show_deployment ;;
    restart) restart_service ;;
    uninstall)
      [[ -z "${2:-}" || "${2:-}" == --yes ]] || die "uninstall 只支持可选参数 --yes"
      uninstall "${2:-}"
      ;;
    *) die "未知参数：$1；可用参数为 show、status、restart、uninstall [--yes]" ;;
  esac
}

main "$@"
