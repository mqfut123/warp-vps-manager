#!/usr/bin/env bash
set -Eeuo pipefail

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
APP_VERSION_VALUE="0.1.3"
APT_LOCK_TIMEOUT=1200
REDSOCKS_FALLBACK_BIN="/usr/local/sbin/redsocks"
REDSOCKS_SOURCE_COMMIT="27b17889a43e32b0c1162514d00967e6967d41bb"
REDSOCKS_SOURCE_SHA256="40acdf4404376a94434f4fcced9d62239ca1a58c759e7998a4fbf519ce8a0a49"
REDSOCKS_SOURCE_URL="https://github.com/darkk/redsocks/archive/${REDSOCKS_SOURCE_COMMIT}.tar.gz"
REDSOCKS_MANAGED_VERSION="redsocks/0.5-${REDSOCKS_SOURCE_COMMIT}"
REDSOCKS_MANAGED_MARKER="${STATE_DIR}/managed-redsocks-fallback"
MANAGED_REDSOCKS_BIN=0
RESOLVED_REPO_RAW_BASE=""
RESOLVED_REPO_COMMIT=""
UNLOCK_TEST_UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36"
UNLOCK_CONNECT_TIMEOUT=5
UNLOCK_MAX_TIME=12

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
  [ "$size_mb" -ge 256 ] || die "Swap 大小过小"
  [ ! -e "$SWAP_FILE" ] || die "$SWAP_FILE 已存在，请先自行检查后再安装"

  log "正在创建 $(format_gb "$size_mb") Swap：$SWAP_FILE"
  if ! dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$size_mb" status=progress; then
    rollback_swap_file "写入 Swap 文件失败"
    die "Swap 创建失败：写入文件失败"
  fi
  if ! chmod 0600 "$SWAP_FILE"; then
    rollback_swap_file "设置 Swap 权限失败"
    die "Swap 创建失败：无法设置权限"
  fi
  if ! mkswap "$SWAP_FILE" >/dev/null; then
    rollback_swap_file "格式化 Swap 失败"
    die "Swap 创建失败：mkswap 失败"
  fi
  if ! swapon "$SWAP_FILE"; then
    rollback_swap_file "启用 Swap 失败"
    die "Swap 创建失败：swapon 失败"
  fi
  if ! grep -qF "$SWAP_FILE" /etc/fstab; then
    if ! printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> /etc/fstab; then
      rollback_swap_file "写入 /etc/fstab 失败"
      die "Swap 创建失败：无法写入 /etc/fstab"
    fi
  fi
  log "Swap 创建完成"
}

rollback_swap_file() {
  local reason="$1"
  local backup_dir="${BACKUP_ROOT}/swap-failed-$(date -u +%Y%m%dT%H%M%SZ)"
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
  local max_mb selected choice custom_gb custom_mb
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
    read -r choice
    case "$choice" in
      1) selected=1024 ;;
      2) selected=2048 ;;
      3)
        printf '请输入要创建的 Swap 大小，单位 G，例如 2：'
        read -r custom_gb
        case "$custom_gb" in
          ''|*[!0-9]*) die "输入无效，已退出安装" ;;
        esac
        selected=$((custom_gb * 1024))
        ;;
      4)
        printf '已选择不创建 Swap，继续安装。\n'
        return 0
        ;;
      5|'')
        die "已退出安装"
        ;;
      *)
        die "输入无效，已退出安装"
        ;;
    esac

    if [ "$selected" -gt "$max_mb" ]; then
      printf '创建失败：可用空间不足。当前最多建议创建 %s Swap。\n' "$(format_gb "$max_mb")"
      continue
    fi

    create_swap_file "$selected"
    return 0
  done
}

check_memory_before_install() {
  local mem_mb swap_total swap_free total_available
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
    printf '输入 1 表示知道风险并继续，其他输入退出：'
    read -r choice
    [ "$choice" = "1" ] || die "已退出安装"
  fi
}

curl_unlock_page() {
  local url="$1"
  curl -4 -fsSL --connect-timeout "$UNLOCK_CONNECT_TIMEOUT" --max-time "$UNLOCK_MAX_TIME" \
    -A "$UNLOCK_TEST_UA" \
    -H 'accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
    -H 'accept-language: en-US,en;q=0.9' \
    "$url" 2>/dev/null || true
}

extract_youtube_region() {
  local body="$1"
  local region
  region="$(sed -n 's/.*"INNERTUBE_CONTEXT_GL"[[:space:]]*:[[:space:]]*"\([A-Za-z][A-Za-z]\)".*/\1/p' <<< "$body")"
  region="${region%%$'\n'*}"
  if [ -z "$region" ]; then
    region="$(sed -n 's/.*"countryCode"[[:space:]]*:[[:space:]]*"\([A-Za-z][A-Za-z]\)".*/\1/p' <<< "$body")"
    region="${region%%$'\n'*}"
  fi
  printf '%s' "$region" | tr '[:lower:]' '[:upper:]'
  printf '\n'
}

extract_gemini_region() {
  local body="$1"
  awk 'match($0, /,2,1,200,"[A-Z][A-Z][A-Z]"/) { print substr($0, RSTART + 10, 3); exit }' <<< "$body"
}

probe_gemini_unlock() {
  local body region
  body="$(curl_unlock_page "https://gemini.google.com/")"
  if [ -z "$body" ]; then
    printf 'unknown|网络连接失败\n'
    return 0
  fi

  region="$(extract_gemini_region "$body")"
  if grep -q '45631641,null,true' <<< "$body"; then
    if [ -n "$region" ]; then
      printf 'yes|地区：%s\n' "$region"
    else
      printf 'yes|\n'
    fi
    return 0
  fi

  if grep -Eiq 'not available in your country|not currently available|is unavailable|unavailable in your country|Gemini is not available' <<< "$body"; then
    printf 'no|当前出口不可用\n'
    return 0
  fi

  printf 'unknown|页面特征不明确\n'
}

probe_youtube_premium_unlock() {
  local body region
  body="$(curl_unlock_page "https://www.youtube.com/premium")"
  if [ -z "$body" ]; then
    printf 'unknown|网络连接失败\n'
    return 0
  fi

  region="$(extract_youtube_region "$body")"
  if grep -q 'www.google.cn' <<< "$body"; then
    printf 'no|地区：CN\n'
    return 0
  fi

  if grep -Eiq 'Premium is not available in your country|Premium is not available' <<< "$body"; then
    if [ -n "$region" ]; then
      printf 'no|地区：%s\n' "$region"
    else
      printf 'no|当前出口不可用\n'
    fi
    return 0
  fi

  if [ -n "$region" ] && grep -Eiq 'ad-free|YouTube and YouTube Music ad-free' <<< "$body"; then
    printf 'yes|地区：%s\n' "$region"
    return 0
  fi

  if [ -z "$region" ]; then
    printf 'unknown|未取到地区\n'
  else
    printf 'unknown|页面特征不明确\n'
  fi
}

print_install_unlock_result() {
  local name="$1"
  local result="$2"
  local status detail suffix
  status="${result%%|*}"
  detail="${result#*|}"
  [ "$detail" != "$result" ] || detail=""
  suffix=""
  [ -n "$detail" ] && suffix="（${detail}）"
  case "$status" in
    yes) printf '  %s：可用%s\n' "$name" "$suffix" ;;
    no) printf '  %s：不可用%s\n' "$name" "$suffix" ;;
    *) printf '  %s：无法确认%s\n' "$name" "$suffix" ;;
  esac
}

pre_install_unlock_probe() {
  printf '\n安装前当前 IPv4 出口解锁检测：\n'
  if ! command -v curl >/dev/null 2>&1; then
    printf '  未找到 curl，跳过安装前检测；安装依赖时会自动补齐。\n'
    return 0
  fi
  printf '  正在检测 Gemini 和 YouTube Premium，请稍等...\n'
  print_install_unlock_result "Gemini" "$(probe_gemini_unlock)"
  print_install_unlock_result "YouTube Premium" "$(probe_youtube_premium_unlock)"
  printf '  说明：这是安装前当前 VPS IPv4 出口结果，安装完成后会再检测 WARP 分流后的 IPv4 出口结果。\n'
}

pkg_install_apt() {
  local mode="$1"
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
  log "如果系统自动更新正在占用 apt/dpkg，最多等待 20 分钟"
  apt_get update -y
  apt_get install -y curl ca-certificates gnupg lsb-release nftables iptables iproute2 python3

  if [ "$mode" = "wireguard" ]; then
    apt_get install -y wireguard-tools
    return
  fi

  apt_get install -y redsocks
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
  local base="${RESOLVED_REPO_RAW_BASE:-${REPO_RAW_BASE%/}}"
  local url="${base}/${rel}"
  local sep="?"
  case "$url" in *\?*) sep="&" ;; esac
  printf '%s%swarp_vps_ts=%s\n' "$url" "$sep" "$(date -u +%s)"
}

resolve_github_raw_base() {
  local base="${REPO_RAW_BASE%/}"
  local path owner repo ref rest api sha
  case "$base" in
    https://raw.githubusercontent.com/*) ;;
    *) return 1 ;;
  esac
  path="${base#https://raw.githubusercontent.com/}"
  owner="${path%%/*}"
  path="${path#*/}"
  repo="${path%%/*}"
  path="${path#*/}"
  ref="${path%%/*}"
  if [ "$path" = "$ref" ]; then
    rest=""
  else
    rest="${path#*/}"
  fi
  [ -n "$owner" ] && [ -n "$repo" ] && [ -n "$ref" ] || return 1
  api="https://api.github.com/repos/${owner}/${repo}/commits/${ref}"
  sha="$(curl -fsSL "$api" | python3 -c 'import json,sys; print(json.load(sys.stdin)["sha"])')" || return 1
  case "$sha" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) return 1 ;;
  esac
  RESOLVED_REPO_COMMIT="$sha"
  if [ -n "$rest" ]; then
    RESOLVED_REPO_RAW_BASE="https://raw.githubusercontent.com/${owner}/${repo}/${sha}/${rest}"
  else
    RESOLVED_REPO_RAW_BASE="https://raw.githubusercontent.com/${owner}/${repo}/${sha}"
  fi
}

resolve_repo_raw_base() {
  RESOLVED_REPO_RAW_BASE="${REPO_RAW_BASE%/}"
  RESOLVED_REPO_COMMIT=""
  case "${REPO_RAW_BASE%/}" in
    https://raw.githubusercontent.com/*)
      resolve_github_raw_base || die "无法把 GitHub raw 地址锁定到具体提交，请检查 GitHub API 连通性或使用完整可访问的 raw 地址"
      ;;
  esac
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
  local build_root archive actual src
  command -v gcc >/dev/null 2>&1 || die "源码构建 redsocks 需要 gcc"
  command -v tar >/dev/null 2>&1 || die "源码构建 redsocks 需要 tar"
  command -v sha256sum >/dev/null 2>&1 || die "源码构建 redsocks 需要 sha256sum"

  build_root="${STATE_DIR}/build/redsocks-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  archive="${build_root}/redsocks.tar.gz"
  install -d -m 0755 "$build_root"

  log "正在下载固定版本 redsocks 源码：${REDSOCKS_SOURCE_COMMIT}"
  curl -LfsS "$REDSOCKS_SOURCE_URL" -o "$archive"
  actual="$(sha256sum "$archive" | awk '{ print $1 }')"
  [ "$actual" = "$REDSOCKS_SOURCE_SHA256" ] || die "redsocks 源码校验失败，期望 ${REDSOCKS_SOURCE_SHA256}，实际 ${actual}"

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
  if "$manager" install -y redsocks; then
    return
  fi

  log "当前 RPM 软件源没有可用 redsocks，改用固定源码构建"
  "$manager" install -y gcc tar gzip libevent-devel
  build_redsocks_from_source
}

pkg_install_rpm() {
  local mode="$1"
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
  if command -v dnf >/dev/null 2>&1; then
    dnf install -y curl ca-certificates gnupg2 nftables iptables-nft iproute python3
    if [ "$mode" = "wireguard" ]; then
      dnf install -y wireguard-tools
      return
    fi
    rpm --import https://pkg.cloudflareclient.com/pubkey.gpg
    curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
      -o /etc/yum.repos.d/cloudflare-warp.repo
    rpm_install_redsocks dnf
    dnf install -y cloudflare-warp
  else
    yum install -y curl ca-certificates gnupg2 nftables iptables iproute python3
    if [ "$mode" = "wireguard" ]; then
      yum install -y wireguard-tools
      return
    fi
    rpm --import https://pkg.cloudflareclient.com/pubkey.gpg
    curl -fsSL https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
      -o /etc/yum.repos.d/cloudflare-warp.repo
    rpm_install_redsocks yum
    yum install -y cloudflare-warp
  fi
}

install_dependencies() {
  local mode="$1"
  load_os_release
  case "$OS_ID" in
    debian|ubuntu)
      pkg_install_apt "$mode"
      ;;
    centos|rhel|rocky|almalinux)
      pkg_install_rpm "$mode"
      ;;
    *)
      die "不支持当前系统：${OS_ID:-未知}；支持 Debian、Ubuntu、CentOS、RHEL、Rocky、AlmaLinux"
      ;;
  esac

  command -v nft >/dev/null 2>&1 || die "依赖安装后仍找不到 nftables"
  command -v ss >/dev/null 2>&1 || die "依赖安装后仍找不到 ss"
  command -v timeout >/dev/null 2>&1 || die "依赖安装后仍找不到 timeout"
  command -v python3 >/dev/null 2>&1 || die "依赖安装后仍找不到 python3"
  if [ "$mode" = "wireguard" ]; then
    command -v wg >/dev/null 2>&1 || die "依赖安装后仍找不到 wg"
    command -v wg-quick >/dev/null 2>&1 || die "依赖安装后仍找不到 wg-quick"
  else
    command -v warp-cli >/dev/null 2>&1 || die "cloudflare-warp 已安装但找不到 warp-cli"
    redsocks_path >/dev/null 2>&1 || die "依赖安装后仍找不到 redsocks"
  fi
}

ensure_no_existing_redsocks_service() {
  if systemctl list-unit-files redsocks.service >/dev/null 2>&1; then
    if systemctl is-active --quiet redsocks.service || systemctl is-enabled --quiet redsocks.service; then
      die "检测到系统已有启用中的 redsocks.service。为避免影响现有业务，请先自行确认后再安装"
    fi
  fi
}

ensure_no_existing_warp_client() {
  if command -v warp-cli >/dev/null 2>&1 || systemctl list-unit-files warp-svc.service >/dev/null 2>&1; then
    die "检测到系统已有 Cloudflare WARP 官方客户端。为避免接管或停用用户原有 WARP，请先自行确认并清理后再安装 Socks5 模式"
  fi
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

tun_available() {
  [ -c /dev/net/tun ]
}

wireguard_recommended() {
  local kernel_major
  tun_available || return 1
  kernel_major="$(uname -r | awk -F. '{ print $1 }')"
  case "$kernel_major" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$kernel_major" -ge 5 ]
}

prompt_install_mode() {
  local recommended choice
  recommended="socks"

  printf '\n请选择 WARP 分流方案：\n' >&2
  printf '  1. Socks5 方案：更稳，低风险。命中规则的 Google IPv4 TCP 走 WARP，UDP/443 阻断后通常回落 TCP。\n' >&2
  printf '  2. WireGuard 方案：高级模式。TCP+UDP 都可按 Google CIDR 走 WARP，但需要 TUN/WireGuard 能力，路由风险更高。\n' >&2
  printf '  3. 退出安装\n' >&2
  if wireguard_recommended; then
    printf '环境检测：TUN 可用，内核版本适合 WireGuard。普通用户推荐 Socks5；明确需要 UDP/QUIC 再选 WireGuard。\n' >&2
  else
    printf '环境检测：当前环境不适合 WireGuard，推荐 Socks5。\n' >&2
  fi
  printf '直接回车默认选择：Socks5\n' >&2
  printf '请输入选项：' >&2
  read -r choice

  case "$choice" in
    '')
      printf '%s\n' "$recommended"
      ;;
    1)
      printf 'socks\n'
      ;;
    2)
      tun_available || die "当前系统没有可用 /dev/net/tun，不能安装 WireGuard 方案"
      printf 'wireguard\n'
      ;;
    3)
      die "已退出安装"
      ;;
    *)
      die "输入无效，已退出安装"
      ;;
  esac
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

  local url
  url="$(raw_asset_url "$rel")"
  curl -fsSL "$url" -o "$dest" || die "下载项目文件失败：${rel}（${url}）"
  chmod "$mode" "$dest"
}

install_project_files() {
  install -d -m 0755 "$APP_DIR" "$APP_DIR/bin" "$APP_DIR/rules" "$ETC_DIR" "$STATE_DIR"
  resolve_repo_raw_base
  if [ -n "$RESOLVED_REPO_COMMIT" ]; then
    log "已锁定 GitHub 提交：${RESOLVED_REPO_COMMIT:0:7}"
  fi
  fetch_asset "install.sh" "$APP_DIR/install.sh" 0755
  fetch_asset "bin/warp-vps" "$APP_DIR/bin/warp-vps" 0755
  fetch_asset "rules/google_ipv4.txt" "$APP_DIR/rules/google_ipv4.txt" 0644
  fetch_asset "rules/google_ipv6.txt" "$APP_DIR/rules/google_ipv6.txt" 0644
  fetch_asset "rules/rules.meta.json" "$APP_DIR/rules/rules.meta.json" 0644
  install -m 0755 "$APP_DIR/bin/warp-vps" "$BIN_PATH"
}

configure_warp() {
  local port="$1"
  local i ok
  systemctl enable --now warp-svc >/dev/null 2>&1 || systemctl start warp-svc >/dev/null 2>&1 || true
  timeout 60 warp-cli --accept-tos registration new >/dev/null 2>&1 \
    || timeout 60 warp-cli --accept-tos register >/dev/null 2>&1 \
    || true
  timeout 30 warp-cli --accept-tos tunnel protocol set MASQUE >/dev/null 2>&1 \
    || timeout 30 warp-cli tunnel protocol set MASQUE >/dev/null 2>&1 \
    || true
  ok=0
  for i in 1 2 3 4 5 6; do
    if timeout 30 warp-cli --accept-tos mode proxy >/dev/null 2>&1; then
      ok=1
      break
    fi
    sleep 2
  done
  [ "$ok" -eq 1 ] || die "无法把 Cloudflare WARP 切换到 SOCKS 代理模式"
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
  local managed_warp_svc=0
  [ "$mode" = "socks" ] && managed_warp_svc=1
  cat > "$CONFIG_FILE" <<EOF
APP_VERSION=${APP_VERSION_VALUE}
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
MANAGED_WARP_SVC=${managed_warp_svc}
MANAGED_REDSOCKS_BIN=${MANAGED_REDSOCKS_BIN:-0}
EOF
  chmod 0600 "$CONFIG_FILE"
}

run_final_self_check() {
  if "$BIN_PATH" test; then
    return 0
  fi
  log "最终自检失败，正在撤销已启用的服务和分流规则"
  if "$BIN_PATH" uninstall; then
    die "最终自检失败，已撤销本项目运行态并把文件移动到备份目录"
  fi
  die "最终自检失败，自动撤销也失败；请检查 systemd 和 nftables 状态"
}

main() {
  require_root
  validate_repo_raw_base "$REPO_RAW_BASE"
  check_memory_before_install
  pre_install_unlock_probe

  local selected_mode
  selected_mode="$(prompt_install_mode)"
  if [ "$selected_mode" = "socks" ]; then
    ensure_no_existing_redsocks_service
    ensure_no_existing_warp_client
  fi
  log "正在安装依赖"
  install_dependencies "$selected_mode"
  [ "$selected_mode" = "socks" ] && preflight_nft_nat

  local warp_port redsocks_port redsocks_uid redsocks_group redsocks_bin
  if [ "$selected_mode" = "socks" ]; then
    warp_port="$(prompt_warp_port)"
    valid_port "$warp_port" || die "内部错误：选择的 WARP SOCKS 端口无效"
    redsocks_port="$(find_free_port "$warp_port")"
    valid_port "$redsocks_port" || die "内部错误：选择的 redsocks 端口无效"
    ensure_redsocks_user
    redsocks_uid="$(id -u "$REDSOCKS_USER")"
    redsocks_group="$(id -gn "$REDSOCKS_USER")"
    redsocks_bin="$(redsocks_path)"
  else
    warp_port=0
    redsocks_port=0
    redsocks_uid=0
    redsocks_group=root
    redsocks_bin=/usr/sbin/redsocks
  fi

  log "正在安装项目文件"
  [ "$selected_mode" = "socks" ] && disable_packaged_redsocks_service
  install_project_files
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
  printf '管理命令：warp-vps {status|test|restart|update|logs|uninstall}\n'
  if [ "$selected_mode" = "socks" ]; then
    printf '已默认阻断 Google 目标 IPv6，避免 IPv6 泄漏。\n'
  else
    printf 'WireGuard 模式会把命中 Google CIDR 的 TCP/UDP 流量路由到 WARP。\n'
  fi
}

main "$@"
