#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="warp-vps-manager"
APP_DIR="/opt/${APP_NAME}"
ETC_DIR="/etc/${APP_NAME}"
STATE_DIR="/var/lib/${APP_NAME}"
BIN_PATH="/usr/local/bin/warp-vps"
CONFIG_FILE="${ETC_DIR}/config.env"
REDSOCKS_USER="warp-vps-redsocks"
DEFAULT_REPO_RAW_BASE="https://raw.githubusercontent.com/mqfut123/warp-vps-manager/main"
REPO_RAW_BASE="${WARP_VPS_REPO_BASE:-$DEFAULT_REPO_RAW_BASE}"
APP_VERSION_VALUE="0.1.0"

log() { printf '[warp-vps] %s\n' "$*"; }
die() { printf '[warp-vps] 错误：%s\n' "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行"
}

load_os_release() {
  [ -r /etc/os-release ] || die "无法读取 /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_VERSION_MAJOR="${OS_VERSION_ID%%.*}"
  OS_CODENAME="${VERSION_CODENAME:-}"
}

pkg_install_apt() {
  case "$OS_ID" in
    ubuntu)
      case "$OS_VERSION_MAJOR" in
        22|24) ;;
        *) die "不支持当前 Ubuntu 版本：${OS_VERSION_ID:-未知}；支持版本：22.04、24.04" ;;
      esac
      ;;
    debian)
      case "$OS_VERSION_MAJOR" in
        12|13) ;;
        *) die "不支持当前 Debian 版本：${OS_VERSION_ID:-未知}；支持版本：12、13" ;;
      esac
      ;;
    *)
      die "不支持当前 apt 系统：${OS_ID:-未知}"
      ;;
  esac

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates gnupg lsb-release nftables iptables iproute2 python3 redsocks

  install -d -m 0755 /usr/share/keyrings
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

  local codename="$OS_CODENAME"
  if [ -z "$codename" ] && command -v lsb_release >/dev/null 2>&1; then
    codename="$(lsb_release -cs)"
  fi
  [ -n "$codename" ] || die "无法识别当前系统代号，不能配置 Cloudflare WARP 软件源"

  local arch
  arch="$(dpkg --print-architecture)"
  cat > /etc/apt/sources.list.d/cloudflare-client.list <<EOF
deb [arch=${arch} signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${codename} main
EOF
  apt-get update -y
  apt-get install -y cloudflare-warp
}

enable_rhel_extra_repos() {
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y dnf-plugins-core || true
    dnf config-manager --set-enabled crb >/dev/null 2>&1 || true
    dnf config-manager --set-enabled powertools >/dev/null 2>&1 || true
    dnf install -y epel-release || true
  else
    yum install -y yum-utils epel-release || true
    yum-config-manager --enable crb >/dev/null 2>&1 || true
    yum-config-manager --enable powertools >/dev/null 2>&1 || true
  fi
}

pkg_install_rpm() {
  case "$OS_ID" in
    centos)
      case "$OS_VERSION_MAJOR" in
        8|9) ;;
        *) die "不支持当前 CentOS 版本：${OS_VERSION_ID:-未知}；支持版本：8、9" ;;
      esac
      ;;
    rhel|rocky|almalinux)
      case "$OS_VERSION_MAJOR" in
        8|9) ;;
        *) die "不支持当前 ${OS_ID} 版本：${OS_VERSION_ID:-未知}；支持主版本：8、9" ;;
      esac
      ;;
    *)
      die "不支持当前 RPM 系统：${OS_ID:-未知}"
      ;;
  esac

  enable_rhel_extra_repos
  rpm --import https://pkg.cloudflareclient.com/pubkey.gpg
  curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
    -o /etc/yum.repos.d/cloudflare-warp.repo
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates gnupg2 nftables iptables-nft iproute python3 redsocks cloudflare-warp
  else
    yum install -y curl ca-certificates gnupg2 nftables iptables iproute python3 redsocks cloudflare-warp
  fi
}

install_dependencies() {
  load_os_release
  case "$OS_ID" in
    debian|ubuntu)
      pkg_install_apt
      ;;
    centos|rhel|rocky|almalinux)
      pkg_install_rpm
      ;;
    *)
      die "不支持当前系统：${OS_ID:-未知}；支持 Debian、Ubuntu、CentOS、RHEL、Rocky、AlmaLinux"
      ;;
  esac

  command -v warp-cli >/dev/null 2>&1 || die "cloudflare-warp 已安装但找不到 warp-cli"
  command -v redsocks >/dev/null 2>&1 || die "依赖安装后仍找不到 redsocks"
  command -v nft >/dev/null 2>&1 || die "依赖安装后仍找不到 nftables"
  command -v ss >/dev/null 2>&1 || die "依赖安装后仍找不到 ss"
  command -v timeout >/dev/null 2>&1 || die "依赖安装后仍找不到 timeout"
  command -v python3 >/dev/null 2>&1 || die "依赖安装后仍找不到 python3"
}

reserved_port() {
  case "$1" in
    22|25|53|80|110|123|143|443|465|587|853|993|995|3306|5432|6379|8080|8443)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

valid_port() {
  case "$1" in
    ''|*[!0-9]*)
      return 1
      ;;
  esac
  [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

port_in_use() {
  ss -H -ltnu "sport = :$1" 2>/dev/null | grep -q .
}

tcp_port_listening() {
  ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .
}

wait_for_tcp_port() {
  local port="$1"
  local max_wait="${2:-20}"
  local waited=0
  while [ "$waited" -lt "$max_wait" ]; do
    tcp_port_listening "$port" && return 0
    sleep 1
    waited=$((waited + 1))
  done
  tcp_port_listening "$port"
}

find_free_port() {
  local avoid="${1:-}"
  local candidate
  local i=0
  while [ "$i" -lt 400 ]; do
    candidate=$((20000 + (((RANDOM << 15) + RANDOM) % 41000)))
    if [ "$candidate" != "$avoid" ] && ! reserved_port "$candidate" && ! port_in_use "$candidate"; then
      printf '%s\n' "$candidate"
      return 0
    fi
    i=$((i + 1))
  done
  die "没有找到可用的高位端口"
}

prompt_warp_port() {
  local input
  if [ -n "${WARP_SOCKS_PORT:-}" ]; then
    input="$WARP_SOCKS_PORT"
  else
    printf '请输入 WARP SOCKS 端口（直接回车随机选择空闲端口）：' >&2
    read -r input
  fi

  if [ -z "$input" ]; then
    find_free_port
    return 0
  fi

  valid_port "$input" || die "端口无效：$input"
  reserved_port "$input" && die "端口 $input 是常见服务端口，请换一个"
  port_in_use "$input" && die "端口 $input 已被占用，请换一个"
  printf '%s\n' "$input"
}

disable_packaged_redsocks_service() {
  if systemctl list-unit-files redsocks.service >/dev/null 2>&1; then
    systemctl stop redsocks.service >/dev/null 2>&1 || true
    systemctl disable redsocks.service >/dev/null 2>&1 || true
  fi
}

validate_repo_raw_base() {
  local url="$1"
  [ -n "$url" ] || die "WARP_VPS_REPO_BASE 不能为空"
  case "$url" in
    https://*) ;;
    *) die "WARP_VPS_REPO_BASE 必须以 https:// 开头" ;;
  esac
  case "$url" in
    *$'\n'*|*$'\r'*|*$'\t'*|*" "*) die "WARP_VPS_REPO_BASE 不能包含空格或换行" ;;
  esac
  local rest="${url#https://}"
  local authority="${rest%%/*}"
  case "$authority" in
    *@*) die "WARP_VPS_REPO_BASE 不能包含账号密码信息" ;;
    '') die "WARP_VPS_REPO_BASE 缺少域名" ;;
  esac
}

ensure_redsocks_user() {
  if id -u "$REDSOCKS_USER" >/dev/null 2>&1; then
    return
  fi
  local nologin="/usr/sbin/nologin"
  [ -x "$nologin" ] || nologin="/sbin/nologin"
  useradd --system --user-group --no-create-home --shell "$nologin" "$REDSOCKS_USER"
}

fetch_asset() {
  local rel="$1"
  local dest="$2"
  local mode="$3"
  local script_dir
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P 2>/dev/null || pwd)"

  if [ -f "${script_dir}/${rel}" ]; then
    install -m "$mode" "${script_dir}/${rel}" "$dest"
    return
  fi

  curl -fsSL "${REPO_RAW_BASE}/${rel}" -o "$dest"
  chmod "$mode" "$dest"
}

install_project_files() {
  install -d -m 0755 "$APP_DIR" "$APP_DIR/bin" "$APP_DIR/rules" "$ETC_DIR" "$STATE_DIR"
  fetch_asset "install.sh" "$APP_DIR/install.sh" 0755
  fetch_asset "bin/warp-vps" "$APP_DIR/bin/warp-vps" 0755
  fetch_asset "rules/google_ipv4.txt" "$APP_DIR/rules/google_ipv4.txt" 0644
  fetch_asset "rules/google_ipv6.txt" "$APP_DIR/rules/google_ipv6.txt" 0644
  fetch_asset "rules/rules.meta.json" "$APP_DIR/rules/rules.meta.json" 0644
  install -m 0755 "$APP_DIR/bin/warp-vps" "$BIN_PATH"
}

configure_warp() {
  local port="$1"
  systemctl enable --now warp-svc >/dev/null 2>&1 || systemctl start warp-svc >/dev/null 2>&1 || true
  timeout 60 warp-cli --accept-tos registration new >/dev/null 2>&1 \
    || timeout 60 warp-cli --accept-tos register >/dev/null 2>&1 \
    || true
  timeout 30 warp-cli --accept-tos tunnel protocol set MASQUE >/dev/null 2>&1 \
    || timeout 30 warp-cli tunnel protocol set MASQUE >/dev/null 2>&1 \
    || true
  timeout 30 warp-cli --accept-tos mode proxy >/dev/null 2>&1 || timeout 30 warp-cli mode proxy >/dev/null 2>&1
  timeout 30 warp-cli --accept-tos proxy port "$port" >/dev/null 2>&1 \
    || timeout 30 warp-cli --accept-tos set-proxy-port "$port" >/dev/null 2>&1 \
    || timeout 30 warp-cli proxy port "$port" >/dev/null 2>&1
  timeout 60 warp-cli --accept-tos connect >/dev/null 2>&1 || timeout 60 warp-cli connect >/dev/null 2>&1
  if ! wait_for_tcp_port "$port" 20; then
    die "warp-cli 没有监听 SOCKS 端口 $port"
  fi
  if ! curl --socks5-hostname "127.0.0.1:${port}" -fsS --connect-timeout 8 --max-time 15 \
    https://www.cloudflare.com/cdn-cgi/trace | grep -Eq '^warp=(on|plus)$'; then
    die "WARP SOCKS 测试没有返回 warp=on"
  fi
}

write_config() {
  local warp_port="$1"
  local redsocks_port="$2"
  local redsocks_uid="$3"
  local redsocks_group="$4"
  local redsocks_bin="$5"
  cat > "$CONFIG_FILE" <<EOF
APP_VERSION=${APP_VERSION_VALUE}
REPO_RAW_BASE=${REPO_RAW_BASE}
WARP_SOCKS_PORT=${warp_port}
REDSOCKS_PORT=${redsocks_port}
REDSOCKS_USER=${REDSOCKS_USER}
REDSOCKS_UID=${redsocks_uid}
REDSOCKS_GROUP=${redsocks_group}
REDSOCKS_BIN=${redsocks_bin}
EOF
  chmod 0600 "$CONFIG_FILE"
}

main() {
  require_root
  validate_repo_raw_base "$REPO_RAW_BASE"
  log "正在安装依赖"
  install_dependencies

  local warp_port redsocks_port redsocks_uid redsocks_group redsocks_bin
  warp_port="$(prompt_warp_port)"
  valid_port "$warp_port" || die "内部错误：选择的 WARP SOCKS 端口无效"
  redsocks_port="$(find_free_port "$warp_port")"
  valid_port "$redsocks_port" || die "内部错误：选择的 redsocks 端口无效"
  ensure_redsocks_user
  redsocks_uid="$(id -u "$REDSOCKS_USER")"
  redsocks_group="$(id -gn "$REDSOCKS_USER")"
  redsocks_bin="$(command -v redsocks)"

  log "正在安装项目文件"
  disable_packaged_redsocks_service
  install_project_files
  write_config "$warp_port" "$redsocks_port" "$redsocks_uid" "$redsocks_group" "$redsocks_bin"

  log "正在配置 Cloudflare WARP SOCKS，端口：$warp_port"
  configure_warp "$warp_port"

  log "正在安装系统服务和分流规则"
  "$BIN_PATH" install-systemd
  systemctl daemon-reload
  systemctl enable --now warp-vps-redsocks.service
  systemctl enable --now warp-vps.service
  systemctl enable --now warp-vps-health.timer

  log "正在运行最终自检"
  "$BIN_PATH" test

  printf '\nWARP VPS Manager 安装完成。\n'
  printf 'WARP SOCKS 端口：%s\n' "$warp_port"
  printf '管理命令：warp-vps {status|test|restart|update|logs|uninstall}\n'
  printf '已默认阻断 Google 目标 IPv6，避免 IPv6 泄漏。\n'
}

main "$@"
