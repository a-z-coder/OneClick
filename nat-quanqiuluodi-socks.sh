#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# 前置条件：已经运行 Nat机一键命令/nat-oneclick.sh。
# 本脚本不修改原节点和原订阅，另建一份只含全球 SOCKS5 节点的订阅。

SCRIPT_NAME="$(basename "$0")"
CONFIG_PATH="${CONFIG_PATH:-/etc/xray/config.json}"
OUTPUT_DIR="${OUTPUT_DIR:-$(dirname "$CONFIG_PATH")}"
ORIGINAL_LINK_FILE="${ORIGINAL_LINK_FILE:-$OUTPUT_DIR/vless-links.txt}"
ORIGINAL_SUB_URL_FILE="${ORIGINAL_SUB_URL_FILE:-$OUTPUT_DIR/yijian-subscription-url.txt}"
ORIGINAL_SUB_TOKEN_FILE="${ORIGINAL_SUB_TOKEN_FILE:-$OUTPUT_DIR/yijian-subscription-token.txt}"
SUB_ROOT_FILE="${SUB_ROOT_FILE:-$OUTPUT_DIR/yijian-subscription-root.txt}"
GLOBAL_TOKEN_FILE="$OUTPUT_DIR/nat-quanqiuluodi-subscription-token.txt"
GLOBAL_URL_FILE="$OUTPUT_DIR/nat-quanqiuluodi-subscription-url.txt"
GLOBAL_UUID_PREFIX_FILE="$OUTPUT_DIR/nat-quanqiuluodi-uuid-prefix.txt"
GLOBAL_LINK_FILE="$OUTPUT_DIR/nat-quanqiuluodi-links.txt"
MANAGED_PREFIX="nat-global-"
XHTTP_INBOUND_TAG="vless-xhttp-tls"
SOCKS_ADDRESS="${SOCKS_ADDRESS:-10.91.0.1}"
SOCKS_PORT="${SOCKS_PORT:-8080}"
XRAY_BIN="${XRAY_BIN:-}"
TMP_CONFIG=""
TMP_SUB=""

die() {
  echo "错误：$*" >&2
  exit 1
}

ok() {
  echo "[完成] $*"
}

cleanup() {
  [[ -z "$TMP_CONFIG" || ! -e "$TMP_CONFIG" ]] || rm -f -- "$TMP_CONFIG"
  [[ -z "$TMP_SUB" || ! -e "$TMP_SUB" ]] || rm -f -- "$TMP_SUB"
}
trap cleanup EXIT

show_result() {
  [[ -s "$GLOBAL_URL_FILE" ]] || die "尚未生成全球订阅，请先直接运行 $SCRIPT_NAME"
  echo "全球订阅：$(sed -n '1p' "$GLOBAL_URL_FILE")"
  if [[ -s "$GLOBAL_LINK_FILE" ]]; then
    echo "节点数量：$(awk 'NF {count++} END {print count + 0}' "$GLOBAL_LINK_FILE")"
    echo "节点文件：$GLOBAL_LINK_FILE"
  fi
}

restart_xray() {
  local old_pid=""

  if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] \
    && systemctl cat xray-yijian.service >/dev/null 2>&1; then
    systemctl restart xray-yijian.service
    return
  fi

  if command -v rc-service >/dev/null 2>&1 && [[ -x /etc/init.d/xray-yijian ]]; then
    rc-service xray-yijian restart >/dev/null
    return
  fi

  if [[ -s "$OUTPUT_DIR/xray-yijian.pid" ]]; then
    old_pid="$(sed -n '1p' "$OUTPUT_DIR/xray-yijian.pid")"
  fi
  if [[ "$old_pid" =~ ^[0-9]+$ ]] && kill -0 "$old_pid" >/dev/null 2>&1; then
    kill -TERM "$old_pid" || return 1
    sleep 1
    ! kill -0 "$old_pid" >/dev/null 2>&1 || return 1
  fi

  nohup "$XRAY_BIN" run -c "$CONFIG_PATH" >/dev/null 2>&1 &
  local new_pid="$!"
  sleep 1
  kill -0 "$new_pid" >/dev/null 2>&1 || return 1
  printf '%s\n' "$new_pid" > "$OUTPUT_DIR/xray-yijian.pid"
}

[[ "$(id -u)" -eq 0 ]] || die "请使用 root 运行此脚本"

if [[ "${1:-}" == "show" ]]; then
  show_result
  exit 0
fi
[[ -z "${1:-}" ]] || die "未知参数：$1；查看结果请使用：$SCRIPT_NAME show"

command -v jq >/dev/null 2>&1 || die "未找到 jq，请先成功运行 nat-oneclick.sh"
command -v openssl >/dev/null 2>&1 || die "未找到 openssl，请先成功运行 nat-oneclick.sh"
[[ -f "$CONFIG_PATH" ]] || die "找不到 Xray 配置：$CONFIG_PATH"
[[ -s "$ORIGINAL_LINK_FILE" ]] || die "找不到原节点文件：$ORIGINAL_LINK_FILE"
[[ -s "$ORIGINAL_SUB_URL_FILE" ]] || die "找不到原订阅网址文件：$ORIGINAL_SUB_URL_FILE"
[[ -s "$ORIGINAL_SUB_TOKEN_FILE" ]] || die "找不到原订阅令牌文件：$ORIGINAL_SUB_TOKEN_FILE"
[[ -s "$SUB_ROOT_FILE" ]] || die "找不到订阅根目录记录：$SUB_ROOT_FILE"
[[ "$SOCKS_PORT" =~ ^[0-9]+$ ]] && (( SOCKS_PORT >= 1 && SOCKS_PORT <= 65535 )) \
  || die "SOCKS_PORT 必须是 1 到 65535 之间的整数"
jq empty "$CONFIG_PATH" >/dev/null 2>&1 || die "Xray 配置不是有效 JSON：$CONFIG_PATH"

if [[ -z "$XRAY_BIN" ]]; then
  XRAY_BIN="$(command -v xray || true)"
fi
if [[ -z "$XRAY_BIN" && -x /usr/local/bin/xray ]]; then
  XRAY_BIN="/usr/local/bin/xray"
fi
[[ -n "$XRAY_BIN" && -x "$XRAY_BIN" ]] || die "找不到 Xray 可执行文件"

SUB_ROOT="$(sed -n '1p' "$SUB_ROOT_FILE" | tr -d '\r')"
ORIGINAL_SUB_URL="$(sed -n '1p' "$ORIGINAL_SUB_URL_FILE" | tr -d '\r')"
ORIGINAL_SUB_TOKEN="$(sed -n '1p' "$ORIGINAL_SUB_TOKEN_FILE" | tr -d '\r')"
[[ -n "$SUB_ROOT" && -d "$SUB_ROOT" ]] || die "订阅根目录不存在：$SUB_ROOT"
[[ "$ORIGINAL_SUB_URL" == http://*/*/jhsub.txt || "$ORIGINAL_SUB_URL" == https://*/*/jhsub.txt ]] \
  || die "无法解析原订阅网址：$ORIGINAL_SUB_URL"

# 优先国家按要求排列，其后是其他国家/地区，最后是流媒体和服务入口。
ENDPOINTS_JSON="$(cat <<'JSON'
[
  {"code":"us","name":"美国"},
  {"code":"sg","name":"新加坡"},
  {"code":"jp","name":"日本"},
  {"code":"hk","name":"香港"},
  {"code":"kr","name":"韩国"},
  {"code":"my","name":"马来西亚"},
  {"code":"au","name":"澳大利亚"},
  {"code":"nz","name":"新西兰"},
  {"code":"ca","name":"加拿大"},
  {"code":"mx","name":"墨西哥"},
  {"code":"br","name":"巴西"},
  {"code":"ar","name":"阿根廷"},
  {"code":"cl","name":"智利"},
  {"code":"gb","name":"英国"},
  {"code":"de","name":"德国"},
  {"code":"fr","name":"法国"},
  {"code":"nl","name":"荷兰"},
  {"code":"ch","name":"瑞士"},
  {"code":"ae","name":"阿联酋"},
  {"code":"za","name":"南非"},
  {"code":"is","name":"冰岛"},
  {"code":"ng","name":"尼日利亚"},
  {"code":"tr","name":"土耳其"},
  {"code":"ua","name":"乌克兰"},
  {"code":"dk","name":"丹麦"},
  {"code":"af","name":"阿富汗"},
  {"code":"al","name":"阿尔巴尼亚"},
  {"code":"dz","name":"阿尔及利亚"},
  {"code":"ad","name":"安道尔"},
  {"code":"ao","name":"安哥拉"},
  {"code":"am","name":"亚美尼亚"},
  {"code":"aw","name":"阿鲁巴"},
  {"code":"at","name":"奥地利"},
  {"code":"az","name":"阿塞拜疆"},
  {"code":"bh","name":"巴林"},
  {"code":"bd","name":"孟加拉国"},
  {"code":"bb","name":"巴巴多斯"},
  {"code":"by","name":"白俄罗斯"},
  {"code":"be","name":"比利时"},
  {"code":"bm","name":"百慕大"},
  {"code":"bt","name":"不丹"},
  {"code":"bo","name":"玻利维亚"},
  {"code":"ba","name":"波斯尼亚和黑塞哥维那"},
  {"code":"vg","name":"英属维尔京群岛"},
  {"code":"bn","name":"文莱"},
  {"code":"bg","name":"保加利亚"},
  {"code":"kh","name":"柬埔寨"},
  {"code":"ky","name":"开曼群岛"},
  {"code":"cn","name":"中国"},
  {"code":"co","name":"哥伦比亚"},
  {"code":"cr","name":"哥斯达黎加"},
  {"code":"hr","name":"克罗地亚"},
  {"code":"cy","name":"塞浦路斯"},
  {"code":"cz","name":"捷克"},
  {"code":"ec","name":"厄瓜多尔"},
  {"code":"eg","name":"埃及"},
  {"code":"ee","name":"爱沙尼亚"},
  {"code":"fi","name":"芬兰"},
  {"code":"ge","name":"格鲁吉亚"},
  {"code":"gr","name":"希腊"},
  {"code":"gt","name":"危地马拉"},
  {"code":"hu","name":"匈牙利"},
  {"code":"in","name":"印度"},
  {"code":"id","name":"印度尼西亚"},
  {"code":"ie","name":"爱尔兰"},
  {"code":"it","name":"意大利"},
  {"code":"kz","name":"哈萨克斯坦"},
  {"code":"lv","name":"拉脱维亚"},
  {"code":"lt","name":"立陶宛"},
  {"code":"lu","name":"卢森堡"},
  {"code":"md","name":"摩尔多瓦"},
  {"code":"mc","name":"摩纳哥"},
  {"code":"no","name":"挪威"},
  {"code":"om","name":"阿曼"},
  {"code":"pa","name":"巴拿马"},
  {"code":"pe","name":"秘鲁"},
  {"code":"ph","name":"菲律宾"},
  {"code":"pl","name":"波兰"},
  {"code":"pt","name":"葡萄牙"},
  {"code":"pr","name":"波多黎各"},
  {"code":"ro","name":"罗马尼亚"},
  {"code":"ru","name":"俄罗斯"},
  {"code":"rs","name":"塞尔维亚"},
  {"code":"sk","name":"斯洛伐克"},
  {"code":"si","name":"斯洛文尼亚"},
  {"code":"es","name":"西班牙"},
  {"code":"se","name":"瑞典"},
  {"code":"tw","name":"台湾"},
  {"code":"th","name":"泰国"},
  {"code":"bs","name":"巴哈马"},
  {"code":"uy","name":"乌拉圭"},
  {"code":"ve","name":"委内瑞拉"},
  {"code":"vn","name":"越南"},
  {"code":"nfx","name":"Netflix美国"},
  {"code":"apus","name":"Amazon Prime美国"},
  {"code":"nxuk","name":"Netflix英国"},
  {"code":"bpuk","name":"BBC iPlayer英国"},
  {"code":"ch4","name":"Channel 4英国"},
  {"code":"itv","name":"ITV英国"},
  {"code":"hulu","name":"Hulu美国"},
  {"code":"nxau","name":"Netflix澳大利亚"},
  {"code":"nine","name":"Nine澳大利亚"},
  {"code":"ftel","name":"Foxtel Now澳大利亚"},
  {"code":"tply","name":"10 Play澳大利亚"},
  {"code":"esus","name":"ESPN+美国"},
  {"code":"hbom","name":"Max美国"},
  {"code":"para","name":"Paramount+美国"},
  {"code":"abus","name":"ABC美国"},
  {"code":"dsus","name":"Disney+美国"},
  {"code":"apuk","name":"Amazon Prime英国"},
  {"code":"ptv","name":"Peacock美国"},
  {"code":"fbtv","name":"Fubo美国"},
  {"code":"sbsa","name":"SBS澳大利亚"},
  {"code":"cgpt","name":"ChatGPT"},
  {"code":"mgmp","name":"MGM+美国"},
  {"code":"optu","name":"Optus Sport澳大利亚"},
  {"code":"svnp","name":"7plus澳大利亚"},
  {"code":"ch5","name":"Channel 5英国"},
  {"code":"nfde","name":"Netflix德国"},
  {"code":"tubi","name":"Tubi美国"},
  {"code":"spnt","name":"Sportsnet加拿大"},
  {"code":"cbcg","name":"CBC Gem加拿大"},
  {"code":"svtv","name":"ServusTV奥地利"},
  {"code":"roku","name":"Roku美国"},
  {"code":"dscv","name":"Discovery+美国"},
  {"code":"cwnw","name":"CW美国"},
  {"code":"amtv","name":"Amazon miniTV印度"},
  {"code":"hall","name":"Hallmark+美国"},
  {"code":"xumo","name":"Xumo美国"},
  {"code":"amc","name":"AMC+美国"}
]
JSON
)"

ENDPOINT_COUNT="$(jq 'length' <<<"$ENDPOINTS_JSON")"
UNIQUE_CODE_COUNT="$(jq '[.[].code] | unique | length' <<<"$ENDPOINTS_JSON")"
PRIORITY_CODES="$(jq -r '.[0:25] | map(.code) | join(",")' <<<"$ENDPOINTS_JSON")"
[[ "$ENDPOINT_COUNT" -eq 130 && "$UNIQUE_CODE_COUNT" -eq 130 ]] \
  || die "脚本内置 SOCKS 清单不完整或存在重复 code"
[[ "$PRIORITY_CODES" == "us,sg,jp,hk,kr,my,au,nz,ca,mx,br,ar,cl,gb,de,fr,nl,ch,ae,za,is,ng,tr,ua,dk" ]] \
  || die "脚本内置优先国家顺序不正确"

if [[ -s "$GLOBAL_UUID_PREFIX_FILE" ]]; then
  UUID_PREFIX="$(sed -n '1p' "$GLOBAL_UUID_PREFIX_FILE" | tr -d '\r')"
else
  UUID_SEED="$(cat /proc/sys/kernel/random/uuid)"
  UUID_PREFIX="${UUID_SEED:0:24}"
fi
[[ "$UUID_PREFIX" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-$ ]] \
  || die "全球节点 UUID 前缀无效：$UUID_PREFIX"

# 将唯一 code 编码到 UUID 最后一组，避免调用 130 次随机命令。
MANAGED_ENDPOINTS="$(jq -cn \
  --argjson endpoints "$ENDPOINTS_JSON" \
  --arg uuid_prefix "$UUID_PREFIX" '
    def hex_digit: ["0","1","2","3","4","5","6","7","8","9","a","b","c","d","e","f"][.];
    def hex_byte: [((. / 16) | floor | hex_digit), ((. % 16) | hex_digit)] | join("");
    def uuid_suffix:
      (explode | map(hex_byte) | join("")) as $hex
      | ("000000000000" + $hex)[-12:];
    $endpoints | map(. + {id: ($uuid_prefix + (.code | uuid_suffix))})
  ')"
[[ "$(jq '[.[].id] | unique | length' <<<"$MANAGED_ENDPOINTS")" -eq "$ENDPOINT_COUNT" ]] \
  || die "生成的全球节点 UUID 存在重复"

# 从原 XHTTP 节点提取 TLS、Host、SNI 和路径，只把连接域名固定为 cdn.shopify.com。
BASE_XHTTP="$(awk '/^vless:\/\// && /type=xhttp/ {print; exit}' "$ORIGINAL_LINK_FILE")"
[[ -n "$BASE_XHTTP" ]] || die "原节点文件中没有 VLESS-XHTTP 节点"
BASE_NO_NAME="${BASE_XHTTP%%#*}"
[[ "$BASE_NO_NAME" == *\?* ]] || die "无法解析原 XHTTP 节点参数"
BASE_AUTHORITY="${BASE_NO_NAME%%\?*}"
BASE_QUERY="${BASE_NO_NAME#*\?}"
BASE_SERVER="${BASE_AUTHORITY#*@}"
CDN_PORT="${BASE_SERVER##*:}"
[[ "$CDN_PORT" =~ ^[0-9]+$ ]] || die "无法解析原 XHTTP 节点端口"
[[ "&$BASE_QUERY&" == *"&security=tls&"* && "&$BASE_QUERY&" == *"&type=xhttp&"* ]] \
  || die "原 XHTTP 节点不是 TLS + XHTTP 节点"
CDN_TAIL="cdn.shopify.com:${CDN_PORT}?${BASE_QUERY}"

if [[ -s "$GLOBAL_TOKEN_FILE" ]]; then
  GLOBAL_TOKEN="$(sed -n '1p' "$GLOBAL_TOKEN_FILE" | tr -d '\r')"
else
  GLOBAL_TOKEN="$(openssl rand -hex 12)"
fi
[[ "$GLOBAL_TOKEN" =~ ^[0-9a-f]{24}$ ]] || die "全球订阅令牌格式无效"
[[ "$GLOBAL_TOKEN" != "$ORIGINAL_SUB_TOKEN" ]] || die "全球订阅令牌与原订阅重复，未执行修改"

SUB_BASE_URL="${ORIGINAL_SUB_URL%/*}"
SUB_BASE_URL="${SUB_BASE_URL%/*}"
GLOBAL_SUB_URL="$SUB_BASE_URL/$GLOBAL_TOKEN/jhsub.txt"
[[ "$GLOBAL_SUB_URL" != "$ORIGINAL_SUB_URL" ]] || die "新旧订阅网址相同，未执行修改"
GLOBAL_SUB_DIR="$SUB_ROOT/$GLOBAL_TOKEN"
GLOBAL_SUB_FILE="$GLOBAL_SUB_DIR/jhsub.txt"
GLOBAL_PLAIN_FILE="$GLOBAL_SUB_DIR/nodes.txt"
mkdir -p -- "$GLOBAL_SUB_DIR"

TMP_CONFIG="$(mktemp "$OUTPUT_DIR/nat-global-config.XXXXXX")"
mv -- "$TMP_CONFIG" "${TMP_CONFIG}.json"
TMP_CONFIG="${TMP_CONFIG}.json"
TMP_SUB="$(mktemp "$GLOBAL_SUB_DIR/nat-global-sub.XXXXXX")"

jq \
  --argjson endpoints "$MANAGED_ENDPOINTS" \
  --arg inbound_tag "$XHTTP_INBOUND_TAG" \
  --arg prefix "$MANAGED_PREFIX" \
  --arg socks_address "$SOCKS_ADDRESS" \
  --argjson socks_port "$SOCKS_PORT" '
    ([.inbounds | to_entries[]
      | select(.value.tag == $inbound_tag and .value.protocol == "vless")
      | .key]) as $inbound_indexes
    | if ($inbound_indexes | length) != 1
      then error("未找到唯一的 vless-xhttp-tls 入站")
      else .
      end
    | ($inbound_indexes[0]) as $i
    | .inbounds[$i].settings.clients = (
        ((.inbounds[$i].settings.clients // [])
          | map(select((((.email // "") | startswith($prefix))) | not)))
        + ($endpoints | map({id: .id, email: ($prefix + .code)}))
      )
    | .outbounds = (
        ((.outbounds // [])
          | map(select((((.tag // "") | startswith($prefix))) | not)))
        + ($endpoints | map({
            tag: ($prefix + .code + "-out"),
            protocol: "socks",
            settings: {
              servers: [{
                address: $socks_address,
                port: $socks_port,
                users: [{user: ("user-" + .code), pass: ("globe-server-" + .code)}]
              }]
            }
          }))
      )
    | .routing = (
        (.routing // {})
        | .rules = (
            ($endpoints | map({
              type: "field",
              user: [($prefix + .code)],
              outboundTag: ($prefix + .code + "-out")
            }))
            + ((.rules // [])
              | map(select((((.outboundTag // "") | startswith($prefix))) | not)))
          )
      )
  ' "$CONFIG_PATH" > "$TMP_CONFIG" || die "生成 Xray 全球路由配置失败，原配置未修改"

jq empty "$TMP_CONFIG" >/dev/null 2>&1 || die "生成的 Xray 配置不是有效 JSON，原配置未修改"
if ! XRAY_TEST_OUTPUT="$("$XRAY_BIN" run -test -c "$TMP_CONFIG" 2>&1)"; then
  echo "---------------- Xray 配置检查日志 ----------------" >&2
  printf '%s\n' "$XRAY_TEST_OUTPUT" >&2
  echo "----------------------------------------------------" >&2
  die "Xray 配置检查失败，原配置未修改"
fi

jq -r --arg tail "$CDN_TAIL" \
  '.[] | "vless://\(.id)@\($tail)#\(("nat全球-" + .name) | @uri)"' \
  <<<"$MANAGED_ENDPOINTS" > "$TMP_SUB"
FINAL_NODE_COUNT="$(awk 'NF {count++} END {print count + 0}' "$TMP_SUB")"
EXPECTED_NODE_COUNT="$ENDPOINT_COUNT"
[[ "$FINAL_NODE_COUNT" -eq "$EXPECTED_NODE_COUNT" ]] \
  || die "订阅节点数量校验失败，原配置未修改"

STAMP="$(date +%Y%m%d%H%M%S)"
CONFIG_BACKUP="${CONFIG_PATH}.bak.nat-global.${STAMP}"
cp -p -- "$CONFIG_PATH" "$CONFIG_BACKUP"

GLOBAL_SUB_BACKUP=""
if [[ -e "$GLOBAL_SUB_FILE" ]]; then
  GLOBAL_SUB_BACKUP="${GLOBAL_SUB_FILE}.bak.${STAMP}"
  cp -p -- "$GLOBAL_SUB_FILE" "$GLOBAL_SUB_BACKUP"
fi

install -m 600 -- "$TMP_CONFIG" "$CONFIG_PATH"
install -m 600 -- "$TMP_SUB" "$GLOBAL_SUB_FILE"
install -m 600 -- "$TMP_SUB" "$GLOBAL_PLAIN_FILE"

if ! restart_xray; then
  cp -p -- "$CONFIG_BACKUP" "$CONFIG_PATH"
  if [[ -n "$GLOBAL_SUB_BACKUP" ]]; then
    cp -p -- "$GLOBAL_SUB_BACKUP" "$GLOBAL_SUB_FILE"
  fi
  die "Xray 重启失败；配置和已有全球订阅已恢复，请检查服务日志"
fi

install -m 600 -- "$TMP_SUB" "$GLOBAL_LINK_FILE"
printf '%s\n' "$GLOBAL_TOKEN" > "$GLOBAL_TOKEN_FILE"
printf '%s\n' "$GLOBAL_SUB_URL" > "$GLOBAL_URL_FILE"
printf '%s\n' "$UUID_PREFIX" > "$GLOBAL_UUID_PREFIX_FILE"
chmod 600 "$GLOBAL_TOKEN_FILE" "$GLOBAL_URL_FILE" "$GLOBAL_UUID_PREFIX_FILE"

ok "原订阅未修改：$ORIGINAL_SUB_URL"
ok "全球订阅已生成：$GLOBAL_SUB_URL"
ok "新订阅共 $FINAL_NODE_COUNT 个全球 SOCKS5 节点，不包含原节点"
ok "全球节点统一经 cdn.shopify.com 接入"
ok "Xray 配置备份：$CONFIG_BACKUP"
echo "再次查看：$SCRIPT_NAME show"
