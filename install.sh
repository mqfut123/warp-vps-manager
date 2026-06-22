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
VERSION="0.1.0"

log() { printf '[warp-vps] %s\n' "$*"; }
die() { printf '[warp-vps] ERROR: %s\n' "$*" >&2; exit 1; }

require_root() {
  [ "$(id -u)" -eq 0 ] || die "must run as root"
}

load_os_release() {
  [ -r /etc/os-release ] || die "cannot read /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID="${ID:-}"
  OS_VERSION_ID="${VERSION_ID:-}"
  OS_CODENAME="${VERSION_CODENAME:-}"
}

pkg_install_apt() {
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
  [ -n "$codename" ] || die "cannot determine apt codename for Cloudflare WARP repository"

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
    rocky|almalinux)
      pkg_install_rpm
      ;;
    *)
      die "unsupported OS: ${OS_ID:-unknown}; supported: Debian, Ubuntu, Rocky, AlmaLinux"
      ;;
  esac

  command -v warp-cli >/dev/null 2>&1 || die "cloudflare-warp installed but warp-cli not found"
  command -v redsocks >/dev/null 2>&1 || die "redsocks not found after dependency installation"
  command -v nft >/dev/null 2>&1 || die "nft not found after dependency installation"
  command -v ss >/dev/null 2>&1 || die "ss not found after dependency installation"
  command -v timeout >/dev/null 2>&1 || die "timeout not found after dependency installation"
  command -v python3 >/dev/null 2>&1 || die "python3 not found after dependency installation"
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
  die "failed to find a free high port"
}

prompt_warp_port() {
  local input
  if [ -n "${WARP_SOCKS_PORT:-}" ]; then
    input="$WARP_SOCKS_PORT"
  else
    printf 'Enter WARP SOCKS port [press Enter for a random free port]: '
    read -r input
  fi

  if [ -z "$input" ]; then
    find_free_port
    return 0
  fi

  valid_port "$input" || die "invalid port: $input"
  reserved_port "$input" && die "port $input is reserved by a common service"
  port_in_use "$input" && die "port $input is already listening"
  printf '%s\n' "$input"
}

validate_repo_raw_base() {
  local url="$1"
  [ -n "$url" ] || die "WARP_VPS_REPO_BASE cannot be empty"
  case "$url" in
    https://*) ;;
    *) die "WARP_VPS_REPO_BASE must start with https://" ;;
  esac
  case "$url" in
    *$'\n'*|*$'\r'*|*$'\t'*|*" "*) die "WARP_VPS_REPO_BASE must not contain whitespace" ;;
  esac
  local rest="${url#https://}"
  local authority="${rest%%/*}"
  case "$authority" in
    *@*) die "WARP_VPS_REPO_BASE must not contain credentials or userinfo" ;;
    '') die "WARP_VPS_REPO_BASE missing host" ;;
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
  sleep 3
  if ! ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .; then
    die "warp-cli did not listen on SOCKS port $port"
  fi
  if ! curl --socks5-hostname "127.0.0.1:${port}" -fsS --connect-timeout 8 --max-time 15 \
    https://www.cloudflare.com/cdn-cgi/trace | grep -Eq '^warp=(on|plus)$'; then
    die "WARP SOCKS trace did not report warp=on"
  fi
}

write_config() {
  local warp_port="$1"
  local redsocks_port="$2"
  local redsocks_uid="$3"
  local redsocks_group="$4"
  local redsocks_bin="$5"
  cat > "$CONFIG_FILE" <<EOF
APP_VERSION=${VERSION}
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
  log "installing dependencies"
  install_dependencies

  local warp_port redsocks_port redsocks_uid redsocks_group redsocks_bin
  warp_port="$(prompt_warp_port)"
  redsocks_port="$(find_free_port "$warp_port")"
  ensure_redsocks_user
  redsocks_uid="$(id -u "$REDSOCKS_USER")"
  redsocks_group="$(id -gn "$REDSOCKS_USER")"
  redsocks_bin="$(command -v redsocks)"

  log "installing project files"
  install_project_files
  write_config "$warp_port" "$redsocks_port" "$redsocks_uid" "$redsocks_group" "$redsocks_bin"

  log "configuring Cloudflare WARP SOCKS on port $warp_port"
  configure_warp "$warp_port"

  log "installing services and nftables rules"
  "$BIN_PATH" install-systemd
  systemctl daemon-reload
  systemctl enable --now warp-vps-redsocks.service
  systemctl enable --now warp-vps.service
  systemctl enable --now warp-vps-health.timer

  log "running final test"
  "$BIN_PATH" test

  printf '\nWARP VPS Manager installed.\n'
  printf 'WARP SOCKS port: %s\n' "$warp_port"
  printf 'Management command: warp-vps {status|test|restart|update|logs|uninstall}\n'
  printf 'IPv6 target traffic is blocked to prevent leak.\n'
}

main "$@"
