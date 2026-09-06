#!/usr/bin/env bash
set -Eeuo pipefail

# Debian/Ubuntu VPS 一键开荒脚本。
# 唯一输入：SSH_PORT 和 SSH_PUBLIC_KEY；私钥永远不会被脚本读取。

SCRIPT_NAME="$(basename "$0")"
CONFIG_INPUT=""
SSH_PORT=""
SSH_PUBLIC_KEY=""
SSH_SERVICE=""
SSHD_BIN=""
SSH_CONFIG="/etc/ssh/sshd_config"
SSH_DROP_IN="/etc/ssh/sshd_config.d/000-vps-oneclick.conf"
SSH_BACKUP="/etc/ssh/sshd_config.vps-oneclick.bak"
SWAP_SCRIPT=""

cleanup() {
  if [[ -n "$SWAP_SCRIPT" && -f "$SWAP_SCRIPT" ]]; then
    rm -f -- "$SWAP_SCRIPT"
  fi
}
trap cleanup EXIT

die() {
  printf '[失败] %s\n' "$*" >&2
  exit 1
}

info() {
  printf '[信息] %s\n' "$*"
}

ok() {
  printf '[成功] %s\n' "$*"
}

[[ "$(id -u)" -eq 0 ]] || die "请使用 root 运行 $SCRIPT_NAME"
command -v apt-get >/dev/null 2>&1 || die "当前系统没有 apt-get，本脚本只支持 Debian/Ubuntu"
command -v systemctl >/dev/null 2>&1 || die "当前系统没有 systemctl，本脚本需要 systemd"

trim_value() {
  printf '%s' "$1" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
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

read_config() {
  info "请一次性粘贴配置，最后单独输入 VPS_CONFIG_END 并回车"
  printf '%s\n' \
    'VPS_CONFIG_BEGIN' \
    'SSH_PORT=51919' \
    'SSH_PUBLIC_KEY=ssh-ed25519 AAAA... 备注' \
    'VPS_CONFIG_END'

  CONFIG_INPUT="$(awk '
    {
      sub(/\r$/, "")
      if ($0 == "VPS_CONFIG_BEGIN") {
        started = 1
        next
      }
      if ($0 == "VPS_CONFIG_END") {
        if (started) found = 1
        exit
      }
      if (started) print
    }
    END {
      if (!started || !found) exit 1
    }
  ')" || die "未读取到完整配置，必须包含 VPS_CONFIG_BEGIN 和 VPS_CONFIG_END"

  [[ -n "$CONFIG_INPUT" ]] || die "配置不能为空"
  SSH_PORT="$(trim_value "$(config_value SSH_PORT)")"
  SSH_PUBLIC_KEY="$(trim_value "$(config_value SSH_PUBLIC_KEY)")"
  ok "配置读取完成：SSH_PORT 和 SSH_PUBLIC_KEY"
}

validate_config() {
  [[ -n "$SSH_PORT" ]] || die "配置缺少 SSH_PORT"
  [[ -n "$SSH_PUBLIC_KEY" ]] || die "配置缺少 SSH_PUBLIC_KEY"
  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH_PORT 必须是数字"
  (( SSH_PORT >= 20000 && SSH_PORT <= 65535 )) || die "SSH_PORT 必须在 20000-65535 范围内"
  [[ "$SSH_PUBLIC_KEY" != *$'\n'* && "$SSH_PUBLIC_KEY" != *$'\r'* ]] || die "SSH_PUBLIC_KEY 不能换行"
  [[ "$SSH_PUBLIC_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)[[:space:]][^[:space:]]+([[:space:]].*)?$ ]] || die "SSH_PUBLIC_KEY 不是有效的 OpenSSH 公钥格式"
  ok "配置校验通过：SSH 端口和公钥格式正确"
}

install_dependencies() {
  info "更新系统软件包并安装依赖"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get upgrade -y
  apt-get install -y ca-certificates curl wget iproute2 procps openssh-server openssh-client iptables nftables fail2ban
  ok "系统依赖安装完成"
}

find_sshd() {
  SSHD_BIN="$(command -v sshd || true)"
  if [[ -z "$SSHD_BIN" && -x /usr/sbin/sshd ]]; then
    SSHD_BIN="/usr/sbin/sshd"
  fi
  [[ -n "$SSHD_BIN" ]] || die "未找到 sshd"
}

find_ssh_service() {
  if systemctl list-unit-files --no-legend 2>/dev/null | awk '$1 == "ssh.service" {found=1} END {exit found ? 0 : 1}'; then
    SSH_SERVICE="ssh"
  elif systemctl list-unit-files --no-legend 2>/dev/null | awk '$1 == "sshd.service" {found=1} END {exit found ? 0 : 1}'; then
    SSH_SERVICE="sshd"
  else
    die "未找到 ssh 或 sshd systemd 服务"
  fi
}

port_is_listening() {
  ss -H -ltn 2>/dev/null | awk -v port="$SSH_PORT" '$4 ~ ":" port "$" {found=1} END {exit found ? 0 : 1}'
}

rollback_ssh() {
  if [[ -f "$SSH_BACKUP" ]]; then
    cp -a -- "$SSH_BACKUP" "$SSH_CONFIG"
  fi
  rm -f -- "$SSH_DROP_IN"
  "$SSHD_BIN" -t >/dev/null 2>&1 || true
  systemctl reload "$SSH_SERVICE" >/dev/null 2>&1 || true
}

write_ssh_drop_in() {
  local stage="$1"
  case "$stage" in
    key)
      cat > "$SSH_DROP_IN" <<'EOF'
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AuthenticationMethods any
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
ChallengeResponseAuthentication yes
EOF
      ;;
    port)
      cat > "$SSH_DROP_IN" <<EOF
Port $SSH_PORT
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AuthenticationMethods any
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
ChallengeResponseAuthentication yes
EOF
      ;;
    lock)
      cat > "$SSH_DROP_IN" <<EOF
Port $SSH_PORT
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
AuthenticationMethods any
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
EOF
      ;;
    *)
      return 1
      ;;
  esac
  chmod 644 "$SSH_DROP_IN"
}

reload_and_check_ssh() {
  "$SSHD_BIN" -t || return 1
  systemctl reload "$SSH_SERVICE" || return 1
  systemctl is-active --quiet "$SSH_SERVICE" || return 1
}

configure_ssh() {
  local public_key_file
  find_sshd
  find_ssh_service
  [[ -f "$SSH_CONFIG" ]] || die "未找到 $SSH_CONFIG"

  if port_is_listening; then
    die "SSH_PORT $SSH_PORT 已被其他服务占用，请换一个端口"
  fi

  public_key_file="$(mktemp)"
  printf '%s\n' "$SSH_PUBLIC_KEY" > "$public_key_file"
  if ! ssh-keygen -lf "$public_key_file" >/dev/null 2>&1; then
    rm -f -- "$public_key_file"
    die "SSH_PUBLIC_KEY 不是可识别的 OpenSSH 公钥"
  fi
  rm -f -- "$public_key_file"

  install -d -m 700 /root/.ssh
  touch /root/.ssh/authorized_keys
  if grep -Fqx -- "$SSH_PUBLIC_KEY" /root/.ssh/authorized_keys; then
    info "公钥已经存在"
  else
    printf '%s\n' "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
    ok "公钥安装成功"
  fi
  chmod 600 /root/.ssh/authorized_keys
  chown -R root:root /root/.ssh

  [[ -e "$SSH_BACKUP" ]] || cp -a -- "$SSH_CONFIG" "$SSH_BACKUP"
  mkdir -p /etc/ssh/sshd_config.d

  # 先移除主配置中的旧值，再由 000 drop-in 按三个阶段统一接管。
  sed -i -E '/^[[:space:]]*#?[[:space:]]*(Port|PasswordAuthentication|KbdInteractiveAuthentication|ChallengeResponseAuthentication|PubkeyAuthentication|AuthenticationMethods|AuthorizedKeysFile|PermitRootLogin)[[:space:]]+/d' "$SSH_CONFIG"
  if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf[[:space:]]*$' "$SSH_CONFIG"; then
    printf '\nInclude /etc/ssh/sshd_config.d/*.conf\n' >> "$SSH_CONFIG"
  fi

  # 第 1 阶段：先启用公钥登录，继续保留原端口和密码登录，避免立即锁死。
  write_ssh_drop_in key || {
    rollback_ssh
    die "第 1 阶段配置公钥登录失败，已恢复原配置"
  }
  if ! reload_and_check_ssh || ! "$SSHD_BIN" -T | grep -q '^pubkeyauthentication yes$' || ! "$SSHD_BIN" -T | grep -q '^permitrootlogin yes$'; then
    rollback_ssh
    die "第 1 阶段公钥登录配置校验失败，已恢复原配置"
  fi
  ok "第 1 阶段完成：公钥登录已启用，原 SSH 端口和密码登录保持不变"

  # 第 2 阶段：只切换 SSH 端口，密码登录仍然保留作为临时后备。
  write_ssh_drop_in port || {
    rollback_ssh
    die "第 2 阶段写入 SSH 新端口失败，已恢复原配置"
  }
  if ! reload_and_check_ssh || ! "$SSHD_BIN" -T | grep -q "^port $SSH_PORT$" || ! port_is_listening; then
    rollback_ssh
    die "第 2 阶段 SSH 新端口校验失败，已恢复原配置"
  fi
  ok "第 2 阶段完成：SSH 已监听端口 $SSH_PORT，密码登录仍保持开启"

  # 第 3 阶段：确认端口已监听后，最后关闭所有密码相关登录方式。
  write_ssh_drop_in lock || {
    rollback_ssh
    die "第 3 阶段写入密码登录关闭配置失败，已恢复原配置"
  }
  if ! reload_and_check_ssh \
    || ! "$SSHD_BIN" -T | grep -q '^pubkeyauthentication yes$' \
    || ! "$SSHD_BIN" -T | grep -q '^permitrootlogin prohibit-password$' \
    || ! "$SSHD_BIN" -T | grep -q '^passwordauthentication no$' \
    || ! "$SSHD_BIN" -T | grep -q '^kbdinteractiveauthentication no$' \
    || ! "$SSHD_BIN" -T | grep -q "^port $SSH_PORT$" \
    || ! port_is_listening; then
    rollback_ssh
    die "第 3 阶段关闭密码登录后的校验失败，已恢复原配置"
  fi
  ok "第 3 阶段完成：密码、键盘交互和挑战响应登录已关闭，公钥登录保持可用"
}

clear_firewall() {
  info "清理防火墙规则"
  systemctl disable --now ufw 2>/dev/null || true
  systemctl disable --now firewalld 2>/dev/null || true
  command -v iptables >/dev/null 2>&1 || die "未找到 iptables"
  iptables -P INPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT ACCEPT
  iptables -F
  iptables -X
  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -P INPUT ACCEPT
    ip6tables -P FORWARD ACCEPT
    ip6tables -P OUTPUT ACCEPT
    ip6tables -F
    ip6tables -X
  fi
  ok "防火墙规则已清理并放行"
}

enable_bbr() {
  info "执行 BBR + FQ 安装命令"
  bash <(curl -fsSL https://raw.githubusercontent.com/byJoey/Actions-bbr-v3/main/install.sh)
  [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" == "bbr" ]] || die "BBR 未成功启用"
  ok "BBR 已启用"
}

configure_fail2ban() {
  info "配置 Fail2Ban"
  cat > /etc/fail2ban/jail.d/sshd-custom.local <<'EOF'
[sshd]
enabled = true
backend = systemd
banaction = nftables-allports
maxretry = 3
findtime = 300
bantime = 86400
ignoreip = 127.0.0.1/8 ::1
EOF
  systemctl enable fail2ban
  if ! systemctl restart fail2ban; then
    journalctl -u fail2ban -n 30 --no-pager || true
    die "Fail2Ban 启动失败"
  fi
  systemctl is-active --quiet fail2ban || die "Fail2Ban 未处于运行状态"
  [[ -S /run/fail2ban/fail2ban.sock ]] || die "Fail2Ban 控制 socket 未就绪"
  if ! fail2ban-client status sshd; then
    journalctl -u fail2ban -n 30 --no-pager || true
    die "Fail2Ban sshd 规则未正常加载"
  fi
  ok "Fail2Ban 已启用：5 分钟失败 3 次，封禁 1 天"
}

enable_swap() {
  SWAP_SCRIPT="$(mktemp /tmp/vps-oneclick-swap.XXXXXX.sh)"
  info "执行 Swap 安装命令"
  wget --tries=1 --timeout=20 -qO "$SWAP_SCRIPT" https://www.moerats.com/usr/shell/swap.sh
  bash "$SWAP_SCRIPT"
  ok "Swap 安装命令执行完成"
}

show_result() {
  echo
  echo "============================================================"
  echo "服务器开荒完成"
  echo "============================================================"
  echo "SSH 端口：$SSH_PORT"
  echo "公钥位置：/root/.ssh/authorized_keys"
  echo "SSH 配置备份：$SSH_BACKUP"
  echo
  echo "必须在本机新开终端测试私钥登录，确认成功后再关闭当前会话："
  echo "ssh -p $SSH_PORT root@服务器公网IP"
  echo
  echo "当前监听端口："
  ss -lntp || true
}

reboot_server() {
  echo
  info "全部开荒步骤执行成功，准备重启服务器"
  ok "服务器即将重启；重启后请使用私钥通过新端口 $SSH_PORT 登录"
  systemctl reboot
}

echo "============================================================"
echo "  $SCRIPT_NAME：Debian/Ubuntu VPS 一键开荒"
echo "============================================================"
read_config
validate_config
install_dependencies
configure_ssh
clear_firewall
configure_fail2ban
enable_swap
enable_bbr
show_result
reboot_server
