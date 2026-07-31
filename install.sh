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
REDSOCKS_CONF="${ETC_DIR}/redsocks.conf"
NFT_CONF="${ETC_DIR}/nftables.conf"
REDSOCKS_USER="warp-vps-redsocks"
WG_IFACE="warp-vps-wg"
WGCF_BIN="${APP_DIR}/bin/wgcf"
WGCF_ACCOUNT="${STATE_DIR}/wgcf/wgcf-account.toml"
WG_CONFIG="/etc/wireguard/${WG_IFACE}.conf"
SWAP_FILE="/swapfile-warp-vps-manager"
DEFAULT_REPO_RAW_BASE="https://raw.githubusercontent.com/mqfut123/warp-vps-manager/main"
REPO_RAW_BASE="${WARP_VPS_REPO_BASE:-$DEFAULT_REPO_RAW_BASE}"
APT_LOCK_TIMEOUT=1200
DOWNLOAD_CONNECT_TIMEOUT=10
DOWNLOAD_MAX_TIME=120
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
INSTALL_CLEANUP_ARMED=0
INSTALL_COMPLETE=0
PREVIOUS_WG_IFACE="$WG_IFACE"
PREVIOUS_WG_CONFIG="$WG_CONFIG"
PREVIOUS_MODE=""
PROJECT_STAGE_DIR=""
PROJECT_BACKUP_DIR=""
TARGET_CONFIG_FILE=""
INSTALL_BACKEND_REUSED=0
TARGET_CONFIG_PREPARED=0
TARGET_BACKEND_PREPARED=0
INSTALL_RUNTIME_TOUCHED=0
TARGET_MODE=""
HEALTH_AUTOMATION_PAUSED=0
HEALTH_AUTOMATION_TOUCHED=0
INSTALL_FILES_ACTIVATED=0
TARGET_PREP_STARTED=0
PREVIOUS_HEALTH_TIMER_ACTIVE=0
OPERATION_LOCK_HELD=0
MENU_ACTION_RC=0
INSTALL_NONINTERACTIVE=0
INSTALL_MODE_OPTION=""
INSTALL_SCOPE_OPTION=""
INSTALL_SWAP_OPTION=""
INSTALL_SOCKS_PORT_OPTION=""

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

interactive_terminal_available() {
  [ -t 0 ] || [ -t 1 ] || [ -t 2 ]
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

acquire_operation_lock() {
  command -v flock >/dev/null 2>&1 || return 0
  exec 9>/run/warp-vps-manager.operation.lock \
    || die "无法建立管理操作锁，未修改当前运行态"
  flock -w 10 9 \
    || die "另一项 WARP VPS Manager 管理操作正在进行，请稍后重试"
  OPERATION_LOCK_HELD=1
}

release_operation_lock() {
  [ "$OPERATION_LOCK_HELD" -eq 1 ] || return 0
  flock -u 9 >/dev/null 2>&1 || true
  exec 9>&-
  OPERATION_LOCK_HELD=0
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
  if ! dd if=/dev/zero of="$SWAP_FILE" bs=1M count="$size_mb"; then
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
  if ! awk -v swap_file="$SWAP_FILE" '$1 == swap_file { found=1 } END { exit !found }' /etc/fstab; then
    if ! printf '%s none swap sw 0 0\n' "$SWAP_FILE" >> /etc/fstab; then
      rollback_swap_file "写入 /etc/fstab 失败"
      return 1
    fi
  fi
  log "Swap 创建完成"
}

rollback_swap_file() {
  local reason="$1"
  local backup_dir cleaned_fstab fstab_entry
  backup_dir="${BACKUP_ROOT}/swap-failed-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fstab_entry=0
  log "$reason，正在撤销本次 Swap 创建"
  if ! install -d -m 0755 "$backup_dir"; then
    log "无法创建 Swap 回滚目录，已保留当前 Swap 状态：$backup_dir"
    return 0
  fi
  if awk -v swap_file="$SWAP_FILE" '$1 == swap_file { found=1 } END { exit !found }' /etc/fstab; then
    fstab_entry=1
    if ! install -m 0644 /etc/fstab "${backup_dir}/fstab.before-warp-vps"; then
      log "无法备份 /etc/fstab，已保留当前 Swap 状态"
      return 0
    fi
    cleaned_fstab="${backup_dir}/fstab.cleaned"
    if ! awk -v swap_file="$SWAP_FILE" '$1 != swap_file { print }' /etc/fstab > "$cleaned_fstab"; then
      log "无法生成清理后的 /etc/fstab，已保留当前 Swap 状态"
      return 0
    fi
  fi
  if awk -v swap_file="$SWAP_FILE" '$1 == swap_file { found=1 } END { exit !found }' /proc/swaps 2>/dev/null; then
    if ! swapoff "$SWAP_FILE" >/dev/null 2>&1; then
      log "无法停用 $SWAP_FILE，已保留当前 fstab 记录和文件，避免破坏正在使用的 Swap"
      return 0
    fi
  fi
  if [ "$fstab_entry" -eq 1 ]; then
    if ! install -m 0644 "$cleaned_fstab" /etc/fstab; then
      swapon "$SWAP_FILE" >/dev/null 2>&1 || true
      log "无法恢复 /etc/fstab，已保留 Swap 文件；请检查：${backup_dir}/fstab.before-warp-vps"
      return 0
    fi
  fi
  if [ -e "$SWAP_FILE" ]; then
    if ! : > "$SWAP_FILE"; then
      if [ "$fstab_entry" -eq 1 ]; then
        install -m 0644 "${backup_dir}/fstab.before-warp-vps" /etc/fstab >/dev/null 2>&1 || true
      fi
      swapon "$SWAP_FILE" >/dev/null 2>&1 || true
      log "无法释放失败 Swap 占用的磁盘空间：$SWAP_FILE"
      return 0
    fi
    if ! mv "$SWAP_FILE" "${backup_dir}/swapfile-warp-vps-manager"; then
      log "Swap 空间已释放，但无法移动零长度占位文件：$SWAP_FILE"
      return 0
    fi
    log "失败 Swap 已释放磁盘空间，零长度占位已移动到：${backup_dir}/swapfile-warp-vps-manager"
  fi
}

prompt_swap_creation() {
  local mem_mb="$1"
  local max_mb selected choice custom_gb
  while true; do
    max_mb="$(max_creatable_swap_mb)"
    printf '\n检测到系统没有 Swap；当前可用内存为 %s。\n' "$(format_gb "$mem_mb")"
    if [ "$mem_mb" -lt 1024 ]; then
      printf '可用内存不足 1G，创建 Swap 可降低依赖安装或 WARP 启动失败的概率。\n'
    else
      printf '默认安装会创建 1G Swap；如不需要，可选择继续但不创建。\n'
    fi
    printf '当前磁盘最多建议创建约 %s Swap。\n' "$(format_gb "$max_mb")"
    printf '\n请选择：\n'
    printf '  1. 创建 1G Swap（默认）\n'
    printf '  2. 创建 2G Swap\n'
    printf '  3. 自定义 Swap 大小\n'
    printf '  4. 不创建 Swap，接受安装中途失败的风险继续\n'
    printf '  5. 退出安装\n'
    printf '请输入选项（直接回车默认 1）：'
    read_input choice || die "无法读取输入，已退出安装"
    case "$choice" in
      ''|1) selected=1024 ;;
      2) selected=2048 ;;
      3)
        while true; do
          printf '请输入要创建的 Swap 大小，单位 G，例如 2：'
          read_input custom_gb || die "无法读取输入，已退出安装"
          case "$custom_gb" in
            ''|*[!0-9]*|0) printf '输入无效，请输入大于 0 的整数。\n' ; continue ;;
          esac
          if [ "${#custom_gb}" -gt 6 ]; then
            printf '输入过大，请输入不超过 6 位的整数。\n'
            continue
          fi
          custom_gb=$((10#$custom_gb))
          if [ "$custom_gb" -eq 0 ]; then
            printf '输入无效，请输入大于 0 的整数。\n'
            continue
          fi
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

collect_noninteractive_swap_choice() {
  local swap_total selected max_mb swap_gb
  SWAP_ACTION="none"
  SWAP_SIZE_MB=0
  swap_total="$(swap_total_mb)"
  if [ "$swap_total" -gt 0 ]; then
    return 0
  fi

  case "${INSTALL_SWAP_OPTION:-auto}" in
    auto) selected=1024 ;;
    none)
      log "非交互安装已选择不创建 Swap"
      return 0
      ;;
    *)
      swap_gb=$((10#$INSTALL_SWAP_OPTION))
      selected=$((swap_gb * 1024))
      ;;
  esac

  max_mb="$(max_creatable_swap_mb)"
  [ "$selected" -le "$max_mb" ] \
    || die "磁盘空间不足，最多建议创建 $(format_gb "$max_mb") Swap；可使用 --swap none 明确跳过"
  SWAP_ACTION="create"
  SWAP_SIZE_MB="$selected"
}

collect_swap_choice() {
  local mem_mb swap_total swap_free total_available choice
  if [ "$INSTALL_NONINTERACTIVE" -eq 1 ]; then
    collect_noninteractive_swap_choice
    return 0
  fi
  SWAP_ACTION="none"
  SWAP_SIZE_MB=0
  mem_mb="$(mem_available_mb)"
  swap_total="$(swap_total_mb)"
  swap_free="$(swap_free_mb)"
  total_available=$((mem_mb + swap_free))

  if [ "$swap_total" -eq 0 ]; then
    prompt_swap_creation "$mem_mb"
    return 0
  fi

  [ "$mem_mb" -ge 1024 ] && return 0

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
    if [ "$INSTALL_NONINTERACTIVE" -eq 1 ]; then
      die "Swap 创建失败，已撤销本次创建"
    fi
    printf 'Swap 创建失败，已撤销本次创建。请重新选择。\n'
    mem_mb="$(mem_available_mb)"
    prompt_swap_creation "$mem_mb"
  done
}

pkg_install_apt() {
  local mode="$1"
  local scope="${2:-google}"
  local install_rc
  export DEBIAN_FRONTEND=noninteractive
  log "如果系统自动更新正在占用 apt/dpkg，最多等待 20 分钟"
  apt_get update -y

  if [ "$mode" = "wireguard" ]; then
    if [ "$scope" = "global" ]; then
      apt_get install -y curl ca-certificates coreutils nftables iproute2 python3 wireguard-tools
    else
      apt_get install -y curl ca-certificates coreutils iproute2 python3 wireguard-tools
    fi
    return
  fi

  apt_get install -y curl ca-certificates coreutils gnupg lsb-release nftables iproute2 python3
  if ! redsocks_path >/dev/null 2>&1; then
    install_rc=0
    apt_get install -y redsocks || install_rc=$?
    disable_new_packaged_redsocks_service
    [ "$install_rc" -eq 0 ] || return "$install_rc"
  fi
  if warp_client_complete; then
    return
  fi

  install -d -m 0755 /usr/share/keyrings
  curl -fsSL --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" --max-time "$DOWNLOAD_MAX_TIME" \
    https://pkg.cloudflareclient.com/pubkey.gpg \
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
  apt_get install -y --reinstall cloudflare-warp
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
  local marker_value
  MANAGED_REDSOCKS_BIN=0
  [ -x "$REDSOCKS_FALLBACK_BIN" ] || return 0
  if [ -r "$REDSOCKS_MANAGED_MARKER" ]; then
    marker_value="$(head -n 1 "$REDSOCKS_MANAGED_MARKER" 2>/dev/null || true)"
    if [ "$marker_value" = "$REDSOCKS_MANAGED_VERSION" ] \
      && grep -aFq "$REDSOCKS_MANAGED_VERSION" "$REDSOCKS_FALLBACK_BIN" 2>/dev/null; then
      MANAGED_REDSOCKS_BIN=1
    fi
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
  curl -LfsS --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" --max-time "$DOWNLOAD_MAX_TIME" \
    "$REDSOCKS_SOURCE_URL" -o "$archive"

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
  local install_rc
  if redsocks_path >/dev/null 2>&1; then
    mark_managed_redsocks_if_current
    return
  fi

  if [ "$OS_ID" = "fedora" ]; then
    install_rc=0
    "$manager" install -y redsocks || install_rc=$?
    disable_new_packaged_redsocks_service
    return "$install_rc"
  fi

  log "当前 RPM 系统使用固定上游源码构建 redsocks"
  "$manager" install -y gcc tar gzip libevent-devel
  build_redsocks_from_source
}

pkg_install_rpm() {
  local mode="$1"
  local manager="$2"
  local scope="${3:-google}"
  local key_file key_tmp repo_file repo_tmp
  if [ "$mode" = "wireguard" ]; then
    if [ "$scope" = "global" ]; then
      "$manager" install -y curl ca-certificates coreutils nftables iproute python3 wireguard-tools
    else
      "$manager" install -y curl ca-certificates coreutils iproute python3 wireguard-tools
    fi
    return
  fi

  if [ "$OS_ID" != "fedora" ]; then
    enable_rhel_extra_repos
  fi
  "$manager" install -y curl ca-certificates coreutils nftables iproute python3
  rpm_install_redsocks "$manager"
  if ! warp_client_complete; then
    key_file="${STATE_DIR}/cloudflare-warp-pubkey.gpg"
    key_tmp="${key_file}.new"
    repo_file=/etc/yum.repos.d/cloudflare-warp.repo
    repo_tmp="${repo_file}.new"
    install -d -m 0755 "$STATE_DIR" /etc/yum.repos.d
    curl -fsSL --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" --max-time "$DOWNLOAD_MAX_TIME" \
      https://pkg.cloudflareclient.com/pubkey.gpg \
      -o "$key_tmp" \
      || die "Cloudflare WARP RPM 公钥下载失败"
    rpm --import "$key_tmp" || die "Cloudflare WARP RPM 公钥导入失败"
    chmod 0644 "$key_tmp"
    mv "$key_tmp" "$key_file" || die "无法保存 Cloudflare WARP RPM 公钥"
    curl -fsSL --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" --max-time "$DOWNLOAD_MAX_TIME" \
      https://pkg.cloudflareclient.com/cloudflare-warp-ascii.repo \
      -o "$repo_tmp" \
      || die "Cloudflare WARP RPM 软件源下载失败"
    chmod 0644 "$repo_tmp"
    mv "$repo_tmp" "$repo_file" || die "无法启用 Cloudflare WARP RPM 软件源"
    if rpm -q cloudflare-warp >/dev/null 2>&1; then
      "$manager" reinstall -y cloudflare-warp
    else
      "$manager" install -y cloudflare-warp
    fi
  fi
}

install_dependencies() {
  local mode="$1"
  local scope="${2:-google}"
  local manager
  if mode_dependencies_complete "$mode" "$scope"; then
    log "目标模式所需依赖已齐全，直接复用现有安装"
    return 0
  fi
  load_os_release
  if command -v apt-get >/dev/null 2>&1; then
    pkg_install_apt "$mode" "$scope"
  elif command -v dnf >/dev/null 2>&1; then
    manager="dnf"
    pkg_install_rpm "$mode" "$manager" "$scope"
  elif command -v yum >/dev/null 2>&1; then
    manager="yum"
    pkg_install_rpm "$mode" "$manager" "$scope"
  else
    die "找不到 apt-get、dnf 或 yum，无法安装依赖"
  fi

  command -v curl >/dev/null 2>&1 || die "依赖安装后仍找不到 curl"
  command -v ip >/dev/null 2>&1 || die "依赖安装后仍找不到 ip"
  command -v python3 >/dev/null 2>&1 || die "依赖安装后仍找不到 python3"
  command -v timeout >/dev/null 2>&1 || die "依赖安装后仍找不到 timeout"
  if [ "$mode" = "wireguard" ]; then
    command -v wg >/dev/null 2>&1 || die "依赖安装后仍找不到 wg"
    command -v wg-quick >/dev/null 2>&1 || die "依赖安装后仍找不到 wg-quick"
    unit_file_exists 'wg-quick@.service' || die "wireguard-tools 已安装但找不到 wg-quick@.service"
    if [ "$scope" = "global" ]; then
      command -v nft >/dev/null 2>&1 || die "WireGuard 全局模式依赖安装后仍找不到 nftables"
    fi
  else
    command -v ss >/dev/null 2>&1 || die "依赖安装后仍找不到 ss"
    command -v nft >/dev/null 2>&1 || die "依赖安装后仍找不到 nftables"
    warp_client_complete || die "cloudflare-warp 安装不完整，找不到 warp-cli 或 warp-svc.service"
    redsocks_path >/dev/null 2>&1 || die "依赖安装后仍找不到 redsocks"
  fi
}

mode_dependencies_complete() {
  local mode="$1"
  local scope="${2:-google}"
  command -v curl >/dev/null 2>&1 \
    && command -v ip >/dev/null 2>&1 \
    && command -v python3 >/dev/null 2>&1 \
    && command -v timeout >/dev/null 2>&1 \
    || return 1
  case "$mode" in
    wireguard)
      command -v wg >/dev/null 2>&1 \
        && command -v wg-quick >/dev/null 2>&1 \
        && unit_file_exists 'wg-quick@.service' \
        && { [ "$scope" != "global" ] || command -v nft >/dev/null 2>&1; }
      ;;
    socks)
      command -v ss >/dev/null 2>&1 \
        && command -v nft >/dev/null 2>&1 \
        && warp_client_complete \
        && redsocks_path >/dev/null 2>&1
      ;;
    *) return 1 ;;
  esac
}

unit_file_exists() {
  local unit="$1"
  local units
  units="$(systemctl list-unit-files --no-legend 2>/dev/null)" \
    || die "无法查询 systemd 服务文件：$unit"
  awk -v unit="$unit" '$1 == unit { found=1 } END { exit !found }' <<< "$units"
}

warp_client_complete() {
  command -v warp-cli >/dev/null 2>&1 && unit_file_exists warp-svc.service
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
  if unit_file_exists warp-svc.service; then
    WARP_CLIENT_PREEXISTED=1
  fi
  if [ "$WARP_CLIENT_PREEXISTED" -eq 0 ]; then
    MANAGED_WARP_SVC_VALUE=1
  fi
}

disable_new_packaged_redsocks_service() {
  [ "$REDSOCKS_UNIT_PREEXISTED" -eq 0 ] || return 0
  unit_file_exists redsocks.service || return 0
  systemctl stop redsocks.service >/dev/null 2>&1 || true
  systemctl disable redsocks.service >/dev/null 2>&1 || true
  if systemctl is-active --quiet redsocks.service; then
    log "新安装的 redsocks.service 未能停止；项目仍会使用独立服务和配置"
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
    ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .
    return
  fi

  printf -v port_hex '%04X' "$port"
  for file in /proc/net/tcp /proc/net/tcp6; do
    [ -r "$file" ] || continue
    if awk -v port="$port_hex" '
      NR > 1 {
        split($2, address, ":")
        if (toupper(address[2]) == port && toupper($4) == "0A") found=1
      }
      END { exit !found }
    ' "$file"; then
      return 0
    fi
  done
  return 1
}

read_project_mode() {
  [ -r "$CONFIG_FILE" ] || return 1
  local line mode=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      WARP_MODE=*) mode="${line#*=}" ;;
    esac
  done < "$CONFIG_FILE"
  case "$mode" in
    socks|wireguard) printf '%s\n' "$mode" ;;
    *) return 1 ;;
  esac
}

read_project_scope() {
  [ -r "$CONFIG_FILE" ] || return 1
  local line scope=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      WARP_SCOPE=*) scope="${line#*=}" ;;
    esac
  done < "$CONFIG_FILE"
  case "$scope" in
    '') printf 'google\n' ;;
    google|global) printf '%s\n' "$scope" ;;
    *) return 1 ;;
  esac
}

prompt_route_scope() {
  local choice
  printf '\n请选择 WARP 路由范围：\n' >&2
  printf '  1. 精准分流 Google 服务（默认）\n' >&2
  printf '  2. 全局走 WARP（WireGuard 支持双栈全协议；Socks5 接管 VPS 主动发起的公网 IPv4 TCP）\n' >&2
  printf '直接回车默认选择：精准分流 Google\n' >&2
  while true; do
    printf '请输入选项：' >&2
    read_input choice || die "无法读取输入，已退出安装"
    case "$choice" in
      ''|1) printf 'google\n'; return 0 ;;
      2) printf 'global\n'; return 0 ;;
      *) printf '输入无效，请输入 1、2，或直接回车。\n' >&2 ;;
    esac
  done
}

select_route_scope() {
  local current_scope="${1:-google}"
  if [ "$INSTALL_NONINTERACTIVE" -eq 0 ]; then
    prompt_route_scope
    return
  fi

  case "$INSTALL_SCOPE_OPTION" in
    '') printf '%s\n' "$current_scope" ;;
    keep)
      [ -e "$CONFIG_FILE" ] \
        || { installer_cli_error "全新安装不能使用 --scope keep"; return 2; }
      printf '%s\n' "$current_scope"
      ;;
    google|global) printf '%s\n' "$INSTALL_SCOPE_OPTION" ;;
    *) installer_cli_error "内部错误：未识别的路由范围选项" ;;
  esac
}

prompt_install_mode() {
  local recommended choice current_mode scope="${2:-google}"
  if [ "$#" -gt 0 ]; then
    current_mode="$1"
  else
    current_mode="$(read_project_mode || true)"
  fi
  recommended="${current_mode:-wireguard}"

  printf '\n请选择 WARP 分流方案：\n' >&2
  if [ "$scope" = "global" ]; then
    printf '  1. Socks5 方案：VPS 主动发起的公网 IPv4 TCP 走 WARP；UDP 和 IPv6 不由 Socks5 承载。\n' >&2
    printf '  2. WireGuard 方案：公网 IPv4、IPv6、TCP、UDP 和 QUIC 全局走 WARP。\n' >&2
  else
    printf '  1. Socks5 方案：Google IPv4 TCP 走 WARP，Google IPv4 UDP/443（QUIC）和 Google IPv6 拒绝。\n' >&2
    printf '  2. WireGuard 方案：Google IPv4、IPv6、TCP、UDP 和 QUIC 都按 Google CIDR 走 WARP。\n' >&2
  fi
  printf '  3. 退出安装\n' >&2
  printf '普通用户推荐 WireGuard；只需要兼容本地代理模式时再选 Socks5。\n' >&2
  if [ -n "$current_mode" ]; then
    printf '当前模式：%s；直接回车保持当前模式。\n' "$current_mode" >&2
  else
    printf '直接回车默认选择：WireGuard\n' >&2
  fi
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

select_install_mode() {
  local current_mode="${1:-}"
  local scope="${2:-google}"
  if [ "$INSTALL_NONINTERACTIVE" -eq 0 ]; then
    prompt_install_mode "$current_mode" "$scope"
    return
  fi

  case "$INSTALL_MODE_OPTION" in
    '')
      if [ -n "$current_mode" ]; then
        printf '%s\n' "$current_mode"
      else
        printf 'wireguard\n'
      fi
      ;;
    keep)
      [ -n "$current_mode" ] \
        || { installer_cli_error "全新安装不能使用 --mode keep"; return 2; }
      printf '%s\n' "$current_mode"
      ;;
    socks|wireguard) printf '%s\n' "$INSTALL_MODE_OPTION" ;;
    *) installer_cli_error "内部错误：未识别的安装模式选项" ;;
  esac
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
  local reusable_port="${1:-}"
  local input
  if [ -n "${WARP_SOCKS_PORT:-}" ]; then
    input="$WARP_SOCKS_PORT"
    valid_port "$input" || die "环境变量 WARP_SOCKS_PORT 不是有效端口：$input"
    if [ "$input" != "$reusable_port" ] && port_in_use "$input"; then
      die "环境变量 WARP_SOCKS_PORT 指定的端口已被占用：$input"
    fi
    printf '%s\n' "$input"
    return 0
  fi

  while true; do
    if [ -n "$reusable_port" ]; then
      printf '当前 WARP SOCKS 端口：%s；直接回车保持不变：' "$reusable_port" >&2
    else
      printf '请输入 WARP SOCKS 端口（直接回车随机选择空闲端口）：' >&2
    fi
    read_input input || die "无法读取输入，已退出安装"
    if [ -z "$input" ]; then
      if [ -n "$reusable_port" ]; then
        printf '%s\n' "$reusable_port"
      else
        find_free_port
      fi
      return 0
    fi
    if ! valid_port "$input"; then
      printf '端口无效，请输入 1-65535 的数字。\n' >&2
      continue
    fi
    if [ "$input" != "$reusable_port" ] && port_in_use "$input"; then
      printf '端口 %s 已被占用，请换一个。\n' "$input" >&2
      continue
    fi
    printf '%s\n' "$input"
    return 0
  done
}

select_noninteractive_warp_port() {
  local reusable_port="${1:-}"
  local selected="${INSTALL_SOCKS_PORT_OPTION:-}"
  if [ -z "$selected" ] && [ -n "${WARP_SOCKS_PORT:-}" ]; then
    selected="$WARP_SOCKS_PORT"
  fi
  if [ -z "$selected" ]; then
    if [ -n "$reusable_port" ]; then
      printf '%s\n' "$reusable_port"
    else
      find_free_port
    fi
    return 0
  fi
  if [ "$selected" = "auto" ]; then
    find_free_port "$reusable_port"
    return 0
  fi
  if ! valid_port "$selected"; then
    installer_cli_error "--socks-port 必须是 auto 或 1-65535 的端口"
    return 2
  fi
  if [ "$selected" != "$reusable_port" ] && port_in_use "$selected"; then
    die "--socks-port 指定的端口已被占用：$selected"
  fi
  printf '%s\n' "$selected"
}

read_project_warp_port() {
  [ -r "$CONFIG_FILE" ] || return 1
  local line mode="" port=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      WARP_MODE=*) mode="${line#*=}" ;;
      WARP_SOCKS_PORT=*) port="${line#*=}" ;;
    esac
  done < "$CONFIG_FILE"
  [ "$mode" = "socks" ] || return 1
  valid_port "$port" || return 1
  printf '%s\n' "$port"
}

read_project_redsocks_port() {
  [ -r "$CONFIG_FILE" ] || return 1
  local line mode="" port=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      WARP_MODE=*) mode="${line#*=}" ;;
      REDSOCKS_PORT=*) port="${line#*=}" ;;
    esac
  done < "$CONFIG_FILE"
  [ "$mode" = "socks" ] || return 1
  valid_port "$port" || return 1
  printf '%s\n' "$port"
}

valid_runtime_iface() {
  case "$1" in
    ''|*[!A-Za-z0-9_.:-]*) return 1 ;;
    *) [ "${#1}" -le 15 ] ;;
  esac
}

valid_runtime_path() {
  case "$1" in
    /*)
      case "$1" in *$'\n'*|*$'\r'*|*$'\t'*|*" "*) return 1 ;; esac
      return 0
      ;;
    *) return 1 ;;
  esac
}

read_previous_wireguard_runtime() {
  PREVIOUS_WG_IFACE="$WG_IFACE"
  PREVIOUS_WG_CONFIG="$WG_CONFIG"
  PREVIOUS_MODE=""
  [ -r "$CONFIG_FILE" ] || return 0

  local line value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      WARP_MODE=*)
        value="${line#*=}"
        case "$value" in
          socks|wireguard) PREVIOUS_MODE="$value" ;;
        esac
        ;;
      WG_IFACE=*)
        value="${line#*=}"
        if valid_runtime_iface "$value"; then
          PREVIOUS_WG_IFACE="$value"
        fi
        ;;
      WG_CONFIG=*)
        value="${line#*=}"
        if valid_runtime_path "$value"; then
          PREVIOUS_WG_CONFIG="$value"
        fi
        ;;
    esac
  done < "$CONFIG_FILE"
  return 0
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
  curl -fsSL --connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT" --max-time "$DOWNLOAD_MAX_TIME" \
    "$url" -o "$dest" || die "下载项目文件失败：${rel}（${url}）"
  chmod "$mode" "$dest"
}

validate_staged_rules() {
  local stage="$1"
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$stage" <<'PY'
import ipaddress
import json
import pathlib
import sys

stage = pathlib.Path(sys.argv[1])
counts = {}
for family, version in (("ipv4", 4), ("ipv6", 6)):
    path = stage / "rules" / f"google_{family}.txt"
    count = 0
    for lineno, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line != raw or any(ch.isspace() for ch in line):
            raise SystemExit(f"{path}:{lineno}: 存在非法空格")
        network = ipaddress.ip_network(line, strict=True)
        if network.version != version:
            raise SystemExit(f"{path}:{lineno}: IP 版本不匹配")
        count += 1
    if count == 0:
        raise SystemExit(f"{path}: 规则为空")
    counts[family] = count

meta_path = stage / "rules" / "rules.meta.json"
meta = json.loads(meta_path.read_text(encoding="utf-8"))
if not isinstance(meta, dict):
    raise SystemExit(f"{meta_path}: 元数据必须是 JSON 对象")
for family in ("ipv4", "ipv6"):
    key = f"{family}_count"
    value = meta.get(key)
    if type(value) is not int or value != counts[family]:
        raise SystemExit(
            f"{meta_path}: {key}={value!r}，规则实际数量={counts[family]}"
        )
PY
}

validate_existing_config() {
  [ -e "$CONFIG_FILE" ] || return 0
  [ -r "$CONFIG_FILE" ] || die "现有配置无法读取，未修改当前运行态：$CONFIG_FILE"
  WARP_VPS_CONFIG_FILE="$CONFIG_FILE" \
    WARP_VPS_RULES_DIR="$PROJECT_STAGE_DIR/rules" \
    bash -c '. "$1"; load_config' _ "$PROJECT_STAGE_DIR/bin/warp-vps" \
    || die "现有配置损坏，未修改当前运行态：$CONFIG_FILE"
}

stage_project_files() {
  PROJECT_STAGE_DIR="${STATE_DIR}/install-stage-$$"
  install -d -m 0755 "$PROJECT_STAGE_DIR" "$PROJECT_STAGE_DIR/bin" "$PROJECT_STAGE_DIR/rules"
  fetch_asset "install.sh" "$PROJECT_STAGE_DIR/install.sh" 0755
  fetch_asset "bin/warp-vps" "$PROJECT_STAGE_DIR/bin/warp-vps" 0755
  fetch_asset "rules/google_ipv4.txt" "$PROJECT_STAGE_DIR/rules/google_ipv4.txt" 0644
  fetch_asset "rules/google_ipv6.txt" "$PROJECT_STAGE_DIR/rules/google_ipv6.txt" 0644
  fetch_asset "rules/rules.meta.json" "$PROJECT_STAGE_DIR/rules/rules.meta.json" 0644
  bash -n "$PROJECT_STAGE_DIR/install.sh" || die "下载的 install.sh 语法无效"
  bash -n "$PROJECT_STAGE_DIR/bin/warp-vps" || die "下载的 warp-vps 语法无效"
  grep -Eq '^[^#[:space:]]' "$PROJECT_STAGE_DIR/rules/google_ipv4.txt" || die "下载的 IPv4 规则为空"
  grep -Eq '^[^#[:space:]]' "$PROJECT_STAGE_DIR/rules/google_ipv6.txt" || die "下载的 IPv6 规则为空"
  validate_staged_rules "$PROJECT_STAGE_DIR" || die "下载的规则快照校验失败"
}

backup_project_files() {
  PROJECT_BACKUP_DIR="${STATE_DIR}/install-rollback/$(date -u +%Y%m%dT%H%M%SZ)-$$"
  install -d -m 0755 "$PROJECT_BACKUP_DIR/app/bin" "$PROJECT_BACKUP_DIR/app/rules" \
    "$PROJECT_BACKUP_DIR/etc" "$PROJECT_BACKUP_DIR/systemd" \
    "$PROJECT_BACKUP_DIR/state/wgcf" "$PROJECT_BACKUP_DIR/missing" || return 1
  backup_project_file "${APP_DIR}/install.sh" "$PROJECT_BACKUP_DIR/app/install.sh" app-install 0755 || return 1
  backup_project_file "${APP_DIR}/bin/warp-vps" "$PROJECT_BACKUP_DIR/app/bin/warp-vps" app-manager 0755 || return 1
  backup_project_file "$WGCF_BIN" "$PROJECT_BACKUP_DIR/app/bin/wgcf" wgcf-binary 0755 || return 1
  backup_project_file "${APP_DIR}/rules/google_ipv4.txt" "$PROJECT_BACKUP_DIR/app/rules/google_ipv4.txt" rules-ipv4 0644 || return 1
  backup_project_file "${APP_DIR}/rules/google_ipv6.txt" "$PROJECT_BACKUP_DIR/app/rules/google_ipv6.txt" rules-ipv6 0644 || return 1
  backup_project_file "${APP_DIR}/rules/rules.meta.json" "$PROJECT_BACKUP_DIR/app/rules/rules.meta.json" rules-meta 0644 || return 1
  backup_project_file "$BIN_PATH" "$PROJECT_BACKUP_DIR/warp-vps" command 0755 || return 1
  backup_project_file "$CONFIG_FILE" "$PROJECT_BACKUP_DIR/config.env" config 0600 || return 1
  backup_project_file "$WG_CONFIG" "$PROJECT_BACKUP_DIR/wireguard.conf" wireguard-config 0600 || return 1
  backup_project_file "$WGCF_ACCOUNT" "$PROJECT_BACKUP_DIR/state/wgcf/wgcf-account.toml" wgcf-account 0600 || return 1
  backup_project_file "$REDSOCKS_CONF" "$PROJECT_BACKUP_DIR/etc/redsocks.conf" redsocks-config 0644 || return 1
  backup_project_file "$NFT_CONF" "$PROJECT_BACKUP_DIR/etc/nftables.conf" nftables-config 0644 || return 1
  backup_project_file /etc/systemd/system/warp-vps-redsocks.service \
    "$PROJECT_BACKUP_DIR/systemd/warp-vps-redsocks.service" unit-redsocks 0644 || return 1
  backup_project_file /etc/systemd/system/warp-vps.service \
    "$PROJECT_BACKUP_DIR/systemd/warp-vps.service" unit-routing 0644 || return 1
  backup_project_file /etc/systemd/system/warp-vps-health.service \
    "$PROJECT_BACKUP_DIR/systemd/warp-vps-health.service" unit-health 0644 || return 1
  backup_project_file /etc/systemd/system/warp-vps-health.timer \
    "$PROJECT_BACKUP_DIR/systemd/warp-vps-health.timer" unit-health-timer 0644 || return 1
}

backup_project_file() {
  local source="$1"
  local backup="$2"
  local label="$3"
  local mode="$4"
  if [ -f "$source" ]; then
    install -m "$mode" "$source" "$backup" || return 1
  else
    : > "$PROJECT_BACKUP_DIR/missing/$label" || return 1
  fi
}

activate_project_files() {
  [ -n "$PROJECT_STAGE_DIR" ] || return 1
  install -d -m 0755 "$APP_DIR" "$APP_DIR/bin" "$APP_DIR/rules" "$ETC_DIR" || return 1
  install -m 0755 "$PROJECT_STAGE_DIR/install.sh" "$APP_DIR/install.sh" || return 1
  install -m 0755 "$PROJECT_STAGE_DIR/bin/warp-vps" "$APP_DIR/bin/warp-vps" || return 1
  install -m 0644 "$PROJECT_STAGE_DIR/rules/google_ipv4.txt" "$APP_DIR/rules/google_ipv4.txt" || return 1
  install -m 0644 "$PROJECT_STAGE_DIR/rules/google_ipv6.txt" "$APP_DIR/rules/google_ipv6.txt" || return 1
  install -m 0644 "$PROJECT_STAGE_DIR/rules/rules.meta.json" "$APP_DIR/rules/rules.meta.json" || return 1
  install -m 0755 "$APP_DIR/bin/warp-vps" "$BIN_PATH" || return 1
}

restore_project_files() {
  [ -n "$PROJECT_BACKUP_DIR" ] || return 1
  install -d -m 0755 "$PROJECT_BACKUP_DIR/failed-new" || return 1
  restore_project_file "$APP_DIR/install.sh" "$PROJECT_BACKUP_DIR/app/install.sh" app-install 0755 || return 1
  restore_project_file "$APP_DIR/bin/warp-vps" "$PROJECT_BACKUP_DIR/app/bin/warp-vps" app-manager 0755 || return 1
  restore_project_file "$WGCF_BIN" "$PROJECT_BACKUP_DIR/app/bin/wgcf" wgcf-binary 0755 || return 1
  restore_project_file "$APP_DIR/rules/google_ipv4.txt" "$PROJECT_BACKUP_DIR/app/rules/google_ipv4.txt" rules-ipv4 0644 || return 1
  restore_project_file "$APP_DIR/rules/google_ipv6.txt" "$PROJECT_BACKUP_DIR/app/rules/google_ipv6.txt" rules-ipv6 0644 || return 1
  restore_project_file "$APP_DIR/rules/rules.meta.json" "$PROJECT_BACKUP_DIR/app/rules/rules.meta.json" rules-meta 0644 || return 1
  restore_project_file "$BIN_PATH" "$PROJECT_BACKUP_DIR/warp-vps" command 0755 || return 1
  restore_project_file "$CONFIG_FILE" "$PROJECT_BACKUP_DIR/config.env" config 0600 || return 1
  restore_project_file "$WG_CONFIG" "$PROJECT_BACKUP_DIR/wireguard.conf" wireguard-config 0600 || return 1
  restore_project_file "$WGCF_ACCOUNT" "$PROJECT_BACKUP_DIR/state/wgcf/wgcf-account.toml" wgcf-account 0600 || return 1
  restore_project_file "$REDSOCKS_CONF" "$PROJECT_BACKUP_DIR/etc/redsocks.conf" redsocks-config 0644 || return 1
  restore_project_file "$NFT_CONF" "$PROJECT_BACKUP_DIR/etc/nftables.conf" nftables-config 0644 || return 1
  restore_project_file /etc/systemd/system/warp-vps-redsocks.service \
    "$PROJECT_BACKUP_DIR/systemd/warp-vps-redsocks.service" unit-redsocks 0644 || return 1
  restore_project_file /etc/systemd/system/warp-vps.service \
    "$PROJECT_BACKUP_DIR/systemd/warp-vps.service" unit-routing 0644 || return 1
  restore_project_file /etc/systemd/system/warp-vps-health.service \
    "$PROJECT_BACKUP_DIR/systemd/warp-vps-health.service" unit-health 0644 || return 1
  restore_project_file /etc/systemd/system/warp-vps-health.timer \
    "$PROJECT_BACKUP_DIR/systemd/warp-vps-health.timer" unit-health-timer 0644 || return 1
}

restore_project_file() {
  local live="$1"
  local backup="$2"
  local label="$3"
  local mode="$4"
  if [ -f "$backup" ]; then
    install -m "$mode" "$backup" "$live" || return 1
  elif [ -f "$PROJECT_BACKUP_DIR/missing/$label" ]; then
    if [ -e "$live" ]; then
      mv "$live" "$PROJECT_BACKUP_DIR/failed-new/$label" || return 1
    fi
  else
    return 1
  fi
  return 0
}

project_unit_stopped() {
  local unit="$1"
  local state_output load_state active_state
  state_output="$(systemctl show "$unit" -p LoadState -p ActiveState --no-pager 2>/dev/null)" || {
    log "无法查询 systemd 服务状态：${unit}"
    return 1
  }
  load_state="$(awk -F= '$1 == "LoadState" { print substr($0, index($0, "=") + 1); exit }' <<< "$state_output")"
  [ "$load_state" = "not-found" ] && return 0
  [ -n "$load_state" ] || {
    log "systemd 没有返回服务加载状态：${unit}"
    return 1
  }
  active_state="$(awk -F= '$1 == "ActiveState" { print substr($0, index($0, "=") + 1); exit }' <<< "$state_output")"
  case "$active_state" in
    inactive|failed) return 0 ;;
    active|activating|deactivating|reloading) return 1 ;;
    *)
      log "无法确认 systemd 服务是否已停止：${unit}（状态：${active_state:-无}）"
      return 1
      ;;
  esac
}

project_unit_disabled() {
  local unit="$1"
  local state_output load_state unit_state rc
  state_output="$(systemctl show "$unit" -p LoadState --no-pager 2>/dev/null)" || {
    log "无法查询 systemd 服务加载状态：${unit}"
    return 1
  }
  load_state="$(awk -F= '$1 == "LoadState" { print substr($0, index($0, "=") + 1); exit }' <<< "$state_output")"
  [ "$load_state" = "not-found" ] && return 0
  [ -n "$load_state" ] || {
    log "systemd 没有返回服务加载状态：${unit}"
    return 1
  }
  rc=0
  unit_state="$(systemctl is-enabled "$unit" 2>/dev/null)" || rc=$?
  case "$unit_state" in
    enabled|enabled-runtime) return 1 ;;
    disabled|masked|masked-runtime|not-found|linked|linked-runtime|alias|static|indirect|generated|transient) return 0 ;;
    *)
      log "无法确认 systemd 服务是否已禁用：${unit}（状态：${unit_state:-无}，退出码：${rc}）"
      return 1
      ;;
  esac
}

project_wg_interface_absent() {
  local links
  links="$(ip -o link show 2>/dev/null)" || return 1
  ! awk -F ': ' -v iface="$1" '
    {
      name=$2
      sub(/@.*/, "", name)
      if (name == iface) found=1
    }
    END { exit !found }
  ' <<< "$links"
}

write_config_file() {
  local destination="$1"
  shift
  local mode="$1"
  local warp_port="$2"
  local redsocks_port="$3"
  local redsocks_uid="$4"
  local redsocks_group="$5"
  local redsocks_bin="$6"
  local scope="${7:-google}"
  local config_tmp="${destination}.new.$$"
  cat > "$config_tmp" <<EOF || die "无法写入临时配置文件：$config_tmp"
REPO_RAW_BASE=${REPO_RAW_BASE}
WARP_MODE=${mode}
WARP_SCOPE=${scope}
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
  chmod 0600 "$config_tmp" || die "无法设置配置文件权限：$config_tmp"
  mv "$config_tmp" "$destination" || die "无法激活配置文件：$destination"
}

write_config() {
  write_config_file "$CONFIG_FILE" "$@"
}

project_unit_active() {
  local unit="$1"
  local state_output load_state active_state
  state_output="$(systemctl show "$unit" -p LoadState -p ActiveState --no-pager 2>/dev/null)" || return 2
  load_state="$(awk -F= '$1 == "LoadState" { print substr($0, index($0, "=") + 1); exit }' <<< "$state_output")"
  [ "$load_state" != "not-found" ] || return 1
  [ -n "$load_state" ] || return 2
  active_state="$(awk -F= '$1 == "ActiveState" { print substr($0, index($0, "=") + 1); exit }' <<< "$state_output")"
  case "$active_state" in
    active) return 0 ;;
    inactive|failed) return 1 ;;
    *) return 2 ;;
  esac
}

project_wg_interface_present() {
  local links rc
  links="$(ip -o link show 2>/dev/null)" || return 2
  rc=0
  awk -F ': ' -v iface="$1" '
    {
      name=$2
      sub(/@.*/, "", name)
      if (name == iface) found=1
    }
    END { exit !found }
  ' <<< "$links" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

target_wireguard_config_valid() {
  WARP_VPS_CONFIG_FILE="$TARGET_CONFIG_FILE" \
    WARP_VPS_RULES_DIR="$PROJECT_STAGE_DIR/rules" \
    bash -c '. "$1"; load_config; wg_config_valid "$WG_CONFIG"' \
      _ "$PROJECT_STAGE_DIR/bin/warp-vps"
}

current_socks_backend_local_ready() {
  local warp_port="$1"
  bash -c '. "$1"; WARP_SOCKS_PORT="$2"; warp_proxy_local_ready' \
    _ "$PROJECT_STAGE_DIR/bin/warp-vps" "$warp_port"
}

current_socks_backend_owns_port() {
  local warp_port="$1"
  bash -c '. "$1"; service_owns_listening_port warp-svc.service "$2"' \
    _ "$PROJECT_STAGE_DIR/bin/warp-vps" "$warp_port"
}

current_redsocks_backend_owns_port() {
  local redsocks_port="$1"
  bash -c '. "$1"; service_owns_listening_port warp-vps-redsocks.service "$2"' \
    _ "$PROJECT_STAGE_DIR/bin/warp-vps" "$redsocks_port"
}

project_port_conflicts() {
  local port="$1"
  local reusable_port="$2"
  local ownership_check="$3"
  port_in_use "$port" || return 1
  [ "$port" = "$reusable_port" ] || return 0
  "$ownership_check" "$port" && return 1
  return 0
}

current_backend_reusable() {
  local selected_mode="$1"
  local warp_port="$2"
  local reusable_warp_port="$3"
  [ "$PREVIOUS_MODE" = "$selected_mode" ] || return 1
  if [ "$selected_mode" = "wireguard" ]; then
    local service_rc=0 interface_rc=0
    command -v ip >/dev/null 2>&1 || return 1
    project_unit_active "wg-quick@${PREVIOUS_WG_IFACE}.service" || service_rc=$?
    project_wg_interface_present "$PREVIOUS_WG_IFACE" || interface_rc=$?
    if [ "$service_rc" -eq 2 ] || [ "$interface_rc" -eq 2 ]; then
      die "无法确认当前 WireGuard 本地运行态；未执行重装"
    fi
    if [ "$service_rc" -eq 0 ] && [ "$interface_rc" -eq 0 ]; then
      wg show "$PREVIOUS_WG_IFACE" >/dev/null 2>&1 || return 1
      target_wireguard_config_valid \
        || die "当前 WireGuard 正在运行，但磁盘配置无法用于安全重建；已保持当前流量不变"
      return 0
    fi
    return 1
  fi
  [ -n "$reusable_warp_port" ] && [ "$warp_port" = "$reusable_warp_port" ] || return 1
  current_socks_backend_local_ready "$warp_port"
}

quiesce_health_automation() {
  local timer_rc=0
  [ "$HEALTH_AUTOMATION_PAUSED" -eq 0 ] || return 0
  project_unit_active warp-vps-health.timer || timer_rc=$?
  [ "$timer_rc" -ne 2 ] || {
    log "无法确认自动健康检查当前状态，未改动当前分流"
    return 1
  }
  [ "$timer_rc" -ne 0 ] || PREVIOUS_HEALTH_TIMER_ACTIVE=1
  HEALTH_AUTOMATION_TOUCHED=1
  systemctl stop warp-vps-health.timer >/dev/null 2>&1 || true
  systemctl stop warp-vps-health.service >/dev/null 2>&1 || true
  systemctl stop warp-vps-health.timer >/dev/null 2>&1 || true
  if ! project_unit_stopped warp-vps-health.timer || ! project_unit_stopped warp-vps-health.service; then
    log "自动健康检查仍在运行，未改动当前分流"
    return 1
  fi
  HEALTH_AUTOMATION_PAUSED=1
}

pause_project_routing() {
  quiesce_health_automation || return 1
  INSTALL_RUNTIME_TOUCHED=1
  systemctl stop warp-vps.service >/dev/null 2>&1 || true
  systemctl disable warp-vps.service >/dev/null 2>&1 || true
  if [ -x "$BIN_PATH" ] && [ -r "$CONFIG_FILE" ]; then
    "$BIN_PATH" stop-rules >/dev/null 2>&1 || true
  fi
  project_unit_stopped warp-vps.service || return 1
}

prepare_target_backend() {
  local selected_mode="$1"
  [ "$INSTALL_BACKEND_REUSED" -eq 0 ] || return 0
  if [ "$selected_mode" = "wireguard" ]; then
    if [ "$PREVIOUS_MODE" = "wireguard" ] && [ "$INSTALL_RUNTIME_TOUCHED" -eq 0 ]; then
      log "现有 WireGuard 需要重建；配置和预检将在失败恢复保护下执行"
      return 0
    fi
    if [ "$TARGET_CONFIG_PREPARED" -eq 0 ]; then
      log "正在准备 WireGuard WARP 配置；当前分流尚未停止"
      TARGET_PREP_STARTED=1
      WARP_VPS_CONFIG_FILE="$TARGET_CONFIG_FILE" \
        WARP_VPS_RULES_DIR="$PROJECT_STAGE_DIR/rules" \
        "$PROJECT_STAGE_DIR/bin/warp-vps" setup-wireguard || return 1
      TARGET_CONFIG_PREPARED=1
    fi
    if [ "$INSTALL_RUNTIME_TOUCHED" -eq 0 ]; then
      log "WireGuard 配置已准备完成；将在旧分流暂停后执行本地路由预检"
      return 0
    fi
    log "正在预检 WireGuard 网卡和本地路由"
    WARP_VPS_CONFIG_FILE="$TARGET_CONFIG_FILE" \
      WARP_VPS_RULES_DIR="$PROJECT_STAGE_DIR/rules" \
      "$PROJECT_STAGE_DIR/bin/warp-vps" preflight-wireguard || return 1
    TARGET_BACKEND_PREPARED=1
    return 0
  fi
  if [ "$PREVIOUS_MODE" = "socks" ]; then
    log "Socks5 端口变更将在旧规则停止后应用"
    return 0
  fi
  log "正在准备 Cloudflare WARP SOCKS；当前分流尚未停止"
  TARGET_PREP_STARTED=1
  WARP_VPS_CONFIG_FILE="$TARGET_CONFIG_FILE" \
    WARP_VPS_RULES_DIR="$PROJECT_STAGE_DIR/rules" \
    "$PROJECT_STAGE_DIR/bin/warp-vps" configure-warp || return 1
  TARGET_BACKEND_PREPARED=1
}

stop_project_runtime() {
  local runtime_iface="${1:-$WG_IFACE}"
  local runtime_config="${2:-$WG_CONFIG}"
  local preserve_warp_service="${3:-0}"
  local unit
  systemctl stop warp-vps-health.timer >/dev/null 2>&1 || true
  systemctl stop warp-vps-health.service >/dev/null 2>&1 || true
  systemctl stop warp-vps-health.timer >/dev/null 2>&1 || true
  if ! project_unit_stopped warp-vps-health.timer; then
    log "健康检查定时器仍在运行：warp-vps-health.timer"
    return 1
  fi
  if ! project_unit_stopped warp-vps-health.service; then
    log "本项目健康检查仍在运行：warp-vps-health.service"
    return 1
  fi
  systemctl stop warp-vps.service >/dev/null 2>&1 || true
  systemctl disable warp-vps.service >/dev/null 2>&1 || true
  # Either mode-specific backend unit may not exist yet.
  for unit in warp-vps-redsocks.service "wg-quick@${runtime_iface}.service"; do
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl disable "$unit" >/dev/null 2>&1 || true
  done
  if [ "$MANAGED_WARP_SVC_VALUE" -eq 1 ] && [ "$preserve_warp_service" -eq 0 ]; then
    systemctl stop warp-svc.service >/dev/null 2>&1 || true
    systemctl disable warp-svc.service >/dev/null 2>&1 || true
  fi
  if [ -x "$BIN_PATH" ] && [ -r "$CONFIG_FILE" ]; then
    "$BIN_PATH" stop-rules >/dev/null 2>&1 || true
  fi
  if command -v nft >/dev/null 2>&1; then
    nft delete table inet warp_vps >/dev/null 2>&1 || true
  fi
  if command -v ip >/dev/null 2>&1 && ip link show "$runtime_iface" >/dev/null 2>&1; then
    if command -v wg-quick >/dev/null 2>&1; then
      wg-quick down "$runtime_config" >/dev/null 2>&1 \
        || wg-quick down "$runtime_iface" >/dev/null 2>&1 \
        || true
    fi
    if ip link show "$runtime_iface" >/dev/null 2>&1; then
      ip link delete dev "$runtime_iface" >/dev/null 2>&1 \
        || {
          log "无法停止本项目 WireGuard 网卡：$runtime_iface"
          return 1
      }
    fi
  elif [ "$PREVIOUS_MODE" = "wireguard" ] && ! command -v ip >/dev/null 2>&1; then
    log "找不到 ip，无法确认旧 WireGuard 网卡已经停用"
    return 1
  fi

  for unit in warp-vps-health.timer warp-vps-health.service warp-vps.service; do
    if ! project_unit_stopped "$unit"; then
      log "本项目服务仍在运行：$unit"
      return 1
    fi
  done
  for unit in warp-vps-redsocks.service "wg-quick@${runtime_iface}.service"; do
    if ! project_unit_stopped "$unit"; then
      log "旧模式服务仍在运行：$unit"
      return 1
    fi
    if ! project_unit_disabled "$unit"; then
      log "旧模式服务仍保持启用：$unit"
      return 1
    fi
  done
  if [ "$MANAGED_WARP_SVC_VALUE" -eq 1 ] && [ "$preserve_warp_service" -eq 0 ]; then
    if ! project_unit_stopped warp-svc.service; then
      log "本项目管理的 WARP 服务仍在运行：warp-svc.service"
      return 1
    fi
    if ! project_unit_disabled warp-svc.service; then
      log "本项目管理的 WARP 服务仍保持启用：warp-svc.service"
      return 1
    fi
  fi
  if command -v ip >/dev/null 2>&1 && ! project_wg_interface_absent "$runtime_iface"; then
    log "本项目 WireGuard 网卡仍在运行或状态无法读取：$runtime_iface"
    return 1
  fi
}

cleanup_failed_install() {
  local rc=$?
  trap - EXIT
  if [ "$INSTALL_CLEANUP_ARMED" -eq 1 ] && [ "$INSTALL_COMPLETE" -eq 0 ]; then
    set +e
    log "安装未完成，正在恢复安装前的项目文件和运行态"
    if restore_previous_runtime; then
      log "已恢复安装前的项目运行态；本次错误仍保留在上方输出"
    else
      log "未能完整恢复安装前运行态；配置、回滚文件和日志已保留：$PROJECT_BACKUP_DIR"
    fi
  fi
  exit "$rc"
}

restore_previous_runtime() {
  local failed=0

  if [ "$INSTALL_RUNTIME_TOUCHED" -eq 0 ]; then
    if [ "$TARGET_PREP_STARTED" -eq 0 ] && [ "$INSTALL_FILES_ACTIVATED" -eq 0 ]; then
      restore_health_automation \
        || log "自动健康检查未能恢复；旧分流运行态未受影响"
      return 0
    fi
    cleanup_prepared_target "$TARGET_MODE" || failed=1
    restore_prepared_target_files || return 1
    restore_health_automation \
      || log "自动健康检查未能恢复；旧分流运行态未受影响"
    [ "$failed" -eq 0 ]
    return
  fi

  if [ "$INSTALL_FILES_ACTIVATED" -eq 1 ]; then
    if [ "$INSTALL_BACKEND_REUSED" -eq 1 ]; then
      stop_reused_target_routing || failed=1
    else
      stop_project_runtime "$WG_IFACE" "$WG_CONFIG" || failed=1
    fi
  fi
  cleanup_prepared_target "$TARGET_MODE" || failed=1
  restore_project_files || return 1
  systemctl daemon-reload >/dev/null 2>&1 || failed=1

  if [ -f "$PROJECT_BACKUP_DIR/config.env" ]; then
    start_previous_runtime || failed=1
  else
    restore_health_automation \
      || log "自动健康检查未能恢复；不影响已清理的目标分流"
  fi
  [ "$failed" -eq 0 ]
}

cleanup_prepared_target() {
  local selected_mode="$1"
  local interface_rc=1 failed=0
  [ "$TARGET_PREP_STARTED" -eq 1 ] || return 0

  if [ "$selected_mode" = "wireguard" ]; then
    [ "$INSTALL_RUNTIME_TOUCHED" -eq 1 ] || return 0
    systemctl stop "wg-quick@${WG_IFACE}.service" >/dev/null 2>&1 || true
    if [ -x "$PROJECT_STAGE_DIR/bin/warp-vps" ] && [ -r "$TARGET_CONFIG_FILE" ]; then
      WARP_VPS_CONFIG_FILE="$TARGET_CONFIG_FILE" \
        WARP_VPS_RULES_DIR="$PROJECT_STAGE_DIR/rules" \
        "$PROJECT_STAGE_DIR/bin/warp-vps" stop-rules >/dev/null 2>&1 || true
    fi
    project_wg_interface_present "$WG_IFACE" || interface_rc=$?
    [ "$interface_rc" -ne 2 ] || return 1
    if [ "$interface_rc" -eq 0 ]; then
      if command -v wg-quick >/dev/null 2>&1; then
        wg-quick down "$WG_CONFIG" >/dev/null 2>&1 \
          || wg-quick down "$WG_IFACE" >/dev/null 2>&1 \
          || true
      fi
      project_wg_interface_present "$WG_IFACE" || interface_rc=$?
      if [ "$interface_rc" -eq 0 ]; then
        ip link delete dev "$WG_IFACE" >/dev/null 2>&1 || failed=1
      elif [ "$interface_rc" -eq 2 ]; then
        failed=1
      fi
    fi
    interface_rc=1
    project_wg_interface_present "$WG_IFACE" || interface_rc=$?
    [ "$interface_rc" -eq 1 ] || failed=1
  elif [ "$selected_mode" = "socks" ] && [ "$PREVIOUS_MODE" != "socks" ] \
    && [ "$MANAGED_WARP_SVC_VALUE" -eq 1 ]; then
    systemctl stop warp-svc.service >/dev/null 2>&1 || true
    systemctl disable warp-svc.service >/dev/null 2>&1 || true
    project_unit_stopped warp-svc.service || failed=1
    project_unit_disabled warp-svc.service || failed=1
  fi
  [ "$failed" -eq 0 ]
}

restore_prepared_target_files() {
  [ -n "$PROJECT_BACKUP_DIR" ] || return 1
  install -d -m 0755 "$PROJECT_BACKUP_DIR/failed-new" || return 1
  [ "$TARGET_MODE" = "wireguard" ] || return 0
  restore_project_file "$WG_CONFIG" "$PROJECT_BACKUP_DIR/wireguard.conf" wireguard-config 0600 || return 1
  restore_project_file "$WGCF_ACCOUNT" "$PROJECT_BACKUP_DIR/state/wgcf/wgcf-account.toml" wgcf-account 0600 || return 1
  restore_project_file "$WGCF_BIN" "$PROJECT_BACKUP_DIR/app/bin/wgcf" wgcf-binary 0755 || return 1
}

stop_reused_target_routing() {
  local failed=0
  systemctl stop warp-vps-health.timer >/dev/null 2>&1 || true
  systemctl stop warp-vps-health.service >/dev/null 2>&1 || true
  systemctl stop warp-vps.service >/dev/null 2>&1 || true
  if [ -x "$BIN_PATH" ] && [ -r "$CONFIG_FILE" ]; then
    "$BIN_PATH" stop-rules >/dev/null 2>&1 || failed=1
  fi
  project_unit_stopped warp-vps.service || failed=1
  if [ "$TARGET_MODE" = "socks" ]; then
    systemctl stop warp-vps-redsocks.service >/dev/null 2>&1 || true
    project_unit_stopped warp-vps-redsocks.service || failed=1
  fi
  [ "$failed" -eq 0 ]
}

restore_health_automation() {
  [ "$HEALTH_AUTOMATION_TOUCHED" -eq 1 ] || return 0
  if [ "$PREVIOUS_HEALTH_TIMER_ACTIVE" -eq 1 ]; then
    systemctl start warp-vps-health.timer >/dev/null 2>&1 || return 1
  else
    systemctl stop warp-vps-health.timer >/dev/null 2>&1 || true
  fi
}

start_previous_runtime() {
  local old_warp_port=""
  "$BIN_PATH" install-systemd || return 1
  systemctl daemon-reload || return 1
  if [ "$PREVIOUS_MODE" = "wireguard" ]; then
    enable_and_start_unit "wg-quick@${PREVIOUS_WG_IFACE}.service" || return 1
  elif [ "$PREVIOUS_MODE" = "socks" ]; then
    enable_and_start_unit warp-svc.service || return 1
    old_warp_port="$(awk -F= '$1 == "WARP_SOCKS_PORT" { print $2; exit }' "$CONFIG_FILE")"
    if ! valid_port "$old_warp_port" || ! port_in_use "$old_warp_port"; then
      "$BIN_PATH" configure-warp || return 1
    fi
    enable_and_start_unit warp-vps-redsocks.service || return 1
  else
    return 1
  fi
  enable_and_start_unit warp-vps.service || return 1
  restore_health_automation || log "原自动健康检查状态未能恢复；不影响已恢复的分流运行"
}

enable_project_unit() {
  local unit="$1"
  enable_and_start_unit "$unit" || die "无法启动系统服务：$unit"
}

enable_and_start_unit() {
  local unit="$1"
  systemctl enable "$unit" || return 1
  systemctl start "$unit"
}

enable_health_timer() {
  if systemctl enable warp-vps-health.timer >/dev/null 2>&1 \
    && systemctl start warp-vps-health.timer >/dev/null 2>&1; then
    return 0
  fi
  log "自动健康检查定时器未能启用；不影响当前分流运行"
  return 0
}

project_installation_present() {
  [ -x "$BIN_PATH" ] && [ -e "$CONFIG_FILE" ]
}

menu_mode_label() {
  local mode
  mode="$(read_project_mode 2>/dev/null || true)"
  case "$mode" in
    wireguard) printf 'WireGuard\n' ;;
    socks) printf 'Socks5\n' ;;
    *) printf '配置需要检查\n' ;;
  esac
}

menu_scope_label() {
  local scope
  scope="$(read_project_scope 2>/dev/null || true)"
  case "$scope" in
    google) printf '精准分流 Google\n' ;;
    global) printf '全局走 WARP\n' ;;
    *) printf '配置需要检查\n' ;;
  esac
}

print_installer_menu() {
  printf '\nWARP VPS Manager 管理菜单\n'
  printf '当前模式：%s\n' "$(menu_mode_label)"
  printf '路由范围：%s\n' "$(menu_scope_label)"
  printf '  1. 查看本地运行状态\n'
  printf '  2. 运行完整诊断\n'
  printf '  3. 检测 Gemini / YouTube Premium 解锁\n'
  printf '  4. 重启分流链路\n'
  printf '  5. 更新脚本和 Google IP 规则\n'
  printf '  6. 重装或切换路由范围 / 运行模式\n'
  printf '  7. 查看最近日志\n'
  printf '  8. 卸载\n'
  printf '  0. 退出\n'
}

run_menu_manager_action() {
  set +e
  "$BIN_PATH" "$@"
  MENU_ACTION_RC=$?
  set -e
}

wait_for_menu_return() {
  local ignored
  printf '\n按回车返回主菜单：'
  read_input ignored || return 1
  : "$ignored"
}

finish_menu_action() {
  local label="$1"
  if [ "$MENU_ACTION_RC" -eq 0 ]; then
    printf '\n[warp-vps] %s已完成。\n' "$label"
  else
    printf '\n[warp-vps] %s未完成（退出码：%s），请查看上方错误；已返回主菜单。\n' \
      "$label" "$MENU_ACTION_RC" >&2
  fi
  wait_for_menu_return || return 1
}

installer_menu() {
  require_root
  local choice
  while true; do
    print_installer_menu
    printf '请输入选项：'
    if ! read_input choice; then
      printf '\n未读取到输入，已退出管理菜单。\n'
      return 0
    fi
    case "$choice" in
      1)
        run_menu_manager_action status
        finish_menu_action "状态检查" || return 0
        ;;
      2)
        run_menu_manager_action test
        finish_menu_action "完整诊断" || return 0
        ;;
      3)
        run_menu_manager_action unlock-check
        finish_menu_action "解锁检测" || return 0
        ;;
      4)
        run_menu_manager_action restart
        finish_menu_action "重启" || return 0
        ;;
      5)
        run_menu_manager_action update
        if [ "$MENU_ACTION_RC" -eq 0 ]; then
          printf '\n[warp-vps] 更新完成。请重新运行 warp-vps 使用新版本管理菜单。\n'
          return 0
        fi
        finish_menu_action "更新" || return 0
        ;;
      6)
        printf '\n即将进入现有安装事务；可重新选择路由范围和 Socks5 / WireGuard 模式。\n'
        set +e
        (
          set -Eeuo pipefail
          main
        )
        MENU_ACTION_RC=$?
        set -e
        if [ "$MENU_ACTION_RC" -eq 0 ]; then
          printf '\n[warp-vps] 重装或切换已完成。请重新运行 warp-vps。\n'
          return 0
        fi
        finish_menu_action "重装或切换" || return 0
        ;;
      7)
        run_menu_manager_action logs
        finish_menu_action "日志查询" || return 0
        ;;
      8)
        run_menu_manager_action uninstall
        if [ "$MENU_ACTION_RC" -eq 0 ]; then
          return 0
        fi
        finish_menu_action "卸载" || return 0
        ;;
      0)
        printf '已退出管理菜单。\n'
        return 0
        ;;
      *)
        printf '输入无效，请输入 0-8。\n' >&2
        ;;
    esac
  done
}

installer_usage() {
  cat <<'EOF'
用法：
  install.sh
  install.sh --menu
  install.sh --install
  install.sh --install --non-interactive [--mode keep|wireguard|socks]
             [--scope keep|google|global] [--swap auto|none|N]
             [--socks-port auto|PORT]

  无参数 / --menu  需要终端；未安装时开始安装，已有安装时进入管理菜单
  --install         需要终端；进入安装、重装或模式切换流程
  --non-interactive 禁止读取输入；全新默认 Google 精准分流、WireGuard、无 Swap 时创建 1G
  --mode             选择模式；keep 仅适用于已有安装
  --scope            选择路由范围；keep 仅适用于已有安装
  --swap             auto 默认按需创建 1G；N 为 GiB；none 明确跳过
  --socks-port       Socks5 使用自动空闲端口或指定端口
EOF
}

installer_cli_error() {
  printf '[warp-vps] 错误：%s\n' "$*" >&2
  return 2
}

parse_install_options() {
  local seen_noninteractive=0 seen_mode=0 seen_scope=0 seen_swap=0 seen_port=0 value
  INSTALL_NONINTERACTIVE=0
  INSTALL_MODE_OPTION=""
  INSTALL_SCOPE_OPTION=""
  INSTALL_SWAP_OPTION=""
  INSTALL_SOCKS_PORT_OPTION=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --non-interactive)
        [ "$seen_noninteractive" -eq 0 ] \
          || { installer_cli_error "--non-interactive 不能重复"; return 2; }
        INSTALL_NONINTERACTIVE=1
        seen_noninteractive=1
        shift
        ;;
      --mode)
        [ "$seen_mode" -eq 0 ] || { installer_cli_error "--mode 不能重复"; return 2; }
        [ "$#" -ge 2 ] || { installer_cli_error "--mode 缺少参数"; return 2; }
        value="$2"
        case "$value" in
          keep|wireguard|socks) ;;
          *) installer_cli_error "--mode 只接受 keep、wireguard 或 socks"; return 2 ;;
        esac
        INSTALL_MODE_OPTION="$value"
        seen_mode=1
        shift 2
        ;;
      --scope)
        [ "$seen_scope" -eq 0 ] || { installer_cli_error "--scope 不能重复"; return 2; }
        [ "$#" -ge 2 ] || { installer_cli_error "--scope 缺少参数"; return 2; }
        value="$2"
        case "$value" in
          keep|google|global) ;;
          *) installer_cli_error "--scope 只接受 keep、google 或 global"; return 2 ;;
        esac
        INSTALL_SCOPE_OPTION="$value"
        seen_scope=1
        shift 2
        ;;
      --swap)
        [ "$seen_swap" -eq 0 ] || { installer_cli_error "--swap 不能重复"; return 2; }
        [ "$#" -ge 2 ] || { installer_cli_error "--swap 缺少参数"; return 2; }
        value="$2"
        case "$value" in
          auto|none) ;;
          ''|*[!0-9]*) installer_cli_error "--swap 只接受 auto、none 或正整数 GiB"; return 2 ;;
          *)
            [ "${#value}" -le 6 ] \
              || { installer_cli_error "--swap 的 GiB 数值不能超过 6 位"; return 2; }
            [ "$((10#$value))" -gt 0 ] \
              || { installer_cli_error "--swap 只接受 auto、none 或正整数 GiB"; return 2; }
            ;;
        esac
        INSTALL_SWAP_OPTION="$value"
        seen_swap=1
        shift 2
        ;;
      --socks-port)
        [ "$seen_port" -eq 0 ] \
          || { installer_cli_error "--socks-port 不能重复"; return 2; }
        [ "$#" -ge 2 ] || { installer_cli_error "--socks-port 缺少参数"; return 2; }
        value="$2"
        if [ "$value" != "auto" ] && ! valid_port "$value"; then
          installer_cli_error "--socks-port 必须是 auto 或 1-65535 的端口"
          return 2
        fi
        INSTALL_SOCKS_PORT_OPTION="$value"
        seen_port=1
        shift 2
        ;;
      *) installer_cli_error "未知安装参数：$1"; return 2 ;;
    esac
  done

  if [ "$INSTALL_NONINTERACTIVE" -eq 0 ] \
    && { [ "$seen_mode" -eq 1 ] || [ "$seen_scope" -eq 1 ] \
      || [ "$seen_swap" -eq 1 ] || [ "$seen_port" -eq 1 ]; }; then
    installer_cli_error "--mode、--scope、--swap 和 --socks-port 必须与 --non-interactive 一起使用"
    return 2
  fi
}

dispatch_installer() {
  if [ "$#" -eq 0 ]; then
    if ! interactive_terminal_available; then
      installer_cli_error "当前没有交互终端；自动化安装请使用 --install --non-interactive" || true
      installer_usage >&2
      return 2
    fi
    if project_installation_present; then
      installer_menu
    else
      main
    fi
    return
  fi

  case "$1" in
    --menu)
      [ "$#" -eq 1 ] || { installer_usage >&2; return 2; }
      if ! interactive_terminal_available; then
        installer_cli_error "管理菜单需要交互终端；请改用 warp-vps 的显式命令" || true
        installer_usage >&2
        return 2
      fi
      if project_installation_present; then
        installer_menu
      else
        main
      fi
      ;;
    --install)
      shift
      parse_install_options "$@" || { installer_usage >&2; return 2; }
      if [ "$INSTALL_NONINTERACTIVE" -eq 0 ] && ! interactive_terminal_available; then
        installer_cli_error "交互安装需要终端；自动化安装请增加 --non-interactive" || true
        installer_usage >&2
        return 2
      fi
      main
      ;;
    -h|--help|help)
      [ "$#" -eq 1 ] || { installer_usage >&2; return 2; }
      installer_usage
      ;;
    *) installer_usage >&2; return 2 ;;
  esac
}

main() {
  require_root
  require_systemd
  validate_repo_raw_base "$REPO_RAW_BASE"

  local selected_mode selected_scope warp_port redsocks_port redsocks_uid redsocks_group redsocks_bin
  local reusable_warp_port=""
  local reusable_redsocks_port=""
  local prompted_mode prompted_scope locked_mode locked_scope locked_warp_port locked_redsocks_port
  local preserve_warp_service=0
  if [ -e "$CONFIG_FILE" ]; then
    [ -r "$CONFIG_FILE" ] || die "现有配置无法读取，未修改当前运行态：$CONFIG_FILE"
    prompted_mode="$(read_project_mode)" \
      || die "现有配置缺少有效的 WARP_MODE，未修改当前运行态：$CONFIG_FILE"
    prompted_scope="$(read_project_scope)" \
      || die "现有配置包含无效的 WARP_SCOPE，未修改当前运行态：$CONFIG_FILE"
  else
    prompted_mode=""
    prompted_scope="google"
  fi
  collect_swap_choice
  selected_scope="$(select_route_scope "$prompted_scope")"
  selected_mode="$(select_install_mode "$prompted_mode" "$selected_scope")"
  TARGET_MODE="$selected_mode"
  if [ "$selected_mode" = "wireguard" ] && [ -n "$INSTALL_SOCKS_PORT_OPTION" ]; then
    installer_cli_error "WireGuard 模式不能使用 --socks-port"
    return 2
  fi
  if [ "$prompted_mode" = "socks" ]; then
    reusable_warp_port="$(read_project_warp_port || true)"
    reusable_redsocks_port="$(read_project_redsocks_port || true)"
  fi
  if [ "$selected_mode" = "socks" ]; then
    if [ "$INSTALL_NONINTERACTIVE" -eq 1 ]; then
      warp_port="$(select_noninteractive_warp_port "$reusable_warp_port")"
    else
      warp_port="$(prompt_warp_port "$reusable_warp_port")"
    fi
    valid_port "$warp_port" || die "内部错误：选择的 WARP SOCKS 端口无效"
    if [ "$warp_port" = "$reusable_warp_port" ] && [ -n "$reusable_redsocks_port" ]; then
      redsocks_port="$reusable_redsocks_port"
    else
      redsocks_port="$(find_free_port "$warp_port")"
    fi
    valid_port "$redsocks_port" || die "内部错误：选择的 redsocks 端口无效"
  else
    warp_port=0
    redsocks_port=0
  fi

  acquire_operation_lock
  locked_mode="$(read_project_mode || true)"
  if [ -e "$CONFIG_FILE" ]; then
    locked_scope="$(read_project_scope || true)"
  else
    locked_scope="google"
  fi
  [ "$locked_mode" = "$prompted_mode" ] \
    || die "等待输入期间安装模式已被其他管理操作修改，请重新运行安装器"
  [ "$locked_scope" = "$prompted_scope" ] \
    || die "等待输入期间路由范围已被其他管理操作修改，请重新运行安装器"
  if [ "$prompted_mode" = "socks" ]; then
    locked_warp_port="$(read_project_warp_port || true)"
    locked_redsocks_port="$(read_project_redsocks_port || true)"
    if [ "$locked_warp_port" != "$reusable_warp_port" ] \
      || [ "$locked_redsocks_port" != "$reusable_redsocks_port" ]; then
      die "等待输入期间 Socks5 配置已被其他管理操作修改，请重新运行安装器"
    fi
  fi
  if [ "$SWAP_ACTION" = "create" ] && [ "$(swap_total_mb)" -gt 0 ]; then
    log "检测到系统现已有 Swap，不再重复创建"
    SWAP_ACTION="none"
    SWAP_SIZE_MB=0
  fi
  capture_service_ownership "$selected_mode"
  read_previous_wireguard_runtime
  if [ "$selected_mode" = "wireguard" ] && [ "$PREVIOUS_MODE" = "wireguard" ]; then
    WG_IFACE="$PREVIOUS_WG_IFACE"
    WG_CONFIG="$PREVIOUS_WG_CONFIG"
  fi

  log "正在下载并检查项目文件"
  stage_project_files
  validate_existing_config
  backup_project_files || die "无法备份当前项目文件，安装未修改现有运行态"

  apply_swap_choice

  log "正在安装依赖"
  install_dependencies "$selected_mode" "$selected_scope"
  validate_staged_rules "$PROJECT_STAGE_DIR" || die "下载的规则快照校验失败"

  if [ "$selected_mode" = "socks" ]; then
    disable_new_packaged_redsocks_service
    preflight_nft_nat
    if project_port_conflicts \
      "$warp_port" "$reusable_warp_port" current_socks_backend_owns_port; then
      die "端口 $warp_port 已被其他进程占用，不能作为 WARP SOCKS 端口；请直接重跑安装器选择其他端口"
    fi
    if project_port_conflicts \
      "$redsocks_port" "$reusable_redsocks_port" current_redsocks_backend_owns_port; then
      die "内部端口 $redsocks_port 已被其他进程占用，不能作为项目透明转发端口；请直接重跑安装器"
    fi
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

  TARGET_CONFIG_FILE="$PROJECT_STAGE_DIR/config.env"
  write_config_file "$TARGET_CONFIG_FILE" "$selected_mode" "$warp_port" "$redsocks_port" \
    "$redsocks_uid" "$redsocks_group" "$redsocks_bin" "$selected_scope"
  if current_backend_reusable "$selected_mode" "$warp_port" "$reusable_warp_port"; then
    INSTALL_BACKEND_REUSED=1
    log "当前 ${selected_mode} 后端本地运行正常，重装期间保持运行"
  fi

  INSTALL_CLEANUP_ARMED=1
  trap cleanup_failed_install EXIT
  quiesce_health_automation || die "无法暂停自动健康检查；当前分流保持不变"
  if ! prepare_target_backend "$selected_mode"; then
    die "目标模式未能准备完成；旧模式未停止，可处理上方错误后直接重跑安装器"
  fi

  if [ "$INSTALL_BACKEND_REUSED" -eq 1 ]; then
    pause_project_routing || die "无法暂停旧分流规则；当前后端保持运行"
  else
    [ "$selected_mode" = "socks" ] && preserve_warp_service=1
    INSTALL_RUNTIME_TOUCHED=1
    stop_project_runtime "$PREVIOUS_WG_IFACE" "$PREVIOUS_WG_CONFIG" "$preserve_warp_service" \
      || die "无法停止上次安装留下的项目运行态"
  fi
  if [ "$selected_mode" = "wireguard" ] && [ "$INSTALL_BACKEND_REUSED" -eq 0 ] \
    && [ "$TARGET_BACKEND_PREPARED" -eq 0 ]; then
    prepare_target_backend "$selected_mode" \
      || die "WireGuard 目标模式预检失败；正在恢复安装前运行态"
  fi
  log "正在安装项目文件和管理命令"
  INSTALL_FILES_ACTIVATED=1
  activate_project_files || die "项目文件写入失败"
  write_config "$selected_mode" "$warp_port" "$redsocks_port" "$redsocks_uid" "$redsocks_group" \
    "$redsocks_bin" "$selected_scope"
  if [ "$selected_mode" = "socks" ] && [ "$INSTALL_BACKEND_REUSED" -eq 0 ] \
    && [ "$TARGET_BACKEND_PREPARED" -eq 0 ]; then
    log "正在应用新的 Cloudflare WARP SOCKS 端口：$warp_port"
    TARGET_PREP_STARTED=1
    "$BIN_PATH" configure-warp || die "Cloudflare WARP SOCKS 本地代理未就绪"
    TARGET_BACKEND_PREPARED=1
  fi

  log "正在安装系统服务和分流规则"
  "$BIN_PATH" install-systemd || die "无法写入 systemd 服务"
  systemctl daemon-reload || die "systemd 重新加载失败"
  if [ "$selected_mode" = "socks" ]; then
    enable_project_unit warp-svc.service
    if [ "$INSTALL_BACKEND_REUSED" -eq 1 ]; then
      systemctl enable warp-vps-redsocks.service \
        || die "无法启用系统服务：warp-vps-redsocks.service"
      systemctl restart warp-vps-redsocks.service \
        || die "无法重新加载本地透明转发服务"
    else
      enable_project_unit warp-vps-redsocks.service
    fi
  else
    enable_project_unit "wg-quick@${WG_IFACE}.service"
  fi
  enable_project_unit warp-vps.service
  enable_health_timer

  INSTALL_COMPLETE=1
  INSTALL_CLEANUP_ARMED=0
  trap - EXIT
  release_operation_lock

  printf '\nWARP VPS Manager 安装完成。\n'
  if [ "$selected_mode" = "socks" ]; then
    printf '安装模式：Socks5 兼容模式\n'
  else
    printf '安装模式：WireGuard 默认模式\n'
  fi
  if [ "$selected_mode" = "socks" ]; then
    printf 'WARP SOCKS 端口：%s\n' "$warp_port"
  fi
  if [ "$selected_scope" = "global" ]; then
    printf '路由范围：全局走 WARP\n'
  else
    printf '路由范围：精准分流 Google 服务\n'
  fi
  printf '交互菜单：warp-vps\n'
  printf '显式命令：warp-vps {status|test|restart|unlock-check|update|reinstall|switch|logs|uninstall}\n'
  if [ "$selected_mode" = "socks" ] && [ "$selected_scope" = "global" ]; then
    printf 'Socks5 全局模式会把 VPS 主动发起的公网 IPv4 TCP 透明转发到 WARP；入站连接回包保持原生路径，Google IPv4 UDP/443（QUIC）和 Google IPv6 继续拒绝。\n'
  elif [ "$selected_mode" = "socks" ]; then
    printf 'Google IPv4 UDP/443（QUIC）已拒绝，支持回落的客户端会改用经 WARP 的 TCP；Google 目标 IPv6 继续拒绝。\n'
  elif [ "$selected_scope" = "global" ]; then
    printf 'WireGuard 全局模式会把 IPv4、IPv6、TCP、UDP 和 QUIC 流量路由到 WARP。\n'
  else
    printf 'WireGuard 模式会把命中 Google CIDR 的 IPv4、IPv6、TCP、UDP 和 QUIC 流量路由到 WARP。\n'
  fi

  printf '\n安装已完成，以下 IPv4 出口解锁检测仅供参考，不影响安装结果：\n'
  "$BIN_PATH" unlock-check || true
}

if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  dispatch_installer "$@"
fi
