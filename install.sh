#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_SOURCE="${BASH_SOURCE[0]:-}"
APP_NAME="warp-vps-manager"
APP_DIR="/opt/${APP_NAME}"
ETC_DIR="/etc/${APP_NAME}"
STATE_DIR="/var/lib/${APP_NAME}"
BACKUP_ROOT="/var/backups/${APP_NAME}"
BIN_PATH="/usr/local/bin/warp-vps"
CONFIG_FILE="${ETC_DIR}/config.env"
REDSOCKS_USER="warp-vps-redsocks"
WG_IFACE="warp-vps-wg"
WGCF_BIN="${APP_DIR}/bin/wgcf"
WG_CONFIG="/etc/wireguard/${WG_IFACE}.conf"
SWAP_FILE="/swapfile-warp-vps-manager"
DEFAULT_REPO_RAW_BASE="https://raw.githubusercontent.com/mqfut123/warp-vps-manager/main"
REPO_RAW_BASE="${WARP_VPS_REPO_BASE:-$DEFAULT_REPO_RAW_BASE}"
APT_LOCK_TIMEOUT=1200
REDSOCKS_FALLBACK_BIN="/usr/local/sbin/redsocks"
REDSOCKS_SOURCE_COMMIT="27b17889a43e32b0c1162514d00967e6967d41bb"
REDSOCKS_SOURCE_URL="https://github.com/darkk/redsocks/archive/${REDSOCKS_SOURCE_COMMIT}.tar.gz"
REDSOCKS_MANAGED_VERSION="redsocks/0.5-${REDSOCKS_SOURCE_COMMIT}"
REDSOCKS_MANAGED_MARKER="${STATE_DIR}/managed-redsocks-fallback"
MANAGED_REDSOCKS_BIN=0
MANAGED_WARP_SVC_VALUE=0
REDSOCKS_UNIT_PREEXISTED=0
WARP_CLIENT_PREEXISTED=0
SWAP_ACTION="none"
SWAP_SIZE_MB=0

log() { printf '[warp-vps] %s\n' "$*"; }
die() { printf '[warp-vps] 错误：%s\n' "$*" >&2; exit 1; }

read_input() {
  local var_name="$1"
  if [ -r /dev/tty ]; then
    # shellcheck disable=SC2229
    IFS= read -r "$var_name" </dev/tty
  else
    # shellcheck disable=SC2229
    IFS= read -r "$var_name"
  fi
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "请使用 root 用户运行"
}

require_systemd() {
  command -v systemctl >/dev/null 2>&1 || die "当前系统没有 systemctl，本项目需要 systemd"
  [ -d /run/systemd/system ] || die "当前系统没有运行 systemd，不能安装本项目"
  systemctl list-unit-files --no-legend >/dev/null 2>&1 \
    || die "无法连接 systemd，不能安装本项目"
}

load_os_release() {
  ID=""
  VERSION_CODENAME=""
  UBUNTU_CODENAME=""
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
  fi
  OS_ID="${ID:-}"
  OS_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
}

mem_available_mb() {
  awk '/^MemAvailable:/ { print int($2 / 1024); exit }' /proc/meminfo
}

swap_total_mb() {
  awk '/^SwapTotal:/ { print int($2 / 1024); exit }' /proc/meminfo
}

swap_free_mb() {
  awk '/^SwapFree:/ { print int($2 / 1024); exit }' /proc/meminfo
}

root_free_mb() {
  df -Pm / | awk 'NR == 2 { print $4 }'
}

format_gb() {
  local mb="$1"
  awk -v mb="$mb" 'BEGIN { printf "%.1fG", mb / 1024 }'
}

max_creatable_swap_mb() {
  local free_mb
  free_mb="$(root_free_mb)"
  if [ "$free_mb" -le 768 ]; then
    printf '0\n'
  else
    printf '%s\n' "$((free_mb - 512))"
  fi
}

create_swap_file() {
  local size_mb="$1"
  [ "$size_mb" -ge 256 ] || return 1
  if [ -e "$SWAP_FILE" ]; then
    log "$SWAP_FILE 已存在，不能覆盖"
    return 1
  fi

  log "正在创建 $(format_gb "$size_mb") Swap：$SWAP_FILE"
  if ! dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$size_mb" status=progress; then
    rollback_swap_file "写入 Swap 文件失败"
    return 1
  fi
  if ! chmod 0600 "$SWAP_FILE"; then
    rollback_swap_file "设置 Swap 权限失败"
    return 1
  fi
  if ! mkswap "$SWAP_FILE" >/dev/null; then
    rollback_swap_file "格式化 Swap 失败"
    return 1
  fi
  if ! swapon "$SWAP_FILE"; then
    rollback_swap_file "启用 Swap 失败"
    return 1
  fi
  if ! grep -qF "$SWAP_FILE" /etc/fstab; then
    if ! printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> /etc/fstab; then
      rollback_swap_file "写入 /etc/fstab 失败"
      return 1
    fi
  fi
  log "Swap 创建完成"
}

rollback_swap_file() {
  local reason="$1"
  local backup_dir
  backup_dir="${BACKUP_ROOT}/swap-failed-$(date -u +%Y%m%dT%H%M%SZ)"
  log "$reason，正在撤销本次 Swap 创建"
  if grep -qF "$SWAP_FILE" /proc/swaps 2>/dev/null; then
    swapoff "$SWAP_FILE" >/dev/null 2>&1 || true
  fi
  if [ -e "$SWAP_FILE" ]; then
    install -d -m 0755 "$backup_dir"
    mv "$SWAP_FILE" "${backup_dir}/swapfile-warp-vps-manager"
    log "半成品 Swap 文件已移动到：${backup_dir}/swapfile-warp-vps-manager"
  fi
}

prompt_swap_creation() {
  local mem_mb="$1"
  local max_mb selected choice custom_gb
  while true; do
    max_mb="$(max_creatable_swap_mb)"
    printf '\n检测到当前可用内存只有 %s，且系统没有 Swap。\n' "$(format_gb "$mem_mb")"
    printf '如果继续安装，Cloudflare WARP 或依赖安装可能因为内存不足失败。\n'
    printf '当前磁盘最多建议创建约 %s Swap。\n' "$(format_gb "$max_mb")"
    printf '\n请选择：\n'
    printf '  1. 创建 1G Swap\n'
    printf '  2. 创建 2G Swap（推荐）\n'
    printf '  3. 自定义 Swap 大小\n'
    printf '  4. 不创建 Swap，接受安装中途失败的风险继续\n'
    printf '  5. 退出安装\n'
    printf '请输入选项：'
    read_input choice || die "无法读取输入，已退出安装"
    case "$choice" in
      1) selected=1024 ;;
      2) selected=2048 ;;
      3)
        while true; do
          printf '请输入要创建的 Swap 大小，单位 G，例如 2：'
          read_input custom_gb || die "无法读取输入，已退出安装"
          case "$custom_gb" in
            ''|*[!0-9]*|0) printf '输入无效，请输入大于 0 的整数。\n' ; continue ;;
          esac
          break
        done
        selected=$((custom_gb * 1024))
        ;;
      4)
        printf '已选择不创建 Swap，继续安装。\n'
        SWAP_ACTION="none"
        SWAP_SIZE_MB=0
        return 0
        ;;
      5)
        die "已退出安装"
        ;;
      *)
        printf '输入无效，请输入 1、2、3、4 或 5。\n'
        continue
        ;;
    esac

    if [ "$selected" -gt "$max_mb" ]; then
      printf '创建失败：可用空间不足。当前最多建议创建 %s Swap。\n' "$(format_gb "$max_mb")"
      continue
    fi

    SWAP_ACTION="create"
    SWAP_SIZE_MB="$selected"
    return 0
  done
}

collect_swap_choice() {
  local mem_mb swap_total swap_free total_available choice
  SWAP_ACTION="none"
  SWAP_SIZE_MB=0
  mem_mb="$(mem_available_mb)"
  swap_total="$(swap_total_mb)"
  swap_free="$(swap_free_mb)"
  total_available=$((mem_mb + swap_free))

  [ "$mem_mb" -ge 1024 ] && return 0

  if [ "$swap_total" -eq 0 ]; then
    prompt_swap_creation "$mem_mb"
    return 0
  fi

  if [ "$total_available" -lt 1024 ]; then
    printf '\n检测到当前可用内存 %s，Swap 总量 %s，Swap 可用 %s。\n' \
      "$(format_gb "$mem_mb")" "$(format_gb "$swap_total")" "$(format_gb "$swap_free")"
    printf '内存仍然偏低，安装存在失败风险。建议先自行调整 Swap 后再安装。\n'
    while true; do
      printf '输入 1 表示知道风险并继续，输入 2 退出：'
      read_input choice || die "无法读取输入，已退出安装"
      case "$choice" in
        1) return 0 ;;
        2) die "已退出安装" ;;
        *) printf '输入无效，请输入 1 或 2。\n' ;;
      esac
    done
  fi
}

apply_swap_choice() {
  local mem_mb
  while [ "$SWAP_ACTION" = "create" ]; do
    if create_swap_file "$SWAP_SIZE_MB"; then
      return 0
    fi
    printf 'Swap 创建失败，已撤销本次创建。请重新选择。\n'
    mem_mb="$(mem_available_mb)"
    prompt_swap_creation "$mem_mb"
  done
}

pkg_install_apt() {
  local mode="$1"
  export DEBIAN_FRONTEND=noninteractive
  log "如果系统自动更新正在占用 apt/dpkg，最多等待 20 分钟"
  apt_get update -y

  if [ "$mode" = "wireguard" ]; then
    apt_get install -y curl ca-certificates coreutils iproute2 python3 wireguard-tools
    return
  fi

  apt_get install -y curl ca-certificates coreutils gnupg lsb-release nftables iproute2 python3 redsocks
  if command -v warp-cli >/dev/null 2>&1; then
    return
  fi

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
  apt_get update -y
  apt_get install -y cloudflare-warp
}

apt_get() {
  apt-get -o DPkg::Lock::Timeout="${APT_LOCK_TIMEOUT}" "$@"
}

redsocks_path() {
  if command -v redsocks >/dev/null 2>&1; then
    command -v redsocks
    return 0
  fi
  if [ -x "$REDSOCKS_FALLBACK_BIN" ]; then
    printf '%s\n' "$REDSOCKS_FALLBACK_BIN"
    return 0
  fi
  return 1
}

mark_managed_redsocks_if_current() {
  MANAGED_REDSOCKS_BIN=0
  [ -x "$REDSOCKS_FALLBACK_BIN" ] || return 0
  if [ -r "$REDSOCKS_MANAGED_MARKER" ]; then
    MANAGED_REDSOCKS_BIN=1
    return 0
  fi
  if grep -aFq "$REDSOCKS_MANAGED_VERSION" "$REDSOCKS_FALLBACK_BIN" 2>/dev/null; then
    MANAGED_REDSOCKS_BIN=1
  fi
}

raw_asset_url() {
  local rel="$1"
  printf '%s/%s\n' "${REPO_RAW_BASE%/}" "$rel"
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

build_redsocks_from_source() {
  local build_root archive src
  command -v gcc >/dev/null 2>&1 || die "源码构建 redsocks 需要 gcc"
  command -v tar >/dev/null 2>&1 || die "源码构建 redsocks 需要 tar"

  build_root="${STATE_DIR}/build/redsocks-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  archive="${build_root}/redsocks.tar.gz"
  install -d -m 0755 "$build_root"

  log "正在下载固定版本 redsocks 源码：${REDSOCKS_SOURCE_COMMIT}"
  curl -LfsS "$REDSOCKS_SOURCE_URL" -o "$archive"

  tar -xzf "$archive" -C "$build_root"
  src="${build_root}/redsocks-${REDSOCKS_SOURCE_COMMIT}"
  [ -d "$src" ] || die "redsocks 源码解压失败"

  install -d -m 0755 "$src/gen"
  printf '#define USE_IPTABLES\n' > "$src/config.h"
  cat > "$src/gen/version.c" <<EOF
/* this file is generated by ${APP_NAME} installer */
#include "../version.h"
const char* redsocks_version = "redsocks/0.5-${REDSOCKS_SOURCE_COMMIT}";
EOF

  (
    cd "$src"
    gcc -g -O2 -std=c99 -D_XOPEN_SOURCE=600 -D_DEFAULT_SOURCE -D_GNU_SOURCE -Wall \
      -o redsocks \
      parser.c main.c redsocks.c log.c http-connect.c socks4.c socks5.c http-relay.c \
      base.c base64.c md5.c http-auth.c utils.c redudp.c dnstc.c gen/version.c \
      -levent_core
  )
  if [ -e "$REDSOCKS_FALLBACK_BIN" ] && [ ! -x "$REDSOCKS_FALLBACK_BIN" ]; then
    die "目标路径已存在但不是可执行文件：$REDSOCKS_FALLBACK_BIN"
  fi
  install -m 0755 "$src/redsocks" "$REDSOCKS_FALLBACK_BIN"
  install -d -m 0755 "$STATE_DIR"
  printf '%s\n' "$REDSOCKS_MANAGED_VERSION" > "$REDSOCKS_MANAGED_MARKER"
  MANAGED_REDSOCKS_BIN=1
  [ -x "$REDSOCKS_FALLBACK_BIN" ] || die "redsocks 源码构建后仍找不到可执行文件"
}

rpm_install_redsocks() {
  local manager="$1"
  if redsocks_path >/dev/null 2>&1; then
    mark_managed_redsocks_if_current
    return
  fi

  if [ "$OS_ID" = "fedora" ]; then
    "$manager" install -y redsocks
    return
  fi

  log "当前 RPM 系统使用固定上游源码构建 redsocks"
  "$manager" install -y gcc tar gzip libevent-devel
  build_redsocks_from_source
}

pkg_install_rpm() {
  local mode="$1"
  local manager="$2"
  if [ "$OS_ID" != "fedora" ]; then
    enable_rhel_extra_repos
  fi

  if [ "$mode" = "wireguard" ]; then
    "$manager" install -y curl ca-certificates coreutils iproute python3 wireguard-tools
    return
  fi

  "$manager" install -y curl ca-certificates coreutils nftables iproute python3
  rpm_install_redsocks "$manager"
  if ! command -v warp-cli >/dev/null 2>&1; then
    rpm --import https://pkg.cloudflareclient.com/pubkey.gpg
    curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
      -o /etc/yum.repos.d/cloudflare-warp.repo
    "$manager" install -y cloudflare-warp
  fi
}

install_dependencies() {
  local mode="$1"
  local manager
  load_os_release
  if command -v apt-get >/dev/null 2>&1; then
    pkg_install_apt "$mode"
  elif command -v dnf >/dev/null 2>&1; then
    manager="dnf"
    pkg_install_rpm "$mode" "$manager"
  elif command -v yum >/dev/null 2>&1; then
    manager="yum"
    pkg_install_rpm "$mode" "$manager"
  else
    die "找不到 apt-get、dnf 或 yum，无法安装依赖"
  fi

  command -v curl >/dev/null 2>&1 || die "依赖安装后仍找不到 curl"
  command -v ip >/dev/null 2>&1 || die "依赖安装后仍找不到 ip"
  command -v ss >/dev/null 2>&1 || die "依赖安装后仍找不到 ss"
  command -v timeout >/dev/null 2>&1 || die "依赖安装后仍找不到 timeout"
  command -v python3 >/dev/null 2>&1 || die "依赖安装后仍找不到 python3"
  if [ "$mode" = "wireguard" ]; then
    command -v wg >/dev/null 2>&1 || die "依赖安装后仍找不到 wg"
    command -v wg-quick >/dev/null 2>&1 || die "依赖安装后仍找不到 wg-quick"
  else
    command -v nft >/dev/null 2>&1 || die "依赖安装后仍找不到 nftables"
    command -v warp-cli >/dev/null 2>&1 || die "cloudflare-warp 已安装但找不到 warp-cli"
    redsocks_path >/dev/null 2>&1 || die "依赖安装后仍找不到 redsocks"
  fi
}

unit_file_exists() {
  local unit="$1"
  systemctl list-unit-files "$unit" --no-legend 2>/dev/null \
    | awk -v unit="$unit" '$1 == unit { found=1 } END { exit !found }'
}

capture_service_ownership() {
  local mode="$1"
  REDSOCKS_UNIT_PREEXISTED=0
  WARP_CLIENT_PREEXISTED=0
  MANAGED_WARP_SVC_VALUE=0
  if [ -r "$CONFIG_FILE" ] && grep -qx 'MANAGED_WARP_SVC=1' "$CONFIG_FILE"; then
    MANAGED_WARP_SVC_VALUE=1
  fi
  [ "$mode" = "socks" ] || return 0

  if unit_file_exists redsocks.service; then
    REDSOCKS_UNIT_PREEXISTED=1
  fi
  if command -v warp-cli >/dev/null 2>&1 || unit_file_exists warp-svc.service; then
    WARP_CLIENT_PREEXISTED=1
  fi
  if [ "$WARP_CLIENT_PREEXISTED" -eq 0 ]; then
    MANAGED_WARP_SVC_VALUE=1
  fi
}

disable_new_packaged_redsocks_service() {
  [ "$REDSOCKS_UNIT_PREEXISTED" -eq 0 ] || return 0
  unit_file_exists redsocks.service || return 0
  systemctl disable --now redsocks.service >/dev/null 2>&1 || true
}

preflight_nft_nat() {
  local table="warp_vps_preflight_$$"
  nft delete table inet "$table" >/dev/null 2>&1 || true
  if ! nft -f - <<EOF
add table inet ${table}
add chain inet ${table} output_nat { type nat hook output priority -100; policy accept; }
delete table inet ${table}
EOF
  then
    nft delete table inet "$table" >/dev/null 2>&1 || true
    die "当前系统不支持 nftables OUTPUT NAT，不能安装 Socks5 透明分流方案"
  fi
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
  local port="$1"
  local port_hex file
  if command -v ss >/dev/null 2>&1; then
    ss -H -ltnu "sport = :${port}" 2>/dev/null | grep -q .
    return
  fi

  printf -v port_hex '%04X' "$port"
  for file in /proc/net/tcp /proc/net/tcp6 /proc/net/udp /proc/net/udp6; do
    [ -r "$file" ] || continue
    if awk -v port="$port_hex" '
      NR > 1 { split($2, address, ":"); if (toupper(address[2]) == port) found=1 }
      END { exit !found }
    ' "$file"; then
      return 0
    fi
  done
  return 1
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

prompt_install_mode() {
  local recommended choice
  recommended="socks"

  printf '\n请选择 WARP 分流方案：\n' >&2
  printf '  1. Socks5 方案：更稳，低风险。命中规则的 Google IPv4 TCP 走 WARP，UDP/443 阻断后通常回落 TCP。\n' >&2
  printf '  2. WireGuard 方案：高级模式。TCP+UDP 都可按 Google CIDR 走 WARP，安装时会实际拉起接口做预检。\n' >&2
  printf '  3. 退出安装\n' >&2
  printf '普通用户推荐 Socks5；明确需要 UDP/QUIC 再选 WireGuard。\n' >&2
  printf '直接回车默认选择：Socks5\n' >&2
  while true; do
    printf '请输入选项：' >&2
    read_input choice || die "无法读取输入，已退出安装"
    case "$choice" in
      '') printf '%s\n' "$recommended"; return 0 ;;
      1) printf 'socks\n'; return 0 ;;
      2) printf 'wireguard\n'; return 0 ;;
      3) die "已退出安装" ;;
      *) printf '输入无效，请输入 1、2、3，或直接回车。\n' >&2 ;;
    esac
  done
}

find_free_port() {
  local avoid="${1:-}"
  local candidate
  local i=0
  while [ "$i" -lt 400 ]; do
    candidate=$((20000 + (((RANDOM << 15) + RANDOM) % 41000)))
    if [ "$candidate" != "$avoid" ] && ! port_in_use "$candidate"; then
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
    valid_port "$input" || die "环境变量 WARP_SOCKS_PORT 不是有效端口：$input"
    port_in_use "$input" && die "环境变量 WARP_SOCKS_PORT 指定的端口已被占用：$input"
    printf '%s\n' "$input"
    return 0
  fi

  while true; do
    printf '请输入 WARP SOCKS 端口（直接回车随机选择空闲端口）：' >&2
    read_input input || die "无法读取输入，已退出安装"
    if [ -z "$input" ]; then
      find_free_port
      return 0
    fi
    if ! valid_port "$input"; then
      printf '端口无效，请输入 1-65535 的数字。\n' >&2
      continue
    fi
    if port_in_use "$input"; then
      printf '端口 %s 已被占用，请换一个。\n' "$input" >&2
      continue
    fi
    printf '%s\n' "$input"
    return 0
  done
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
  local source_path script_dir
  source_path="$SCRIPT_SOURCE"
  script_dir=""
  if [ -n "$source_path" ]; then
    script_dir="$(cd -- "$(dirname -- "$source_path")" && pwd -P 2>/dev/null)" || script_dir=""
  fi

  if [ -n "$script_dir" ] && [ -f "${script_dir}/${rel}" ]; then
    install -m "$mode" "${script_dir}/${rel}" "$dest"
    return
  fi

  local url
  url="$(raw_asset_url "$rel")"
  curl -fsSL "$url" -o "$dest" || die "下载项目文件失败：${rel}（${url}）"
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

warp_registration_missing() {
  local output status_output
  if output="$(timeout 30 warp-cli --accept-tos registration show 2>&1)"; then
    return 1
  fi
  status_output="$(timeout 30 warp-cli --accept-tos status 2>&1 || true)"
  output="${output}"$'\n'"${status_output}"
  grep -Eiq 'registration.*(missing|required|not found)|not registered|no .*registration' <<< "$output"
}

set_warp_proxy_mode() {
  local i
  for i in 1 2 3 4 5 6; do
    if timeout 30 warp-cli --accept-tos mode proxy >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

configure_warp() {
  local port="$1"
  local i ok
  systemctl enable --now warp-svc >/dev/null 2>&1 \
    || die "无法启动 Cloudflare WARP 服务"

  if ! set_warp_proxy_mode; then
    if ! warp_registration_missing; then
      die "无法把已注册的 Cloudflare WARP 切换到 SOCKS 代理模式"
    fi
    log "Cloudflare WARP 尚未注册，正在创建注册"
    timeout 60 warp-cli --accept-tos registration new >/dev/null 2>&1 \
      || timeout 60 warp-cli --accept-tos register >/dev/null 2>&1 \
      || die "Cloudflare WARP 注册失败"
    set_warp_proxy_mode || die "注册后仍无法把 Cloudflare WARP 切换到 SOCKS 代理模式"
  fi

  timeout 30 warp-cli --accept-tos tunnel protocol set MASQUE >/dev/null 2>&1 \
    || timeout 30 warp-cli tunnel protocol set MASQUE >/dev/null 2>&1 \
    || true
  ok=0
  for i in 1 2 3 4 5 6; do
    if timeout 30 warp-cli --accept-tos proxy port "$port" >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 2
  done
  [ "$ok" -eq 1 ] || die "无法设置 WARP SOCKS 端口 $port"
  for i in 1 2 3; do
    timeout 60 warp-cli --accept-tos connect >/dev/null 2>&1 && break
    sleep 2
  done
  if ! wait_for_tcp_port "$port" 20; then
    die "warp-cli 没有监听 SOCKS 端口 $port"
  fi
  if ! curl --socks5-hostname "127.0.0.1:${port}" -fsS --connect-timeout 8 --max-time 15 \
    https://www.cloudflare.com/cdn-cgi/trace | grep -Eq '^warp=(on|plus)$'; then
    die "WARP SOCKS 测试没有返回 warp=on"
  fi
}

write_config() {
  local mode="$1"
  local warp_port="$2"
  local redsocks_port="$3"
  local redsocks_uid="$4"
  local redsocks_group="$5"
  local redsocks_bin="$6"
  cat > "$CONFIG_FILE" <<EOF
REPO_RAW_BASE=${REPO_RAW_BASE}
WARP_MODE=${mode}
WARP_SOCKS_PORT=${warp_port}
REDSOCKS_PORT=${redsocks_port}
REDSOCKS_USER=${REDSOCKS_USER}
REDSOCKS_UID=${redsocks_uid}
REDSOCKS_GROUP=${redsocks_group}
REDSOCKS_BIN=${redsocks_bin}
WG_IFACE=${WG_IFACE}
WGCF_BIN=${WGCF_BIN}
WG_CONFIG=${WG_CONFIG}
MANAGED_WARP_SVC=${MANAGED_WARP_SVC_VALUE}
MANAGED_REDSOCKS_BIN=${MANAGED_REDSOCKS_BIN:-0}
EOF
  chmod 0600 "$CONFIG_FILE"
}

stop_project_runtime() {
  systemctl disable --now warp-vps-health.timer warp-vps-health.service \
    warp-vps.service warp-vps-redsocks.service "wg-quick@${WG_IFACE}.service" \
    >/dev/null 2>&1 || true
  if [ "$MANAGED_WARP_SVC_VALUE" -eq 1 ]; then
    systemctl disable --now warp-svc.service >/dev/null 2>&1 || true
  fi
  if [ -x "$BIN_PATH" ] && [ -r "$CONFIG_FILE" ]; then
    "$BIN_PATH" stop-rules >/dev/null 2>&1 || true
  fi
  if command -v nft >/dev/null 2>&1; then
    nft delete table inet warp_vps >/dev/null 2>&1 || true
  fi
  if command -v ip >/dev/null 2>&1 && ip link show "$WG_IFACE" >/dev/null 2>&1; then
    if command -v wg-quick >/dev/null 2>&1; then
      wg-quick down "$WG_CONFIG" >/dev/null 2>&1 \
        || wg-quick down "$WG_IFACE" >/dev/null 2>&1 \
        || true
    fi
    if ip link show "$WG_IFACE" >/dev/null 2>&1; then
      ip link delete dev "$WG_IFACE" >/dev/null 2>&1 \
        || die "无法停止本项目 WireGuard 网卡：$WG_IFACE"
    fi
  fi
}

run_final_self_check() {
  if "$BIN_PATH" test; then
    return 0
  fi
  log "最终自检失败，正在停止本项目服务和分流规则"
  stop_project_runtime
  die "最终自检失败；已停止本项目运行态，CLI、配置和日志已保留。请运行 warp-vps logs 排查，修复后可直接重跑安装器"
}

main() {
  require_root
  require_systemd
  validate_repo_raw_base "$REPO_RAW_BASE"

  local selected_mode warp_port redsocks_port redsocks_uid redsocks_group redsocks_bin
  selected_mode="$(prompt_install_mode)"
  collect_swap_choice
  if [ "$selected_mode" = "socks" ]; then
    warp_port="$(prompt_warp_port)"
    valid_port "$warp_port" || die "内部错误：选择的 WARP SOCKS 端口无效"
    redsocks_port="$(find_free_port "$warp_port")"
    valid_port "$redsocks_port" || die "内部错误：选择的 redsocks 端口无效"
  else
    warp_port=0
    redsocks_port=0
  fi

  capture_service_ownership "$selected_mode"
  stop_project_runtime

  log "正在安装项目文件和管理命令"
  install_project_files
  write_config "$selected_mode" "$warp_port" "$redsocks_port" 0 root /usr/sbin/redsocks

  apply_swap_choice

  log "正在安装依赖"
  install_dependencies "$selected_mode"

  if [ "$selected_mode" = "socks" ]; then
    disable_new_packaged_redsocks_service
    preflight_nft_nat
    port_in_use "$warp_port" && die "安装依赖期间端口 $warp_port 被占用，请直接重跑安装器选择其他端口"
    port_in_use "$redsocks_port" && die "安装依赖期间内部端口 $redsocks_port 被占用，请直接重跑安装器"
    ensure_redsocks_user
    redsocks_uid="$(id -u "$REDSOCKS_USER")"
    redsocks_group="$(id -gn "$REDSOCKS_USER")"
    redsocks_bin="$(redsocks_path)"
    mark_managed_redsocks_if_current
  else
    redsocks_uid=0
    redsocks_group=root
    redsocks_bin=/usr/sbin/redsocks
  fi

  write_config "$selected_mode" "$warp_port" "$redsocks_port" "$redsocks_uid" "$redsocks_group" "$redsocks_bin"

  if [ "$selected_mode" = "socks" ]; then
    log "正在配置 Cloudflare WARP SOCKS，端口：$warp_port"
    configure_warp "$warp_port"
  else
    log "正在配置 WireGuard WARP 高级模式"
    "$BIN_PATH" setup-wireguard
    "$BIN_PATH" preflight-wireguard
  fi

  log "正在安装系统服务和分流规则"
  "$BIN_PATH" install-systemd
  systemctl daemon-reload
  if [ "$selected_mode" = "socks" ]; then
    systemctl enable --now warp-vps-redsocks.service
  else
    systemctl enable --now "wg-quick@${WG_IFACE}.service"
  fi
  systemctl enable --now warp-vps.service
  systemctl enable --now warp-vps-health.timer

  log "正在运行最终自检"
  run_final_self_check

  printf '\nWARP VPS Manager 安装完成。\n'
  if [ "$selected_mode" = "socks" ]; then
    printf '安装模式：Socks5 稳定模式\n'
  else
    printf '安装模式：WireGuard 高级模式\n'
  fi
  if [ "$selected_mode" = "socks" ]; then
    printf 'WARP SOCKS 端口：%s\n' "$warp_port"
  fi
  printf '管理命令：warp-vps {status|test|restart|unlock-check|update|logs|uninstall}\n'
  if [ "$selected_mode" = "socks" ]; then
    printf '已默认阻断 Google 目标 IPv6，避免 IPv6 泄漏。\n'
  else
    printf 'WireGuard 模式会把命中 Google CIDR 的 TCP/UDP 流量路由到 WARP。\n'
  fi

  printf '\n安装后 IPv4 出口解锁检测：\n'
  "$BIN_PATH" unlock-check || true
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
