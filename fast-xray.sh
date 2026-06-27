#!/bin/sh
# fast-xray: Debian/Ubuntu interactive installer for Xray + Nginx + acme.sh
# Inspired by Project X level-0 ch05-ch07, but uses production-oriented paths.

set -eu

APP_NAME="fast-xray"
SHORTCUT="fx"
WEBROOT="/var/www/fast-xray/html"
NGINX_CONF="/etc/nginx/sites-available/fast-xray.conf"
NGINX_LINK="/etc/nginx/sites-enabled/fast-xray.conf"
STATE_DIR="/etc/fast-xray"
STATE_FILE="/etc/fast-xray/profile.env"
CACHE_DIR="/var/cache/fast-xray"
CERT_BASE="/etc/xray/certs"
XRAY_CONFIG_DIR="/usr/local/etc/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_BIN="/usr/local/bin/xray"
XRAY_LOG_DIR="/var/log/xray"
FALLBACK_PORT_DEFAULT="8080"
ACME_HOME="/root/.acme.sh"
ACME_SH="$ACME_HOME/acme.sh"
INSTALL_SCRIPT_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

DOMAIN=""
EMAIL=""
UUID=""
FALLBACK_PORT="$FALLBACK_PORT_DEFAULT"
USE_CUSTOM_CONFIG="n"
CUSTOM_CONFIG_PATH=""
RUN_STAGING="y"
ENABLE_BBR="y"
FORCE_ISSUE="n"

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
info() { printf '\n[fast-xray] %s\n' "$*"; }
err() { red "[fast-xray] ERROR: $*" >&2; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "请使用 root 运行：sudo sh fast-xray.sh"
    exit 1
  fi
}

need_debian_family() {
  if [ ! -r /etc/os-release ]; then
    err "无法识别系统。此脚本只支持 Debian 系系统。"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu|linuxmint|raspbian) return 0 ;;
  esac
  case " ${ID_LIKE:-} " in
    *" debian "*) return 0 ;;
  esac
  err "此脚本只支持 Debian 系系统，例如 Debian / Ubuntu。当前 ID=${ID:-unknown}, ID_LIKE=${ID_LIKE:-unknown}"
  exit 1
}

need_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    err "未检测到 systemd/systemctl。此脚本依赖 Xray 官方 systemd 安装方式。"
    exit 1
  fi
}

is_yes() {
  case "$(printf '%s' "$1" | tr 'A-Z' 'a-z')" in
    y|yes|1|true|是|好) return 0 ;;
    *) return 1 ;;
  esac
}

ask() {
  prompt="$1"
  default="$2"
  if [ -n "$default" ]; then
    printf '%s [%s]: ' "$prompt" "$default"
  else
    printf '%s: ' "$prompt"
  fi
  ans=""
  read -r ans || ans=""
  if [ -z "$ans" ]; then
    ans="$default"
  fi
  REPLY="$ans"
}

ask_required() {
  prompt="$1"
  default="$2"
  while :; do
    ask "$prompt" "$default"
    if [ -n "$REPLY" ]; then
      return 0
    fi
    yellow "此项不能为空。"
  done
}

valid_domain() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$'
}

valid_port() {
  p="$1"
  printf '%s' "$p" | grep -Eq '^[0-9]+$' || return 1
  [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

sed_escape() {
  printf '%s' "$1" | sed 's/[&|]/\\&/g'
}

backup_file() {
  f="$1"
  if [ -e "$f" ] || [ -L "$f" ]; then
    cp -a "$f" "$f.bak.$(date +%Y%m%d-%H%M%S)"
  fi
}

install_deps() {
  info "安装基础依赖：curl / wget / nginx / cron / unzip / ca-certificates"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl wget nginx cron unzip openssl iproute2
  systemctl enable --now cron >/dev/null 2>&1 || true
}

collect_inputs() {
  info "交互参数"
  while :; do
    ask_required "请输入用于 Xray TLS 的完整域名，例如 a.example.com" ""
    DOMAIN="$REPLY"
    if valid_domain "$DOMAIN"; then
      break
    fi
    yellow "域名格式看起来不正确，请输入完整 FQDN，例如 a.example.com。"
  done

  ask "请输入 Let's Encrypt 账户邮箱，可留空" "admin@$DOMAIN"
  EMAIL="$REPLY"

  while :; do
    ask "请输入 fallback 本地端口" "$FALLBACK_PORT_DEFAULT"
    FALLBACK_PORT="$REPLY"
    if valid_port "$FALLBACK_PORT"; then
      break
    fi
    yellow "端口范围必须是 1-65535。"
  done

  ask "是否使用自定义 config.json？支持 __DOMAIN__ / __UUID__ / __CERT_FILE__ / __KEY_FILE__ 等占位符" "n"
  USE_CUSTOM_CONFIG="$REPLY"
  if is_yes "$USE_CUSTOM_CONFIG"; then
    while :; do
      ask_required "请输入自定义 config.json 的本机路径" ""
      CUSTOM_CONFIG_PATH="$REPLY"
      if [ -f "$CUSTOM_CONFIG_PATH" ]; then
        break
      fi
      yellow "文件不存在：$CUSTOM_CONFIG_PATH"
    done
  fi

  ask "是否先申请 Let's Encrypt staging 测试证书，避免正式签发失败次数过多？" "y"
  RUN_STAGING="$REPLY"

  ask "正式证书签发时是否强制重新签发 --force？首次安装通常不需要；如果刚跑过 staging，脚本会自动强制" "n"
  FORCE_ISSUE="$REPLY"

  ask "是否启用内核自带 BBR + fq？" "y"
  ENABLE_BBR="$REPLY"
}

prepare_dirs_and_users() {
  info "创建生产路径、系统用户与权限"

  if ! getent group xray >/dev/null 2>&1; then
    groupadd --system xray
  fi
  if ! id xray >/dev/null 2>&1; then
    useradd --system --gid xray --home-dir /var/lib/xray --create-home --shell /usr/sbin/nologin xray
  fi

  install -d -m 0755 "$STATE_DIR"
  install -d -m 0755 "$CACHE_DIR"
  install -d -o www-data -g www-data -m 0755 "$WEBROOT"
  install -d -o xray -g xray -m 0750 "$XRAY_LOG_DIR"
  : > "$XRAY_LOG_DIR/access.log"
  : > "$XRAY_LOG_DIR/error.log"
  chown xray:xray "$XRAY_LOG_DIR/access.log" "$XRAY_LOG_DIR/error.log"
  chmod 0640 "$XRAY_LOG_DIR/access.log" "$XRAY_LOG_DIR/error.log"

  install -d -o root -g xray -m 0750 "$XRAY_CONFIG_DIR"
  install -d -o root -g xray -m 0750 "$CERT_BASE/$DOMAIN"
}

write_webpage() {
  info "写入伪装/回落网页"
  cat > "$WEBROOT/index.html" <<EOF_HTML
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>$DOMAIN</title>
  <style>
    body { margin: 0; font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f6f7f9; color: #222; }
    main { max-width: 720px; margin: 12vh auto; padding: 32px; background: #fff; border: 1px solid #e5e7eb; border-radius: 18px; box-shadow: 0 10px 35px rgba(0,0,0,.06); }
    h1 { margin: 0 0 12px; font-size: 28px; }
    p { line-height: 1.7; color: #4b5563; }
    code { background: #f1f5f9; padding: 2px 6px; border-radius: 6px; }
  </style>
</head>
<body>
  <main>
    <h1>$DOMAIN</h1>
    <p>This site is online. The HTTPS endpoint and fallback page are managed by <code>fast-xray</code>.</p>
  </main>
</body>
</html>
EOF_HTML
  chown -R www-data:www-data "$WEBROOT"
  find "$WEBROOT" -type d -exec chmod 0755 {} \;
  find "$WEBROOT" -type f -exec chmod 0644 {} \;
}

configure_nginx() {
  info "配置 Nginx：80 端口用于 ACME 与 HTTPS 跳转；127.0.0.1:$FALLBACK_PORT 用于 Xray fallback"
  backup_file "$NGINX_CONF"
  cat > "$NGINX_CONF" <<EOF_NGINX
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    root $WEBROOT;
    index index.html;

    location ^~ /.well-known/acme-challenge/ {
        root $WEBROOT;
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 127.0.0.1:$FALLBACK_PORT;
    server_name $DOMAIN;

    root $WEBROOT;
    index index.html;

    add_header Strict-Transport-Security "max-age=63072000" always;

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF_NGINX

  ln -sfn "$NGINX_CONF" "$NGINX_LINK"
  nginx -t
  systemctl enable --now nginx
  systemctl restart nginx
}

open_firewall_if_ufw_active() {
  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q '^Status: active'; then
      info "检测到 UFW 已启用，放行 80/tcp 与 443/tcp"
      ufw allow 80/tcp >/dev/null || true
      ufw allow 443/tcp >/dev/null || true
    fi
  fi
}

install_acme() {
  info "安装/更新 acme.sh"
  if [ ! -x "$ACME_SH" ]; then
    curl -fsSL https://get.acme.sh | HOME=/root sh
  fi
  if [ ! -x "$ACME_SH" ]; then
    err "acme.sh 安装失败，未找到 $ACME_SH"
    exit 1
  fi
  "$ACME_SH" --upgrade --auto-upgrade
  "$ACME_SH" --set-default-ca --server letsencrypt
  if [ -n "$EMAIL" ]; then
    "$ACME_SH" --register-account -m "$EMAIL" --server letsencrypt || true
  fi
}

issue_cert() {
  info "申请 TLS 证书：$DOMAIN"
  if is_yes "$RUN_STAGING"; then
    "$ACME_SH" --issue --server letsencrypt_test -d "$DOMAIN" -w "$WEBROOT" --keylength ec-256
    FORCE_ISSUE="y"
  fi

  if is_yes "$FORCE_ISSUE"; then
    "$ACME_SH" --issue --server letsencrypt -d "$DOMAIN" -w "$WEBROOT" --keylength ec-256 --force
  else
    "$ACME_SH" --issue --server letsencrypt -d "$DOMAIN" -w "$WEBROOT" --keylength ec-256
  fi
}

install_xray_core() {
  info "使用 XTLS 官方安装脚本安装/更新 Xray Core"
  tmp_script="$CACHE_DIR/install-release.sh"
  curl -fsSL -o "$tmp_script" "$INSTALL_SCRIPT_URL"
  chmod 0700 "$tmp_script"
  bash "$tmp_script"
  rm -f "$tmp_script"

  if [ ! -x "$XRAY_BIN" ]; then
    err "Xray 安装失败，未找到 $XRAY_BIN"
    exit 1
  fi
}

install_cert_to_production_path() {
  info "安装证书到生产路径：$CERT_BASE/$DOMAIN"
  cert_file="$CERT_BASE/$DOMAIN/fullchain.crt"
  key_file="$CERT_BASE/$DOMAIN/private.key"

  "$ACME_SH" --install-cert -d "$DOMAIN" --ecc \
    --fullchain-file "$cert_file" \
    --key-file "$key_file" \
    --reloadcmd "systemctl try-restart xray >/dev/null 2>&1 || true"

  chown root:xray "$CERT_BASE/$DOMAIN" "$cert_file" "$key_file"
  chmod 0750 "$CERT_BASE/$DOMAIN"
  chmod 0644 "$cert_file"
  chmod 0640 "$key_file"
}

generate_uuid() {
  if [ -x "$XRAY_BIN" ]; then
    UUID="$($XRAY_BIN uuid 2>/dev/null | head -n 1 || true)"
  fi
  if [ -z "$UUID" ] && [ -r /proc/sys/kernel/random/uuid ]; then
    UUID="$(cat /proc/sys/kernel/random/uuid)"
  fi
  if [ -z "$UUID" ]; then
    err "无法生成 UUID。"
    exit 1
  fi
}

write_default_xray_config() {
  cert_file="$CERT_BASE/$DOMAIN/fullchain.crt"
  key_file="$CERT_BASE/$DOMAIN/private.key"
  tmp_config="$(mktemp)"

  cat > "$tmp_config" <<EOF_JSON
{
  "log": {
    "loglevel": "warning",
    "access": "$XRAY_LOG_DIR/access.log",
    "error": "$XRAY_LOG_DIR/error.log"
  },
  "dns": {
    "servers": [
      "https+local://1.1.1.1/dns-query",
      "localhost"
    ]
  },
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "ip": ["geoip:private"],
        "outboundTag": "block"
      },
      {
        "ip": ["geoip:cn"],
        "outboundTag": "block"
      },
      {
        "domain": ["geosite:category-ads-all"],
        "outboundTag": "block"
      }
    ]
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "users": [
          {
            "id": "$UUID",
            "flow": "xtls-rprx-vision",
            "level": 0,
            "email": "user@$DOMAIN"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "dest": "127.0.0.1:$FALLBACK_PORT"
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "alpn": ["http/1.1"],
          "certificates": [
            {
              "certificateFile": "$cert_file",
              "keyFile": "$key_file"
            }
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ]
}
EOF_JSON

  backup_file "$XRAY_CONFIG"
  install -o root -g xray -m 0640 "$tmp_config" "$XRAY_CONFIG"
  rm -f "$tmp_config"
}

write_custom_xray_config() {
  cert_file="$CERT_BASE/$DOMAIN/fullchain.crt"
  key_file="$CERT_BASE/$DOMAIN/private.key"
  tmp_config="$(mktemp)"

  d="$(sed_escape "$DOMAIN")"
  u="$(sed_escape "$UUID")"
  cf="$(sed_escape "$cert_file")"
  kf="$(sed_escape "$key_file")"
  fp="$(sed_escape "$FALLBACK_PORT")"
  al="$(sed_escape "$XRAY_LOG_DIR/access.log")"
  el="$(sed_escape "$XRAY_LOG_DIR/error.log")"

  sed \
    -e "s|__DOMAIN__|$d|g" \
    -e "s|__UUID__|$u|g" \
    -e "s|__CERT_FILE__|$cf|g" \
    -e "s|__KEY_FILE__|$kf|g" \
    -e "s|__FALLBACK_PORT__|$fp|g" \
    -e "s|__ACCESS_LOG__|$al|g" \
    -e "s|__ERROR_LOG__|$el|g" \
    "$CUSTOM_CONFIG_PATH" > "$tmp_config"

  backup_file "$XRAY_CONFIG"
  install -o root -g xray -m 0640 "$tmp_config" "$XRAY_CONFIG"
  rm -f "$tmp_config"
}

write_xray_config() {
  info "写入 Xray 配置：$XRAY_CONFIG"
  generate_uuid
  if is_yes "$USE_CUSTOM_CONFIG"; then
    write_custom_xray_config
  else
    write_default_xray_config
  fi
}

configure_xray_service_permissions() {
  info "配置 systemd override：使用专用 xray 用户运行，并允许绑定 443"
  install -d -m 0755 /etc/systemd/system/xray.service.d
  cat > /etc/systemd/system/xray.service.d/10-fast-xray.conf <<'EOF_OVERRIDE'
[Service]
User=xray
Group=xray
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ReadWritePaths=/var/log/xray
EOF_OVERRIDE

  chown -R xray:xray "$XRAY_LOG_DIR"
  chmod 0750 "$XRAY_LOG_DIR"
  chmod 0640 "$XRAY_LOG_DIR"/*.log
  chown root:xray "$XRAY_CONFIG_DIR" "$XRAY_CONFIG"
  chmod 0750 "$XRAY_CONFIG_DIR"
  chmod 0640 "$XRAY_CONFIG"

  systemctl daemon-reload
}

test_xray_config() {
  info "测试 Xray 配置"
  if "$XRAY_BIN" run -test -config "$XRAY_CONFIG"; then
    return 0
  fi
  if "$XRAY_BIN" test -config "$XRAY_CONFIG"; then
    return 0
  fi
  err "Xray 配置测试失败：$XRAY_CONFIG"
  exit 1
}

start_xray() {
  info "启动并设置 Xray 开机自启"
  systemctl enable --now xray
  systemctl restart xray
  systemctl --no-pager --full status xray || true
}

enable_bbr() {
  if ! is_yes "$ENABLE_BBR"; then
    return 0
  fi
  info "启用内核自带 BBR + fq"
  cat > /etc/sysctl.d/99-fast-xray-bbr.conf <<'EOF_BBR'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF_BBR
  sysctl --system >/dev/null || true
  sysctl net.ipv4.tcp_congestion_control || true
  sysctl net.core.default_qdisc || true
}

write_state_file() {
  cert_file="$CERT_BASE/$DOMAIN/fullchain.crt"
  key_file="$CERT_BASE/$DOMAIN/private.key"
  cat > "$STATE_FILE" <<EOF_STATE
DOMAIN=$DOMAIN
UUID=$UUID
FALLBACK_PORT=$FALLBACK_PORT
XRAY_CONFIG=$XRAY_CONFIG
CERT_FILE=$cert_file
KEY_FILE=$key_file
WEBROOT=$WEBROOT
ACCESS_LOG=$XRAY_LOG_DIR/access.log
ERROR_LOG=$XRAY_LOG_DIR/error.log
EOF_STATE
  chmod 0600 "$STATE_FILE"
}

install_fx_shortcut() {
  info "创建本地快捷指令：$SHORTCUT"
  cat > "/usr/local/bin/$SHORTCUT" <<'EOF_FX'
#!/bin/sh
STATE_FILE="/etc/fast-xray/profile.env"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"

if [ -r "$STATE_FILE" ]; then
  # shellcheck disable=SC1090
  . "$STATE_FILE"
fi

cmd="${1:-help}"
case "$cmd" in
  start|stop|restart|reload|enable|disable)
    systemctl "$cmd" xray
    ;;
  status)
    systemctl --no-pager --full status xray
    ;;
  logs)
    journalctl -u xray -e --no-pager
    ;;
  follow)
    journalctl -u xray -f
    ;;
  test)
    if "$XRAY_BIN" run -test -config "$XRAY_CONFIG"; then
      exit 0
    fi
    "$XRAY_BIN" test -config "$XRAY_CONFIG"
    ;;
  uuid)
    "$XRAY_BIN" uuid
    ;;
  config)
    editor="${EDITOR:-nano}"
    "$editor" "$XRAY_CONFIG"
    ;;
  nginx)
    nginx -t && systemctl restart nginx
    ;;
  renew-cert)
    if [ -z "${DOMAIN:-}" ]; then
      echo "No DOMAIN in $STATE_FILE" >&2
      exit 1
    fi
    /root/.acme.sh/acme.sh --renew -d "$DOMAIN" --ecc --force
    systemctl try-restart xray || true
    ;;
  link)
    if [ -z "${DOMAIN:-}" ] || [ -z "${UUID:-}" ]; then
      echo "No DOMAIN/UUID in $STATE_FILE" >&2
      exit 1
    fi
    echo "vless://${UUID}@${DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=tls&sni=${DOMAIN}&type=tcp&headerType=none#${DOMAIN}-fast-xray"
    ;;
  info)
    if [ -r "$STATE_FILE" ]; then
      cat "$STATE_FILE"
    else
      echo "State file not found: $STATE_FILE"
    fi
    ;;
  help|*)
    cat <<'EOF_HELP'
fx usage:
  fx status       查看服务状态
  fx start        启动服务
  fx stop         停止服务
  fx restart      重启服务
  fx enable       开机自启
  fx disable      禁用开机自启
  fx logs         查看最近日志
  fx follow       实时跟踪日志
  fx test         测试配置文件
  fx config       编辑配置文件
  fx uuid         生成 UUID
  fx nginx        测试并重启 Nginx
  fx renew-cert   强制续签证书并尝试重启服务
  fx link         输出默认 VLESS Vision 分享链接
  fx info         显示 fast-xray 状态文件
EOF_HELP
    ;;
esac
EOF_FX
  chmod 0755 "/usr/local/bin/$SHORTCUT"
}

save_self_if_possible() {
  if [ -r "$0" ]; then
    cp -f "$0" /usr/local/sbin/fast-xray 2>/dev/null || true
    chmod 0755 /usr/local/sbin/fast-xray 2>/dev/null || true
  fi
}

final_output() {
  green "安装完成。"
  printf '\n'
  printf '域名: %s\n' "$DOMAIN"
  printf 'UUID: %s\n' "$UUID"
  printf '配置: %s\n' "$XRAY_CONFIG"
  printf '证书: %s/%s\n' "$CERT_BASE/$DOMAIN" "fullchain.crt / private.key"
  printf '网站根目录: %s\n' "$WEBROOT"
  printf '快捷指令: %s\n' "$SHORTCUT"
  printf '\n常用命令：\n'
  printf '  %s status\n' "$SHORTCUT"
  printf '  %s test\n' "$SHORTCUT"
  printf '  %s restart\n' "$SHORTCUT"
  printf '  %s link\n' "$SHORTCUT"
}

main() {
  need_root
  need_debian_family
  need_systemd
  collect_inputs
  install_deps
  prepare_dirs_and_users
  write_webpage
  configure_nginx
  open_firewall_if_ufw_active
  install_acme
  issue_cert
  install_xray_core
  install_cert_to_production_path
  write_xray_config
  configure_xray_service_permissions
  test_xray_config
  enable_bbr
  start_xray
  write_state_file
  install_fx_shortcut
  save_self_if_possible
  final_output
}

main "$@"
