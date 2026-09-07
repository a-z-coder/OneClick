#!/bin/sh
# 全新 Alpine 默认可能没有 Bash；先用 POSIX sh 安装并切换到 Bash。
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then
    exec bash "$0" "$@"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache bash || {
      echo "[失败] Alpine Bash 安装失败，无法继续运行脚本" >&2
      exit 1
    }
    exec bash "$0" "$@"
  else
    echo "[失败] 本脚本需要 Bash；当前系统既没有 Bash，也无法使用 apk 自动安装" >&2
    exit 1
  fi
fi

set -Eeuo pipefail

# 独立 Xray 一键配置脚本
# 功能：
#   1. 生成 VLESS-TCP-Reality-Vision 入站；
#   2. 生成 VLESS-XHTTP-TLS 入站；
#   3. 按配置中的每个优选域名生成一个 XHTTP-TLS 客户端节点；
#   4. 按配置中的顺序生成节点，并设置整体 IPv4/IPv6 出站；
#   5. 写入配置并按当前系统的服务方式启动 Xray。
#
# 本脚本不依赖 Argosbx，也不会申请或续期证书。
# 证书、私钥、橙云源站域名、优选域名和端口均由使用者输入。

SCRIPT_NAME="$(basename "$0")"
MANAGED_REALITY_TAG="vless-reality-vision"
MANAGED_XHTTP_TAG="vless-xhttp-tls"

TMP_DIR=""
CONFIG_PATH=""
NODE_ORDER=""
NODE_ORDER_IDS=()
declare -A NODE_ORDER_SEEN=()
OUTBOUND_IP_VERSION=""
OUTBOUND_DOMAIN_STRATEGY=""

cleanup() {
  if [[ -n "$TMP_DIR" && -d "$TMP_DIR" ]]; then
    rm -f -- "$TMP_DIR"/* 2>/dev/null || true
    rmdir -- "$TMP_DIR" 2>/dev/null || true
  fi
}
trap cleanup EXIT

die() {
  echo "[失败] $*" >&2
  exit 1
}

info() {
  echo "[信息] $*"
}

ok() {
  echo "[成功] $*"
}

warn() {
  echo "[警告] $*" >&2
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

# 一键部署所需的少量基础工具；只在缺少依赖时安装。
install_dependencies() {
  local httpd_ready=1
  if command_exists apk; then
    command_exists busybox-extras && busybox-extras httpd --help >/dev/null 2>&1 || httpd_ready=0
  elif command_exists httpd && httpd --help >/dev/null 2>&1; then
    :
  elif command_exists busybox && busybox httpd --help >/dev/null 2>&1; then
    :
  elif command_exists busybox-extras && busybox-extras httpd --help >/dev/null 2>&1; then
    :
  else
    httpd_ready=0
  fi

  if command_exists jq && command_exists openssl && command_exists unzip && \
     command_exists sha256sum && { command_exists curl || command_exists wget; } && \
     [[ "$httpd_ready" -eq 1 ]]; then
    return 0
  fi

  echo "[信息] 正在安装 Xray 配置所需的基础工具"
  if command_exists apk; then
    apk add --no-cache jq openssl unzip coreutils curl ca-certificates busybox-extras || die "Alpine 基础工具安装失败"
  elif command_exists apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get update || die "APT 软件源更新失败"
    DEBIAN_FRONTEND=noninteractive apt-get install -y jq openssl unzip coreutils curl ca-certificates busybox || die "Debian/Ubuntu 基础工具安装失败"
  elif command_exists dnf; then
    dnf install -y jq openssl unzip coreutils curl ca-certificates busybox || die "DNF 基础工具安装失败"
  elif command_exists yum; then
    yum install -y jq openssl unzip coreutils curl ca-certificates busybox || die "YUM 基础工具安装失败"
  else
    die "不支持当前软件包管理器，无法自动安装基础工具"
  fi

  command_exists jq || die "安装后仍未找到 jq"
  command_exists openssl || die "安装后仍未找到 openssl"
  command_exists unzip || die "安装后仍未找到 unzip"
  command_exists curl || command_exists wget || die "安装后仍未找到 curl 或 wget"
  find_httpd_runner || true
  [[ -n "${HTTPD_BIN:-}" ]] || die "安装后仍未找到可用的 HTTP 服务"
  ok "基础工具安装完成"
}

# 一次性读取固定格式的部署配置，兼容浏览器复制的纯文本内容。
read_deployment_config() {
  local config_line preferred_index preferred_domain
  echo "请粘贴完整配置（从 YIjian_CONFIG_BEGIN 到 YIjian_CONFIG_END），然后回车：" >&2
  CONFIG_INPUT="$(awk '
    {
      sub(/\r$/, "")
      if ($0 == "```" || $0 == "YIjian_CONFIG_BEGIN") { if ($0 == "YIjian_CONFIG_BEGIN") started = 1; next }
      if ($0 == "YIjian_CONFIG_END") {
        if (started) found = 1
        exit
      }
      if (started) print
    }
    END { if (!started || !found) exit 1 }
  ')" || die "未读取到完整配置，必须包含 YIjian_CONFIG_BEGIN 和 YIjian_CONFIG_END"
  [[ -n "$CONFIG_INPUT" ]] || die "部署配置不能为空"

  REALITY_PORT="$(config_value REALITY_PORT)"
  ORIGIN_DOMAIN="$(normalize_domain_value "$(config_value ORIGIN_DOMAIN)")"
  NODE_ORDER="$(trim_value "$(config_value NODE_ORDER)")"
  OUTBOUND_IP_VERSION="$(trim_value "$(config_value OUTBOUND_IP_VERSION)")"
  PREFERRED_DOMAINS=()
  declare -A PREFERRED_DOMAIN_VALUES=()
  while IFS= read -r config_line; do
    config_line="${config_line#"${config_line%%[![:space:]]*}"}"
    if [[ "$config_line" =~ ^PREFERRED_DOMAIN_([1-9][0-9]*)=(.*)$ ]]; then
      PREFERRED_DOMAIN_VALUES["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
  done <<< "$CONFIG_INPUT"
  if (( ${#PREFERRED_DOMAIN_VALUES[@]} > 0 )); then
    while IFS= read -r preferred_index; do
      # CDN 优选项只接受纯域名；URL 或 Markdown 链接应直接在校验阶段报错。
      preferred_domain="$(trim_value "${PREFERRED_DOMAIN_VALUES[$preferred_index]}")"
      [[ -n "$preferred_domain" ]] || die "PREFERRED_DOMAIN_${preferred_index} 为空"
      PREFERRED_DOMAINS+=("$preferred_domain")
    done < <(printf '%s\n' "${!PREFERRED_DOMAIN_VALUES[@]}" | sort -n)
  fi
  XHTTP_PORT="$(config_value XHTTP_PORT)"
  SUB_PORT="$(config_value SUB_PORT)"
  NODE_NAME_PREFIX="$(trim_value "$(config_value NODE_NAME_PREFIX)")"
  CERT_CONTENT="$(extract_pem_block CERTIFICATE_BEGIN CERTIFICATE_END)"
  KEY_CONTENT="$(extract_pem_block PRIVATE_KEY_BEGIN PRIVATE_KEY_END)"

  [[ -n "$REALITY_PORT" ]] || die "配置中缺少 REALITY_PORT：vless直连端口"
  [[ -n "$ORIGIN_DOMAIN" ]] || die "配置中缺少 ORIGIN_DOMAIN：优选自己域名"
  [[ -n "$NODE_ORDER" ]] || die "配置中缺少 NODE_ORDER：请填写 REALITY_V4、REALITY_V6、CDN_1 等节点标识"
  [[ -n "$OUTBOUND_IP_VERSION" ]] || die "配置中缺少 OUTBOUND_IP_VERSION：只能填写 4 或 6"
  parse_node_order
  [[ -n "${PREFERRED_DOMAINS[0]:-}" ]] || die "没有找到 PREFERRED_DOMAIN_1、PREFERRED_DOMAIN_2 等 CDN 域名"
  [[ -n "$XHTTP_PORT" ]] || die "配置中缺少 XHTTP_PORT：优选端口"
  [[ -n "$SUB_PORT" ]] || die "配置中缺少 SUB_PORT：订阅端口"
  [[ -n "$CERT_CONTENT" ]] || die "配置中缺少 CERTIFICATE_BEGIN/END 证书区块"
  [[ -n "$KEY_CONTENT" ]] || die "配置中缺少 PRIVATE_KEY_BEGIN/END 私钥区块"
}

trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

parse_node_order() {
  local item
  local -a raw_order=()

  [[ "$NODE_ORDER" != ,* && "$NODE_ORDER" != *, && "$NODE_ORDER" != *,,* ]] || \
    die "NODE_ORDER 不能包含空的节点标识：$NODE_ORDER"

  NODE_ORDER_IDS=()
  NODE_ORDER_SEEN=()
  IFS=',' read -r -a raw_order <<< "$NODE_ORDER"
  for item in "${raw_order[@]}"; do
    item="$(trim_value "$item")"
    [[ "$item" =~ ^(REALITY_V4|REALITY_V6|CDN_[1-9][0-9]*)$ ]] || \
      die "NODE_ORDER 中的节点标识无效：$item；可用格式为 REALITY_V4、REALITY_V6、CDN_N"
    [[ -z "${NODE_ORDER_SEEN[$item]+x}" ]] || die "NODE_ORDER 中的节点重复：$item"
    NODE_ORDER_IDS+=("$item")
    NODE_ORDER_SEEN["$item"]=1
  done
}

# ORIGIN_DOMAIN 可填写纯域名、Markdown 链接或 http(s) URL；PREFERRED_DOMAIN_N 只接受纯域名。
normalize_domain_value() {
  local value markdown_pattern
  value="$(trim_value "$1")"
  markdown_pattern='^\[[^]]+\]\((https?://)?([^/?#]+)(/[^)]*)?\)$'
  if [[ "$value" =~ $markdown_pattern ]]; then
    value="${BASH_REMATCH[2]}"
  elif [[ "$value" =~ ^https?:// ]]; then
    value="${value#http://}"
    value="${value#https://}"
    value="${value%%/*}"
  fi
  trim_value "$value"
}

config_value() {
  local key="$1"
  printf '%s\n' "$CONFIG_INPUT" | awk -v key="$key" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
    }
    line !~ /^#/ && index(line, key "=") == 1 {
      print substr(line, length(key) + 2)
      exit
    }
  '
}

extract_pem_block() {
  local begin="$1"
  local end="$2"
  printf '%s\n' "$CONFIG_INPUT" | awk -v begin="$begin" -v end="$end" '
    $0 == begin { capture = 1; next }
    capture {
      print
      if ($0 == end) exit
    }
  '
}

validate_port() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] || die "$label 必须是数字"
  (( value >= 1 && value <= 65535 )) || die "$label 必须在 1-65535 范围内"
}

validate_outbound_ip_version() {
  [[ "$1" == "4" || "$1" == "6" ]] || die "OUTBOUND_IP_VERSION 必须是 4 或 6，当前值：$1"
}

validate_domain() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "$label 格式不正确：$value"
  [[ "$value" != *..* ]] || die "$label 不能包含连续点号：$value"
}

validate_domain_list() {
  local domain
  for domain in "${PREFERRED_DOMAINS[@]}"; do
    [[ -n "$domain" ]] || continue
    validate_domain "优选域名" "$domain"
  done
}

validate_host_port() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^[A-Za-z0-9.-]+:[0-9]+$ ]] || die "$label 必须是 host:port 格式：$value"
  local port="${value##*:}"
  validate_port "$label 中的端口" "$port"
}

detect_public_host() {
  local url="https://icanhazip.com"
  local public_ipv4=""
  local public_ipv6=""
  if command_exists curl; then
    public_ipv4="$(curl -s4m5 -k "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    public_ipv6="$(curl -s6m5 -k "$url" 2>/dev/null | tr -d '[:space:]' || true)"
  elif command_exists wget; then
    public_ipv4="$(timeout 5 wget -4 --tries=2 -qO- "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    public_ipv6="$(timeout 5 wget -6 --tries=2 -qO- "$url" 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [[ "$public_ipv4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s' "$public_ipv4"
  elif [[ "$public_ipv6" == *:* ]]; then
    printf '[%s]' "$public_ipv6"
  else
    return 1
  fi
}

find_subscription_file() {
  local output_dir="$1"
  find "$output_dir/xray-sub" -type f -name 'jhsub.txt' -print 2>/dev/null | sed -n '1p'
}

rebuild_subscription_url() {
  local output_dir="$1"
  local sub_file=""
  local sub_token=""
  local sub_port=""
  local public_host=""

  sub_file="$(find_subscription_file "$output_dir")"
  [[ -n "$sub_file" ]] || return 1
  sub_token="$(basename "$(dirname "$sub_file")")"
  [[ -n "$sub_token" ]] || return 1

  if [[ -s "$output_dir/yijian-subscription-port.txt" ]]; then
    sub_port="$(sed -n '1p' "$output_dir/yijian-subscription-port.txt")"
  elif command_exists ps; then
    sub_port="$(ps 2>/dev/null | awk '/[h]ttpd/ { for (i = 1; i < NF; i++) if ($i == "-p") { print $(i + 1); exit } }')"
  fi
  [[ "$sub_port" =~ ^[0-9]+$ ]] || return 1
  public_host="$(detect_public_host)" || return 1
  printf 'http://%s:%s/%s/jhsub.txt' "$public_host" "$sub_port" "$sub_token"
}

show_port_usage() {
  if command_exists ss; then
    ss -lntup
  elif command_exists netstat; then
    netstat -lntup
  elif command_exists busybox && busybox netstat --help >/dev/null 2>&1; then
    busybox netstat -lntup
  elif command_exists busybox-extras && busybox-extras netstat --help >/dev/null 2>&1; then
    busybox-extras netstat -lntup
  else
    warn "未找到 ss 或 netstat，无法列出当前监听端口"
    return 1
  fi
}

show_deployment() {
  local output_dir="${1:-/etc/xray}"
  local link_file="$output_dir/vless-links.txt"
  local sub_url_file="$output_dir/yijian-subscription-url.txt"
  local sub_url=""
  local node_number=0
  local node_line=""

  [[ -d "$output_dir" ]] || die "输出目录不存在：$output_dir"
  [[ -s "$link_file" ]] || die "节点文件不存在或为空：$link_file"

  if [[ -s "$sub_url_file" ]]; then
    sub_url="$(sed -n '1p' "$sub_url_file")"
  else
    sub_url="$(rebuild_subscription_url "$output_dir" || true)"
  fi
  [[ -n "$sub_url" ]] || die "无法确定订阅网址；请检查订阅服务是否运行，或使用部署时保存的订阅网址"

  while IFS= read -r node_line; do
    [[ -n "$node_line" ]] || continue
    node_number=$((node_number + 1))
    if [[ "$node_line" == *"security=reality"* ]]; then
      echo "节点 $node_number：VLESS-TCP-Reality-Vision"
    else
      echo "节点 $node_number：VLESS-XHTTP-TLS-CDN"
    fi
    printf '%s\n' "$node_line"
  done < "$link_file"
  [[ "$node_number" -gt 0 ]] || die "节点文件中未找到有效节点：$link_file"
  echo "订阅内容：$node_number 个节点"
  echo "订阅网址：$sub_url"
  echo
  echo "所有端口占用："
  show_port_usage || true
}

# 使用 jq 的 URI 编码，避免路径或域名中的特殊字符破坏 VLESS 链接。
urlencode() {
  jq -nr --arg value "$1" '$value | @uri'
}

find_xray() {
  local candidate
  if command_exists xray; then
    command -v xray
    return 0
  fi
  for candidate in /usr/local/bin/xray /usr/bin/xray /usr/local/sbin/xray; do
    if [[ -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# 直接下载 Xray 官方 Release，不要求系统使用 systemd。
install_xray() {
  local asset archive extract_dir target
  case "$(uname -m)" in
    x86_64|amd64) asset="Xray-linux-64.zip" ;;
    aarch64|arm64) asset="Xray-linux-arm64-v8a.zip" ;;
    *) die "当前 Xray 安装暂不支持此 CPU 架构：$(uname -m)" ;;
  esac

  archive="$(mktemp /tmp/xray.XXXXXX.zip)" || die "无法创建 Xray 下载临时文件"
  extract_dir="$(mktemp -d /tmp/xray-core.XXXXXX)" || die "无法创建 Xray 解压目录"
  target="/usr/local/bin/xray"
  if command_exists curl; then
    curl -fL "https://github.com/XTLS/Xray-core/releases/latest/download/$asset" -o "$archive" || die "下载 Xray 官方二进制失败"
  else
    wget -O "$archive" "https://github.com/XTLS/Xray-core/releases/latest/download/$asset" || die "下载 Xray 官方二进制失败"
  fi
  unzip -j "$archive" xray -d "$extract_dir" >/dev/null || die "解压 Xray 官方二进制失败"
  install -m 755 "$extract_dir/xray" "$target" || die "安装 Xray 二进制失败"
  rm -f -- "$archive" "$extract_dir/xray"
  rmdir -- "$extract_dir" 2>/dev/null || true
  "$target" version >/dev/null 2>&1 || die "安装后的 Xray 无法运行"
}

# 按 Argosbx 的兼容顺序启动：systemd、OpenRC、无服务管理器。
start_xray() {
  if command_exists systemctl && [[ -d /run/systemd/system ]]; then
    cat > /etc/systemd/system/xray-yijian.service <<EOF
[Unit]
Description=Xray yijian service
After=network.target

[Service]
Type=simple
ExecStart=$XRAY_BIN run -c $CONFIG_PATH
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || die "systemd 配置加载失败"
    systemctl enable --now xray-yijian.service || die "systemd 无法启动 Xray"
    XRAY_START_MODE="systemd：xray-yijian.service"
  elif command_exists rc-service && command_exists rc-update; then
    cat > /etc/init.d/xray-yijian <<EOF
#!/sbin/openrc-run
description="Xray yijian service"
command="$XRAY_BIN"
command_args="run -c $CONFIG_PATH"
command_background="yes"
pidfile="/run/xray-yijian.pid"
depend() {
  need net
}
EOF
    chmod 755 /etc/init.d/xray-yijian
    rc-update add xray-yijian default >/dev/null 2>&1 || die "OpenRC 无法添加 Xray 自启动"
    rc-service xray-yijian restart >/dev/null 2>&1 || rc-service xray-yijian start >/dev/null 2>&1 || die "OpenRC 无法启动 Xray"
    XRAY_START_MODE="OpenRC：xray-yijian"
  else
    nohup "$XRAY_BIN" run -c "$CONFIG_PATH" >/dev/null 2>&1 &
    XRAY_PID="$!"
    printf '%s\n' "$XRAY_PID" > "$OUTPUT_DIR/xray-yijian.pid"
    XRAY_START_MODE="后台进程：PID $XRAY_PID"
  fi
}

# 选择参考脚本使用的 HTTP 服务实现。Alpine 优先使用 busybox-extras，
# 其他系统再回退到带 httpd applet 的 BusyBox 或独立 httpd 命令。
find_httpd_runner() {
  local candidate
  HTTPD_BIN=""
  HTTPD_APPLET=""
  if command_exists apk && command_exists busybox-extras; then
    candidate="$(command -v busybox-extras)"
    if "$candidate" httpd --help >/dev/null 2>&1; then
      HTTPD_BIN="$candidate"
      HTTPD_APPLET="httpd"
      return 0
    fi
  fi
  if command_exists httpd && httpd --help >/dev/null 2>&1; then
    HTTPD_BIN="$(command -v httpd)"
    return 0
  fi
  for candidate in busybox busybox-extras; do
    if command_exists "$candidate"; then
      candidate="$(command -v "$candidate")"
      if "$candidate" httpd --help >/dev/null 2>&1; then
        HTTPD_BIN="$candidate"
        HTTPD_APPLET="httpd"
        return 0
      fi
    fi
  done
  return 1
}

# 将订阅 HTTP 服务注册为系统服务，确保服务器重启后自动恢复。
start_subscription_service() {
  find_httpd_runner || true
  [[ -n "$HTTPD_BIN" ]] || die "未找到可用的 httpd（Alpine 请安装 busybox-extras）"

  # 记录服务参数，供 show 和人工排查使用。
  printf '%s\n' "$SUB_PORT" > "$OUTPUT_DIR/yijian-subscription-port.txt"
  printf '%s\n' "$SUB_TOKEN" > "$OUTPUT_DIR/yijian-subscription-token.txt"
  printf '%s\n' "$SUB_ROOT" > "$OUTPUT_DIR/yijian-subscription-root.txt"
  chmod 600 "$OUTPUT_DIR/yijian-subscription-port.txt" "$OUTPUT_DIR/yijian-subscription-token.txt" "$OUTPUT_DIR/yijian-subscription-root.txt"

  if command_exists systemctl && [[ -d /run/systemd/system ]]; then
    cat > /etc/systemd/system/xray-yijian-sub.service <<EOF
[Unit]
Description=Xray yijian subscription HTTP service
After=network.target

[Service]
Type=simple
ExecStart=$HTTPD_BIN ${HTTPD_APPLET:+$HTTPD_APPLET }-f -p $SUB_PORT -h $SUB_ROOT
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || die "systemd 配置加载失败"
    systemctl enable --now xray-yijian-sub.service || die "systemd 无法启动订阅 HTTP 服务"
    systemctl is-active --quiet xray-yijian-sub.service || die "订阅 HTTP 服务未处于运行状态，请检查端口 $SUB_PORT 是否被占用"
    SUB_START_MODE="systemd：xray-yijian-sub.service"
  elif command_exists rc-service && command_exists rc-update; then
    cat > /etc/init.d/xray-yijian-sub <<EOF
#!/sbin/openrc-run
description="Xray yijian subscription HTTP service"
command="$HTTPD_BIN"
command_args="${HTTPD_APPLET:+$HTTPD_APPLET }-f -p $SUB_PORT -h $SUB_ROOT"
command_background="yes"
pidfile="/run/xray-yijian-sub.pid"
depend() {
  need net
}
EOF
    chmod 755 /etc/init.d/xray-yijian-sub
    rc-update add xray-yijian-sub default >/dev/null 2>&1 || die "OpenRC 无法添加订阅服务自启动"
    rc-service xray-yijian-sub restart >/dev/null 2>&1 || rc-service xray-yijian-sub start >/dev/null 2>&1 || die "OpenRC 无法启动订阅 HTTP 服务"
    rc-service xray-yijian-sub status >/dev/null 2>&1 || die "订阅 HTTP 服务未处于运行状态，请检查端口 $SUB_PORT 是否被占用"
    SUB_START_MODE="OpenRC：xray-yijian-sub"
  else
    # 无服务管理器时仅能维持当前运行周期，避免虚报“重启后恢复”。
    if [[ -n "$HTTPD_APPLET" ]]; then
      nohup "$HTTPD_BIN" "$HTTPD_APPLET" -f -p "$SUB_PORT" -h "$SUB_ROOT" >/dev/null 2>&1 &
    else
      nohup "$HTTPD_BIN" -f -p "$SUB_PORT" -h "$SUB_ROOT" >/dev/null 2>&1 &
    fi
    SUB_PID="$!"
    sleep 1
    kill -0 "$SUB_PID" >/dev/null 2>&1 || die "订阅 HTTP 服务启动后已退出，请检查端口 $SUB_PORT 是否被占用"
    printf '%s\n' "$SUB_PID" > "$OUTPUT_DIR/xray-yijian-sub.pid"
    SUB_START_MODE="后台进程：PID $SUB_PID（当前环境没有可用的系统服务管理器，重启后不会自动恢复）"
  fi
}

[[ "$(id -u)" -eq 0 ]] || die "请使用 root 运行此脚本"

if [[ "${1:-}" == "show" ]]; then
  show_deployment "${2:-/etc/xray}"
  exit 0
fi
[[ -z "${1:-}" ]] || die "未知参数：$1；查看已生成节点请使用：$SCRIPT_NAME show [输出目录]"

echo "============================================================"
echo "  $SCRIPT_NAME"
echo "  独立 Xray：VLESS-Reality + VLESS-XHTTP-TLS 橙云节点"
echo "============================================================"
echo

install_dependencies
XRAY_BIN="$(find_xray || true)"
if [[ -z "$XRAY_BIN" ]]; then
  echo "[信息] 未找到 Xray，开始安装 Xray"
  install_xray
  XRAY_BIN="$(find_xray || true)"
  [[ -n "$XRAY_BIN" ]] || die "Xray 安装完成但仍未找到可执行文件"
  ok "Xray 安装完成：$XRAY_BIN"
fi
ok "已找到 Xray：$XRAY_BIN"

echo
echo "--- 第 1 步：输入节点参数 ---"
REALITY_CONNECT_HOST=""
read_deployment_config
# Reality 伪装参数固定采用 Argosbx 默认值，不再让输入，避免参数混淆。
REALITY_SNI="apple.com"
REALITY_DEST="apple.com:443"
CONFIG_PATH="/etc/xray/config.json"
OUTPUT_DIR="$(dirname "$CONFIG_PATH")"
XHTTP_PATH="/xhttp-$(openssl rand -hex 6)"

# 证书和私钥已由一次性配置块读取，脚本自动保存到输出目录。
CERT_FILE="$OUTPUT_DIR/yijian-origin-cert.pem"
KEY_FILE="$OUTPUT_DIR/yijian-origin-key.pem"

echo
echo "--- 第 2 步：校验输入参数 ---"
validate_port "Reality 端口" "$REALITY_PORT"
validate_port "XHTTP-TLS 端口" "$XHTTP_PORT"
validate_port "订阅端口" "$SUB_PORT"
validate_outbound_ip_version "$OUTBOUND_IP_VERSION"
OUTBOUND_DOMAIN_STRATEGY="UseIPv${OUTBOUND_IP_VERSION}"
[[ "$REALITY_PORT" != "$XHTTP_PORT" && "$REALITY_PORT" != "$SUB_PORT" && "$XHTTP_PORT" != "$SUB_PORT" ]] || die "三个端口不能相同"
validate_domain "橙云源站域名" "$ORIGIN_DOMAIN"
validate_domain_list
validate_host_port "Reality 伪装目标" "$REALITY_DEST"
[[ "$XHTTP_PATH" == /* ]] || XHTTP_PATH="/$XHTTP_PATH"
[[ "$XHTTP_PATH" =~ ^/[A-Za-z0-9._~/-]+$ ]] || die "XHTTP 路径只能包含字母、数字、/、.、_、~、-"

# Cloudflare 橙云只代理这些 HTTPS 端口，其他端口不能按预期走 CDN。
case "$XHTTP_PORT" in
  443|2053|2083|2087|2096|8443) ;;
  *) die "XHTTP-TLS 端口 $XHTTP_PORT 不是 Cloudflare 橙云支持的端口（443/2053/2083/2087/2096/8443）" ;;
esac

[[ -f "$CONFIG_PATH" || ! -e "$CONFIG_PATH" ]] || die "配置路径不是普通文件：$CONFIG_PATH"
mkdir -p -- "$OUTPUT_DIR"
printf '%s' "$CERT_CONTENT" > "$CERT_FILE"
printf '%s' "$KEY_CONTENT" > "$KEY_FILE"
chmod 600 "$CERT_FILE" "$KEY_FILE"
[[ -r "$CERT_FILE" ]] || die "证书写入失败：$CERT_FILE"
[[ -r "$KEY_FILE" ]] || die "私钥写入失败：$KEY_FILE"

openssl x509 -in "$CERT_FILE" -noout >/dev/null 2>&1 || die "证书不是有效 PEM X.509 文件：$CERT_FILE"
openssl pkey -in "$KEY_FILE" -passin pass: -noout >/dev/null 2>&1 || die "私钥不存在或不是未加密私钥：$KEY_FILE"
openssl x509 -in "$CERT_FILE" -noout -checkhost "$ORIGIN_DOMAIN" >/dev/null 2>&1 || die "证书不包含橙云源站域名：$ORIGIN_DOMAIN"

CERT_PUB_SHA="$(openssl x509 -in "$CERT_FILE" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
KEY_PUB_SHA="$(openssl pkey -in "$KEY_FILE" -passin pass: -pubout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
[[ -n "$CERT_PUB_SHA" && "$CERT_PUB_SHA" == "$KEY_PUB_SHA" ]] || die "证书和私钥不匹配"
ok "端口、域名、路径以及证书私钥校验通过"

echo
echo "--- 第 3 步：准备 Xray 配置 ---"
mkdir -p -- "$(dirname "$CONFIG_PATH")"
TMP_DIR="$(mktemp -d /tmp/xray-vless-setup.XXXXXX)"
TMP_CONFIG="$TMP_DIR/config.json"

if [[ -e "$CONFIG_PATH" ]]; then
  jq empty "$CONFIG_PATH" >/dev/null 2>&1 || die "现有 Xray 配置不是有效 JSON，未修改任何文件：$CONFIG_PATH"
  BASE_CONFIG="$CONFIG_PATH"
else
  BASE_CONFIG="$TMP_DIR/base.json"
  cat > "$BASE_CONFIG" <<'EOF'
{
  "log": {"loglevel": "warning"},
  "inbounds": [],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ]
}
EOF
fi

UUID_REALITY="$(cat /proc/sys/kernel/random/uuid)"
UUID_XHTTP="$(cat /proc/sys/kernel/random/uuid)"
SHORT_ID="$(openssl rand -hex 8)"
if ! KEY_OUTPUT="$($XRAY_BIN x25519 2>&1)"; then
  die "Xray x25519 执行失败，请检查 Xray 可执行文件和版本"
fi

# Xray 的输出格式有多个版本：
#   Private key: ... / Public key: ...
#   PrivateKey: ... / Password: ...
#   PrivateKey: ... / Password (PublicKey): ... / Hash32: ...
# 其中 Password 是 Reality 公钥，Hash32 不是公钥，不能写入客户端 pbk。
extract_x25519_value() {
  local kind="$1"
  printf '%s\n' "$KEY_OUTPUT" | awk -v kind="$kind" '
    function emit(value) {
      gsub(/\r/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      if (value != "") {
        print value
        exit
      }
    }
    {
      for (i = 1; i <= NF; i++) {
        token = $i
        if (kind == "private") {
          if (token == "PrivateKey:" && i < NF) emit($(i + 1))
          if (token ~ /^PrivateKey:[^[:space:]]+$/) {
            sub(/^PrivateKey:/, "", token)
            emit(token)
          }
          if (token == "Private" && i < NF) {
            next_token = $(i + 1)
            if (next_token == "key:" && i + 1 < NF) emit($(i + 2))
            if (next_token ~ /^key:[^[:space:]]+$/) {
              sub(/^key:/, "", next_token)
              emit(next_token)
            }
          }
        } else {
          if (token == "Password" && i < NF) {
            next_token = $(i + 1)
            if (next_token == "(PublicKey):" && i + 1 < NF) emit($(i + 2))
            if (next_token ~ /^\(PublicKey\):[^[:space:]]+$/) {
              sub(/^\(PublicKey\):/, "", next_token)
              emit(next_token)
            }
          }
          if (token == "Password:" && i < NF) emit($(i + 1))
          if (token ~ /^Password:[^[:space:]]+$/) {
            sub(/^Password:/, "", token)
            emit(token)
          }
          if (token == "PublicKey:" && i < NF) emit($(i + 1))
          if (token ~ /^PublicKey:[^[:space:]]+$/) {
            sub(/^PublicKey:/, "", token)
            emit(token)
          }
          if (token == "Public" && i < NF) {
            next_token = $(i + 1)
            if (next_token == "key:" && i + 1 < NF) emit($(i + 2))
            if (next_token ~ /^key:[^[:space:]]+$/) {
              sub(/^key:/, "", next_token)
              emit(next_token)
            }
          }
        }
      }
    }
  '
}

REALITY_PRIVATE_KEY="$(extract_x25519_value private)"
REALITY_PUBLIC_KEY="$(extract_x25519_value public)"
[[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die "Xray x25519 未返回可识别的私钥/公钥，请检查 Xray 版本"

REALITY_JSON="$(jq -cn \
  --arg tag "$MANAGED_REALITY_TAG" \
  --argjson port "$REALITY_PORT" \
  --arg uuid "$UUID_REALITY" \
  --arg dest "$REALITY_DEST" \
  --arg sni "$REALITY_SNI" \
  --arg private_key "$REALITY_PRIVATE_KEY" \
  --arg short_id "$SHORT_ID" \
  '{tag:$tag,port:$port,protocol:"vless",settings:{clients:[{id:$uuid,flow:"xtls-rprx-vision"}],decryption:"none"},streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,dest:$dest,xver:0,serverNames:[$sni],privateKey:$private_key,shortIds:[$short_id]}},sniffing:{enabled:true,destOverride:["http","tls","quic"],metadataOnly:false,routeOnly:true}}')"

XHTTP_JSON="$(jq -cn \
  --arg tag "$MANAGED_XHTTP_TAG" \
  --argjson port "$XHTTP_PORT" \
  --arg uuid "$UUID_XHTTP" \
  --arg host "$ORIGIN_DOMAIN" \
  --arg path "$XHTTP_PATH" \
  --arg cert "$CERT_FILE" \
  --arg key "$KEY_FILE" \
  '{tag:$tag,port:$port,protocol:"vless",settings:{clients:[{id:$uuid}],decryption:"none"},streamSettings:{network:"xhttp",security:"tls",xhttpSettings:{host:$host,path:$path,mode:"auto"},tlsSettings:{minVersion:"1.2",maxVersion:"1.3",alpn:["h2","h3","http/1.1"],certificates:[{certificateFile:$cert,keyFile:$key}]}},sniffing:{enabled:true,destOverride:["http","tls","quic"],metadataOnly:false,routeOnly:true}}')"

jq --argjson reality "$REALITY_JSON" --argjson xhttp "$XHTTP_JSON" \
  --arg domain_strategy "$OUTBOUND_DOMAIN_STRATEGY" \
  '.inbounds = ((.inbounds // []) | map(select((.tag // "") != "vless-reality-vision" and (.tag // "") != "vless-xhttp-tls")) + [$reality, $xhttp])
   | .outbounds = ((.outbounds // [])
     | map(if (.protocol // "") == "freedom"
           then .settings = ((.settings // {}) + {domainStrategy:$domain_strategy})
           else .
           end)
     | if any(.[]; (.protocol // "") == "freedom")
       then .
       else [{protocol:"freedom",tag:"yijian-direct",settings:{domainStrategy:$domain_strategy}}] + .
       end)' \
  "$BASE_CONFIG" > "$TMP_CONFIG" || die "生成 Xray 配置失败"
jq empty "$TMP_CONFIG" >/dev/null 2>&1 || die "生成的 Xray 配置不是有效 JSON"
ok "Xray 配置已生成，freedom 出站固定使用 IPv${OUTBOUND_IP_VERSION}；原有其他入站和出站保持不变"

echo
echo "--- 第 4 步：应用 Xray 配置 ---"
install -m 600 -- "$TMP_CONFIG" "$CONFIG_PATH"
ok "Xray 配置已写入：$CONFIG_PATH"

start_xray
ok "Xray 已启动：$XRAY_START_MODE"

echo
echo "--- 第 5 步：生成节点和订阅 ---"
# 按 Argosbx 的方式探测：先 IPv4，IPv4 不可用时再使用 IPv6。
V46_URL="https://icanhazip.com"
PUBLIC_IPV4=""
PUBLIC_IPV6=""
if command_exists curl; then
  PUBLIC_IPV4="$(curl -s4m5 -k "$V46_URL" 2>/dev/null | tr -d '[:space:]' || true)"
  PUBLIC_IPV6="$(curl -s6m5 -k "$V46_URL" 2>/dev/null | tr -d '[:space:]' || true)"
else
  PUBLIC_IPV4="$(timeout 5 wget -4 --tries=2 -qO- "$V46_URL" 2>/dev/null | tr -d '[:space:]' || true)"
  PUBLIC_IPV6="$(timeout 5 wget -6 --tries=2 -qO- "$V46_URL" 2>/dev/null | tr -d '[:space:]' || true)"
fi
PUBLIC_HOSTS=()
SUB_HOST=""
if [[ "$PUBLIC_IPV4" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  PUBLIC_HOSTS+=("$PUBLIC_IPV4")
  SUB_HOST="$PUBLIC_IPV4"
fi
if [[ "$PUBLIC_IPV6" == *:* ]]; then
  PUBLIC_HOSTS+=("[$PUBLIC_IPV6]")
  [[ -n "$SUB_HOST" ]] || SUB_HOST="[$PUBLIC_IPV6]"
fi
(( ${#PUBLIC_HOSTS[@]} > 0 )) || die "未能探测公网 IPv4 或 IPv6"
IP_FAMILY=""
[[ -n "$PUBLIC_IPV4" ]] && IP_FAMILY="IPv4"
[[ -n "$PUBLIC_IPV6" ]] && IP_FAMILY="${IP_FAMILY:+$IP_FAMILY/}IPv6"
ok "检测到公网地址：$IP_FAMILY；将生成 ${#PUBLIC_HOSTS[@]} 个 Reality 节点"

REALITY_SNI_ENC="$(urlencode "$REALITY_SNI")"
REALITY_PUBLIC_ENC="$(urlencode "$REALITY_PUBLIC_KEY")"
SHORT_ID_ENC="$(urlencode "$SHORT_ID")"
ORIGIN_ENC="$(urlencode "$ORIGIN_DOMAIN")"
PATH_ENC="$(urlencode "$XHTTP_PATH")"
declare -A NODE_LINK_BASE=()
declare -A NODE_BASE_NAME=()
declare -A NODE_ORDER_USED=()
NODE_GENERATION_ORDER=()

if [[ -n "$PUBLIC_IPV4" ]]; then
  NODE_LINK_BASE[REALITY_V4]="vless://${UUID_REALITY}@${PUBLIC_IPV4}:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI_ENC}&fp=chrome&pbk=${REALITY_PUBLIC_ENC}&sid=${SHORT_ID_ENC}&type=tcp&headerType=none"
  NODE_BASE_NAME[REALITY_V4]="${NODE_NAME_PREFIX}V4-直连"
  NODE_GENERATION_ORDER+=(REALITY_V4)
fi
if [[ -n "$PUBLIC_IPV6" ]]; then
  NODE_LINK_BASE[REALITY_V6]="vless://${UUID_REALITY}@[${PUBLIC_IPV6}]:${REALITY_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI_ENC}&fp=chrome&pbk=${REALITY_PUBLIC_ENC}&sid=${SHORT_ID_ENC}&type=tcp&headerType=none"
  NODE_BASE_NAME[REALITY_V6]="${NODE_NAME_PREFIX}V6-直连"
  NODE_GENERATION_ORDER+=(REALITY_V6)
fi

for preferred_index in "${!PREFERRED_DOMAINS[@]}"; do
  preferred_node_id="CDN_$((preferred_index + 1))"
  PREFERRED_DOMAIN="${PREFERRED_DOMAINS[$preferred_index]}"
  NODE_LINK_BASE["$preferred_node_id"]="vless://${UUID_XHTTP}@${PREFERRED_DOMAIN}:${XHTTP_PORT}?encryption=none&security=tls&sni=${ORIGIN_ENC}&host=${ORIGIN_ENC}&type=xhttp&path=${PATH_ENC}&mode=auto"
  NODE_BASE_NAME["$preferred_node_id"]="${NODE_NAME_PREFIX}V4-CDN-${PREFERRED_DOMAIN}-直连"
  NODE_GENERATION_ORDER+=("$preferred_node_id")
done

NODE_LINES=()
node_number=0
for node_id in "${NODE_ORDER_IDS[@]}"; do
  if [[ -z "${NODE_LINK_BASE[$node_id]+x}" ]]; then
    if [[ "$node_id" == CDN_* ]]; then
      die "NODE_ORDER 中的 $node_id 没有对应的 PREFERRED_DOMAIN_N"
    fi
    warn "NODE_ORDER 中的 $node_id 当前没有可用公网地址，已跳过"
    continue
  fi
  node_number=$((node_number + 1))
  node_order_prefix="$(printf '%02d' "$node_number")-"
  node_display_name="${node_order_prefix}${NODE_BASE_NAME[$node_id]}"
  node_display_name_enc="$(urlencode "$node_display_name")"
  NODE_LINES+=("${NODE_LINK_BASE[$node_id]}#${node_display_name_enc}")
  NODE_ORDER_USED["$node_id"]=1
done

for node_id in "${NODE_GENERATION_ORDER[@]}"; do
  [[ -n "${NODE_ORDER_USED[$node_id]+x}" ]] || die "实际生成的节点 $node_id 未在 NODE_ORDER 中配置"
done

LINK_FILE="$OUTPUT_DIR/vless-links.txt"
printf '%s\n' "${NODE_LINES[@]}" > "$LINK_FILE"
SUB_TOKEN="$(openssl rand -hex 12)"
SUB_ROOT="$OUTPUT_DIR/xray-sub"
SUB_DIR="$SUB_ROOT/$SUB_TOKEN"
SUB_FILE="$SUB_DIR/jhsub.txt"
SUB_PLAIN="$SUB_DIR/nodes.txt"
mkdir -p -- "$SUB_DIR"
printf '%s\n' "${NODE_LINES[@]}" > "$SUB_FILE"
cp -- "$SUB_FILE" "$SUB_PLAIN"
chmod 600 "$LINK_FILE" "$SUB_FILE" "$SUB_PLAIN"
ok "节点链接已写入：$LINK_FILE"

echo
echo "--- 第 6 步：启动订阅 HTTP 服务 ---"
SUB_URL="http://${SUB_HOST}:${SUB_PORT}/${SUB_TOKEN}/jhsub.txt"
SUB_URL_FILE="$OUTPUT_DIR/yijian-subscription-url.txt"
printf '%s\n' "$SUB_URL" > "$SUB_URL_FILE"
chmod 600 "$SUB_URL_FILE"
start_subscription_service
ok "订阅服务已启动：$SUB_START_MODE"
ok "订阅网址已保存：$SUB_URL_FILE"

echo
echo "============================================================"
echo "部署完成"
echo "============================================================"
echo "节点总数：${#NODE_LINES[@]}（Reality=${#PUBLIC_HOSTS[@]}，CDN=${#PREFERRED_DOMAINS[@]}）"
printf '%s\n' "${NODE_LINES[@]}"
echo ""
echo "订阅链接（网址）：$SUB_URL"
echo "订阅文件（明文 jhsub.txt）：$SUB_FILE"
echo "Xray 配置：$CONFIG_PATH"
echo "占用端口：Reality=$REALITY_PORT，XHTTP-TLS=$XHTTP_PORT，订阅HTTP=$SUB_PORT"
echo "整体出站：IPv${OUTBOUND_IP_VERSION}（$OUTBOUND_DOMAIN_STRATEGY）"
echo ""
echo "注意：优选域名为 ${PREFERRED_DOMAINS[*]}；证书域名、Host 和 SNI 为 $ORIGIN_DOMAIN。"
echo "注意：Reality 伪装域名和目标均为 apple.com，采用 Argosbx 默认设置。"
