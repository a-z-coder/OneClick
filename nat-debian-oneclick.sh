#!/bin/sh
if [ -z "${BASH_VERSION:-}" ]; then
  if command -v bash >/dev/null 2>&1; then exec bash "$0" "$@"; fi
  if command -v apk >/dev/null 2>&1; then apk add --no-cache bash || exit 1; exec bash "$0" "$@"; fi
  echo "[失败] 本脚本需要 Bash；当前系统没有 Bash，也无法使用 apk 安装" >&2
  exit 1
fi
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_VERSION="2.1.4"
OUTPUT_DIR="/etc/xray"
CONFIG_PATH="$OUTPUT_DIR/config.json"
SUB_ROOT="$OUTPUT_DIR/xray-sub"
TMP_DIR=""
XRAY_BIN=""
NGINX_BIN=""
NGINX_USER="nginx"
NGINX_GROUP="nginx"
SERVICE_MODE=""
PACKAGE_MANAGER=""
BASE_CONFIG=""
TMP_CONFIG=""
CERT_FILE=""
KEY_FILE=""
CERT_SHA256=""
CONFIG_INPUT=""
CERT_CONTENT=""
KEY_CONTENT=""
SUBSCRIPTION_MODE="NONE"
SUBSCRIPTION_ENABLED=0
CERT_REQUIRED=0
SUB_DOMAIN=""
SUB_IP=""
SUB_PORT=""
SUB_TOKEN=""
SUB_HOST=""
SUB_HOST_FAMILY=""
SUB_URL=""
SUB_DIR=""
SUB_FILE=""
XHTTP_PATH=""
REALITY_SNI="apple.com"
REALITY_DEST="apple.com:443"
declare -A CONFIG_VALUES=()
declare -a NODE_IDS=() NODE_TYPES=() NODE_PORTS=() NODE_ENTRY_IPS=() NODE_EXIT_IPS=()
declare -a NODE_NAMES=() NODE_IP_FAMILIES=() NODE_EXIT_FAMILIES=()
declare -a NODE_HY2_STARTS=() NODE_HY2_ENDS=() NODE_HY2_PASSWORDS=()
declare -a HY2_IDS=() NODE_LINES=() NEW_INBOUNDS=() NEW_OUTBOUNDS=() NEW_RULES=()

cleanup() { [[ -z "$TMP_DIR" || ! -d "$TMP_DIR" ]] || { rm -f -- "$TMP_DIR"/* 2>/dev/null || true; rmdir -- "$TMP_DIR" 2>/dev/null || true; }; }
trap cleanup EXIT
die() { printf '[失败] %s\n' "$*" >&2; exit 1; }
info() { printf '[信息] %s\n' "$*"; }
ok() { printf '[成功] %s\n' "$*"; }
warn() { printf '[警告] %s\n' "$*" >&2; }
command_exists() { command -v "$1" >/dev/null 2>&1; }
trim_value() { local v="$1"; v="${v#${v%%[![:space:]]*}}"; v="${v%${v##*[![:space:]]}}"; printf '%s' "$v"; }
config_value() { printf '%s' "${CONFIG_VALUES[$1]:-}"; }
required_value() { local v="${CONFIG_VALUES[$1]:-}"; [[ -n "$v" ]] || die "配置中缺少 $1"; printf '%s' "$v"; }
urlencode() { jq -nr --arg value "$1" '$value | @uri'; }
url_host() { [[ "$1" == *:* ]] && printf '[%s]' "$1" || printf '%s' "$1"; }

extract_pem_block() {
  local begin="$1" end="$2"
  printf '%s\n' "$CONFIG_INPUT" | awk -v begin="$begin" -v end="$end" '$0==begin{capture=1;print;next} capture{print; if($0==end){found=1;exit}} END{if(!found)exit 1}'
}

read_deployment_config() {
  local line key value pem="" field node_index=0 has_cert=0 has_key=0
  printf '请粘贴从 YIjian_CONFIG_BEGIN 到 YIjian_CONFIG_END 的完整配置；每次 NODE_TYPE 开始一个新节点：\n' >&2
  CONFIG_INPUT="$(awk '{sub(/\r$/,""); if($0=="YIjian_CONFIG_BEGIN"){started=1;next} if($0=="YIjian_CONFIG_END"){if(started)found=1;exit} if(started&&$0!="```")print} END{if(!started||!found)exit 1}')" || die "配置必须包含 YIjian_CONFIG_BEGIN 和 YIjian_CONFIG_END"
  [[ -n "$CONFIG_INPUT" ]] || die "部署配置不能为空"
  while IFS= read -r line; do
    line="$(trim_value "$line")"; [[ -n "$line" ]] || continue
    if [[ -n "$pem" ]]; then [[ "$line" == "${pem}_END" ]] && pem=""; continue; fi
    case "$line" in CERTIFICATE_BEGIN) pem=CERTIFICATE; continue;; PRIVATE_KEY_BEGIN) pem=PRIVATE_KEY; continue;; \#*) continue;; esac
    [[ "$line" =~ ^([A-Z0-9_]+)=(.*)$ ]] || die "无法识别的配置行：$line"
    key="${BASH_REMATCH[1]}"; value="$(trim_value "${BASH_REMATCH[2]}")"
    if [[ "$key" =~ ^NODE_(TYPE|PORT|PORT_RANGE|ENTRY_IP|EXIT_IP|NAME|PREFERRED_DOMAIN|ORIGIN_DOMAIN|SNI|PASSWORD)$ ]]; then
      field="${BASH_REMATCH[1]}"
      if [[ "$field" == TYPE ]]; then node_index=$((node_index + 1)); elif (( node_index == 0 )); then die "NODE_TYPE 必须放在每个节点配置的第一行"; fi
      key="NODE_${node_index}_${field}"
    elif [[ "$key" != SUBSCRIPTION_MODE && "$key" != SUB_DOMAIN && "$key" != SUB_IP && "$key" != SUB_PORT && "$key" != SUB_TOKEN ]]; then
      die "未知配置项：$key"
    fi
    [[ -z "${CONFIG_VALUES[$key]+x}" ]] || die "配置项重复：$key"
    CONFIG_VALUES["$key"]="$value"
  done <<< "$CONFIG_INPUT"
  [[ -z "$pem" ]] || die "证书或私钥区块缺少结束标记"
  [[ "$CONFIG_INPUT" == *CERTIFICATE_BEGIN* ]] && has_cert=1
  [[ "$CONFIG_INPUT" == *PRIVATE_KEY_BEGIN* ]] && has_key=1
  (( has_cert == has_key )) || die "证书和私钥必须同时提供"
  if (( has_cert == 1 )); then CERT_CONTENT="$(extract_pem_block CERTIFICATE_BEGIN CERTIFICATE_END)" || die "证书区块不完整"; KEY_CONTENT="$(extract_pem_block PRIVATE_KEY_BEGIN PRIVATE_KEY_END)" || die "私钥区块不完整"; fi
}

validate_port() { local label="$1" value="$2"; [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]] || die "$label 必须是 1 到 65535 的十进制整数"; (( value <= 65535 )) || die "$label 超出范围"; }
validate_domain() {
  local label="$1" value="$2" part; local -a parts=()
  (( ${#value} <= 253 )) || die "$label 过长：$value"; [[ "$value" == *.* ]] || die "$label 必须是完整域名：$value"
  IFS='.' read -r -a parts <<< "$value"
  for part in "${parts[@]}"; do (( ${#part} <= 63 )) || die "$label 标签过长：$value"; [[ "$part" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || die "$label 格式不正确：$value"; done
  [[ "$value" != *..* && "$value" != *. ]] || die "$label 格式不正确：$value"
}
validate_ipv4() { local v="$1" o; local -a a=(); [[ "$v" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1; IFS=. read -r -a a <<< "$v"; for o in "${a[@]}"; do [[ "$o" == 0 || "$o" != 0* ]] || return 1; (( 10#$o <= 255 )) || return 1; done; }
validate_ipv6() { local v="$1" rest group count=0; [[ "$v" == *:* && "$v" =~ ^[0-9A-Fa-f:]+$ && "$v" != *:::* ]] || return 1; [[ "$v" != :* || "$v" == ::* ]] || return 1; [[ "$v" != *: || "$v" == *:: ]] || return 1; [[ "$v" != *::* || "${v#*::}" != *::* ]] || return 1; rest="$v"; while [[ -n "$rest" ]]; do if [[ "$rest" == *:* ]]; then group="${rest%%:*}"; rest="${rest#*:}"; else group="$rest"; rest=""; fi; if [[ -n "$group" ]]; then [[ "$group" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1; count=$((count+1)); fi; done; if [[ "$v" == *::* ]]; then (( count < 8 )); else (( count == 8 )); fi; }
ip_family() { validate_ipv4 "$1" && { printf 4; return; }; validate_ipv6 "$1" && { printf 6; return; }; return 1; }

validate_deployment_config() {
  local index prefix type port entry exit range start end password sni key field subscription_mode expected=1 other
  local -a raw_indices=(); declare -A used_ports=()
  for key in "${!CONFIG_VALUES[@]}"; do [[ "$key" =~ ^NODE_([1-9][0-9]*)_ ]] && raw_indices+=("${BASH_REMATCH[1]}"); done
  (( ${#raw_indices[@]} > 0 )) || die "配置中没有节点"
  mapfile -t NODE_IDS < <(printf '%s\n' "${raw_indices[@]}" | sort -nu)
  for index in "${NODE_IDS[@]}"; do [[ "$index" == "$expected" ]] || die "节点编号必须从 1 连续递增，缺少 NODE_${expected}"; expected=$((expected+1)); done
  for index in "${NODE_IDS[@]}"; do
    prefix="NODE_${index}"; type="$(required_value "${prefix}_TYPE")"; NODE_TYPES[$index]="$type"; NODE_NAMES[$index]="$(required_value "${prefix}_NAME")"
    for key in "${!CONFIG_VALUES[@]}"; do [[ "$key" == "${prefix}_"* ]] || continue; field="${key#${prefix}_}"; case "$type" in REALITY) [[ "$field" =~ ^(TYPE|PORT|ENTRY_IP|EXIT_IP|NAME)$ ]] || die "节点 $index 的 REALITY 不使用 $field";; CDN) [[ "$field" =~ ^(TYPE|PORT|PREFERRED_DOMAIN|ORIGIN_DOMAIN|NAME)$ ]] || die "节点 $index 的 CDN 不使用 $field";; HY2) [[ "$field" =~ ^(TYPE|PORT_RANGE|ENTRY_IP|EXIT_IP|SNI|PASSWORD|NAME)$ ]] || die "节点 $index 的 HY2 不使用 $field";; *) die "节点 $index 的 TYPE 只能是 REALITY、CDN 或 HY2";; esac; done
    case "$type" in
      REALITY) port="$(required_value "${prefix}_PORT")"; validate_port "节点 $index 的 Reality 端口" "$port"; entry="$(required_value "${prefix}_ENTRY_IP")"; exit="$(required_value "${prefix}_EXIT_IP")"; ;;
      CDN) port="$(required_value "${prefix}_PORT")"; validate_port "节点 $index 的 CDN 端口" "$port"; validate_domain "节点 $index 的优选域名" "$(required_value "${prefix}_PREFERRED_DOMAIN")"; validate_domain "节点 $index 的源站域名" "$(required_value "${prefix}_ORIGIN_DOMAIN")"; case "$port" in 443|2053|2083|2087|2096|8443);; *) die "节点 $index 的 CDN 端口不是 Cloudflare 支持的端口";; esac; CERT_REQUIRED=1; ;;
      HY2) range="$(required_value "${prefix}_PORT_RANGE")"; [[ "$range" =~ ^([1-9][0-9]{0,4}):([1-9][0-9]{0,4})$ ]] || die "节点 $index 的 PORT_RANGE 必须是 起始端口:结束端口"; start="${BASH_REMATCH[1]}"; end="${BASH_REMATCH[2]}"; validate_port "节点 $index 的 HY2 起始端口" "$start"; validate_port "节点 $index 的 HY2 结束端口" "$end"; (( end > start )) || die "节点 $index 的 HY2 结束端口必须大于起始端口"; port="$start"; NODE_HY2_STARTS[$index]="$start"; NODE_HY2_ENDS[$index]="$end"; HY2_IDS+=("$index"); entry="$(required_value "${prefix}_ENTRY_IP")"; exit="$(required_value "${prefix}_EXIT_IP")"; sni="$(required_value "${prefix}_SNI")"; validate_domain "节点 $index 的 HY2 SNI" "$sni"; password="$(required_value "${prefix}_PASSWORD")"; [[ "$password" == AUTO || "$password" =~ ^[A-Za-z0-9._~-]{8,128}$ ]] || die "节点 $index 的 HY2 密码格式不正确"; NODE_HY2_PASSWORDS[$index]="$password"; CERT_REQUIRED=1; ;;
      *) die "节点 $index 的 TYPE 只能是 REALITY、CDN 或 HY2";;
    esac
    NODE_PORTS[$index]="$port"
    if [[ "$type" == REALITY || "$type" == HY2 ]]; then NODE_ENTRY_IPS[$index]="$entry"; NODE_EXIT_IPS[$index]="$exit"; NODE_IP_FAMILIES[$index]="$(ip_family "$entry")" || die "节点 $index 的入口 IP 无效"; NODE_EXIT_FAMILIES[$index]="$(ip_family "$exit")" || die "节点 $index 的出口 IP 无效"; [[ "$entry" != 0.0.0.0 && "$entry" != :: && "$exit" != 0.0.0.0 && "$exit" != :: ]] || die "节点 $index 的 IP 不能是未指定地址"; fi
    [[ -z "${used_ports[$port]+x}" ]] || die "节点 $index 的端口 $port 与节点 ${used_ports[$port]} 重复"; used_ports[$port]="$index"
  done
  subscription_mode="$(config_value SUBSCRIPTION_MODE)"; if [[ -z "$subscription_mode" ]]; then [[ -n "${CONFIG_VALUES[SUB_DOMAIN]+x}" ]] && subscription_mode=DOMAIN || subscription_mode=NONE; fi; SUB_DOMAIN=""; SUB_IP=""; SUB_PORT=""; SUB_TOKEN=""
  case "$subscription_mode" in
    NONE) for key in SUB_DOMAIN SUB_IP SUB_PORT SUB_TOKEN; do [[ -z "${CONFIG_VALUES[$key]+x}" ]] || die "SUBSCRIPTION_MODE=NONE 时不能配置 $key"; done;;
    DOMAIN) [[ -z "${CONFIG_VALUES[SUB_IP]+x}" ]] || die "DOMAIN 模式不使用 SUB_IP"; SUB_DOMAIN="$(required_value SUB_DOMAIN)"; SUB_PORT="$(required_value SUB_PORT)"; SUB_TOKEN="$(required_value SUB_TOKEN)"; validate_domain "订阅域名" "$SUB_DOMAIN"; validate_port "HTTPS 订阅端口" "$SUB_PORT"; SUB_HOST="$SUB_DOMAIN"; SUBSCRIPTION_ENABLED=1; CERT_REQUIRED=1;;
    IP) [[ -z "${CONFIG_VALUES[SUB_DOMAIN]+x}" ]] || die "IP 模式不使用 SUB_DOMAIN"; SUB_IP="$(required_value SUB_IP)"; SUB_PORT="$(required_value SUB_PORT)"; SUB_TOKEN="$(required_value SUB_TOKEN)"; SUB_HOST_FAMILY="$(ip_family "$SUB_IP")" || die "订阅 IP 无效"; validate_port "HTTP 订阅端口" "$SUB_PORT"; SUB_HOST="$SUB_IP"; SUBSCRIPTION_ENABLED=1;;
    *) die "SUBSCRIPTION_MODE 只能是 NONE、DOMAIN 或 IP";;
  esac
  SUBSCRIPTION_MODE="$subscription_mode"; (( CERT_REQUIRED == 0 )) || [[ -n "$CERT_CONTENT" && -n "$KEY_CONTENT" ]] || die "当前配置需要同时提供证书和私钥"
  if (( SUBSCRIPTION_ENABLED == 1 )); then [[ -z "${used_ports[$SUB_PORT]+x}" ]] || die "订阅端口与节点端口重复"; [[ "$SUB_TOKEN" == AUTO || "$SUB_TOKEN" =~ ^[A-Za-z0-9_-]{12,64}$ ]] || die "SUB_TOKEN 格式不正确"; fi
  for index in "${HY2_IDS[@]}"; do
    start="${NODE_HY2_STARTS[$index]}"; end="${NODE_HY2_ENDS[$index]}"
    (( SUBSCRIPTION_ENABLED == 0 || SUB_PORT < start || SUB_PORT > end )) || die "订阅端口落在节点 $index 的 HY2 跳跃范围内"
    for other in "${NODE_IDS[@]}"; do [[ "$other" == "$index" ]] && continue; port="${NODE_PORTS[$other]}"; (( port < start || port > end )) || die "节点 $other 的端口落在节点 $index 的 HY2 跳跃范围内"; done
    for other in "${HY2_IDS[@]}"; do [[ "$other" -gt "$index" ]] || continue; (( ${NODE_HY2_STARTS[$other]} > end || ${NODE_HY2_ENDS[$other]} < start )) || die "节点 $index 与节点 $other 的 HY2 跳跃范围重叠"; done
  done
}

detect_platform() {
  if command_exists systemctl && [[ -d /run/systemd/system ]]; then SERVICE_MODE=systemd; elif command_exists rc-service && command_exists rc-update; then SERVICE_MODE=openrc; else die "未找到可用的 systemd 或 OpenRC 服务管理器"; fi
  if command_exists apk; then PACKAGE_MANAGER=apk; elif command_exists apt-get; then PACKAGE_MANAGER=apt; else die "未找到支持的 apk 或 apt-get 软件包管理器"; fi
}
find_nginx_runner() { if command_exists nginx && nginx -v >/dev/null 2>&1; then NGINX_BIN="$(command -v nginx)"; return; fi; NGINX_BIN=""; return 1; }
find_xray() { local c; command_exists xray && { command -v xray; return; }; for c in /usr/local/bin/xray /usr/bin/xray /usr/local/sbin/xray; do [[ -x "$c" ]] && { printf '%s' "$c"; return; }; done; return 1; }
install_dependencies() {
  local -a packages=(jq openssl unzip coreutils curl ca-certificates); (( SUBSCRIPTION_ENABLED == 1 )) && packages+=(nginx); (( ${#HY2_IDS[@]} > 0 )) && packages+=(nftables)
  local -a missing=(); local p; for p in "${packages[@]}"; do case "$p" in jq) command_exists jq || missing+=("$p");; openssl) command_exists openssl || missing+=("$p");; unzip) command_exists unzip || missing+=("$p");; coreutils) command_exists sha256sum || missing+=("$p");; curl) command_exists curl || missing+=("$p");; ca-certificates) [[ -s /etc/ssl/certs/ca-certificates.crt ]] || missing+=("$p");; nginx) command_exists nginx || missing+=("$p");; nftables) command_exists nft || missing+=("$p");; esac; done
  if (( ${#missing[@]} > 0 )); then
    info "安装缺少的工具：${missing[*]}"
    if [[ "$PACKAGE_MANAGER" == apk ]]; then apk add --no-cache "${missing[@]}" || die "Alpine 依赖安装失败"; else apt-get update || die "APT 软件源更新失败"; DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" || die "APT 依赖安装失败"; fi
  fi
  command_exists jq && command_exists openssl && command_exists sha256sum && { command_exists curl || command_exists wget; } || die "依赖安装后仍缺少必需工具"; (( SUBSCRIPTION_ENABLED == 0 )) || find_nginx_runner || die "订阅模式需要 Nginx"; (( ${#HY2_IDS[@]} == 0 )) || command_exists nft || die "HY2 需要 nftables";
  if (( SUBSCRIPTION_ENABLED == 1 )); then
    if id nginx >/dev/null 2>&1; then NGINX_USER=nginx; NGINX_GROUP=nginx; elif id www-data >/dev/null 2>&1; then NGINX_USER=www-data; NGINX_GROUP=www-data; else die "找不到 Nginx 运行用户"; fi
    if [[ "$SERVICE_MODE" == systemd ]]; then systemctl disable --now nginx.service >/dev/null 2>&1 || true; else rc-service nginx stop >/dev/null 2>&1 || true; rc-update del nginx default >/dev/null 2>&1 || true; fi
  fi
}

install_xray() { local asset archive extract_dir; case "$(uname -m)" in x86_64|amd64) asset=Xray-linux-64.zip;; aarch64|arm64) asset=Xray-linux-arm64-v8a.zip;; *) die "当前架构不受 Xray 支持";; esac; archive="$(mktemp /tmp/xray.XXXXXX.zip)"; extract_dir="$(mktemp -d /tmp/xray-core.XXXXXX)"; if command_exists curl; then curl -fL "https://github.com/XTLS/Xray-core/releases/latest/download/$asset" -o "$archive" || die "下载 Xray 失败"; else wget -O "$archive" "https://github.com/XTLS/Xray-core/releases/latest/download/$asset" || die "下载 Xray 失败"; fi; unzip -j "$archive" xray -d "$extract_dir" >/dev/null || die "解压 Xray 失败"; install -m 755 "$extract_dir/xray" /usr/local/bin/xray || die "安装 Xray 失败"; rm -f "$archive" "$extract_dir/xray"; rmdir "$extract_dir" 2>/dev/null || true; XRAY_BIN=/usr/local/bin/xray; "$XRAY_BIN" version >/dev/null 2>&1 || die "安装后的 Xray 无法运行"; }

prepare_certificate() {
  local cert_pub key_pub domain index; printf '%s\n' "$CERT_CONTENT" > "$TMP_DIR/cert.pem"; printf '%s\n' "$KEY_CONTENT" > "$TMP_DIR/key.pem"; openssl x509 -in "$TMP_DIR/cert.pem" -noout >/dev/null 2>&1 || die "证书不是有效 PEM X.509"; openssl pkey -in "$TMP_DIR/key.pem" -passin pass: -noout >/dev/null 2>&1 || die "私钥无效或带密码"; if [[ "$SUBSCRIPTION_MODE" == DOMAIN ]]; then openssl x509 -in "$TMP_DIR/cert.pem" -noout -checkhost "$SUB_DOMAIN" >/dev/null 2>&1 || die "证书不包含订阅域名"; fi; for index in "${NODE_IDS[@]}"; do case "${NODE_TYPES[$index]}" in CDN) domain="$(config_value "NODE_${index}_ORIGIN_DOMAIN")";; HY2) domain="$(config_value "NODE_${index}_SNI")";; *) continue;; esac; openssl x509 -in "$TMP_DIR/cert.pem" -noout -checkhost "$domain" >/dev/null 2>&1 || die "证书不包含节点 $index 的域名"; done; cert_pub="$(openssl x509 -in "$TMP_DIR/cert.pem" -pubkey -noout | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"; key_pub="$(openssl pkey -in "$TMP_DIR/key.pem" -passin pass: -pubout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"; [[ -n "$cert_pub" && "$cert_pub" == "$key_pub" ]] || die "证书和私钥不匹配"; CERT_SHA256="$(openssl x509 -in "$TMP_DIR/cert.pem" -outform DER | sha256sum | awk '{print $1}')"; CERT_FILE="$OUTPUT_DIR/yijian-origin-cert.pem"; KEY_FILE="$OUTPUT_DIR/yijian-origin-key.pem"; install -m 600 "$TMP_DIR/cert.pem" "$CERT_FILE"; install -m 600 "$TMP_DIR/key.pem" "$KEY_FILE";
}

extract_x25519_value() { local kind="$1"; printf '%s\n' "$KEY_OUTPUT" | awk -v kind="$kind" 'function emit(v){gsub(/\r/,"",v);gsub(/^[[:space:]]+|[[:space:]]+$/, "", v);if(v!=""){print v;exit}}{for(i=1;i<=NF;i++){t=$i;if(kind=="private"){if(t=="PrivateKey:"&&i<NF)emit($(i+1));if(t~/^PrivateKey:[^[:space:]]+$/){sub(/^PrivateKey:/,"",t);emit(t)};if(t=="Private"&&i<NF){n=$(i+1);if(n=="key:"&&i+1<NF)emit($(i+2));if(n~/^key:[^[:space:]]+$/){sub(/^key:/,"",n);emit(n)}}}else{if(t=="Password"&&i<NF){n=$(i+1);if(n=="(PublicKey):"&&i+1<NF)emit($(i+2));if(n~/^\(PublicKey\):[^[:space:]]+$/){sub(/^\(PublicKey\):/,"",n);emit(n)}};if(t=="Password:"&&i<NF)emit($(i+1));if(t~/^Password:[^[:space:]]+$/){sub(/^Password:/,"",t);emit(t)};if(t=="PublicKey:"&&i<NF)emit($(i+1));if(t~/^PublicKey:[^[:space:]]+$/){sub(/^PublicKey:/,"",t);emit(t)};if(t=="Public"&&i<NF){n=$(i+1);if(n=="key:"&&i+1<NF)emit($(i+2));if(n~/^key:[^[:space:]]+$/){sub(/^key:/,"",n);emit(n)}}}}}' ; }

prepare_base_config() { TMP_CONFIG="$TMP_DIR/config.json"; if [[ -e "$CONFIG_PATH" ]]; then [[ -f "$CONFIG_PATH" ]] || die "Xray 配置路径不是普通文件"; jq empty "$CONFIG_PATH" >/dev/null 2>&1 || die "现有 Xray 配置不是有效 JSON"; BASE_CONFIG="$CONFIG_PATH"; else BASE_CONFIG="$TMP_DIR/base.json"; cat > "$BASE_CONFIG" <<'EOF'
{"log":{"loglevel":"warning"},"inbounds":[],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"blackhole","tag":"block"}]}
EOF
  fi; }

build_nodes() {
  local index prefix type port tag outtag entry exit family name uuid short_id private_key public_key reality_json outbound_json rule_json link listen origin preferred path_enc origin_enc password sni
  REALITY_SNI_ENC="$(urlencode "$REALITY_SNI")"; XHTTP_PATH="/xhttp-$(openssl rand -hex 6)"; path_enc="$(urlencode "$XHTTP_PATH")"; NEW_INBOUNDS=(); NEW_OUTBOUNDS=(); NEW_RULES=(); NODE_LINES=()
  for index in "${NODE_IDS[@]}"; do prefix="NODE_${index}"; type="${NODE_TYPES[$index]}"; port="${NODE_PORTS[$index]}"; name="${NODE_NAMES[$index]}"; tag="yijian-in-$index"; outtag="yijian-out-$index"; listen="0.0.0.0"; [[ "$type" == CDN || "${NODE_IP_FAMILIES[$index]:-4}" == 6 ]] && listen="::";
    case "$type" in
      REALITY) entry="${NODE_ENTRY_IPS[$index]}"; exit="${NODE_EXIT_IPS[$index]}"; family="${NODE_EXIT_FAMILIES[$index]}"; uuid="$(cat /proc/sys/kernel/random/uuid)"; short_id="$(openssl rand -hex 8)"; KEY_OUTPUT="$($XRAY_BIN x25519 2>&1)" || die "节点 $index 的 Reality 密钥生成失败"; private_key="$(extract_x25519_value private)"; public_key="$(extract_x25519_value public)"; [[ -n "$private_key" && -n "$public_key" ]] || die "节点 $index 的 Reality 密钥无法识别"; reality_json="$(jq -cn --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg uuid "$uuid" --arg dest "$REALITY_DEST" --arg sni "$REALITY_SNI" --arg pk "$private_key" --arg sid "$short_id" '{tag:$tag,listen:$listen,port:$port,protocol:"vless",settings:{clients:[{id:$uuid,flow:"xtls-rprx-vision"}],decryption:"none"},streamSettings:{network:"tcp",security:"reality",realitySettings:{show:false,dest:$dest,xver:0,serverNames:[$sni],privateKey:$pk,shortIds:[$sid]}}}')"; outbound_json="$(jq -cn --arg tag "$outtag" --arg exit "$exit" --arg strategy "UseIPv$family" '{tag:$tag,protocol:"freedom",sendThrough:$exit,settings:{domainStrategy:$strategy}}')"; link="vless://$uuid@$(url_host "$entry"):$port?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_SNI_ENC&fp=chrome&pbk=$(urlencode "$public_key")&sid=$short_id&type=tcp&headerType=none#$(urlencode "$name")";;
      CDN) preferred="$(config_value "${prefix}_PREFERRED_DOMAIN")"; origin="$(config_value "${prefix}_ORIGIN_DOMAIN")"; uuid="$(cat /proc/sys/kernel/random/uuid)"; reality_json="$(jq -cn --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg uuid "$uuid" --arg path "$XHTTP_PATH" --arg cert "$CERT_FILE" --arg key "$KEY_FILE" '{tag:$tag,listen:$listen,port:$port,protocol:"vless",settings:{clients:[{id:$uuid}],decryption:"none"},streamSettings:{network:"xhttp",security:"tls",xhttpSettings:{path:$path,mode:"auto"},tlsSettings:{alpn:["h2","http/1.1"],certificates:[{certificateFile:$cert,keyFile:$key}]}}}')"; outbound_json="$(jq -cn --arg tag "$outtag" '{tag:$tag,protocol:"freedom",settings:{domainStrategy:"AsIs"}}')"; origin_enc="$(urlencode "$origin")"; link="vless://$uuid@$preferred:$port?encryption=none&security=tls&sni=$origin_enc&host=$origin_enc&type=xhttp&path=$path_enc&mode=auto#$(urlencode "$name")";;
      HY2) entry="${NODE_ENTRY_IPS[$index]}"; exit="${NODE_EXIT_IPS[$index]}"; family="${NODE_EXIT_FAMILIES[$index]}"; sni="$(config_value "${prefix}_SNI")"; password="${NODE_HY2_PASSWORDS[$index]}"; [[ "$password" == AUTO ]] && password="$(openssl rand -hex 16)" && NODE_HY2_PASSWORDS[$index]="$password"; reality_json="$(jq -cn --arg tag "$tag" --arg listen "$listen" --argjson port "$port" --arg auth "$password" --arg cert "$CERT_FILE" --arg key "$KEY_FILE" '{tag:$tag,listen:$listen,port:$port,protocol:"hysteria",settings:{version:2,users:[{auth:$auth}]},streamSettings:{method:"hysteria",security:"tls",hysteriaSettings:{version:2},tlsSettings:{alpn:["h3"],certificates:[{certificateFile:$cert,keyFile:$key}]}}}')"; outbound_json="$(jq -cn --arg tag "$outtag" --arg exit "$exit" --arg strategy "UseIPv$family" '{tag:$tag,protocol:"freedom",sendThrough:$exit,settings:{domainStrategy:$strategy}}')"; link="hysteria2://$(urlencode "$password")@$(url_host "$entry"):$port?security=tls&alpn=h3&insecure=0&allowInsecure=0&mport=${NODE_HY2_STARTS[$index]}-${NODE_HY2_ENDS[$index]}&sni=$(urlencode "$sni")&pinSHA256=$CERT_SHA256#$(urlencode "$name")";;
    esac
    NEW_INBOUNDS+=("$reality_json"); NEW_OUTBOUNDS+=("$outbound_json"); rule_json="$(jq -cn --arg inbound "$tag" --arg outbound "$outtag" '{type:"field",inboundTag:[$inbound],outboundTag:$outbound}')"; NEW_RULES+=("$rule_json"); NODE_LINES+=("$link")
  done
}

merge_xray_config() { local i o r; i="$(printf '%s\n' "${NEW_INBOUNDS[@]}" | jq -s '.')"; o="$(printf '%s\n' "${NEW_OUTBOUNDS[@]}" | jq -s '.')"; r="$(printf '%s\n' "${NEW_RULES[@]}" | jq -s '.')"; jq --argjson ni "$i" --argjson no "$o" --argjson nr "$r" 'def mi: test("^yijian-in-[1-9][0-9]*$") or .=="vless-reality-vision" or .=="vless-xhttp-tls"; def mo: test("^yijian-out-[1-9][0-9]*$"); .inbounds=((.inbounds//[])|map(select((.tag//"")|mi|not))+$ni)|.outbounds=((.outbounds//[])|map(select((.tag//"")|mo|not))+$no)|.routing=(.routing//{})|.routing.rules=($nr+((.routing.rules//[])|map(select((any(.inboundTag[]?;mi) or ((.outboundTag//"")|mo))|not))))' "$BASE_CONFIG" > "$TMP_CONFIG" || die "生成 Xray 配置失败"; jq empty "$TMP_CONFIG" >/dev/null 2>&1 || die "生成的 Xray 配置不是有效 JSON"; "$XRAY_BIN" run -test -c "$TMP_CONFIG" >/dev/null 2>&1 || die "Xray 配置检查失败"; }

configure_hy2_hop_service() {
  local index nft_file=/etc/xray/yijian-hy2-hop.nft nft_bin="$(command -v nft || true)"
  if (( ${#HY2_IDS[@]} == 0 )); then
    if [[ "$SERVICE_MODE" == systemd ]]; then systemctl disable --now xray-yijian-hy2-hop.service >/dev/null 2>&1 || true; else rc-service xray-yijian-hy2-hop stop >/dev/null 2>&1 || true; rc-update del xray-yijian-hy2-hop default >/dev/null 2>&1 || true; fi
    rm -f -- /etc/systemd/system/xray-yijian-hy2-hop.service
    [[ "$SERVICE_MODE" == systemd ]] && systemctl daemon-reload >/dev/null 2>&1 || true
    rm -f -- "$nft_file" /etc/init.d/xray-yijian-hy2-hop
    command_exists nft && nft delete table inet xray_yijian_hy2 >/dev/null 2>&1 || true
    return
  fi
  [[ -n "$nft_bin" ]] || die "找不到 nftables"
  cat > "$nft_file" <<'EOF'
table inet xray_yijian_hy2 {
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
EOF
  for index in "${HY2_IDS[@]}"; do
    if [[ "${NODE_IP_FAMILIES[$index]}" == 6 ]]; then
      printf '    ip6 daddr %s udp dport %s-%s redirect to :%s\n' "${NODE_ENTRY_IPS[$index]}" "${NODE_HY2_STARTS[$index]}" "${NODE_HY2_ENDS[$index]}" "${NODE_HY2_STARTS[$index]}" >> "$nft_file"
    else
      printf '    ip daddr %s udp dport %s-%s redirect to :%s\n' "${NODE_ENTRY_IPS[$index]}" "${NODE_HY2_STARTS[$index]}" "${NODE_HY2_ENDS[$index]}" "${NODE_HY2_STARTS[$index]}" >> "$nft_file"
    fi
  done
  cat >> "$nft_file" <<'EOF'
  }
}
EOF
  if [[ "$SERVICE_MODE" == systemd ]]; then
    cat > /etc/systemd/system/xray-yijian-hy2-hop.service <<EOF
[Unit]
Description=Xray yijian HY2 UDP port hopping
After=network-online.target
Wants=network-online.target
Before=xray-yijian.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-$nft_bin delete table inet xray_yijian_hy2
ExecStart=$nft_bin -f $nft_file
ExecStop=-$nft_bin delete table inet xray_yijian_hy2

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || die "systemd 配置加载失败"
    systemctl enable xray-yijian-hy2-hop.service >/dev/null || die "无法启用 HY2 跳跃服务"
    systemctl restart xray-yijian-hy2-hop.service || die "无法应用 HY2 跳跃规则"
    systemctl is-active --quiet xray-yijian-hy2-hop.service || die "HY2 跳跃服务未运行"
    return
  fi
  cat > /etc/init.d/xray-yijian-hy2-hop <<EOF
#!/sbin/openrc-run
description="Xray yijian HY2 UDP port hopping"
command="$nft_bin"
command_args="-f $nft_file"
start_pre() { "$nft_bin" delete table inet xray_yijian_hy2 >/dev/null 2>&1 || true; }
stop() { "$nft_bin" delete table inet xray_yijian_hy2 >/dev/null 2>&1 || true; }
depend() { need net; }
EOF
  chmod 755 /etc/init.d/xray-yijian-hy2-hop
  rc-update add xray-yijian-hy2-hop default >/dev/null 2>&1 || die "无法启用 HY2 跳跃自启动"
  rc-service xray-yijian-hy2-hop restart >/dev/null 2>&1 || die "无法应用 HY2 跳跃规则"
  rc-service xray-yijian-hy2-hop status >/dev/null 2>&1 || die "HY2 跳跃服务未运行"
}

start_xray_service() {
  if [[ "$SERVICE_MODE" == systemd ]]; then
    cat > /etc/systemd/system/xray-yijian.service <<EOF
[Unit]
Description=Xray yijian node service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$XRAY_BIN run -c $CONFIG_PATH
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || die "systemd 配置加载失败"
    systemctl enable xray-yijian.service >/dev/null || die "无法启用 Xray 自启动"
    systemctl restart xray-yijian.service || die "Xray 启动失败"
    systemctl is-active --quiet xray-yijian.service || die "Xray 服务未运行"
    return
  fi
  cat > /etc/init.d/xray-yijian <<EOF
#!/sbin/openrc-run
description="Xray yijian node service"
command="$XRAY_BIN"
command_args="run -c $CONFIG_PATH"
command_background="yes"
pidfile="/run/xray-yijian.pid"
depend() { need net; use xray-yijian-hy2-hop; }
EOF
  chmod 755 /etc/init.d/xray-yijian
  rc-update add xray-yijian default >/dev/null 2>&1 || die "无法启用 Xray 自启动"
  rc-service xray-yijian restart >/dev/null 2>&1 || rc-service xray-yijian start >/dev/null 2>&1 || die "Xray 启动失败"
  rc-service xray-yijian status >/dev/null 2>&1 || die "Xray 服务未运行"
}

write_subscription_files() {
  [[ "$SUB_TOKEN" == AUTO ]] && SUB_TOKEN="$(openssl rand -hex 16)"
  SUB_DIR="$SUB_ROOT/$SUB_TOKEN"; SUB_FILE="$SUB_DIR/jhsub.txt"; mkdir -p -- "$SUB_DIR"
  printf '%s\n' "${NODE_LINES[@]}" > "$OUTPUT_DIR/vless-links.txt"; printf '%s\n' "${NODE_LINES[@]}" > "$SUB_FILE"
  chmod 600 "$OUTPUT_DIR/vless-links.txt"; chmod 640 "$SUB_FILE"; id "$NGINX_USER" >/dev/null 2>&1 || die "找不到 Nginx 运行用户"; chown "root:$NGINX_GROUP" "$SUB_ROOT" "$SUB_DIR" "$SUB_FILE" || die "无法设置订阅文件属主"; chmod 750 "$SUB_ROOT" "$SUB_DIR"
  if [[ "$SUBSCRIPTION_MODE" == IP ]]; then SUB_URL_HOST="$(url_host "$SUB_IP")"; SUB_URL_SCHEME=http; else SUB_URL_HOST="$SUB_DOMAIN"; SUB_URL_SCHEME=https; fi
  if [[ "$SUB_PORT" == 443 && "$SUB_URL_SCHEME" == https ]]; then SUB_URL="${SUB_URL_SCHEME}://${SUB_URL_HOST}/${SUB_TOKEN}/jhsub.txt"; else SUB_URL="${SUB_URL_SCHEME}://${SUB_URL_HOST}:${SUB_PORT}/${SUB_TOKEN}/jhsub.txt"; fi
  printf '%s\n' "$SUB_URL" > "$OUTPUT_DIR/yijian-subscription-url.txt"; printf '%s\n' "$SUB_PORT" > "$OUTPUT_DIR/yijian-subscription-port.txt"; printf '%s\n' "$SUB_TOKEN" > "$OUTPUT_DIR/yijian-subscription-token.txt"; printf '%s\n' "$SUB_ROOT" > "$OUTPUT_DIR/yijian-subscription-root.txt"; chmod 600 "$OUTPUT_DIR"/yijian-subscription-*.txt
}

write_subscription_nginx_config() {
  local listen_address="0.0.0.0" ipv6_listen="" server_name="$SUB_DOMAIN" listen_suffix=" ssl" tls_config=""
  [[ "$SUBSCRIPTION_MODE" == IP ]] && server_name=_
  if [[ "$SUBSCRIPTION_MODE" == DOMAIN ]]; then
    tls_config="$(printf '%s\n' "    ssl_certificate $CERT_FILE;" "    ssl_certificate_key $KEY_FILE;" "    ssl_protocols TLSv1.2 TLSv1.3;")"
  else
    listen_suffix=""
  fi
  [[ -s /proc/net/if_inet6 ]] && ipv6_listen="        listen [::]:$SUB_PORT$listen_suffix;"
  SUB_NGINX_CONF="$OUTPUT_DIR/yijian-subscription-nginx.conf"; SUB_NGINX_PID="/run/xray-yijian-sub-nginx.pid"
  cat > "$SUB_NGINX_CONF" <<EOF
user $NGINX_USER;
daemon off;
worker_processes 1;
pid $SUB_NGINX_PID;
error_log $OUTPUT_DIR/yijian-subscription-nginx-error.log warn;
events { worker_connections 64; }
http {
  access_log off;
  sendfile on;
  keepalive_timeout 15;
  server {
    listen $listen_address:$SUB_PORT$listen_suffix;
$ipv6_listen
    server_name $server_name;
$tls_config
    location = /$SUB_TOKEN/jhsub.txt { root $SUB_ROOT; default_type text/plain; add_header Cache-Control "no-store" always; }
    location / { return 404; }
  }
}
EOF
  chmod 600 "$SUB_NGINX_CONF"; "$NGINX_BIN" -t -c "$SUB_NGINX_CONF" >/dev/null 2>&1 || die "Nginx 订阅配置检查失败"
}

start_subscription_service() {
  find_nginx_runner || true; [[ -n "$NGINX_BIN" ]] || die "未找到 Nginx"
  write_subscription_nginx_config
  if [[ "$SERVICE_MODE" == systemd ]]; then
    systemctl stop xray-yijian-sub.service >/dev/null 2>&1 || true
    cat > /etc/systemd/system/xray-yijian-sub.service <<EOF
[Unit]
Description=Xray yijian HTTPS subscription
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$NGINX_BIN -c $SUB_NGINX_CONF
ExecStop=$NGINX_BIN -c $SUB_NGINX_CONF -s quit
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload || die "systemd 配置加载失败"
    systemctl enable xray-yijian-sub.service >/dev/null || die "无法启用订阅服务自启动"
    systemctl restart xray-yijian-sub.service || die "订阅服务启动失败"
    systemctl is-active --quiet xray-yijian-sub.service || die "订阅服务未运行"
    return
  fi
  rc-service xray-yijian-sub stop >/dev/null 2>&1 || true
  cat > /etc/init.d/xray-yijian-sub <<EOF
#!/sbin/openrc-run
description="Xray yijian HTTPS subscription"
command="$NGINX_BIN"
command_args="-c $SUB_NGINX_CONF"
command_background="yes"
pidfile="$SUB_NGINX_PID"
depend() { need net; }
EOF
  chmod 755 /etc/init.d/xray-yijian-sub
  rc-update add xray-yijian-sub default >/dev/null 2>&1 || die "无法启用订阅服务自启动"
  rc-service xray-yijian-sub restart >/dev/null 2>&1 || rc-service xray-yijian-sub start >/dev/null 2>&1 || die "订阅服务启动失败"
  rc-service xray-yijian-sub status >/dev/null 2>&1 || die "订阅服务未运行"
}

stop_subscription_service() { if [[ "$SERVICE_MODE" == systemd ]]; then systemctl disable --now xray-yijian-sub.service >/dev/null 2>&1 || true; rm -f -- /etc/systemd/system/xray-yijian-sub.service; systemctl daemon-reload >/dev/null 2>&1 || true; else rc-service xray-yijian-sub stop >/dev/null 2>&1 || true; rc-update del xray-yijian-sub default >/dev/null 2>&1 || true; rm -f -- /etc/init.d/xray-yijian-sub; fi; rm -f -- "$OUTPUT_DIR"/yijian-subscription-*.txt "$OUTPUT_DIR/yijian-subscription-nginx.conf"; }
verify_subscription() {
  local local_url response="" host_header="$SUB_DOMAIN"
  if [[ "$SUBSCRIPTION_MODE" == IP ]]; then host_header="$SUB_IP"; [[ "$SUB_HOST_FAMILY" == 6 ]] && local_url="http://[::1]:$SUB_PORT/$SUB_TOKEN/jhsub.txt" || local_url="http://127.0.0.1:$SUB_PORT/$SUB_TOKEN/jhsub.txt"; else [[ "$SUB_PORT" == 443 ]] && local_url="https://$SUB_DOMAIN/$SUB_TOKEN/jhsub.txt" || local_url="https://$SUB_DOMAIN:$SUB_PORT/$SUB_TOKEN/jhsub.txt"; fi
  if command_exists curl; then
    if [[ "$SUBSCRIPTION_MODE" == DOMAIN ]]; then response="$(curl -fsSk --noproxy '*' --max-time 8 --resolve "$SUB_DOMAIN:$SUB_PORT:127.0.0.1" "$local_url" 2>/dev/null || true)"; else response="$(curl -fsSk --noproxy '*' --max-time 8 -H "Host: $host_header" "$local_url" 2>/dev/null || true)"; fi
  fi
  [[ "$response" == vless://* || "$response" == hysteria2://* ]] || die "本机订阅检查失败"
}

show_port_usage() { if command_exists ss; then ss -lntup; elif command_exists netstat; then netstat -lntup; else printf '未找到 ss 或 netstat，无法显示端口占用\n'; fi; }
show_deployment() {
  local output_dir="${1:-$OUTPUT_DIR}" line count=0 url_file="$output_dir/yijian-subscription-url.txt"; [[ -s "$output_dir/vless-links.txt" ]] || die "找不到已生成的节点文件"
  while IFS= read -r line; do [[ -n "$line" ]] || continue; count=$((count+1)); printf '节点 %s：%s\n' "$count" "$line"; done < "$output_dir/vless-links.txt"; printf '节点总数：%s\n' "$count"; if [[ -s "$url_file" ]]; then printf '订阅：%s\n' "$(sed -n '1p' "$url_file")"; else printf '订阅：未启用\n'; fi; show_port_usage
}

main() {
  [[ "$(id -u)" -eq 0 ]] || die "请使用 root 运行此脚本"
  if [[ "${1:-}" == show ]]; then show_deployment "${2:-$OUTPUT_DIR}"; return; fi
  [[ -z "${1:-}" ]] || die "未知参数：$1；可用参数为 show [输出目录]"
  detect_platform
  printf 'NAT 一键部署 %s（服务管理：%s，依赖管理：%s）\n' "$SCRIPT_VERSION" "$SERVICE_MODE" "$PACKAGE_MANAGER"
  read_deployment_config
  validate_deployment_config
  TMP_DIR="$(mktemp -d /tmp/xray-yijian.XXXXXX)" || die "无法创建临时目录"
  install_dependencies
  XRAY_BIN="$(find_xray || true)"; if [[ -z "$XRAY_BIN" ]]; then install_xray; fi
  mkdir -p -- "$OUTPUT_DIR"
  (( CERT_REQUIRED == 0 )) || prepare_certificate
  prepare_base_config
  build_nodes
  merge_xray_config
  install -m 600 "$TMP_CONFIG" "$CONFIG_PATH"
  configure_hy2_hop_service
  start_xray_service
  printf '%s\n' "${NODE_LINES[@]}" > "$OUTPUT_DIR/vless-links.txt"; chmod 600 "$OUTPUT_DIR/vless-links.txt"
  if (( SUBSCRIPTION_ENABLED == 1 )); then write_subscription_files; start_subscription_service; verify_subscription; else stop_subscription_service; fi
  if (( SUBSCRIPTION_ENABLED == 1 )); then ok "${#NODE_IDS[@]} 个节点和订阅服务已部署"; else ok "${#NODE_IDS[@]} 个节点已部署，订阅未启用"; fi
  printf '%s\n' "${NODE_LINES[@]}"
  (( SUBSCRIPTION_ENABLED == 1 )) && printf '订阅网址：%s\n' "$SUB_URL" || printf '订阅网址：未启用\n'
  for index in "${HY2_IDS[@]}"; do printf '节点 %s 的 HY2 UDP 跳跃范围：%s:%s\n' "$index" "${NODE_HY2_STARTS[$index]}" "${NODE_HY2_ENDS[$index]}"; done
  printf '节点文件：%s/vless-links.txt\n' "$OUTPUT_DIR"
}
main "$@"
