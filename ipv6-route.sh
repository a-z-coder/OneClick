#!/usr/bin/env bash
set -Eeuo pipefail

VERSION=1.0.2
CONFIG_DIR=/etc/ipv6-route-setup
CONFIG_FILE=$CONFIG_DIR/addresses.list
INSTALLED_SCRIPT=/usr/local/sbin/ipv6-route-setup
SERVICE_FILE=/etc/systemd/system/ipv6-route-setup.service
XRAY_SERVICE=/etc/systemd/system/xray-yijian.service
XRAY_DROPIN=/etc/systemd/system/xray-yijian.service.d/10-ipv6-route-setup.conf

umask 077

die() {
  printf '错误：%s\n' "$*" >&2
  exit 1
}

require_host() {
  [[ $EUID -eq 0 ]] || die '请以 root 运行。'
  [[ -f /etc/os-release ]] || die '无法确认系统版本。'
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ ${ID:-} == debian && ${VERSION_ID:-} == 13 ]] || die '仅支持 Debian 13。'
  command -v ip >/dev/null 2>&1 || die '缺少 ip 命令，请先安装 iproute2。'
  command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]] || die '需要 systemd。'
}

require_install_source() {
  [[ -f ${BASH_SOURCE[0]} && -s ${BASH_SOURCE[0]} ]] ||
    die '请先把脚本保存为文件再运行；从管道运行无法安装开机服务。'
}

valid_ip() {
  local address=$1 first
  [[ $address == *:* && $address =~ ^[0-9a-fA-F:]+$ ]] || return 1
  first=${address%%:*}
  [[ $first =~ ^[0-9a-fA-F]{4}$ ]] || return 1
  (( 16#$first >= 0x2000 && 16#$first <= 0x3fff )) || return 1
  ip -6 -o address show to "$address/128" >/dev/null 2>&1
}

valid_iface() {
  [[ $1 =~ ^[a-zA-Z0-9_.:-]+$ && -d /sys/class/net/$1 ]]
}

detect_iface() {
  local -a routes=()
  mapfile -t routes < <(ip -6 route show default)
  (( ${#routes[@]} == 1 )) || die '未找到唯一的 IPv6 默认路由，无法自动确定网卡。'
  [[ ${routes[0]} =~ (^|[[:space:]])dev[[:space:]]([^[:space:]]+) ]] || die 'IPv6 默认路由未包含网卡。'
  DETECTED_IFACE=${BASH_REMATCH[2]}
  valid_iface "$DETECTED_IFACE" || die 'IPv6 默认路由的网卡无效。'
}

load_config() {
  local -a lines=()
  [[ -f $CONFIG_FILE ]] || die '尚未保存 IPv6 地址，请先直接运行脚本并输入地址。'
  mapfile -t lines < "$CONFIG_FILE"
  (( ${#lines[@]} >= 2 )) || die '地址配置文件不完整。'
  CONFIG_IFACE=${lines[0]}
  valid_iface "$CONFIG_IFACE" || die '保存的网卡不存在。'
  CONFIG_IPS=("${lines[@]:1}")
  local address
  for address in "${CONFIG_IPS[@]}"; do
    valid_ip "$address" || die "保存的 IPv6 地址无效：$address"
  done
}

address_state() {
  ip -6 -o address show to "$1/128"
}

rollback_added() {
  local address
  for address in "$@"; do
    ip -6 address del "$address/128" dev "$CONFIG_IFACE" >/dev/null 2>&1 || true
  done
}

apply_list() {
  local address state pending=0
  local -a added=()
  for address in "${CONFIG_IPS[@]}"; do
    state=$(address_state "$address") || die "无法检查 IPv6 地址：$address"
    if [[ -z $state ]]; then
      if ! ip -6 address add "$address/128" dev "$CONFIG_IFACE" preferred_lft 0; then
        rollback_added "${added[@]}"
        die "无法把 $address 添加到 $CONFIG_IFACE。"
      fi
      added+=("$address")
      pending=1
    elif [[ $state == *tentative* ]]; then
      pending=1
    fi
  done
  # DAD 在内核中并行执行；只等待一次，不重试添加地址。
  if (( pending )); then sleep 5; fi
  for address in "${CONFIG_IPS[@]}"; do
    if ! state=$(address_state "$address"); then
      rollback_added "${added[@]}"
      die "无法检查 IPv6 地址：$address"
    fi
    if [[ -z $state || $state == *dadfailed* || $state == *tentative* ]]; then
      rollback_added "${added[@]}"
      die "IPv6 地址未就绪：$address"
    fi
  done
  printf '已配置 %s 个 IPv6 地址，网卡：%s\n' "${#CONFIG_IPS[@]}" "$CONFIG_IFACE"
}

apply_addresses() {
  load_config
  apply_list
}

write_config() {
  local tmp
  install -d -m 700 "$CONFIG_DIR"
  tmp=$(mktemp "$CONFIG_DIR/.addresses.XXXXXXXX") || die '无法创建临时配置文件。'
  chmod 600 "$tmp"
  printf '%s\n' "$CONFIG_IFACE" "${CONFIG_IPS[@]}" > "$tmp"
  mv -f -- "$tmp" "$CONFIG_FILE"
}

install_service() {
  if [[ $(readlink -f -- "${BASH_SOURCE[0]}") != "$INSTALLED_SCRIPT" ]]; then
    install -m 755 -- "${BASH_SOURCE[0]}" "$INSTALLED_SCRIPT"
  fi
  [[ -s $INSTALLED_SCRIPT ]] || die '安装后的脚本为空。'
  /bin/bash -n "$INSTALLED_SCRIPT" || die '安装后的脚本有语法错误。'
  cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=Restore extra IPv6 addresses for nodes
Wants=network-online.target
After=network-online.target
Before=xray-yijian.service

[Service]
Type=oneshot
ExecStart=/bin/bash /usr/local/sbin/ipv6-route-setup apply
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  install -d -m 755 "${XRAY_DROPIN%/*}"
  cat > "$XRAY_DROPIN" <<'EOF'
[Unit]
Requires=ipv6-route-setup.service
After=ipv6-route-setup.service
EOF
  systemctl daemon-reload
  systemctl enable ipv6-route-setup.service >/dev/null
  systemctl restart ipv6-route-setup.service || die '地址服务启动失败，请查看 journalctl -u ipv6-route-setup.service -b。'
}

configure() {
  local address=''
  local -a requested=()
  local -A known=()
  require_install_source
  detect_iface
  if [[ -f $CONFIG_FILE ]]; then
    load_config
    [[ $CONFIG_IFACE == "$DETECTED_IFACE" ]] || die '当前 IPv6 默认网卡与已保存的网卡不同，请先核对网络配置。'
  else
    CONFIG_IFACE=$DETECTED_IFACE
    CONFIG_IPS=()
  fi
  printf '检测到 IPv6 网卡：%s\n' "$CONFIG_IFACE"
  printf '每行输入一个 IPv6，输入空行后开始配置：\n'
  while IFS= read -r address || [[ -n $address ]]; do
    address=${address%$'\r'}
    [[ -n $address ]] || break
    requested+=("$address")
  done
  (( ${#requested[@]} > 0 )) || die '没有输入 IPv6 地址。'
  for address in "${CONFIG_IPS[@]}"; do known["$address"]=1; done
  for address in "${requested[@]}"; do
    valid_ip "$address" || die "IPv6 地址格式无效或不是公网单播地址：$address"
    if [[ ! -v known["$address"] ]]; then
      CONFIG_IPS+=("$address")
      known["$address"]=1
    fi
  done
  apply_list
  write_config
  finish_setup
}

finish_setup() {
  install_service
  if [[ -f $XRAY_SERVICE ]] && ! systemctl is-active --quiet xray-yijian.service; then
    systemctl start xray-yijian.service || die 'IPv6 已配置，但 Xray 仍未启动；请查看 journalctl -u xray-yijian.service -b。'
  fi
  printf '完成。重启后会自动恢复这些地址。公网入站是否可达仍需从 VPS 外测试。\n'
}

repair() {
  require_install_source
  load_config
  apply_list
  finish_setup
}

show_status() {
  load_config
  local address state
  printf '版本：%s\n网卡：%s\n' "$VERSION" "$CONFIG_IFACE"
  for address in "${CONFIG_IPS[@]}"; do
    state=$(address_state "$address") || die "无法检查 IPv6 地址：$address"
    if [[ -z $state ]]; then
      printf '%s  未配置到本机\n' "$address"
    elif [[ $state == *dadfailed* || $state == *tentative* ]]; then
      printf '%s  未就绪\n' "$address"
    else
      printf '%s  已配置到本机\n' "$address"
    fi
  done
  printf '地址服务：%s\n' "$(systemctl is-active ipv6-route-setup.service 2>/dev/null || true)"
  if [[ -f $XRAY_SERVICE ]]; then
    printf 'Xray：%s\n' "$(systemctl is-active xray-yijian.service 2>/dev/null || true)"
  fi
}

require_host
case ${1:-} in
  ''|install) configure ;;
  apply) apply_addresses ;;
  repair) repair ;;
  status) show_status ;;
  *) die '用法：bash ipv6-route.sh [install|repair|status]。' ;;
esac
