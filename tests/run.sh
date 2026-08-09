#!/usr/bin/env bash
# Test doubles and variables below are consumed by functions loaded with eval.
# shellcheck disable=SC2016,SC2034,SC2317,SC2329
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
INSTALL_SCRIPT="${ROOT_DIR}/install.sh"
MANAGER_SCRIPT="${ROOT_DIR}/bin/warp-vps"
README_FILE="${ROOT_DIR}/README.md"
GENERATOR_SCRIPT="${ROOT_DIR}/scripts/generate-google-rules.py"
FIXTURE_DIR="${ROOT_DIR}/tests/fixtures"

passed=0
failed=0

fail() {
  printf '    %s\n' "$*" >&2
  return 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [ "$actual" != "$expected" ]; then
    fail "${message}: expected <${expected}>, got <${actual}>"
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  case "$haystack" in
    *"$needle"*) return 0 ;;
    *) fail "${message}: missing <${needle}>" ;;
  esac
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local message="$3"
  case "$haystack" in
    *"$needle"*) fail "${message}: unexpectedly found <${needle}>" ;;
    *) return 0 ;;
  esac
}

assert_file_matches() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -Eq "$pattern" "$file"; then
    fail "${message}: ${file} does not match /${pattern}/"
  fi
}

assert_file_not_matches() {
  local file="$1"
  local pattern="$2"
  local message="$3"
  if grep -Eiq "$pattern" "$file"; then
    fail "${message}: ${file} unexpectedly matches /${pattern}/"
  fi
}

source_without_main() {
  local file="$1"
  # Both production scripts have a single final dispatcher in this exact form.
  # Removing it lets the tests exercise pure functions without touching the host.
  # shellcheck disable=SC1090
  eval "$(sed \
    -e '/^if \[ "${BASH_SOURCE\[0\]:-\$0}" = "\$0" \]; then$/,/^fi$/d' \
    -e '/^main "\$@"$/d' \
    "$file")"
}

function_body() {
  local file="$1"
  local name="$2"
  awk -v signature="${name}() {" '
    $0 == signature { in_function = 1 }
    in_function { print }
    in_function && /^}$/ { exit }
  ' "$file"
}

line_number() {
  local text="$1"
  local pattern="$2"
  awk -v pattern="$pattern" 'index($0, pattern) { print NR; exit }' <<< "$text"
}

run_test() {
  local name="$1"
  local rc
  shift
  ( "$@" )
  rc=$?
  if [ "$rc" -eq 0 ]; then
    printf 'ok - %s\n' "$name"
    passed=$((passed + 1))
  else
    printf 'not ok - %s\n' "$name" >&2
    failed=$((failed + 1))
  fi
}

test_install_mode_reprompts() {
  source_without_main "$INSTALL_SCRIPT"
  CONFIG_FILE="${FIXTURE_DIR}/config/missing.env"

  local mock_udp_probe_log
  mock_udp_probe_log="$(mktemp)"
  probe_outbound_udp() { printf 'probe\n' >> "$mock_udp_probe_log"; return 0; }
  local answer_index=0
  local answers=('invalid' '')
  read_input() {
    printf -v "$1" '%s' "${answers[$answer_index]}"
    answer_index=$((answer_index + 1))
  }
  local output
  if ! output="$(prompt_install_mode 2>/dev/null)"; then
    fail 'prompt_install_mode exited instead of asking again'
    return 1
  fi
  output="${output##*$'\n'}"
  assert_eq 'wireguard' "$output" 'empty retry should select the UDP-backed WireGuard default' || return 1
  assert_eq '1' "$(wc -l < "$mock_udp_probe_log" | tr -d ' ')" \
    'an invalid answer retry must not repeat the UDP probe'
}

test_install_mode_keeps_explicit_numbers() {
  source_without_main "$INSTALL_SCRIPT"
  CONFIG_FILE="${FIXTURE_DIR}/config/missing.env"

  local mock_udp_probe_result=0
  probe_outbound_udp() { return "$mock_udp_probe_result"; }
  local answer='1'
  read_input() { printf -v "$1" '%s' "$answer"; }
  assert_eq 'socks' "$(prompt_install_mode 2>/dev/null)" \
    'explicit option 1 should remain Socks' || return 1

  mock_udp_probe_result=1
  answer='2'
  assert_eq 'wireguard' "$(prompt_install_mode 2>/dev/null)" \
    'explicit option 2 should remain WireGuard when the UDP probe changes the default'
}

test_fresh_install_mode_default_follows_udp_probe() {
  source_without_main "$INSTALL_SCRIPT"
  CONFIG_FILE="${FIXTURE_DIR}/config/missing.env"

  local mock_udp_probe_result=0
  local output prompt_log
  prompt_log="$(mktemp)"
  read_input() { printf -v "$1" '%s' ''; }
  probe_outbound_udp() { return "$mock_udp_probe_result"; }

  output="$(prompt_install_mode 2> "$prompt_log")" || return 1
  assert_eq 'wireguard' "$output" \
    'a valid outbound UDP response should keep WireGuard as the fresh default' || return 1
  assert_contains "$(< "$prompt_log")" 'Cloudflare STUN UDP/3478 有效响应' \
    'the WireGuard recommendation must name the successful UDP evidence' || return 1
  assert_contains "$(< "$prompt_log")" '直接回车默认选择：WireGuard' \
    'the successful UDP prompt must state the WireGuard default' || return 1

  mock_udp_probe_result=1
  : > "$prompt_log"
  output="$(prompt_install_mode 2> "$prompt_log")" || return 1
  assert_eq 'socks' "$output" \
    'a completed UDP probe without a valid response should default to Socks5' || return 1
  assert_contains "$(< "$prompt_log")" '未收到 Cloudflare STUN UDP/3478 有效响应' \
    'the Socks5 recommendation must name the missing UDP evidence' || return 1
  assert_contains "$(< "$prompt_log")" 'WireGuard 只使用 UDP 且不会回退 TCP' \
    'the failed UDP prompt must explain why Socks5 is safer' || return 1
  assert_contains "$(< "$prompt_log")" '直接回车默认选择：Socks5' \
    'the failed UDP prompt must state the Socks5 default' || return 1
  assert_contains "$(< "$prompt_log")" '仍可输入 2 选择 WireGuard' \
    'the UDP recommendation must not block an explicit WireGuard choice' || return 1

  mock_udp_probe_result=2
  : > "$prompt_log"
  output="$(prompt_install_mode 2> "$prompt_log")" || return 1
  assert_eq 'wireguard' "$output" \
    'an indeterminate probe must not be mislabeled as unsupported UDP' || return 1
  assert_contains "$(< "$prompt_log")" '暂时无法完成出站 UDP 探测' \
    'an indeterminate probe must explain that no UDP conclusion was reached' || return 1
  assert_contains "$(< "$prompt_log")" '直接回车默认选择：WireGuard' \
    'an indeterminate probe should retain the established fresh default'
}

test_reinstall_keeps_current_mode_by_default() {
  source_without_main "$INSTALL_SCRIPT"
  local mock_udp_probe_log
  mock_udp_probe_log="$(mktemp)"
  read_input() { printf -v "$1" '%s' ''; }
  probe_outbound_udp() { printf 'probe\n' >> "$mock_udp_probe_log"; return 1; }

  CONFIG_FILE="${FIXTURE_DIR}/config/socks-mode.env"
  assert_eq 'socks' "$(prompt_install_mode 2>/dev/null)" \
    'reinstalling an existing Socks setup must not switch modes on empty input' || return 1

  CONFIG_FILE="${FIXTURE_DIR}/config/custom-wireguard.env"
  assert_eq 'wireguard' "$(prompt_install_mode 2>/dev/null)" \
    'reinstalling an existing WireGuard setup must keep WireGuard on empty input' || return 1
  assert_eq '' "$(< "$mock_udp_probe_log")" \
    'an existing installation must not run the fresh UDP probe'
}

test_outbound_udp_probe_requires_valid_stun_response() {
  source_without_main "$INSTALL_SCRIPT"
  local root server_info server_pid probe_port probe_rc=0
  root="$(mktemp -d)"
  server_info="${root}/server-port"

  python3 - "$server_info" <<'PY' &
import pathlib
import socket
import struct
import sys

cookie = 0x2112A442
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", 0))
sock.settimeout(5)
pathlib.Path(sys.argv[1]).write_text(str(sock.getsockname()[1]), encoding="ascii")
request, peer = sock.recvfrom(2048)
transaction_id = request[8:20]
xor_port = peer[1] ^ (cookie >> 16)
xor_address = int.from_bytes(socket.inet_aton(peer[0]), "big") ^ cookie
value = struct.pack("!BBHI", 0, 1, xor_port, xor_address)
attribute = struct.pack("!HH", 0x0020, len(value)) + value
response = struct.pack("!HHI12s", 0x0101, len(attribute), cookie, transaction_id) + attribute
sock.sendto(response, peer)
sock.close()
PY
  server_pid=$!
  for _attempt in $(seq 1 100); do
    [ -s "$server_info" ] && break
    sleep 0.02
  done
  [ -s "$server_info" ] || {
    fail 'the local STUN fixture did not become ready'
    return 1
  }
  probe_port="$(< "$server_info")"
  probe_outbound_udp 127.0.0.1 "$probe_port" || probe_rc=$?
  wait "$server_pid" || {
    fail 'the valid STUN fixture exited unsuccessfully'
    return 1
  }
  assert_eq '0' "$probe_rc" \
    'the UDP probe should accept a valid STUN Binding response' || return 1

  server_info="${root}/invalid-server-port"
  python3 - "$server_info" <<'PY' &
import pathlib
import socket
import struct
import sys

cookie = 0x2112A442
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", 0))
sock.settimeout(5)
pathlib.Path(sys.argv[1]).write_text(str(sock.getsockname()[1]), encoding="ascii")
for _attempt in range(2):
    request, peer = sock.recvfrom(2048)
    transaction_id = request[8:20]
    sock.sendto(struct.pack("!HHI12s", 0x0101, 0, cookie, transaction_id), peer)
sock.close()
PY
  server_pid=$!
  for _attempt in $(seq 1 100); do
    [ -s "$server_info" ] && break
    sleep 0.02
  done
  [ -s "$server_info" ] || {
    fail 'the invalid STUN fixture did not become ready'
    return 1
  }
  probe_port="$(< "$server_info")"
  probe_rc=0
  probe_outbound_udp 127.0.0.1 "$probe_port" || probe_rc=$?
  wait "$server_pid" || {
    fail 'the invalid STUN fixture exited unsuccessfully'
    return 1
  }
  assert_eq '1' "$probe_rc" \
    'a UDP datagram without a valid STUN mapping must not prove UDP support' || return 1

  server_info="${root}/silent-server-port"
  python3 - "$server_info" <<'PY' &
import pathlib
import socket
import sys

sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.bind(("127.0.0.1", 0))
sock.settimeout(5)
pathlib.Path(sys.argv[1]).write_text(str(sock.getsockname()[1]), encoding="ascii")
for _attempt in range(2):
    sock.recvfrom(2048)
sock.close()
PY
  server_pid=$!
  for _attempt in $(seq 1 100); do
    [ -s "$server_info" ] && break
    sleep 0.02
  done
  [ -s "$server_info" ] || {
    fail 'the silent STUN fixture did not become ready'
    return 1
  }
  probe_port="$(< "$server_info")"
  probe_rc=0
  probe_outbound_udp 127.0.0.1 "$probe_port" || probe_rc=$?
  wait "$server_pid" || {
    fail 'the silent STUN fixture exited unsuccessfully'
    return 1
  }
  assert_eq '1' "$probe_rc" \
    'two UDP requests without a response must report unavailable UDP' || return 1

  probe_rc=0
  (
    export PATH=/path-without-python
    probe_outbound_udp 127.0.0.1 3478
  ) || probe_rc=$?
  assert_eq '2' "$probe_rc" \
    'a missing probe runtime must remain indeterminate instead of unsupported'
}

test_route_scope_prompt_and_defaults() {
  source_without_main "$INSTALL_SCRIPT"
  CONFIG_FILE="${FIXTURE_DIR}/config/missing.env"

  local answer_index=0
  local answers=('invalid' '')
  read_input() {
    printf -v "$1" '%s' "${answers[$answer_index]}"
    answer_index=$((answer_index + 1))
  }
  local output prompt_log
  prompt_log="$(mktemp)"
  output="$(prompt_route_scope 2> "$prompt_log")" || {
    fail 'prompt_route_scope exited instead of asking again'
    return 1
  }
  assert_contains "$(< "$prompt_log")" '输入无效' \
    'an invalid scope choice must be asked again' || return 1
  output="${output##*$'\n'}"
  assert_eq 'google' "$output" \
    'empty scope input after an invalid choice must select precise Google routing' || return 1

  local answer='1'
  read_input() { printf -v "$1" '%s' "$answer"; }
  assert_eq 'google' "$(prompt_route_scope 2>/dev/null)" \
    'explicit scope option 1 must select precise Google routing' || return 1

  answer='2'
  assert_eq 'global' "$(prompt_route_scope 2>/dev/null)" \
    'explicit scope option 2 must select global routing'
}

test_route_scope_config_is_backward_compatible() {
  source_without_main "$INSTALL_SCRIPT"
  source_without_main "$MANAGER_SCRIPT"
  local root output rc=0
  root="$(mktemp -d)"
  CONFIG_FILE="$root/config.env"
  printf '%s\n' \
    'WARP_MODE=wireguard' \
    'WARP_SOCKS_PORT=0' \
    'REDSOCKS_PORT=0' \
    'REDSOCKS_USER=warp-vps-redsocks' \
    'REDSOCKS_UID=991' \
    'REDSOCKS_GROUP=warp-vps-redsocks' \
    'REDSOCKS_BIN=/usr/sbin/redsocks' \
    'WG_IFACE=warp-vps-wg' \
    'WGCF_BIN=/opt/warp-vps-manager/bin/wgcf' \
    'WG_CONFIG=/etc/wireguard/warp-vps-wg.conf' \
    'MANAGED_WARP_SVC=0' \
    'MANAGED_REDSOCKS_BIN=0' \
    > "$CONFIG_FILE"

  load_config
  assert_eq 'google' "$WARP_SCOPE" \
    'a legacy config without WARP_SCOPE must retain precise Google routing' || return 1
  assert_eq 'google' "$(read_project_scope)" \
    'the installer must read a missing legacy scope as Google' || return 1

  printf 'WARP_SCOPE=global\n' >> "$CONFIG_FILE"
  load_config
  assert_eq 'global' "$WARP_SCOPE" 'an explicit global scope must survive config loading' || return 1
  assert_eq 'global' "$(read_project_scope)" \
    'the installer must preserve the explicit scope during reinstall' || return 1

  sed -i.bak 's/^WARP_SCOPE=global$/WARP_SCOPE=invalid/' "$CONFIG_FILE"
  rc=0
  output="$(load_config 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'an invalid WARP_SCOPE must not be accepted'
    return 1
  }
  assert_contains "$output" 'WARP_SCOPE' 'the invalid scope error must name its config field'
}

test_existing_config_validation_precedes_runtime_mutation() {
  source_without_main "$INSTALL_SCRIPT"
  local root event_log output rc=0
  root="$(mktemp -d)"
  event_log="$root/events"
  CONFIG_FILE="$root/config.env"
  printf 'WARP_MODE=broken\n' > "$CONFIG_FILE"
  : > "$event_log"
  require_root() { :; }
  require_systemd() { :; }
  validate_repo_raw_base() { :; }
  prompt_install_mode() { printf 'prompt\n' >> "$event_log"; printf 'wireguard\n'; }
  collect_swap_choice() { printf 'swap-choice\n' >> "$event_log"; }
  acquire_operation_lock() { printf 'lock\n' >> "$event_log"; }
  capture_service_ownership() { printf 'ownership\n' >> "$event_log"; }
  stage_project_files() { printf 'stage\n' >> "$event_log"; }

  output="$(main 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'an existing config with an invalid WARP_MODE must reject reinstall'
    return 1
  }
  assert_contains "$output" '现有配置缺少有效的 WARP_MODE' \
    'the invalid existing mode should be reported explicitly' || return 1
  assert_eq '' "$(< "$event_log")" \
    'invalid existing mode must fail before prompting, locking, staging, or runtime mutation' || return 1

  PROJECT_STAGE_DIR="$root/stage"
  mkdir -p "$PROJECT_STAGE_DIR/bin" "$PROJECT_STAGE_DIR/rules"
  install -m 0755 "$MANAGER_SCRIPT" "$PROJECT_STAGE_DIR/bin/warp-vps"
  CONFIG_FILE="$root/missing.env"
  validate_existing_config || {
    fail 'a genuinely missing config must remain a valid first-install state'
    return 1
  }

  CONFIG_FILE="$root/valid.env"
  printf '%s\n' \
    'WARP_MODE=wireguard' \
    'REDSOCKS_USER=warp-vps-redsocks' \
    'REDSOCKS_UID=991' \
    'REDSOCKS_GROUP=warp-vps-redsocks' \
    'REDSOCKS_BIN=/usr/sbin/redsocks' \
    'WG_IFACE=warp-vps-wg' \
    'WGCF_BIN=/opt/warp-vps-manager/bin/wgcf' \
    'WG_CONFIG=/etc/wireguard/warp-vps-wg.conf' \
    'MANAGED_WARP_SVC=0' \
    'MANAGED_REDSOCKS_BIN=0' \
    > "$CONFIG_FILE"
  validate_existing_config || {
    fail 'a valid existing config should pass staged manager validation'
    return 1
  }

  printf 'UNKNOWN_FIELD=1\n' >> "$CONFIG_FILE"
  validate_existing_config || {
    fail 'a harmless legacy field must not block migration to the canonical config'
    return 1
  }

  sed -i.bak 's/^WG_IFACE=warp-vps-wg$/WG_IFACE=invalid interface/' "$CONFIG_FILE"
  rc=0
  output="$(validate_existing_config 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'an invalid active WireGuard interface identity must reject migration'
    return 1
  }
  assert_contains "$output" '现有 WireGuard' \
    'an unsafe WireGuard runtime identity should be reported before mutation'
}

test_wireguard_config_does_not_require_socks_fields() {
  source_without_main "$MANAGER_SCRIPT"
  local root
  root="$(mktemp -d)"
  CONFIG_FILE="$root/config.env"
  cat > "$CONFIG_FILE" <<'EOF'
WARP_MODE=wireguard
WARP_SCOPE=google
WG_IFACE=warp-vps-wg
WG_CONFIG=/etc/wireguard/warp-vps-wg.conf
EOF

  load_config || {
    fail 'a WireGuard config should not require unused redsocks identity fields'
    return 1
  }
  assert_eq 'wireguard' "$WARP_MODE" 'the minimal WireGuard config must retain its mode' || return 1
  assert_eq 'root' "$REDSOCKS_USER" \
    'unused redsocks identity should receive an internal default in WireGuard mode'
}

test_warp_port_reprompts() {
  source_without_main "$INSTALL_SCRIPT"
  unset WARP_SOCKS_PORT || true

  local answer_index=0
  local answers=($'\\' '')
  read_input() {
    printf -v "$1" '%s' "${answers[$answer_index]}"
    answer_index=$((answer_index + 1))
  }
  find_free_port() { printf '23456\n'; }
  reserved_port() { return 1; }
  port_in_use() { return 1; }

  local output
  if ! output="$(prompt_warp_port 2>/dev/null)"; then
    fail 'prompt_warp_port exited instead of asking again'
    return 1
  fi
  output="${output##*$'\n'}"
  assert_eq '23456' "$output" 'empty retry should select a free port'
}

test_existing_project_port_is_reusable() {
  source_without_main "$INSTALL_SCRIPT"
  WARP_SOCKS_PORT=23456
  port_in_use() { return 0; }

  local output
  output="$(prompt_warp_port 23456 2>/dev/null)"
  assert_eq '23456' "$output" \
    'a reinstall should accept the currently configured project port'
}

test_port_checks_only_tcp() {
  local body
  body="$(function_body "$INSTALL_SCRIPT" port_in_use)"
  assert_contains "$body" 'ss -H -ltn ' 'port checks should inspect TCP listeners' || return 1
  assert_not_contains "$body" 'ltnu' 'a UDP listener must not block a TCP SOCKS port' || return 1
  assert_not_contains "$body" '/proc/net/udp' 'the proc fallback must ignore UDP listeners' || return 1
  assert_contains "$body" 'toupper($4) == "0A"' \
    'the proc fallback must only treat TCP LISTEN sockets as occupied'
}

test_noninteractive_socks_port_selection() {
  source_without_main "$INSTALL_SCRIPT"
  local generated=24000 rc=0 output
  read_input() { fail 'noninteractive port selection must not read input'; }
  find_free_port() { printf '%s\n' "$generated"; }
  port_in_use() { [ "$1" = 25000 ]; }

  INSTALL_SOCKS_PORT_OPTION=''
  unset WARP_SOCKS_PORT || true
  assert_eq '24000' "$(select_noninteractive_warp_port '')" \
    'fresh Socks installation must choose an available port automatically' || return 1
  assert_eq '23456' "$(select_noninteractive_warp_port 23456)" \
    'same-mode Socks reinstall must preserve its port by default' || return 1

  INSTALL_SOCKS_PORT_OPTION=auto
  generated=24001
  assert_eq '24001' "$(select_noninteractive_warp_port 23456)" \
    'explicit auto must select a new available port' || return 1

  INSTALL_SOCKS_PORT_OPTION=24567
  assert_eq '24567' "$(select_noninteractive_warp_port '')" \
    'an explicit free Socks port must be retained' || return 1

  INSTALL_SOCKS_PORT_OPTION=25000
  output="$(select_noninteractive_warp_port '' 2>&1)" || rc=$?
  assert_eq '1' "$rc" 'an occupied explicit Socks port must return a runtime failure' || return 1
  assert_contains "$output" '端口已被占用' 'the occupied-port error must identify its cause'
}

test_stdin_execution_without_bash_source() {
  local file guard output body dispatcher
  for file in "$INSTALL_SCRIPT" "$MANAGER_SCRIPT"; do
    guard="$(tail -n 3 "$file")"
    if [ "$file" = "$INSTALL_SCRIPT" ]; then
      dispatcher='dispatch_installer'
    else
      dispatcher='main'
    fi
    output="$(printf 'set -u\n%s() { printf called; }\n%s\n' "$dispatcher" "$guard" | bash)"
    assert_eq 'called' "$output" \
      "stdin execution should call its public dispatcher without BASH_SOURCE: $file" || return 1
  done

  body="$(function_body "$INSTALL_SCRIPT" fetch_asset)"
  output="$(printf '%s\n' \
    'set -u' \
    'SCRIPT_SOURCE=' \
    'REPO_RAW_BASE=https://example.invalid/project/main' \
    'DOWNLOAD_CONNECT_TIMEOUT=10' \
    'DOWNLOAD_MAX_TIME=120' \
    'raw_asset_url() { printf "%s/%s\\n" "${REPO_RAW_BASE%/}" "$1"; }' \
    'curl() { printf "download:%s\\n" "$*"; }' \
    'chmod() { :; }' \
    "$body" \
    'fetch_asset bin/warp-vps /tmp/unused 0755' \
    | bash)"
  assert_contains "$output" 'https://example.invalid/project/main/bin/warp-vps' \
    'stdin execution should download assets when no script path exists' || return 1

  guard="$(tail -n 3 "$INSTALL_SCRIPT")"
  output="$(printf 'dispatch_installer() { printf "%%s" "$*"; }\n%s\n' "$guard" \
    | bash -s -- --install --non-interactive --scope global --mode wireguard)"
  assert_eq '--install --non-interactive --scope global --mode wireguard' "$output" \
    'bash -s -- must deliver noninteractive installer arguments through the stdin entrypoint'
}

test_installer_entrypoint_routes_fresh_and_installed_hosts() {
  source_without_main "$INSTALL_SCRIPT"
  local installed=0 calls=''
  project_installation_present() { [ "$installed" -eq 1 ]; }
  installer_menu() { calls="${calls}menu "; }
  main() { calls="${calls}install "; }
  interactive_terminal_available() { return 0; }

  dispatch_installer
  assert_eq 'install ' "$calls" 'fresh no-argument installer entry should start installation' || return 1

  calls=''
  installed=1
  dispatch_installer
  assert_eq 'menu ' "$calls" 'installed no-argument installer entry should open the menu' || return 1

  calls=''
  installed=0
  dispatch_installer --menu
  assert_eq 'install ' "$calls" 'a menu request on a fresh host should start installation' || return 1

  calls=''
  installed=1
  dispatch_installer --menu
  assert_eq 'menu ' "$calls" 'a menu request on an installed host should open the menu' || return 1

  calls=''
  dispatch_installer --install
  assert_eq 'install ' "$calls" 'the internal install entry should bypass installed-host menu routing' || return 1

  local rc=0
  calls=''
  dispatch_installer --unknown >/dev/null 2>&1 || rc=$?
  assert_eq '2' "$rc" 'unknown installer options should fail before running an action' || return 1
  assert_eq '' "$calls" 'an unknown installer option must not run an action' || return 1
  rc=0
  calls=''
  dispatch_installer --menu extra >/dev/null 2>&1 || rc=$?
  assert_eq '2' "$rc" 'extra installer options should fail before running an action' || return 1
  assert_eq '' "$calls" 'extra installer options must not run an action'
}

test_installer_noninteractive_option_contract() {
  source_without_main "$INSTALL_SCRIPT"
  local rc=0 output mock_udp_probe_log
  mock_udp_probe_log="$(mktemp)"

  parse_install_options --non-interactive --scope global --mode socks --swap 2 --socks-port 24567
  assert_eq '1' "$INSTALL_NONINTERACTIVE" 'noninteractive parsing must set its execution mode' || return 1
  assert_eq 'global' "$INSTALL_SCOPE_OPTION" 'the requested routing scope must be retained' || return 1
  assert_eq 'socks' "$INSTALL_MODE_OPTION" 'the requested mode must be retained' || return 1
  assert_eq '2' "$INSTALL_SWAP_OPTION" 'the requested Swap size must be retained' || return 1
  assert_eq '24567' "$INSTALL_SOCKS_PORT_OPTION" 'the requested Socks port must be retained' || return 1

  parse_install_options --non-interactive --swap 08
  assert_eq '08' "$INSTALL_SWAP_OPTION" 'a nonzero leading-zero Swap value must stay decimal' || return 1

  for args in \
    '--mode socks' \
    '--scope global' \
    '--non-interactive --non-interactive' \
    '--non-interactive --scope' \
    '--non-interactive --scope invalid' \
    '--non-interactive --scope google --scope global' \
    '--non-interactive --mode' \
    '--non-interactive --mode invalid' \
    '--non-interactive --mode socks --mode wireguard' \
    '--non-interactive --swap' \
    '--non-interactive --swap 0' \
    '--non-interactive --swap 00' \
    '--non-interactive --swap invalid' \
    '--non-interactive --swap 1 --swap 2' \
    '--non-interactive --socks-port 65536' \
    '--non-interactive --socks-port' \
    '--non-interactive --socks-port auto --socks-port 24000' \
    '--non-interactive --unknown'; do
    rc=0
    # shellcheck disable=SC2086
    parse_install_options $args >/dev/null 2>&1 || rc=$?
    assert_eq '2' "$rc" "invalid install options must return usage status: $args" || return 1
  done

  INSTALL_NONINTERACTIVE=1
  INSTALL_MODE_OPTION=''
  read_input() { fail 'noninteractive mode selection must not read input'; }
  probe_outbound_udp() { printf 'probe\n' >> "$mock_udp_probe_log"; return 1; }
  assert_eq 'wireguard' "$(select_install_mode '')" \
    'fresh noninteractive installation must default to WireGuard' || return 1
  assert_eq 'socks' "$(select_install_mode socks)" \
    'noninteractive reinstall must retain the existing mode' || return 1
  INSTALL_MODE_OPTION=keep
  rc=0
  output="$(select_install_mode '' 2>&1)" || rc=$?
  assert_eq '2' "$rc" 'explicit keep on a fresh host must be a usage error' || return 1
  assert_contains "$output" '全新安装不能使用 --mode keep' \
    'fresh keep rejection must explain the conflict' || return 1
  assert_eq '' "$(< "$mock_udp_probe_log")" \
    'noninteractive mode selection must not probe UDP' || return 1

  INSTALL_SCOPE_OPTION=''
  assert_eq 'google' "$(select_route_scope '')" \
    'fresh noninteractive installation must default to precise Google routing' || return 1
  assert_eq 'global' "$(select_route_scope global)" \
    'noninteractive reinstall without --scope must retain the current global scope' || return 1
  assert_eq 'google' "$(select_route_scope google)" \
    'noninteractive reinstall without --scope must retain the current Google scope' || return 1

  INSTALL_SCOPE_OPTION=keep
  rc=0
  output="$(select_route_scope '' 2>&1)" || rc=$?
  assert_eq '2' "$rc" 'explicit scope keep on a fresh host must be a usage error' || return 1
  assert_contains "$output" '全新安装不能使用 --scope keep' \
    'fresh scope keep rejection must explain the conflict' || return 1

  INSTALL_SCOPE_OPTION=google
  assert_eq 'google' "$(select_route_scope global)" \
    'an explicit Google scope must override the current global scope' || return 1
  INSTALL_SCOPE_OPTION=global
  assert_eq 'global' "$(select_route_scope google)" \
    'an explicit global scope must override the current Google scope'
}

test_installer_rejects_semantic_conflicts_before_side_effects() {
  source_without_main "$INSTALL_SCRIPT"
  local calls='' output rc=0
  require_root() { :; }
  require_systemd() { :; }
  validate_repo_raw_base() { :; }
  read_project_mode() { printf 'socks\n'; }
  collect_swap_choice() { calls="${calls}swap "; }
  acquire_operation_lock() { calls="${calls}lock "; }

  parse_install_options --non-interactive --mode wireguard --socks-port auto
  output="$(main 2>&1)" || rc=$?
  assert_eq '2' "$rc" 'WireGuard with a Socks-only port option must be a usage error' || return 1
  assert_contains "$output" 'WireGuard 模式不能使用 --socks-port' \
    'the semantic conflict should explain the incompatible option' || return 1
  assert_eq '' "$calls" \
    'semantic option conflicts must stop before Swap collection, locking or host mutation'
}

test_project_installation_detection_requires_command_and_config() {
  source_without_main "$INSTALL_SCRIPT"
  local root
  root="$(mktemp -d)"
  BIN_PATH="$root/warp-vps"
  CONFIG_FILE="$root/config.env"

  printf '#!/usr/bin/env bash\n' > "$BIN_PATH"
  chmod 0755 "$BIN_PATH"
  printf 'WARP_MODE=wireguard\n' > "$CONFIG_FILE"
  project_installation_present || {
    fail 'a command plus config should be recognized as an installed project'
    return 1
  }

  chmod 0644 "$BIN_PATH"
  if project_installation_present; then
    fail 'a non-executable command must not be mistaken for a complete installation'
    return 1
  fi
  chmod 0755 "$BIN_PATH"
  CONFIG_FILE="$root/missing-config.env"
  if project_installation_present; then
    fail 'a command without its config must be treated as a partial installation'
    return 1
  fi
  BIN_PATH="$root/missing-command"
  CONFIG_FILE="$root/config.env"
  if project_installation_present; then
    fail 'a config without its command must be treated as a partial installation'
    return 1
  fi
  CONFIG_FILE="$root/missing-config.env"
  if project_installation_present; then
    fail 'a host with neither project artifact must remain a fresh installation'
    return 1
  fi
}

test_installer_noninteractive_entry_never_reads_tty() {
  source_without_main "$INSTALL_SCRIPT"
  local calls='' rc=0
  interactive_terminal_available() { return 1; }
  project_installation_present() { return 0; }
  installer_menu() { calls="${calls}menu "; }
  read_input() { calls="${calls}read "; return 1; }
  probe_outbound_udp() { calls="${calls}probe "; return 1; }
  main() {
    calls="${calls}install:${INSTALL_NONINTERACTIVE}:${INSTALL_SCOPE_OPTION}:${INSTALL_MODE_OPTION}:${INSTALL_SWAP_OPTION} "
  }

  dispatch_installer >/dev/null 2>&1 || rc=$?
  assert_eq '2' "$rc" 'no-argument installer without a TTY must reject ambiguous interaction' || return 1
  assert_eq '' "$calls" 'a no-TTY rejection must happen before menu or input' || return 1

  rc=0
  dispatch_installer --menu >/dev/null 2>&1 || rc=$?
  assert_eq '2' "$rc" 'an explicit menu request without a TTY must return usage status' || return 1
  assert_eq '' "$calls" 'a no-TTY menu request must not read input' || return 1

  rc=0
  dispatch_installer --install >/dev/null 2>&1 || rc=$?
  assert_eq '2' "$rc" 'interactive install without a TTY must return usage status' || return 1
  assert_eq '' "$calls" 'an interactive no-TTY install must not start main' || return 1

  dispatch_installer --install --non-interactive --scope global --mode wireguard --swap none
  assert_eq 'install:1:global:wireguard:none ' "$calls" \
    'the explicit noninteractive entry must reach main without reading input'
}

test_real_no_tty_installer_requests_are_bounded() {
  local output rc=0
  output="$(bash "$INSTALL_SCRIPT" --menu </dev/null 2>&1)" || rc=$?
  assert_eq '2' "$rc" 'a real no-TTY menu request must fail immediately with usage status' || return 1
  assert_contains "$output" '管理菜单需要交互终端' \
    'the real no-TTY menu rejection must explain the explicit-command alternative' || return 1

  rc=0
  output="$(bash "$INSTALL_SCRIPT" --install --non-interactive --mode invalid </dev/null 2>&1)" || rc=$?
  assert_eq '2' "$rc" 'invalid noninteractive arguments must fail before host preflight' || return 1
  assert_contains "$output" '--mode 只接受' 'invalid mode output must be actionable'
}

test_installer_menu_maps_public_actions_and_recovers() {
  source_without_main "$INSTALL_SCRIPT"
  local answer_index=0 calls='' renders=0
  local answers=('1' '' '2' '' '3' '' '4' '' '5' '' '8' '' '10' '0')
  require_root() { :; }
  print_installer_menu() { renders=$((renders + 1)); }
  read_input() {
    [ "$answer_index" -lt "${#answers[@]}" ] || return 1
    printf -v "$1" '%s' "${answers[$answer_index]}"
    answer_index=$((answer_index + 1))
  }
  BIN_PATH=menu_manager
  menu_manager() {
    calls="${calls}$1 "
    [ "$1" != 'logs' ] || return 42
  }

  installer_menu >/dev/null 2>&1
  assert_eq 'status test native-unlock-check unlock-check restart logs ' "$calls" \
    'menu choices must map to the existing public manager commands' || return 1
  assert_eq '8' "$renders" \
    'successful, failed, and invalid ordinary actions should all return to the same menu'
}

test_restore_helpers_accept_already_absent_new_files() {
  local rollback_root="${FIXTURE_DIR}/rollback"
  local absent_live="${rollback_root}/live-does-not-exist"
  local absent_backup="${rollback_root}/backup-does-not-exist"

  source_without_main "$INSTALL_SCRIPT"
  PROJECT_BACKUP_DIR="$rollback_root"
  restore_project_file "$absent_live" "$absent_backup" target 0644 || {
    fail 'install rollback treated an originally absent file that remains absent as a failure'
    return 1
  }
  if restore_project_file "$absent_live" "$absent_backup" unrecorded 0644; then
    fail 'install rollback accepted a file with neither backup nor missing marker'
    return 1
  fi

  source_without_main "$MANAGER_SCRIPT"
  restore_update_file "$absent_live" "$absent_backup" target 0644 "$rollback_root" || {
    fail 'update rollback treated an originally absent file that remains absent as a failure'
    return 1
  }
  if restore_update_file "$absent_live" "$absent_backup" unrecorded 0644 "$rollback_root"; then
    fail 'update rollback accepted a file with neither backup nor missing marker'
    return 1
  fi
}

test_installer_menu_terminal_actions_do_not_run_stale_code() {
  source_without_main "$INSTALL_SCRIPT"
  require_root() { :; }
  local render_count=0
  print_installer_menu() { render_count=$((render_count + 1)); printf 'MENU\n'; }
  BIN_PATH=menu_manager

  local answer_index=0 manager_rc=0 calls=''
  local answers=('6')
  read_input() {
    [ "$answer_index" -lt "${#answers[@]}" ] || return 1
    printf -v "$1" '%s' "${answers[$answer_index]}"
    answer_index=$((answer_index + 1))
  }
  menu_manager() { calls="${calls}$1 "; return "$manager_rc"; }
  installer_menu >/dev/null 2>&1
  assert_eq 'update ' "$calls" 'successful update should run exactly once' || return 1
  assert_eq '1' "$render_count" 'successful update should exit the old menu after one render' || return 1

  answer_index=0
  manager_rc=28
  calls=''
  render_count=0
  answers=('6' '' '0')
  installer_menu >/dev/null 2>&1
  assert_eq 'update ' "$calls" 'failed update should not run another manager action' || return 1
  assert_eq '2' "$render_count" 'failed update should return to the menu' || return 1

  answer_index=0
  manager_rc=0
  calls=''
  render_count=0
  answers=('9')
  installer_menu >/dev/null 2>&1
  assert_eq 'uninstall ' "$calls" 'successful uninstall should terminate the menu immediately' || return 1
  assert_eq '1' "$render_count" 'successful uninstall should exit the old menu after one render' || return 1

  answer_index=0
  manager_rc=17
  calls=''
  render_count=0
  answers=('9' '' '0')
  installer_menu >/dev/null 2>&1
  assert_eq 'uninstall ' "$calls" 'failed uninstall should return without dispatching another action' || return 1
  assert_eq '2' "$render_count" 'failed uninstall should return to the menu' || return 1

  answer_index=0
  answers=('7' '' '0')
  main() {
    printf 'INSTALL-BEGIN\n'
    false
    printf 'INSTALL-AFTER-FAILURE\n'
  }
  local output menu_count
  output="$(installer_menu 2>&1)"
  assert_contains "$output" 'INSTALL-BEGIN' 'reinstall should call the existing install transaction' || return 1
  assert_not_contains "$output" 'INSTALL-AFTER-FAILURE' \
    'reinstall must preserve install transaction fail-fast semantics' || return 1
  menu_count="$(grep -o 'MENU' <<< "$output" | wc -l | tr -d ' ')"
  assert_eq '2' "$menu_count" 'a failed reinstall should return to a fresh menu iteration' || return 1

  answer_index=0
  answers=('7')
  main() { printf 'INSTALL-SUCCESS\n'; }
  output="$(installer_menu 2>&1)"
  assert_contains "$output" 'INSTALL-SUCCESS' \
    'successful reinstall should execute the existing install transaction' || return 1
  menu_count="$(grep -o 'MENU' <<< "$output" | wc -l | tr -d ' ')"
  assert_eq '1' "$menu_count" 'a successful reinstall must not continue in the old menu process'
}

test_manager_menu_entry_preserves_explicit_cli_dispatch() {
  source_without_main "$MANAGER_SCRIPT"
  local calls='' interactive=1
  cmd_menu() { calls="${calls}menu "; }
  usage() { calls="${calls}usage "; }
  interactive_terminal_available() { [ "$interactive" -eq 1 ]; }

  main menu
  main
  main help
  interactive=0
  main >/dev/null 2>&1 || true
  assert_eq 'menu menu usage usage ' "$calls" \
    'menu, interactive no-argument, help, and noninteractive no-argument dispatch must stay distinct' || return 1

  calls=''
  cmd_status() { calls="${calls}status "; }
  cmd_test() { calls="${calls}test "; }
  cmd_native_unlock_check() { calls="${calls}native-unlock-check "; }
  cmd_unlock_check() { calls="${calls}unlock-check "; }
  cmd_restart() { calls="${calls}restart "; }
  cmd_update() { calls="${calls}update "; }
  cmd_logs() { calls="${calls}logs "; }
  cmd_uninstall() { calls="${calls}uninstall:$* "; }
  cmd_reinstall() { calls="${calls}reinstall:$* "; }
  cmd_switch() { calls="${calls}switch:$* "; }
  run_with_runtime_lock() {
    local policy="$1"
    shift
    calls="${calls}lock:${policy} "
    "$@"
  }
  main status
  main test
  main native-unlock-check
  main unlock-check
  main restart
  main update
  main logs
  main uninstall --yes
  main reinstall --mode socks
  main switch wireguard --swap none
  assert_eq 'status test native-unlock-check unlock-check lock:wait restart lock:wait update logs lock:wait uninstall:--yes reinstall:--mode socks switch:wireguard --swap none ' \
    "$calls" 'all public CLI commands must retain their dispatcher and arguments' || return 1
  assert_contains "$calls" 'reinstall:--mode socks ' \
    'noninteractive reinstall arguments must reach their dispatcher' || return 1
  assert_contains "$calls" 'switch:wireguard --swap none ' \
    'noninteractive switch arguments must reach their dispatcher' || return 1

  local menu_body main_body
  menu_body="$(function_body "$MANAGER_SCRIPT" cmd_menu)"
  main_body="$(function_body "$MANAGER_SCRIPT" main)"
  assert_contains "$menu_body" 'exec "${APP_DIR}/install.sh" --menu' \
    'manager menu entry should delegate once to the installed canonical menu' || return 1
  assert_not_contains "$menu_body" 'run_with_runtime_lock' \
    'opening the menu must not hold the shared mutation lock' || return 1
  assert_contains "$main_body" 'run_with_runtime_lock wait cmd_uninstall "$@"' \
    'existing uninstall arguments must keep their original dispatcher'
}

test_manager_noninteractive_commands_and_strict_arguments() {
  source_without_main "$MANAGER_SCRIPT"
  local calls='' cmd rc output
  require_root() { :; }
  interactive_terminal_available() { return 1; }
  cmd_status() { calls="${calls}status "; }
  cmd_test() { calls="${calls}test "; }
  cmd_native_unlock_check() { calls="${calls}native-unlock "; }
  cmd_unlock_check() { calls="${calls}unlock "; }
  cmd_restart() { calls="${calls}restart "; }
  cmd_update() { calls="${calls}update "; }
  cmd_logs() { calls="${calls}logs "; }
  cmd_heal() { calls="${calls}heal "; }
  apply_rules() { calls="${calls}apply "; }
  start_rules() { calls="${calls}start-rules "; }
  stop_rules() { calls="${calls}stop-rules "; }
  cmd_configure_warp() { calls="${calls}configure "; }
  cmd_setup_wireguard() { calls="${calls}setup "; }
  cmd_preflight_wireguard() { calls="${calls}preflight "; }
  cmd_wait_wireguard() { calls="${calls}wait "; }
  install_systemd() { calls="${calls}systemd "; }
  run_with_runtime_lock() { shift; "$@"; }

  for cmd in menu status test native-unlock-check unlock-check restart update logs heal apply start-rules stop-rules \
    configure-warp setup-wireguard preflight-wireguard wait-wireguard install-systemd help; do
    calls=''
    rc=0
    main "$cmd" unexpected >/dev/null 2>&1 || rc=$?
    assert_eq '2' "$rc" "$cmd must reject extra arguments" || return 1
    assert_eq '' "$calls" "$cmd must reject bad arguments before running its action" || return 1
  done

  rc=0
  output="$(main menu 2>&1)" || rc=$?
  assert_eq '2' "$rc" 'an explicit manager menu without a TTY must return usage status' || return 1
  assert_contains "$output" '管理菜单需要交互终端' \
    'the manager no-TTY menu rejection must recommend explicit commands' || return 1

  cmd_reinstall() { calls="${calls}reinstall:$* "; }
  calls=''
  main reinstall --mode socks --swap none --socks-port auto
  assert_eq 'reinstall:--mode socks --swap none --socks-port auto ' "$calls" \
    'reinstall must remain a noninteractive argument-forwarding command' || return 1

  calls=''
  main switch socks --swap none
  assert_eq 'reinstall:--mode socks --swap none ' "$calls" \
    'switch must translate its target into the canonical reinstall options' || return 1
  rc=0
  main switch invalid >/dev/null 2>&1 || rc=$?
  assert_eq '2' "$rc" 'switch must reject an unknown target mode' || return 1
  rc=0
  main switch >/dev/null 2>&1 || rc=$?
  assert_eq '2' "$rc" 'switch must reject a missing target mode' || return 1
  rc=0
  main unknown-command >/dev/null 2>&1 || rc=$?
  assert_eq '2' "$rc" 'the manager must reject an unknown command' || return 1

  local switch_body reinstall_body logs_body
  switch_body="$(function_body "$MANAGER_SCRIPT" cmd_switch)"
  reinstall_body="$(function_body "$MANAGER_SCRIPT" cmd_reinstall)"
  logs_body="$(function_body "$MANAGER_SCRIPT" cmd_logs)"
  assert_contains "$switch_body" 'cmd_reinstall --mode "$mode" "$@"' \
    'switch must reuse the canonical reinstall transaction' || return 1
  assert_contains "$reinstall_body" 'exec "${APP_DIR}/install.sh" --install --non-interactive "$@"' \
    'reinstall must delegate once to the installed noninteractive installer' || return 1
  assert_contains "$logs_body" '--no-pager' 'logs must never open an interactive pager' || return 1
  assert_not_contains "$logs_body" 'read_input' 'logs must not read input'
}

test_manager_no_argument_non_tty_is_immediate_usage() {
  local output rc=0
  output="$(bash "$MANAGER_SCRIPT" </dev/null 2>&1)" || rc=$?
  assert_eq '2' "$rc" 'noninteractive no-argument manager invocation must reject a no-op' || return 1
  assert_contains "$output" '用法：warp-vps [命令]' \
    'noninteractive no-argument manager invocation should show usage' || return 1
  assert_not_contains "$output" 'WARP VPS Manager 管理菜单' \
    'noninteractive no-argument manager invocation must not wait in the menu' || return 1

  rc=0
  output="$(bash "$MANAGER_SCRIPT" menu </dev/null 2>&1)" || rc=$?
  assert_eq '2' "$rc" 'an explicit no-TTY manager menu must return usage status' || return 1
  assert_contains "$output" '管理菜单需要交互终端' \
    'the explicit no-TTY menu request must explain why it was rejected'
}

test_menu_contract_is_documented_without_a_second_switch_path() {
  local menu_body
  menu_body="$(function_body "$INSTALL_SCRIPT" installer_menu)"
  assert_contains "$menu_body" 'main' \
    'reinstall and mode switching must reuse the existing install transaction' || return 1
  assert_not_contains "$menu_body" 'acquire_operation_lock' \
    'the menu must not hold the install transaction lock' || return 1
  assert_not_contains "$menu_body" 'run_with_runtime_lock' \
    'the menu must not add a second manager lock' || return 1
  assert_file_matches "$README_FILE" 'warp-vps` 或 `warp-vps menu`' \
    'README should document both interactive menu entries' || return 1
  assert_file_matches "$README_FILE" '检测到已有项目安装时.*进入管理菜单' \
    'README should distinguish fresh installation from the installed curl entry'
}

test_inputs_precede_side_effects() {
  local body swap_line scope_line mode_line port_line marker marker_line
  body="$(function_body "$INSTALL_SCRIPT" main)"
  [ -n "$body" ] || {
    fail 'could not extract install.sh main()'
    return 1
  }

  swap_line="$(line_number "$body" 'collect_swap_choice')"
  scope_line="$(line_number "$body" 'select_route_scope')"
  mode_line="$(line_number "$body" 'select_install_mode')"
  port_line="$(awk '/select_noninteractive_warp_port|prompt_warp_port/ { line=NR } END { print line }' <<< "$body")"
  [ -n "$swap_line" ] || {
    fail 'main() does not collect the Swap choice'
    return 1
  }
  [ -n "$scope_line" ] || {
    fail 'main() does not collect the routing scope'
    return 1
  }
  [ -n "$mode_line" ] || {
    fail 'main() does not collect the install mode'
    return 1
  }
  [ -n "$port_line" ] || {
    fail 'main() does not collect the Socks port'
    return 1
  }
  if [ "$swap_line" -ge "$scope_line" ] || [ "$scope_line" -ge "$mode_line" ] \
    || [ "$mode_line" -ge "$port_line" ]; then
    fail 'interactive choices must be collected in Swap, scope, backend, Socks-port order'
    return 1
  fi

  for marker in apply_swap_choice install_dependencies preflight_nft_nat ensure_redsocks_user stage_project_files backup_project_files activate_project_files write_config configure-warp; do
    marker_line="$(line_number "$body" "$marker")"
    [ -z "$marker_line" ] && continue
    if [ "$marker_line" -le "$port_line" ]; then
      fail "${marker} runs before all interactive input is valid"
      return 1
    fi
  done

  if grep -q 'check_memory_before_install' <<< "$body"; then
    fail 'main() still invokes the mutating Swap/memory workflow before installation'
    return 1
  fi
}

test_installer_operation_lock_bounds_live_mutation() {
  local main_body lock_body acquire_line ownership_line release_line unlock_line
  main_body="$(function_body "$INSTALL_SCRIPT" main)"
  lock_body="$(function_body "$INSTALL_SCRIPT" acquire_operation_lock)"
  acquire_line="$(line_number "$main_body" 'acquire_operation_lock')"
  ownership_line="$(line_number "$main_body" 'capture_service_ownership')"
  release_line="$(line_number "$main_body" 'release_operation_lock')"
  unlock_line="$(line_number "$main_body" '"$BIN_PATH" unlock-check')"
  if [ -z "$acquire_line" ] || [ -z "$ownership_line" ] \
    || [ -z "$release_line" ] || [ -z "$unlock_line" ] \
    || [ "$acquire_line" -ge "$ownership_line" ] \
    || [ "$release_line" -ge "$unlock_line" ]; then
    fail 'the operation lock must cover live-state inspection and release before unlock diagnostics'
    return 1
  fi
  assert_contains "$lock_body" 'command -v flock' \
    'the lock should remain optional on hosts without flock' || return 1
  assert_contains "$lock_body" '/run/warp-vps-manager.operation.lock' \
    'concurrent installers should share one host-level operation lock' || return 1
  assert_contains "$lock_body" 'flock -w 10 9' \
    'a busy operation lock must wait briefly for a health check without waiting indefinitely' || return 1

  source_without_main "$INSTALL_SCRIPT"
  require_root() { :; }
  require_systemd() { :; }
  validate_repo_raw_base() { :; }
  prompt_install_mode() { printf 'wireguard\n'; }
  collect_swap_choice() { :; }
  acquire_operation_lock() { die 'EVENT:lock-busy'; }
  capture_service_ownership() { printf 'EVENT:ownership-mutated\n'; }
  stage_project_files() { printf 'EVENT:files-staged\n'; }

  local output rc=0
  output="$(main 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'a busy operation lock must reject a concurrent install'
    return 1
  }
  assert_contains "$output" 'EVENT:lock-busy' \
    'the lock conflict should be reported to the operator' || return 1
  assert_not_contains "$output" 'EVENT:ownership-mutated' \
    'a lock conflict must stop before inspecting or changing service ownership' || return 1
  assert_not_contains "$output" 'EVENT:files-staged' \
    'a lock conflict must stop before staging the transition'
}

test_manager_operation_lock_policies() {
  source_without_main "$MANAGER_SCRIPT"
  local flock_available=1 busy=1 action_calls=0 unlock_calls=0
  local output_file output rc=0 main_body
  RUNTIME_LOCK_FILE="$(mktemp)"
  require_root() { :; }
  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = flock ]; then
      [ "$flock_available" -eq 1 ]
      return
    fi
    builtin command "$@"
  }
  flock() {
    case "$*" in
      '-n 9'|'-w 10 9') [ "$busy" -eq 0 ] ;;
      '-u 9') unlock_calls=$((unlock_calls + 1)); return 0 ;;
      *) return 1 ;;
    esac
  }
  locked_action() {
    action_calls=$((action_calls + 1))
    printf 'EVENT:action\n'
  }

  output_file="$(mktemp)"
  run_with_runtime_lock skip locked_action > "$output_file" 2>&1 || return 1
  output="$(< "$output_file")"
  assert_eq '0' "$action_calls" \
    'a busy heal lock should skip the repair body' || return 1
  assert_contains "$output" '本次健康检查跳过' \
    'a busy heal lock should be a visible successful skip' || return 1

  output="$({ run_with_runtime_lock wait locked_action; } 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'a busy interactive mutation lock must fail instead of overlapping another operation'
    return 1
  }
  assert_not_contains "$output" 'EVENT:action' \
    'a busy restart/update/uninstall lock must not run the mutation body' || return 1

  busy=0
  run_with_runtime_lock wait locked_action >/dev/null || return 1
  assert_eq '1' "$action_calls" \
    'an available wait lock should execute the mutation body exactly once' || return 1
  assert_eq '1' "$unlock_calls" \
    'a completed mutation should explicitly release its operation lock' || return 1

  failing_action() { return 7; }
  rc=0
  run_with_runtime_lock wait failing_action || rc=$?
  assert_eq '7' "$rc" \
    'unlocking must preserve the wrapped operation exit status' || return 1
  assert_eq '2' "$unlock_calls" \
    'a failed wrapped operation must still release its lock' || return 1

  flock_available=0
  run_with_runtime_lock wait locked_action >/dev/null || return 1
  assert_eq '2' "$action_calls" \
    'hosts without flock must still run the requested operation'

  main_body="$(function_body "$MANAGER_SCRIPT" main)"
  assert_contains "$main_body" 'run_with_runtime_lock wait cmd_restart' \
    'restart must use the shared short-wait operation lock' || return 1
  assert_contains "$main_body" 'run_with_runtime_lock wait cmd_update' \
    'update must use the shared short-wait operation lock' || return 1
  assert_contains "$main_body" 'run_with_runtime_lock wait cmd_uninstall' \
    'uninstall must use the shared short-wait operation lock' || return 1
  assert_contains "$main_body" 'run_with_runtime_lock skip cmd_heal' \
    'automatic healing must skip a busy operation lock without failing' || return 1
  assert_contains "$main_body" 'cmd_configure_warp' \
    'installer-internal WARP setup must not recursively acquire the same operation lock' || return 1
  assert_not_contains "$main_body" 'configure-warp) run_with_runtime_lock' \
    'installer-internal WARP setup must not self-deadlock on the shared lock'
}

test_assets_are_staged_before_runtime_stops() {
  local main_body stage_body cleanup_body stage_line backup_line trap_line stop_line activate_line fetch_line
  main_body="$(function_body "$INSTALL_SCRIPT" main)"
  stage_body="$(function_body "$INSTALL_SCRIPT" stage_project_files)"
  cleanup_body="$(function_body "$INSTALL_SCRIPT" restore_previous_runtime)"
  stage_line="$(line_number "$main_body" 'stage_project_files')"
  backup_line="$(line_number "$main_body" 'backup_project_files')"
  trap_line="$(line_number "$main_body" 'trap cleanup_failed_install EXIT')"
  stop_line="$(line_number "$main_body" 'stop_project_runtime')"
  activate_line="$(line_number "$main_body" 'activate_project_files')"
  if [ -z "$stage_line" ] || [ -z "$backup_line" ] || [ -z "$trap_line" ] \
    || [ -z "$stop_line" ] || [ -z "$activate_line" ]; then
    fail 'project staging and activation are not fully wired into main()'
    return 1
  fi
  if [ "$stage_line" -ge "$backup_line" ] || [ "$backup_line" -ge "$stop_line" ]; then
    fail 'project assets must be fully staged before the previous runtime is stopped'
    return 1
  fi
  if [ "$trap_line" -ge "$stop_line" ] || [ "$stop_line" -ge "$activate_line" ]; then
    fail 'live project files must activate only after cleanup is armed and old runtime stops'
    return 1
  fi

  fetch_line="$(line_number "$stage_body" 'fetch_asset "rules/rules.meta.json"')"
  [ -n "$fetch_line" ] || {
    fail 'the complete project asset set must be downloaded during staging'
    return 1
  }
  assert_contains "$cleanup_body" 'restore_project_files' \
    'partial live activation must restore the installation backup' || return 1
  assert_file_matches "$INSTALL_SCRIPT" 'missing/\$label' \
    'the install backup must record files that did not exist before activation' || return 1
  assert_file_matches "$INSTALL_SCRIPT" 'mv "\$live" "\$PROJECT_BACKUP_DIR/failed-new/\$label"' \
    'rollback must move newly created files that were absent before activation' || return 1
  assert_file_matches "$INSTALL_SCRIPT" 'config_tmp="\$\{destination\}\.new\.\$\$"' \
    'config writes must stage beside the live config' || return 1
  assert_file_matches "$INSTALL_SCRIPT" 'mv "\$config_tmp" "\$destination"' \
    'config writes must activate atomically'
}

test_staged_rules_are_validated_before_runtime_stops() {
  local main_body stage_body validation_line stop_line
  main_body="$(function_body "$INSTALL_SCRIPT" main)"
  stage_body="$(function_body "$INSTALL_SCRIPT" stage_project_files)"
  validation_line="$(line_number "$stage_body" 'validate_staged_rules')"
  stop_line="$(line_number "$main_body" 'stop_project_runtime')"
  [ -n "$validation_line" ] || {
    fail 'staged rule assets are not validated'
    return 1
  }
  [ -n "$stop_line" ] || {
    fail 'main() does not stop the previous runtime'
    return 1
  }
  assert_contains "$stage_body" 'rules.meta.json' \
    'staging must include rule metadata before validation'
}

test_failed_install_arms_runtime_cleanup() {
  local body stop_line trap_line dependency_line
  body="$(function_body "$INSTALL_SCRIPT" main)"
  stop_line="$(line_number "$body" 'stop_project_runtime')"
  trap_line="$(line_number "$body" 'trap cleanup_failed_install EXIT')"
  dependency_line="$(line_number "$body" 'install_dependencies')"
  if [ -z "$stop_line" ] || [ -z "$trap_line" ] || [ -z "$dependency_line" ]; then
    fail 'install failure cleanup is not wired into main()'
    return 1
  fi
  if [ "$dependency_line" -ge "$trap_line" ] || [ "$trap_line" -ge "$stop_line" ]; then
    fail 'dependencies must finish before the old runtime stops, then cleanup must be armed before teardown'
    return 1
  fi
  assert_file_matches "$INSTALL_SCRIPT" '配置、回滚文件和日志已保留' \
    'failed installation cleanup should preserve diagnostics and rollback evidence'
}

test_existing_services_are_reusable() {
  assert_file_not_matches "$INSTALL_SCRIPT" \
    'ensure_no_existing_(redsocks_service|warp_client)' \
    'installed redsocks/WARP components must not be blanket blockers'
}

test_installer_captures_service_ownership() {
  source_without_main "$INSTALL_SCRIPT"
  declare -F capture_service_ownership >/dev/null || {
    fail 'capture_service_ownership is missing'
    return 1
  }
  declare -F disable_new_packaged_redsocks_service >/dev/null || {
    fail 'disable_new_packaged_redsocks_service is missing'
    return 1
  }

  CONFIG_FILE="${FIXTURE_DIR}/config/missing.env"
  unit_file_exists() { return 0; }
  warp-cli() { :; }
  capture_service_ownership socks
  assert_eq '1' "$REDSOCKS_UNIT_PREEXISTED" 'existing redsocks unit must be recorded' || return 1
  assert_eq '1' "$WARP_CLIENT_PREEXISTED" 'existing WARP client must be recorded' || return 1
  assert_eq '0' "$MANAGED_WARP_SVC_VALUE" 'an unrelated existing WARP service must remain unowned' || return 1

  unit_file_exists() { return 1; }
  capture_service_ownership socks
  assert_eq '0' "$WARP_CLIENT_PREEXISTED" \
    'warp-cli without a pre-existing service unit must not claim service ownership' || return 1
  assert_eq '1' "$MANAGED_WARP_SVC_VALUE" \
    'a service unit introduced while repairing a CLI-only client must be managed' || return 1

  unset -f warp-cli
  unit_file_exists() { [ "$1" = 'warp-svc.service' ]; }
  capture_service_ownership socks
  assert_eq '1' "$WARP_CLIENT_PREEXISTED" \
    'a pre-existing WARP service unit must remain unowned even when its CLI is missing' || return 1
  assert_eq '0' "$MANAGED_WARP_SVC_VALUE" \
    'repairing a pre-existing WARP unit must not transfer its ownership' || return 1

  unit_file_exists() { return 1; }
  capture_service_ownership socks
  assert_eq '0' "$REDSOCKS_UNIT_PREEXISTED" 'absent redsocks unit must remain unowned' || return 1
  assert_eq '0' "$WARP_CLIENT_PREEXISTED" 'absent WARP client must be recorded' || return 1
  assert_eq '1' "$MANAGED_WARP_SVC_VALUE" 'a newly installed WARP service must be owned' || return 1

  CONFIG_FILE="${FIXTURE_DIR}/config/managed-warp.env"
  unit_file_exists() {
    [ "$1" = 'warp-svc.service' ]
  }
  capture_service_ownership socks
  assert_eq '1' "$MANAGED_WARP_SVC_VALUE" 'a previously managed WARP service must stay owned' || return 1

  local systemctl_calls=''
  systemctl() {
    systemctl_calls="${systemctl_calls}$*\n"
    case "$*" in
      'is-active --quiet redsocks.service') return 1 ;;
    esac
    return 0
  }
  unit_file_exists() { return 0; }
  REDSOCKS_UNIT_PREEXISTED=1
  disable_new_packaged_redsocks_service
  assert_eq '' "$systemctl_calls" 'pre-existing redsocks.service must be preserved' || return 1

  REDSOCKS_UNIT_PREEXISTED=0
  disable_new_packaged_redsocks_service
  assert_contains "$systemctl_calls" 'stop redsocks.service' \
    'only a newly introduced packaged redsocks service should be stopped' || return 1
  assert_contains "$systemctl_calls" 'disable redsocks.service' \
    'only a newly introduced packaged redsocks service should be disabled'
}

test_installer_systemd_query_errors_fail_closed() {
  source_without_main "$INSTALL_SCRIPT"
  systemctl() { return 1; }

  local output rc=0
  output="$(unit_file_exists warp-svc.service 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'a systemd unit-file query error must not be treated as an absent third-party unit'
    return 1
  }
  assert_contains "$output" '无法查询 systemd 服务文件' \
    'unit ownership query failures must be explicit' || return 1

  if project_unit_stopped warp-vps-redsocks.service >/dev/null; then
    fail 'an active-state query error must not be treated as a stopped backend'
    return 1
  fi
  if project_unit_disabled warp-vps-redsocks.service >/dev/null; then
    fail 'an enabled-state query error must not be treated as a disabled backend'
    return 1
  fi
}

test_installer_absent_systemd_units_are_not_query_failures() {
  source_without_main "$INSTALL_SCRIPT"
  systemctl() {
    case "$*" in
      'list-unit-files --no-legend')
        printf 'warp-svc.service enabled\nwg-quick@.service indirect\n'
        return 0
        ;;
      *) return 64 ;;
    esac
  }

  if unit_file_exists redsocks.service; then
    fail 'an absent optional unit must be treated as absent instead of a systemd query failure'
    return 1
  fi
  unit_file_exists warp-svc.service \
    || fail 'a listed service unit must be reported as present' || return 1
  unit_file_exists 'wg-quick@.service' \
    || fail 'a listed template unit must be reported as present'
}

test_systemd_state_checks_support_old_key_value_output() {
  source_without_main "$INSTALL_SCRIPT"
  local mock_load_state=loaded mock_active_state=inactive mock_enabled_state=static enabled_calls=0
  systemctl() {
    case "$1" in
      show) printf 'LoadState=%s\nActiveState=%s\n' "$mock_load_state" "$mock_active_state" ;;
      is-enabled) enabled_calls=$((enabled_calls + 1)); printf '%s\n' "$mock_enabled_state"; return 1 ;;
      *) return 1 ;;
    esac
  }

  project_unit_stopped example.service || return 1
  project_unit_disabled example.service || {
    fail 'a static unit is not enabled and must not become a transition blocker'
    return 1
  }
  mock_enabled_state=indirect
  project_unit_disabled example.service || {
    fail 'an indirect unit is not enabled and must not become a transition blocker'
    return 1
  }
  mock_enabled_state=linked
  project_unit_disabled example.service || {
    fail 'a linked unit without an enablement link must not become a transition blocker'
    return 1
  }
  mock_load_state=not-found
  enabled_calls=0
  project_unit_stopped missing.service || return 1
  project_unit_disabled missing.service || return 1
  assert_eq '0' "$enabled_calls" 'a missing unit should not need is-enabled output' || return 1

  source_without_main "$MANAGER_SCRIPT"
  mock_load_state=loaded
  mock_active_state=active
  mock_enabled_state=enabled
  systemctl() {
    case "$1" in
      show) printf 'LoadState=%s\nActiveState=%s\n' "$mock_load_state" "$mock_active_state" ;;
      is-enabled) printf '%s\n' "$mock_enabled_state"; return 0 ;;
      *) return 1 ;;
    esac
  }
  uninstall_unit_is_active example.service || {
    fail 'manager must parse ActiveState from systemd v219-style Key=Value output'
    return 1
  }
  uninstall_unit_is_enabled example.service || {
    fail 'an enabled unit must still be detected during teardown'
    return 1
  }
  mock_active_state=inactive
  mock_enabled_state=static
  if uninstall_unit_is_active example.service; then
    fail 'an inactive unit must not be treated as active during teardown'
    return 1
  fi
  if uninstall_unit_is_enabled example.service; then
    fail 'a static unit must not be treated as enabled during teardown'
    return 1
  fi
  mock_load_state=not-found
  if uninstall_unit_is_active missing.service; then
    fail 'a missing unit must already satisfy the inactive postcondition'
    return 1
  fi
  if uninstall_unit_is_enabled missing.service; then
    fail 'a missing unit must already satisfy the disabled postcondition'
    return 1
  fi
  assert_file_not_matches "$MANAGER_SCRIPT" 'systemctl show[^\n]*--value' \
    'runtime maintenance must not require systemd v230 --value support'
}

test_redsocks_cleanup_precedes_warp_install() {
  local body install_line cleanup_line warp_line
  body="$(function_body "$INSTALL_SCRIPT" pkg_install_apt)"
  install_line="$(line_number "$body" 'apt_get install -y redsocks')"
  cleanup_line="$(line_number "$body" 'disable_new_packaged_redsocks_service')"
  warp_line="$(line_number "$body" 'apt_get install -y --reinstall cloudflare-warp')"
  if [ -z "$install_line" ] || [ -z "$cleanup_line" ] || [ -z "$warp_line" ]; then
    fail 'APT dependency phases are incomplete'
    return 1
  fi
  if [ "$install_line" -ge "$cleanup_line" ] || [ "$cleanup_line" -ge "$warp_line" ]; then
    fail 'a newly introduced redsocks.service must be stopped before WARP installation can fail'
  fi
}

test_managed_redsocks_requires_two_ownership_signals() {
  local install_body manager_body
  install_body="$(function_body "$INSTALL_SCRIPT" mark_managed_redsocks_if_current)"
  manager_body="$(function_body "$MANAGER_SCRIPT" managed_redsocks_fallback_exists)"
  for install_body in "$install_body" "$manager_body"; do
    assert_contains "$install_body" 'marker_value' \
      'managed redsocks ownership must validate the marker content' || return 1
    assert_contains "$install_body" 'grep -aFq "$REDSOCKS_MANAGED_VERSION"' \
      'managed redsocks ownership must validate the binary version' || return 1
  done
}

test_managed_warp_service_ownership() {
  source_without_main "$MANAGER_SCRIPT"
  declare -F disable_managed_warp_service >/dev/null || {
    fail 'disable_managed_warp_service is missing'
    return 1
  }

  local systemctl_calls=''
  systemctl() {
    systemctl_calls="${systemctl_calls}$*\n"
    return 0
  }
  info_line() { :; }

  MANAGED_WARP_SVC=0
  disable_managed_warp_service
  assert_eq '' "$systemctl_calls" 'unowned warp-svc must be preserved' || return 1

  MANAGED_WARP_SVC=1
  disable_managed_warp_service
  assert_contains "$systemctl_calls" 'stop warp-svc' 'owned warp-svc should be stopped' || return 1
  assert_contains "$systemctl_calls" 'disable warp-svc' 'owned warp-svc should be disabled' || return 1

  CONFIG_FILE="${FIXTURE_DIR}/config/missing.env"
  unset WARP_MODE WG_IFACE WG_CONFIG MANAGED_WARP_SVC MANAGED_REDSOCKS_BIN REDSOCKS_BIN || true
  managed_redsocks_fallback_exists() { return 1; }
  load_uninstall_config
  assert_eq '0' "$MANAGED_WARP_SVC" \
    'missing config must not invent ownership of an existing WARP service' || return 1

  CONFIG_FILE=/dev/null
  load_uninstall_config
  assert_eq '0' "$MANAGED_WARP_SVC" \
    'an empty config must not invent ownership of an existing WARP service' || return 1

  CONFIG_FILE=/dev/fd/3
  load_uninstall_config 3<<<'WARP_MODE=broken'
  assert_eq '0' "$MANAGED_WARP_SVC" \
    'an invalid mode must not invent ownership of an existing WARP service' || return 1

  CONFIG_FILE=/dev/fd/3
  load_uninstall_config 3<<<'WARP_MODE=socks'
  assert_eq '1' "$MANAGED_WARP_SVC" \
    'a valid legacy Socks config should retain its historical ownership'

  local deactivate_body
  deactivate_body="$(function_body "$MANAGER_SCRIPT" deactivate_runtime_for_uninstall)"
  assert_contains "$deactivate_body" 'uninstall_unit_is_enabled warp-svc.service' \
    'owned warp-svc uninstall must verify that boot activation is disabled'
}

test_package_manager_detection_is_capability_based() {
  assert_file_matches "$INSTALL_SCRIPT" 'command -v apt-get' 'apt must be detected by command availability' || return 1
  assert_file_matches "$INSTALL_SCRIPT" 'command -v dnf' 'dnf must be detected by command availability' || return 1
  assert_file_matches "$INSTALL_SCRIPT" 'command -v yum' 'yum must be detected by command availability' || return 1
  assert_file_not_matches "$INSTALL_SCRIPT" 'case "\$OS_VERSION_MAJOR"|支持版本：|支持主版本：' \
    'distribution version allowlists must not gate installation'
}

test_ubuntu_codename_takes_precedence() {
  assert_file_matches "$INSTALL_SCRIPT" \
    'OS_CODENAME="\$\{UBUNTU_CODENAME:-\$\{VERSION_CODENAME:-\}\}"' \
    'Ubuntu derivatives must prefer UBUNTU_CODENAME over VERSION_CODENAME'
}

test_apt_wireguard_dependencies_are_minimal() {
  source_without_main "$INSTALL_SCRIPT"
  declare -F pkg_install_apt >/dev/null || {
    fail 'pkg_install_apt is missing'
    return 1
  }

  local package_calls=''
  apt-get() {
    package_calls="${package_calls}$*\n"
    return 0
  }
  log() { :; }
  OS_ID=ubuntu
  OS_VERSION_ID=24.04
  OS_VERSION_MAJOR=24
  OS_CODENAME=noble

  pkg_install_apt wireguard
  assert_contains "$package_calls" 'wireguard-tools' 'WireGuard mode should install wireguard-tools' || return 1
  assert_not_contains "$package_calls" 'nftables' 'WireGuard mode must not install nftables' || return 1
  assert_not_contains "$package_calls" 'iptables' 'WireGuard mode must not install iptables' || return 1
  assert_not_contains "$package_calls" 'redsocks' 'WireGuard mode must not install redsocks' || return 1
  assert_not_contains "$package_calls" 'cloudflare-warp' 'WireGuard mode must not install cloudflare-warp' || return 1

  package_calls=''
  PREVIOUS_MODE=socks
  pkg_install_apt wireguard google
  assert_contains "$package_calls" 'nftables' \
    'switching from Socks must retain nftables until its old table can be cleared'
}

test_existing_cloudflare_apt_repo_refreshes_before_updates() {
  source_without_main "$INSTALL_SCRIPT"
  local root repo events='' mode
  root="$(mktemp -d)"
  repo="$root/cloudflare-client.list"
  printf 'stale cloudflare source\n' > "$repo"
  OS_CODENAME=noble

  command() {
    [ "$1" = '-v' ] || return 1
    case "$2" in curl|gpg) return 0 ;; *) builtin command "$@" ;; esac
  }
  refresh_cloudflare_apt_repo() { events="${events}refresh-cloudflare"$'\n'; }
  apt_get() { events="${events}apt:$*"$'\n'; }
  warp_client_complete() { return 0; }
  redsocks_path() { return 1; }
  disable_new_packaged_redsocks_service() { :; }
  log() { :; }

  for mode in wireguard socks; do
    events=''
    pkg_install_apt "$mode" google "$repo" || {
      fail "an existing Cloudflare source should be refreshed before $mode dependencies"
      return 1
    }
    assert_eq 'refresh-cloudflare' "$(head -n 1 <<< "$events")" \
      "an existing Cloudflare source must be refreshed before the first $mode apt update" || return 1
  done

  command() {
    [ "$1" = '-v' ] || return 1
    case "$2" in curl|gpg) return 1 ;; *) builtin command "$@" ;; esac
  }
  events=''
  refresh_cloudflare_apt_repo() {
    events="${events}refresh-cloudflare"$'\n'
    printf 'fresh cloudflare source\n' > "$repo"
  }
  apt_get() {
    if [ "$1" = update ] && [ -e "$repo" ]; then
      fail 'the stale Cloudflare source remained enabled while installing refresh prerequisites'
      return 1
    fi
    events="${events}apt:$*"$'\n'
  }
  prepare_existing_cloudflare_apt_repo "$repo" || {
    fail 'a stale Cloudflare source should be repairable when curl and gpg are missing'
    return 1
  }
  assert_eq $'apt:update -y\napt:install -y curl ca-certificates gnupg\nrefresh-cloudflare' \
    "${events%$'\n'}" \
    'refresh prerequisites must install with the stale source disabled before repo refresh' || return 1
  assert_eq 'fresh cloudflare source' "$(< "$repo")" \
    'the repaired Cloudflare source must replace the temporarily disabled stale source'
}

test_rpm_wireguard_dependencies_are_minimal() {
  source_without_main "$INSTALL_SCRIPT"
  declare -F pkg_install_rpm >/dev/null || {
    fail 'pkg_install_rpm is missing'
    return 1
  }

  local package_calls='' root repo refresh_line clean_line install_line
  dnf() {
    package_calls="${package_calls}$*"$'\n'
    return 0
  }
  yum() {
    package_calls="${package_calls}$*"$'\n'
    return 0
  }
  local extra_repo_calls=0
  enable_rhel_extra_repos() {
    extra_repo_calls=$((extra_repo_calls + 1))
  }
  OS_ID=rocky
  OS_VERSION_ID=9.0
  OS_VERSION_MAJOR=9

  pkg_install_rpm wireguard dnf
  assert_contains "$package_calls" 'wireguard-tools' 'WireGuard mode should install wireguard-tools' || return 1
  assert_not_contains "$package_calls" 'nftables' 'WireGuard mode must not install nftables' || return 1
  assert_not_contains "$package_calls" 'iptables' 'WireGuard mode must not install iptables' || return 1
  assert_not_contains "$package_calls" 'redsocks' 'WireGuard mode must not install redsocks' || return 1
  assert_not_contains "$package_calls" 'cloudflare-warp' 'WireGuard mode must not install cloudflare-warp' || return 1
  assert_eq '0' "$extra_repo_calls" \
    'WireGuard mode must not enable EPEL, CRB or PowerTools repositories' || return 1

  package_calls=''
  PREVIOUS_MODE=socks
  pkg_install_rpm wireguard dnf google
  assert_contains "$package_calls" 'nftables' \
    'switching from Socks must retain nftables until its old table can be cleared' || return 1
  PREVIOUS_MODE=''

  root="$(mktemp -d)"
  repo="$root/cloudflare-warp.repo"
  printf 'stale cloudflare repo\n' > "$repo"
  package_calls=''
  command() {
    [ "$1" = '-v' ] || return 1
    case "$2" in curl|rpm) return 0 ;; *) builtin command "$@" ;; esac
  }
  refresh_cloudflare_rpm_repo() { package_calls="${package_calls}refresh-cloudflare"$'\n'; }
  pkg_install_rpm wireguard dnf google "$repo"
  refresh_line="$(line_number "$package_calls" 'refresh-cloudflare')"
  clean_line="$(line_number "$package_calls" 'clean metadata')"
  install_line="$(line_number "$package_calls" 'wireguard-tools')"
  if [ -z "$refresh_line" ] || [ -z "$clean_line" ] || [ -z "$install_line" ] \
    || [ "$refresh_line" -ge "$clean_line" ] || [ "$clean_line" -ge "$install_line" ]; then
    fail 'an existing Cloudflare RPM repo must refresh before a WireGuard dependency transaction'
    return 1
  fi
  unset -f command
}

test_rpm_existing_repo_bootstraps_refresh_tools_before_wireguard() {
  source_without_main "$INSTALL_SCRIPT"

  local root repo package_calls='' tools_ready=0 repo_enabled_during_bootstrap=0
  local bootstrap_line refresh_line clean_line install_line
  root="$(mktemp -d)"
  repo="$root/cloudflare-warp.repo"
  printf 'stale cloudflare repo\n' > "$repo"
  command() {
    [ "$1" = '-v' ] || return 1
    case "$2" in
      curl|rpm) [ "$tools_ready" -eq 1 ] ;;
      *) builtin command "$@" ;;
    esac
  }
  dnf() {
    if [ "$1" = install ] && [ "$tools_ready" -eq 0 ]; then
      [ ! -e "$repo" ] || repo_enabled_during_bootstrap=1
      tools_ready=1
    fi
    package_calls="${package_calls}$*"$'\n'
    return 0
  }
  refresh_cloudflare_rpm_repo() {
    package_calls="${package_calls}refresh-cloudflare"$'\n'
  }

  pkg_install_rpm wireguard dnf google "$repo"
  assert_eq '0' "$repo_enabled_during_bootstrap" \
    'the stale Cloudflare RPM repo must be disabled while refresh tools are installed' || return 1
  [ -e "$repo" ] || {
    fail 'the existing Cloudflare RPM repo must be restored before refresh'
    return 1
  }
  bootstrap_line="$(line_number "$package_calls" 'install -y curl ca-certificates rpm')"
  refresh_line="$(line_number "$package_calls" 'refresh-cloudflare')"
  clean_line="$(line_number "$package_calls" 'clean metadata')"
  install_line="$(line_number "$package_calls" 'wireguard-tools')"
  if [ -z "$bootstrap_line" ] || [ -z "$refresh_line" ] || [ -z "$clean_line" ] \
    || [ -z "$install_line" ] || [ "$bootstrap_line" -ge "$refresh_line" ] \
    || [ "$refresh_line" -ge "$clean_line" ] || [ "$clean_line" -ge "$install_line" ]; then
    fail 'missing RPM refresh tools must bootstrap with the stale repo disabled before WireGuard dependencies'
    return 1
  fi
  unset -f command
}

test_socks_dependencies_are_mode_specific() {
  source_without_main "$INSTALL_SCRIPT"

  local package_calls=''
  apt-get() {
    package_calls="${package_calls}$*\n"
    return 0
  }
  redsocks_path() { return 1; }
  warp_client_complete() { return 0; }
  disable_new_packaged_redsocks_service() { :; }
  log() { :; }
  OS_ID=ubuntu
  OS_CODENAME=noble

  pkg_install_apt socks
  assert_contains "$package_calls" 'nftables' 'apt Socks mode should install nftables' || return 1
  assert_contains "$package_calls" 'redsocks' 'apt Socks mode should install redsocks' || return 1
  assert_not_contains "$package_calls" 'wireguard-tools' 'apt Socks mode must not install WireGuard tools' || return 1
  assert_not_contains "$package_calls" 'iptables' 'apt Socks mode must not install iptables' || return 1

  package_calls=''
  redsocks_path() { printf '/usr/bin/redsocks\n'; }
  pkg_install_apt socks
  assert_not_contains "$package_calls" 'install -y redsocks' \
    'an existing redsocks binary must be reused without touching its package or service' || return 1

  package_calls=''
  dnf() {
    package_calls="${package_calls}$*\n"
    return 0
  }
  enable_rhel_extra_repos() { :; }
  warp_client_complete() { return 0; }
  rpm_install_redsocks() {
    package_calls="${package_calls}redsocks-path\n"
  }
  OS_ID=rocky

  pkg_install_rpm socks dnf
  assert_contains "$package_calls" 'nftables' 'RPM Socks mode should install nftables' || return 1
  assert_contains "$package_calls" 'redsocks-path' 'RPM Socks mode should install or build redsocks' || return 1
  assert_not_contains "$package_calls" 'wireguard-tools' 'RPM Socks mode must not install WireGuard tools' || return 1
  assert_not_contains "$package_calls" 'iptables' 'RPM Socks mode must not install iptables' || return 1
  assert_not_contains "$package_calls" 'cloudflare-warp' \
    'an existing WARP client must avoid repository and package changes'
}

test_complete_mode_dependencies_skip_package_manager() {
  source_without_main "$INSTALL_SCRIPT"
  local package_calls=0

  mode_dependencies_complete() { return 0; }
  load_os_release() { fail 'complete dependencies must not inspect package-manager metadata'; }
  pkg_install_apt() { package_calls=$((package_calls + 1)); }
  pkg_install_rpm() { package_calls=$((package_calls + 1)); }

  install_dependencies wireguard >/dev/null || {
    fail 'complete WireGuard dependencies should be reused without a package-manager call'
    return 1
  }
  assert_eq '0' "$package_calls" 'complete dependencies should skip package installation'
}

test_incomplete_dependencies_use_current_package_candidate() {
  source_without_main "$INSTALL_SCRIPT"
  local manager_calls='' rpm_installed=1 warp_ready=0 clean_line candidate_line
  OS_ID=fedora
  STATE_DIR=/unused/state

  enable_rhel_extra_repos() { :; }
  rpm_install_redsocks() { :; }
  warp_client_complete() { [ "$warp_ready" -eq 1 ]; }
  install() { return 0; }
  curl() { return 0; }
  chmod() { return 0; }
  mv() { return 0; }
  rpm() {
    case "$1" in
      --import) return 0 ;;
      -q) [ "$rpm_installed" -eq 1 ] ;;
      *) return 1 ;;
    esac
  }
  dnf() {
    manager_calls="${manager_calls}$*"$'\n'
    case "$*" in
      *cloudflare-warp*) warp_ready=1 ;;
    esac
    return 0
  }

  pkg_install_rpm socks dnf || {
    fail 'an incomplete installed WARP dependency should be repaired from the current repository candidate'
    return 1
  }
  assert_not_contains "$manager_calls" 'reinstall' \
    'RPM dependency repair must not reinstall the already installed version instead of selecting the current candidate' \
    || return 1
  grep -Eq '^(install|upgrade).*cloudflare-warp' <<< "$manager_calls" || {
    fail 'an incomplete installed WARP dependency must use an install or upgrade candidate transaction'
    return 1
  }
  clean_line="$(line_number "$manager_calls" 'clean metadata')"
  candidate_line="$(line_number "$manager_calls" 'upgrade -y --best cloudflare-warp')"
  if [ -z "$clean_line" ] || [ -z "$candidate_line" ] || [ "$clean_line" -ge "$candidate_line" ]; then
    fail 'RPM metadata must expire before selecting an upgrade candidate'
    return 1
  fi

  manager_calls=''
  rpm_installed=0
  warp_ready=0
  pkg_install_rpm socks dnf || {
    fail 'a missing WARP dependency should install from the current repository candidate'
    return 1
  }
  grep -Eq '^install.*cloudflare-warp' <<< "$manager_calls" || {
    fail 'a missing RPM dependency must use the current install candidate'
    return 1
  }
  clean_line="$(line_number "$manager_calls" 'clean metadata')"
  candidate_line="$(line_number "$manager_calls" 'install -y cloudflare-warp')"
  if [ -z "$clean_line" ] || [ -z "$candidate_line" ] || [ "$clean_line" -ge "$candidate_line" ]; then
    fail 'RPM metadata must expire before selecting a fresh install candidate'
  fi
}

test_wireguard_dependencies_do_not_require_socks_tools() {
  source_without_main "$INSTALL_SCRIPT"
  local checks=''

  command() {
    [ "$1" = '-v' ] || return 1
    checks="${checks} $2"
    case "$2" in
      curl|ip|python3|timeout|sha256sum|wg|wg-quick) return 0 ;;
      *) return 1 ;;
    esac
  }
  unit_file_exists() { return 0; }

  mode_dependencies_complete wireguard || {
    fail 'WireGuard dependencies should be complete without Socks-only tools'
    return 1
  }
  assert_not_contains "$checks" ' ss' 'WireGuard dependency checks must not require ss' || return 1
  assert_contains "$checks" ' timeout' 'WireGuard dependency checks must bound wgcf execution' || return 1
  assert_not_contains "$checks" ' nft' 'WireGuard dependency checks must not require nftables' || return 1

  PREVIOUS_MODE=socks
  if mode_dependencies_complete wireguard google; then
    fail 'a Socks to WireGuard transition without nft must repair the cleanup dependency'
    return 1
  fi
  command() {
    [ "$1" = '-v' ] || return 1
    case "$2" in
      curl|ip|python3|timeout|sha256sum|wg|wg-quick|nft) return 0 ;;
      *) return 1 ;;
    esac
  }
  mode_dependencies_complete wireguard google || {
    fail 'a Socks to WireGuard transition should reuse complete cleanup dependencies'
    return 1
  }
  PREVIOUS_MODE=''

  command() {
    [ "$1" = '-v' ] || return 1
    case "$2" in
      curl|ip|python3|sha256sum|wg|wg-quick) return 0 ;;
      *) return 1 ;;
    esac
  }
  if mode_dependencies_complete wireguard; then
    fail 'WireGuard dependencies without timeout must not skip coreutils repair'
  fi

  command() {
    [ "$1" = '-v' ] || return 1
    case "$2" in
      curl|ip|python3|timeout|wg|wg-quick) return 0 ;;
      *) return 1 ;;
    esac
  }
  if mode_dependencies_complete wireguard; then
    fail 'WireGuard dependencies without sha256sum must not skip coreutils repair'
  fi
}

test_wireguard_dependency_reuse_requires_systemd_template() {
  source_without_main "$INSTALL_SCRIPT"

  command() {
    [ "$1" = '-v' ] || return 1
    case "$2" in
      curl|ip|python3|timeout|sha256sum|wg|wg-quick) return 0 ;;
      *) return 1 ;;
    esac
  }
  unit_file_exists() { return 1; }

  if mode_dependencies_complete wireguard; then
    fail 'WireGuard binaries without wg-quick@.service must not skip package repair'
    return 1
  fi
}

test_warp_client_reuse_requires_cli_and_unit() {
  source_without_main "$INSTALL_SCRIPT"
  warp-cli() { :; }

  unit_file_exists() { return 1; }
  if warp_client_complete; then
    fail 'warp-cli without warp-svc.service must not be treated as a complete client'
    return 1
  fi

  unit_file_exists() { [ "$1" = 'warp-svc.service' ]; }
  warp_client_complete || {
    fail 'warp-cli plus warp-svc.service should be reused'
    return 1
  }
  assert_file_matches "$INSTALL_SCRIPT" 'apt_get install -y --reinstall cloudflare-warp' \
    'APT should repair a partial Cloudflare WARP package' || return 1
  assert_file_matches "$INSTALL_SCRIPT" '"\$manager" reinstall -y cloudflare-warp' \
    'RPM systems should repair an installed but incomplete Cloudflare WARP package'
}

test_rpm_redsocks_uses_fedora_package_or_source() {
  source_without_main "$INSTALL_SCRIPT"
  local package_calls=''
  local build_calls=0

  redsocks_path() { return 1; }
  mark_managed_redsocks_if_current() { :; }
  unit_file_exists() { return 0; }
  systemctl() { return 0; }
  log() { :; }
  dnf() {
    package_calls="${package_calls}$*\n"
    return 0
  }
  build_redsocks_from_source() {
    build_calls=$((build_calls + 1))
  }

  OS_ID=fedora
  rpm_install_redsocks dnf
  assert_contains "$package_calls" 'install -y redsocks' 'Fedora should use its redsocks package' || return 1
  assert_eq '0' "$build_calls" 'Fedora must not build redsocks from source' || return 1

  package_calls=''
  build_calls=0
  OS_ID=rocky
  rpm_install_redsocks dnf
  assert_contains "$package_calls" 'gcc tar gzip libevent-devel' \
    'non-Fedora RPM systems should install source build dependencies' || return 1
  assert_not_contains "$package_calls" 'install -y redsocks' \
    'non-Fedora RPM systems must not assume a redsocks package exists' || return 1
  assert_eq '1' "$build_calls" 'non-Fedora RPM systems should use the source build path'
}

test_no_iptables_package_dependency() {
  assert_file_not_matches "$INSTALL_SCRIPT" \
    '(^|[[:space:]])iptables(-nft)?([[:space:]]|$)' \
    'the nftables implementation must not install the unused iptables CLI'
}

test_wireguard_uses_runtime_capability() {
  assert_file_not_matches "$INSTALL_SCRIPT" '/dev/net/tun|tun_available|kernel_major|uname -r' \
    'WireGuard selection must not infer support from TUN or a kernel version' || return 1
  assert_file_not_matches "$MANAGER_SCRIPT" '/dev/net/tun' \
    'WireGuard setup must not require TUN for a native interface' || return 1
  assert_file_matches "$MANAGER_SCRIPT" 'wg-quick up' \
    'WireGuard must keep the real interface preflight'
}

test_wgcf_fixed_binary_replaces_old_copy_atomically() {
  source_without_main "$MANAGER_SCRIPT"
  local root request_log output rc=0 download_target payload_hash
  root="$(mktemp -d)"
  request_log="$root/requests"
  DEFAULT_WGCF_BIN="$root/bin/wgcf"
  WGCF_BIN="$DEFAULT_WGCF_BIN"
  uname() { printf 'x86_64\n'; }
  mkdir -p "$(dirname "$WGCF_BIN")"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "wgcf v2.2.31\\n"' \
    > "$WGCF_BIN"
  chmod 0755 "$WGCF_BIN"
  : > "$request_log"
  payload_hash="$(printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "wgcf v2.2.32\\n"' \
    | sha256sum | awk '{ print $1 }')"

  curl() {
    local destination='' url='' arg
    while [ "$#" -gt 0 ]; do
      arg="$1"
      shift
      case "$arg" in
        -o)
          destination="$1"
          shift
          ;;
        https://*) url="$arg" ;;
      esac
    done
    printf '%s\t%s\n' "$url" "$destination" >> "$request_log"
    if [ "${url##*/}" = 'checksums.txt' ]; then
      if [ "${WGCF_TEST_BAD_CHECKSUM:-0}" -eq 1 ]; then
        printf '%064d  wgcf_2.2.32_linux_amd64\n' 0
      else
        printf '%s  wgcf_2.2.32_linux_amd64\n' "$payload_hash"
      fi
      return 0
    fi
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf "wgcf v2.2.32\\n"' \
      > "$destination"
    [ "${WGCF_TEST_CURL_FAIL:-0}" -eq 0 ]
  }

  WGCF_TEST_CURL_FAIL=1
  output="$(install_wgcf_binary 2>&1)" || rc=$?
  assert_eq '1' "$rc" 'a failed fixed-version download must fail setup' || return 1
  assert_eq 'wgcf v2.2.31' "$("$WGCF_BIN" --version)" \
    'a partial download must not replace the existing executable' || return 1

  WGCF_TEST_CURL_FAIL=0
  WGCF_TEST_BAD_CHECKSUM=1
  rc=0
  output="$(install_wgcf_binary 2>&1)" || rc=$?
  assert_eq '1' "$rc" 'a checksum mismatch must fail fixed-version setup' || return 1
  assert_eq 'wgcf v2.2.31' "$("$WGCF_BIN" --version)" \
    'an unverified download must not replace the existing executable' || return 1

  WGCF_TEST_BAD_CHECKSUM=0
  install_wgcf_binary >/dev/null || {
    fail 'the fixed wgcf version should replace an executable old copy'
    return 1
  }
  assert_eq 'wgcf v2.2.32' "$("$WGCF_BIN" --version)" \
    'the live wgcf binary must become the pinned fixed version' || return 1
  assert_contains "$(< "$request_log")" \
    '/v2.2.32/wgcf_2.2.32_linux_amd64' \
    'wgcf downloads must use the fixed release and matching asset name' || return 1
  download_target="$(awk -F '\t' '$1 ~ /linux_amd64$/ { target=$2 } END { print target }' "$request_log")"
  [ "$download_target" != "$WGCF_BIN" ] || {
    fail 'wgcf must download beside the live path before atomic activation'
    return 1
  }
  case "$download_target" in
    "$(dirname "$WGCF_BIN")"/*) ;;
    *)
      fail 'wgcf must stage on the same filesystem as the live binary'
      return 1
      ;;
  esac

  WGCF_BIN="$root/custom/wgcf"
  mkdir -p "$(dirname "$WGCF_BIN")"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "custom wgcf\\n"' \
    > "$WGCF_BIN"
  chmod 0755 "$WGCF_BIN"
  : > "$request_log"
  install_wgcf_binary || {
    fail 'an executable custom wgcf path should remain reusable'
    return 1
  }
  assert_eq 'custom wgcf' "$("$WGCF_BIN" --version)" \
    'a custom wgcf binary must not be replaced by the project pin' || return 1
  assert_eq '' "$(< "$request_log")" \
    'a reusable custom wgcf binary must not trigger a project download'
}

test_wireguard_config_generation_is_retryable() {
  local body root event output wg_config_valid_definition
  body="$(function_body "$MANAGER_SCRIPT" generate_wg_config)"
  assert_contains "$body" 'wg_config_valid "$WG_CONFIG"' \
    'an existing WireGuard config must be parsed before reuse' || return 1
  assert_contains "$body" 'register --accept-tos' \
    'wgcf registration should use its noninteractive accept-tos flag' || return 1
  assert_contains "$body" 'run_wgcf_command register --accept-tos' \
    'wgcf registration must use the bounded command wrapper' || return 1
  assert_contains "$body" 'run_wgcf_command generate' \
    'wgcf generation must use the bounded command wrapper' || return 1
  assert_not_contains "$body" "printf 'yes" \
    'wgcf registration must not depend on an interactive prompt pipe' || return 1
  assert_contains "$body" 'config_tmp="${WG_CONFIG}.new.$$"' \
    'WireGuard config should be staged beside the live file' || return 1
  assert_contains "$body" 'mv "$config_tmp" "$WG_CONFIG"' \
    'a validated WireGuard config should be activated atomically' || return 1

  source_without_main "$MANAGER_SCRIPT"
  local timeout_args='' rc=0
  WGCF_BIN=/opt/warp-vps-manager/bin/wgcf
  timeout() { timeout_args="$*"; return 124; }
  run_wgcf_command register --accept-tos >/dev/null 2>&1 || rc=$?
  assert_eq '124' "$rc" 'a wgcf timeout must propagate to the installation transaction' || return 1
  assert_eq '-k 5 120 /opt/warp-vps-manager/bin/wgcf register --accept-tos' "$timeout_args" \
    'wgcf must have both a total deadline and a forced-kill deadline' || return 1

  root="$(mktemp -d)"
  event="$root/wgcf-events"
  STATE_DIR="$root/state"
  WGCF_ACCOUNT="$STATE_DIR/wgcf/wgcf-account.toml"
  WG_IFACE=warp-vps-wg
  WG_CONFIG="$root/warp-vps-wg.conf"
  WGCF_BIN="$root/wgcf"
  mkdir -p "$STATE_DIR/wgcf"
  printf 'existing-account\n' > "$STATE_DIR/wgcf/wgcf-account.toml"
  : > "$event"
  install() {
    local mode src dst path
    if [ "$1" = '-d' ]; then
      shift
      if [ "${1:-}" = '-m' ]; then shift 2; fi
      for path in "$@"; do
        [ "$path" = /etc/wireguard ] || mkdir -p "$path"
      done
      return 0
    fi
    if [ "$1" = '-m' ]; then
      mode="$2"
      src="$3"
      dst="$4"
      /bin/cp "$src" "$dst"
      chmod "$mode" "$dst"
      return
    fi
    command install "$@"
  }
  install_wgcf_binary() { :; }
  wg_config_valid_definition="$(declare -f wg_config_valid)"
  wg_config_valid() { return 1; }
  run_wgcf_command() {
    printf '%s\n' "$*" >> "$event"
    return 124
  }
  rc=0
  output="$(generate_wg_config 2>&1)" || rc=$?
  assert_eq '1' "$rc" 'a timed-out existing-account generation must fail the transaction' || return 1
  assert_contains "$output" '生成 WireGuard 配置超时' \
    'an existing-account timeout should have a specific local error' || return 1
  assert_eq 'generate' "$(< "$event")" \
    'an existing-account timeout must not discard it and attempt a fresh registration' || return 1

  : > "$event"
  run_wgcf_command() {
    printf '%s\n' "$*" >> "$event"
    return 42
  }
  rc=0
  output="$(generate_wg_config 2>&1)" || rc=$?
  assert_eq '1' "$rc" 'an existing-account generation error must fail the transaction' || return 1
  assert_contains "$output" '生成 WireGuard 配置失败' \
    'an existing-account generation error should remain a local generation failure' || return 1
  assert_eq 'generate' "$(< "$event")" \
    'an existing account must never be discarded for a new registration after generate fails' || return 1

  STATE_DIR="$root/fresh-state"
  WGCF_ACCOUNT="$STATE_DIR/wgcf/wgcf-account.toml"
  : > "$event"
  run_wgcf_command() {
    printf '%s\n' "$*" >> "$event"
    return 124
  }
  rc=0
  output="$(generate_wg_config 2>&1)" || rc=$?
  assert_eq '1' "$rc" 'a fresh registration timeout must fail the transaction' || return 1
  assert_contains "$output" '注册 WireGuard 账户超时' \
    'a fresh registration timeout should identify the failed phase' || return 1
  assert_eq 'register --accept-tos' "$(< "$event")" \
    'wgcf generate must not run after fresh registration times out' || return 1

  STATE_DIR="$root/fresh-success-state"
  WGCF_ACCOUNT="$STATE_DIR/wgcf/wgcf-account.toml"
  : > "$event"
  wg_config_valid() { return 0; }
  run_wgcf_command() {
    printf '%s\n' "$*" >> "$event"
    case "$1" in
      register) printf 'fresh-account\n' > wgcf-account.toml ;;
      generate) /bin/cp "${FIXTURE_DIR}/wireguard/valid.conf" wgcf-profile.conf ;;
    esac
    return 0
  }
  generate_wg_config || {
    fail 'a fresh host should register once and generate its first WireGuard profile'
    return 1
  }
  assert_eq $'register --accept-tos\ngenerate' "$(< "$event")" \
    'only a host without an account should run the registration flow' || return 1

  eval "$wg_config_valid_definition"

  wg-quick() {
    [ "$1" = 'strip' ]
  }
  wg_config_valid "${FIXTURE_DIR}/wireguard/valid.conf" || {
    fail 'a complete project WireGuard config should be reusable'
    return 1
  }
  if wg_config_valid "${FIXTURE_DIR}/config/custom-wireguard.env"; then
    fail 'a non-empty partial or unrelated file must not be reused as WireGuard config'
    return 1
  fi
  if wg_config_valid "${FIXTURE_DIR}/wireguard/invalid-endpoint.conf"; then
    fail 'an endpoint without a port must not be reused'
    return 1
  fi
  if wg_config_valid "${FIXTURE_DIR}/wireguard/unknown-key.conf"; then
    fail 'unknown WireGuard keys must not be silently reused'
    return 1
  fi
  if wg_config_valid "${FIXTURE_DIR}/wireguard/uppercase-table.conf"; then
    fail 'Table must use the lowercase off value required by wg-quick'
    return 1
  fi
  if wg_config_valid "${FIXTURE_DIR}/wireguard/ipv4-only.conf"; then
    fail 'a WireGuard config without an IPv6 interface address must not be reused'
    return 1
  fi
  if wg_config_valid "${FIXTURE_DIR}/wireguard/ipv6-only.conf"; then
    fail 'a WireGuard config without an IPv4 interface address must not be reused'
    return 1
  fi
  if wg_config_valid "${FIXTURE_DIR}/wireguard/allowed-ipv4-only.conf"; then
    fail 'a WireGuard peer without IPv6 AllowedIPs must not be reused'
    return 1
  fi
  if wg_config_valid "${FIXTURE_DIR}/wireguard/allowed-ipv6-only.conf"; then
    fail 'a WireGuard peer without IPv4 AllowedIPs must not be reused'
    return 1
  fi
}

test_wireguard_endpoint_candidates_preserve_hostname_config() {
  source_without_main "$MANAGER_SCRIPT"
  local root output original body
  root="$(mktemp -d)"
  WG_CONFIG="$root/warp-vps-wg.conf"
  timeout() {
    [ "$1" = '-k' ] || return 1
    shift 3
    "$@"
  }

  cat > "$root/sitecustomize.py" <<'PY'
import socket


def fake_getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
    if host != "endpoint.test":
        raise OSError(f"unexpected host: {host}")
    return [
        (socket.AF_INET6, socket.SOCK_DGRAM, socket.IPPROTO_UDP, "", ("2001:db8::10", port, 0, 0)),
        (socket.AF_INET6, socket.SOCK_DGRAM, socket.IPPROTO_UDP, "", ("2001:db8::10", port, 0, 0)),
        (socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP, "", ("192.0.2.10", port)),
        (socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP, "", ("192.0.2.10", port)),
    ]


socket.getaddrinfo = fake_getaddrinfo
PY
  sed 's/engage\.cloudflareclient\.com/endpoint.test/' \
    "${FIXTURE_DIR}/wireguard/valid.conf" > "$WG_CONFIG"
  original="$(< "$WG_CONFIG")"
  output="$(PYTHONPATH="$root" wireguard_endpoint_candidates)" || return 1
  assert_eq $'192.0.2.10:2408\n[2001:db8::10]:2408' "$output" \
    'hostname resolution must deduplicate addresses and prefer IPv4 before IPv6' || return 1
  assert_eq "$original" "$(< "$WG_CONFIG")" \
    'hostname candidate discovery must not rewrite the WireGuard config' || return 1

  sed 's/engage\.cloudflareclient\.com/162.159.192.1/' \
    "${FIXTURE_DIR}/wireguard/valid.conf" > "$WG_CONFIG"
  original="$(< "$WG_CONFIG")"
  output="$(wireguard_endpoint_candidates)" || return 1
  assert_eq '162.159.192.1:2408' "$output" \
    'an IPv4 literal must remain a valid runtime endpoint candidate' || return 1
  assert_eq "$original" "$(< "$WG_CONFIG")" \
    'runtime candidate discovery must not rewrite the WireGuard config' || return 1

  sed 's/engage\.cloudflareclient\.com:2408/[2606:4700:d0::a29f:c001]:2408/' \
    "${FIXTURE_DIR}/wireguard/valid.conf" > "$WG_CONFIG"
  output="$(wireguard_endpoint_candidates)" || return 1
  assert_eq '[2606:4700:d0::a29f:c001]:2408' "$output" \
    'an IPv6 literal must keep WireGuard bracket notation' || return 1

  body="$(function_body "$MANAGER_SCRIPT" wireguard_endpoint_candidates)"
  assert_contains "$body" 'addresses.sort(key=lambda address: address.version)' \
    'resolved endpoints must prefer IPv4 before falling back to IPv6' || return 1
  assert_contains "$body" 'WG_ENDPOINT_RESOLVE_TIMEOUT' \
    'endpoint DNS resolution must have a total deadline'
}

test_wireguard_endpoint_selection_falls_back_and_requires_dual_stack() {
  source_without_main "$MANAGER_SCRIPT"
  local mock_peer_key mock_current_endpoint mock_received set_calls curl_calls original candidates
  mock_peer_key='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB='
  WG_IFACE=warp-vps-wg
  WG_CONFIG="${FIXTURE_DIR}/wireguard/valid.conf"
  original="$(< "$WG_CONFIG")"
  mock_current_endpoint=''
  mock_received=0
  set_calls=''
  curl_calls=''
  candidates=$'[2606:4700:d0::a29f:c001]:2408\n162.159.192.1:2408'
  wg() {
    case "$*" in
      'show warp-vps-wg peers') printf '%s\n' "$mock_peer_key" ;;
      'show warp-vps-wg transfer') printf '%s\t%s\t100\n' "$mock_peer_key" "$mock_received" ;;
      "set warp-vps-wg peer $mock_peer_key endpoint "*)
        mock_current_endpoint="${*: -1}"
        set_calls="${set_calls}${mock_current_endpoint}"$'\n'
        ;;
      *) return 1 ;;
    esac
  }
  curl() {
    curl_calls="${curl_calls}${mock_current_endpoint} $1"$'\n'
    [ "$mock_current_endpoint" = '162.159.192.1:2408' ] || return 28
    case "$1" in
      -4) mock_received=256 ;;
      -6) mock_received=512 ;;
    esac
  }
  wg_handshake_recent() { [ "$mock_current_endpoint" = '162.159.192.1:2408' ]; }
  info_line() { :; }
  ok_line() { :; }

  select_working_wireguard_endpoint "$candidates" || {
    fail 'preflight should fall back from a failed IPv6 transport to working IPv4'
    return 1
  }
  assert_eq $'[2606:4700:d0::a29f:c001]:2408\n162.159.192.1:2408' \
    "${set_calls%$'\n'}" \
    'preflight must try the next resolved endpoint after a failed transport' || return 1
  assert_contains "$curl_calls" '162.159.192.1:2408 -4' \
    'the selected transport must carry Google IPv4' || return 1
  assert_contains "$curl_calls" '162.159.192.1:2408 -6' \
    'an IPv4 WireGuard transport must also prove tunneled Google IPv6' || return 1
  assert_eq "$original" "$(< "$WG_CONFIG")" \
    'a successful runtime endpoint must not be written into the hostname config' || return 1

  mock_current_endpoint=''
  mock_received=0
  set_calls=''
  curl_calls=''
  candidates=$'162.159.192.1:2408\n[2606:4700:d0::a29f:c001]:2408'
  curl() {
    curl_calls="${curl_calls}${mock_current_endpoint} $1"$'\n'
    [ "$mock_current_endpoint" = '[2606:4700:d0::a29f:c001]:2408' ] || return 28
    case "$1" in
      -4) mock_received=384 ;;
      -6) mock_received=768 ;;
    esac
  }
  wg_handshake_recent() { [ "$mock_current_endpoint" = '[2606:4700:d0::a29f:c001]:2408' ]; }
  select_working_wireguard_endpoint "$candidates" || {
    fail 'preflight should fall back from a failed IPv4 transport to working IPv6'
    return 1
  }
  assert_eq $'162.159.192.1:2408\n[2606:4700:d0::a29f:c001]:2408' \
    "${set_calls%$'\n'}" \
    'IPv6 must remain available when the preferred IPv4 transport fails' || return 1

  mock_current_endpoint=''
  mock_received=0
  candidates='162.159.192.1:2408'
  curl() {
    if [ "$1" = '-4' ]; then mock_received=512; return 0; fi
    return 28
  }
  wg_handshake_recent() { return 0; }
  if select_working_wireguard_endpoint "$candidates" >/dev/null; then
    fail 'an endpoint with only tunneled IPv4 must not pass the dual-stack preflight'
    return 1
  fi
}

test_wireguard_endpoint_selection_requires_handshake_and_receive() {
  source_without_main "$MANAGER_SCRIPT"
  local mock_peer_key mock_received body candidates
  mock_peer_key='BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB='
  mock_received=0
  WG_IFACE=warp-vps-wg
  candidates='162.159.192.1:2408'
  wg() {
    case "$*" in
      'show warp-vps-wg peers') printf '%s\n' "$mock_peer_key" ;;
      'show warp-vps-wg transfer') printf '%s\t%s\t100\n' "$mock_peer_key" "$mock_received" ;;
      "set warp-vps-wg peer $mock_peer_key endpoint 162.159.192.1:2408") return 0 ;;
      *) return 1 ;;
    esac
  }
  curl() {
    case "$1" in
      -4) mock_received=256 ;;
      -6) mock_received=512 ;;
    esac
  }
  wg_handshake_recent() { return 1; }
  info_line() { :; }
  ok_line() { :; }
  if select_working_wireguard_endpoint "$candidates" >/dev/null; then
    fail 'HTTP responses and received bytes must not replace a recent WireGuard handshake'
    return 1
  fi

  mock_received=0
  curl() { return 0; }
  wg_handshake_recent() { return 0; }
  if select_working_wireguard_endpoint "$candidates" >/dev/null; then
    fail 'HTTP mocks and a handshake must not pass without increased WireGuard receive bytes'
    return 1
  fi

  mock_received=0
  curl() {
    if [ "$1" = '-4' ]; then
      mock_received=256
    fi
    return 0
  }
  if select_working_wireguard_endpoint "$candidates" >/dev/null; then
    fail 'an IPv6 HTTP response must not pass without its own WireGuard receive increase'
    return 1
  fi

  body="$(function_body "$MANAGER_SCRIPT" select_working_wireguard_endpoint)"
  assert_contains "$body" 'curl -4 -sS' \
    'an IPv4 HTTP response of any status must prove transport reachability' || return 1
  assert_contains "$body" 'curl -6 -sS' \
    'an IPv6 HTTP response of any status must prove transport reachability' || return 1
  assert_contains "$body" "--noproxy '*'" \
    'endpoint validation must bypass environment proxies' || return 1
  assert_not_contains "$body" 'curl -4 -fsS' \
    'HTTP policy errors must not be confused with an IPv4 transport failure' || return 1
  assert_not_contains "$body" 'curl -6 -fsS' \
    'HTTP policy errors must not be confused with an IPv6 transport failure'
}

test_start_rules_validates_wireguard_and_cleans_failures() {
  source_without_main "$MANAGER_SCRIPT"
  local event_log output rc scope candidate
  event_log="$(mktemp)"
  candidate='162.159.192.1:2408'
  WARP_MODE=wireguard
  load_config() { :; }
  wireguard_endpoint_candidates() {
    printf 'resolve:%s\n' "$WARP_SCOPE" >> "$event_log"
    printf '%s\n' "$candidate"
  }
  apply_rules() { printf 'apply:%s:%s\n' "$WARP_MODE" "$WARP_SCOPE" >> "$event_log"; }
  select_working_wireguard_endpoint() {
    printf 'select:%s:%s\n' "$WARP_SCOPE" "$1" >> "$event_log"
    return 1
  }
  stop_wg_routes_strict() { printf 'cleanup:%s\n' "$WARP_SCOPE" >> "$event_log"; }
  die() { printf '%s\n' "$1"; exit 1; }

  for scope in google global; do
    WARP_SCOPE="$scope"
    : > "$event_log"
    rc=0
    output="$(start_rules 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || {
      fail "a failed $scope WireGuard data plane must fail route startup"
      return 1
    }
    assert_eq "resolve:${scope}
apply:wireguard:${scope}
select:${scope}:${candidate}
cleanup:${scope}" "$(< "$event_log")" \
      "a failed $scope data plane must resolve before routing, validate, then clean" || return 1
    assert_contains "$output" 'WireGuard 不会回退 TCP' \
      'startup failure must explain the protocol boundary' || return 1
    assert_contains "$output" 'warp-vps switch socks --socks-port auto' \
      'startup failure must provide the supported alternative' || return 1
  done

  : > "$event_log"
  select_working_wireguard_endpoint() {
    printf 'select:%s:%s\n' "$WARP_SCOPE" "$1" >> "$event_log"
    return 0
  }
  start_rules || return 1
  assert_eq "resolve:global
apply:wireguard:global
select:global:${candidate}" "$(< "$event_log")" \
    'a verified WireGuard startup must retain its applied routes' || return 1

  : > "$event_log"
  WARP_SCOPE=google
  wireguard_endpoint_candidates() {
    printf 'resolve:%s\n' "$WARP_SCOPE" >> "$event_log"
    return 1
  }
  rc=0
  output="$(start_rules 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'endpoint resolution failure must fail route startup'
    return 1
  }
  assert_eq $'resolve:google\ncleanup:google' "$(< "$event_log")" \
    'endpoint resolution failure must clean existing routes before any route write' || return 1

  : > "$event_log"
  WARP_MODE=socks
  wireguard_endpoint_candidates() {
    printf 'unexpected-resolve\n' >> "$event_log"
    return 1
  }
  select_working_wireguard_endpoint() {
    printf 'unexpected-probe\n' >> "$event_log"
    return 1
  }
  start_rules || {
    fail 'Socks route startup must not depend on WireGuard endpoint validation'
    return 1
  }
  assert_eq 'apply:socks:google' "$(< "$event_log")" \
    'Socks startup must apply only its existing local routing path'
}

test_wireguard_preflight_uses_start_rules_and_cleans_interface() {
  source_without_main "$MANAGER_SCRIPT"
  local event_log output rc=0
  event_log="$(mktemp)"
  WARP_MODE=wireguard
  WG_IFACE=warp-vps-wg
  WG_CONFIG="${FIXTURE_DIR}/wireguard/valid.conf"
  SELF_PATH=manager_mock
  require_root() { :; }
  load_config() { :; }
  command() { if [ "${1:-}" = '-v' ]; then return 0; fi; builtin command "$@"; }
  wg_interface_absent() { return 0; }
  wg-quick() { printf 'wg-quick:%s\n' "$*" >> "$event_log"; }
  manager_mock() { printf 'manager:%s\n' "$*" >> "$event_log"; return 1; }
  remove_wireguard_interface() { printf 'cleanup-interface\n' >> "$event_log"; }
  info_line() { :; }
  ok_line() { :; }
  die() { printf '%s\n' "$1"; exit 1; }

  output="$(cmd_preflight_wireguard 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'a failed start-rules data plane must reject target preparation'
    return 1
  }
  assert_contains "$(< "$event_log")" 'manager:start-rules' \
    'installation preflight must use the same startup boundary as systemd' || return 1
  assert_contains "$(< "$event_log")" 'cleanup-interface' \
    'a failed real endpoint check must remove the temporary WireGuard interface' || return 1
  assert_contains "$output" 'WireGuard 预检失败，未写入开机服务' \
    'preflight must reject service installation after data-plane failure'
}

test_wireguard_start_rules_is_the_lifecycle_boundary() {
  local systemd_body preflight_body start_body fail_body heal_body status_body quiet_body
  local restart_body backend_restart_body reload_body installer_body resolve_line apply_line
  systemd_body="$(function_body "$MANAGER_SCRIPT" install_systemd)"
  preflight_body="$(function_body "$MANAGER_SCRIPT" cmd_preflight_wireguard)"
  start_body="$(function_body "$MANAGER_SCRIPT" start_rules)"
  fail_body="$(function_body "$MANAGER_SCRIPT" fail_wireguard_start)"
  heal_body="$(function_body "$MANAGER_SCRIPT" cmd_heal)"
  status_body="$(function_body "$MANAGER_SCRIPT" run_self_check)"
  quiet_body="$(function_body "$MANAGER_SCRIPT" test_quiet)"
  restart_body="$(function_body "$MANAGER_SCRIPT" cmd_restart)"
  backend_restart_body="$(function_body "$MANAGER_SCRIPT" restart_wireguard_runtime)"
  reload_body="$(function_body "$MANAGER_SCRIPT" reload_runtime_after_update)"
  installer_body="$(function_body "$INSTALL_SCRIPT" main)"

  assert_contains "$systemd_body" 'ExecStart=${BIN_PATH} start-rules' \
    'boot, update, reinstall and restart must enter verified route startup' || return 1
  assert_contains "$preflight_body" '"$SELF_PATH" start-rules' \
    'installation preflight must enter the same verified route startup' || return 1
  assert_contains "$restart_body" 'systemctl restart warp-vps.service' \
    'an explicit restart must re-enter verified route startup' || return 1
  assert_not_contains "$backend_restart_body" 'apply_rules' \
    'WireGuard backend repair must not install routes before start-rules resolves candidates' \
    || return 1
  assert_contains "$reload_body" 'systemctl start warp-vps.service' \
    'an update must re-enter verified route startup after installing the new unit' || return 1
  assert_contains "$installer_body" 'enable_project_unit warp-vps.service' \
    'reinstall must start the verified route unit even when reusing the interface' || return 1
  assert_contains "$start_body" 'select_working_wireguard_endpoint' \
    'WireGuard route startup must select a real working endpoint' || return 1
  resolve_line="$(line_number "$start_body" 'candidates="$(wireguard_endpoint_candidates)"')"
  apply_line="$(line_number "$start_body" 'apply_rules')"
  if [ -z "$resolve_line" ] || [ -z "$apply_line" ] \
    || [ "$resolve_line" -ge "$apply_line" ]; then
    fail 'WireGuard endpoint candidates must resolve before project routes can affect DNS'
    return 1
  fi
  assert_contains "$start_body" 'select_working_wireguard_endpoint "$candidates"' \
    'startup must validate the frozen pre-route candidate list' || return 1
  assert_contains "$fail_body" 'stop_wg_routes_strict' \
    'failed endpoint selection must strictly remove project routes' || return 1
  assert_contains "$heal_body" 'repair_rules=1' \
    'a rebuilt WireGuard interface must restart the verified route service' || return 1
  assert_not_contains "$status_body" 'select_working_wireguard_endpoint' \
    'status must remain a local nonblocking report' || return 1
  assert_not_contains "$quiet_body" 'select_working_wireguard_endpoint' \
    'healthy timer checks must not run external endpoint validation'
}

test_wireguard_route_failures_cleanup() {
  source_without_main "$MANAGER_SCRIPT"
  WARP_SCOPE=google
  WG_IFACE=warp-vps-wg
  RULES_DIR="${ROOT_DIR}/rules"
  local fail_on die_message ip_calls ip_log routes4 routes6 route_del_calls
  fail_on=''
  die_message=''
  ip_calls=''
  ip_log="$(mktemp)"
  routes4=''
  routes6=''
  route_del_calls=0

  load_config() { :; }
  validate_rules_file() { :; }
  wg_interface_is_wireguard() { return 0; }
  wg_interface_exists() { return 0; }
  wg_interface_absent() { return 1; }
  protect_ssh_peer_route() { :; }
  wireguard_routes_local_ok() { return 0; }
  stop_wg_global_routes() { :; }
  wg_global_routes_absent() { return 0; }
  route_file_lines() {
    case "$1" in
      *google_ipv4.txt) printf '%s\n' 8.8.8.0/24 8.8.4.0/24 8.34.208.0/20 ;;
      *google_ipv6.txt) printf '%s\n' 2001:4860::/32 2404:6800::/32 2600:1900::/28 ;;
    esac
  }
  die() { die_message="$1"; return 1; }
  remove_mock_route() {
    local var_name="$1"
    local target="$2"
    local current="${!var_name}"
    current="$(awk -v target="$target" 'NF && $0 != target { print }' <<< "$current")"
    printf -v "$var_name" '%s' "$current"
  }
  ip() {
    ip_calls="${ip_calls}$*\n"
    printf '%s\n' "$*" >> "$ip_log"
    [ "$2" = route ] || return 1
    case "$3" in
      replace)
        [ "$4" != "$fail_on" ] || return 1
        if [ "$1" = -4 ]; then
          routes4="${routes4}${routes4:+$'\n'}$4"
        else
          routes6="${routes6}${routes6:+$'\n'}$4"
        fi
        ;;
      show)
        if [ "$1" = -4 ]; then
          grep -Fxq "$5" <<< "$routes4" && printf '%s dev %s\n' "$5" "$7"
        else
          grep -Fxq "$5" <<< "$routes6" && printf '%s dev %s\n' "$5" "$7"
        fi
        ;;
      del)
        if [ "$1" = -4 ]; then
          if grep -Fxq "$4" <<< "$routes4"; then
            route_del_calls=$((route_del_calls + 1))
            remove_mock_route routes4 "$4"
          fi
        else
          if grep -Fxq "$4" <<< "$routes6"; then
            route_del_calls=$((route_del_calls + 1))
            remove_mock_route routes6 "$4"
          fi
        fi
        ;;
      *) return 1 ;;
    esac
  }

  local failed_case failed_cidr expected_deletes
  for failed_case in \
    '8.8.8.0/24:0' \
    '8.8.4.0/24:1' \
    '2001:4860::/32:3' \
    '2404:6800::/32:4'; do
    failed_cidr="${failed_case%:*}"
    expected_deletes="${failed_case##*:}"
    fail_on="$failed_cidr"
    die_message=''
    ip_calls=''
    : > "$ip_log"
    routes4=''
    routes6=''
    route_del_calls=0
    if apply_wg_routes; then
      fail "a route failure at $failed_cidr must fail the WireGuard apply"
      return 1
    fi
    assert_eq '' "$routes4" \
      "a route failure at $failed_cidr should remove every written IPv4 route" || return 1
    assert_eq '' "$routes6" \
      "a route failure at $failed_cidr should remove every written IPv6 route" || return 1
    assert_eq "$expected_deletes" "$route_del_calls" \
      "a route failure at $failed_cidr should delete every route that was actually written" || return 1
    assert_contains "$(< "$ip_log")" '-4 route show exact' \
      "cleanup after $failed_cidr should verify IPv4 route state" || return 1
    assert_contains "$(< "$ip_log")" '-6 route show exact' \
      "cleanup after $failed_cidr should verify IPv6 route state" || return 1
    assert_contains "$die_message" "$failed_cidr" \
      "the failed route CIDR should be reported: $failed_cidr" || return 1
  done

  fail_on=''
  die_message=''
  ip_calls=''
  routes4=''
  routes6=''
  route_del_calls=0
  apply_wg_routes || {
    fail 'route apply should not require a native IPv6 default route'
    return 1
  }
  assert_contains "$ip_calls" '-6 route replace 2001:4860::/32 dev warp-vps-wg' \
    'Google IPv6 routes must be installed without a native IPv6 probe' || return 1
  assert_eq '0' "$route_del_calls" 'a successful dual-stack route apply should not clean routes'
}

test_wireguard_routes_work_without_native_ipv6() {
  source_without_main "$MANAGER_SCRIPT"
  WARP_SCOPE=google
  WG_IFACE=warp-vps-wg
  RULES_DIR=/unused
  local routes4='' routes6='' ip_calls=''

  load_config() { :; }
  validate_rules_file() { :; }
  wg_interface_is_wireguard() { return 0; }
  protect_ssh_peer_route() { :; }
  stop_wg_global_routes() { :; }
  wg_global_routes_absent() { return 0; }
  socks_table_absent() { return 0; }
  route_file_lines() {
    case "$1" in
      *google_ipv4.txt) printf '8.8.8.0/24\n' ;;
      *google_ipv6.txt) printf '2001:4860::/32\n' ;;
    esac
  }
  rule_probe_ip() {
    case "$2" in
      4) printf '8.8.8.0\n' ;;
      6) printf '2001:4860::\n' ;;
    esac
  }
  ip() {
    ip_calls="${ip_calls}$*\n"
    case "$*" in
      '-4 route replace 8.8.8.0/24 dev warp-vps-wg') routes4=8.8.8.0/24; return 0 ;;
      '-6 route replace 2001:4860::/32 dev warp-vps-wg') routes6=2001:4860::/32; return 0 ;;
      '-4 route get 8.8.8.0') [ -n "$routes4" ] && printf '8.8.8.0 dev warp-vps-wg\n' ;;
      '-6 route get 2001:4860::') [ -n "$routes6" ] && printf '2001:4860:: dev warp-vps-wg\n' ;;
      '-4 route show default dev warp-vps-wg'|'-6 route show default dev warp-vps-wg') return 0 ;;
      '-6 route show default'|'-6 route get 2001:4860:4860::8888') return 1 ;;
      *) return 1 ;;
    esac
  }

  apply_wg_routes || {
    fail 'Google dual-stack routes should install without a native IPv6 route'
    return 1
  }
  assert_contains "$ip_calls" '-6 route replace 2001:4860::/32 dev warp-vps-wg' \
    'the tunneled Google IPv6 route must still be installed' || return 1
  assert_eq '2001:4860::/32' "$routes6" \
    'the tunneled Google IPv6 route must remain installed after the real local route check'
}

test_wireguard_route_cleanup_is_dual_stack_independent() {
  source_without_main "$MANAGER_SCRIPT"
  local route_calls=''
  local temp_rules temp_rules_v4
  temp_rules="$(mktemp -d)"
  WG_IFACE=warp-vps-wg
  RULES_DIR="$temp_rules"
  stop_wg_global_routes() { :; }

  ip() { route_calls="${route_calls}$*\n"; }
  printf '2001:4860::/32\n' > "${RULES_DIR}/google_ipv6.txt"
  stop_wg_routes
  assert_contains "$route_calls" '-6 route del 2001:4860::/32 dev warp-vps-wg' \
    'missing IPv4 rules must not suppress IPv6 route cleanup' || return 1

  temp_rules_v4="$(mktemp -d)"
  RULES_DIR="$temp_rules_v4"
  printf '8.8.8.0/24\n' > "${RULES_DIR}/google_ipv4.txt"
  route_calls=''
  stop_wg_routes
  assert_contains "$route_calls" '-4 route del 8.8.8.0/24 dev warp-vps-wg' \
    'missing IPv6 rules must not suppress IPv4 route cleanup'
}

test_wireguard_strict_cleanup_checks_actual_route_state() {
  source_without_main "$MANAGER_SCRIPT"
  local temp_rules route4_present=1 route6_present=1
  local interface_state=present fail_show4=0 fail_delete4=0 sticky4=0 ip_calls=''
  temp_rules="$(mktemp -d)"
  RULES_DIR="$temp_rules"
  WG_IFACE=warp-vps-wg
  stop_wg_global_routes() { :; }
  wg_global_routes_absent() { return 0; }
  printf '8.8.8.0/24\n' > "$RULES_DIR/google_ipv4.txt"
  printf '2001:4860::/32\n' > "$RULES_DIR/google_ipv6.txt"
  wg_interface_absent() {
    case "$interface_state" in
      absent) return 0 ;;
      present) return 1 ;;
      *) return 2 ;;
    esac
  }
  wg_interface_exists() { [ "$interface_state" = present ]; }
  ip() {
    ip_calls="${ip_calls}$*\n"
    case "$*" in
      '-4 route show exact 8.8.8.0/24 dev warp-vps-wg')
        [ "$fail_show4" -eq 0 ] || return 2
        [ "$route4_present" -eq 0 ] || printf '8.8.8.0/24 dev warp-vps-wg\n'
        ;;
      '-6 route show exact 2001:4860::/32 dev warp-vps-wg')
        [ "$route6_present" -eq 0 ] || printf '2001:4860::/32 dev warp-vps-wg\n'
        ;;
      '-4 route del 8.8.8.0/24 dev warp-vps-wg')
        [ "$fail_delete4" -eq 0 ] || return 2
        [ "$sticky4" -eq 1 ] || route4_present=0
        ;;
      '-6 route del 2001:4860::/32 dev warp-vps-wg') route6_present=0 ;;
      *) return 2 ;;
    esac
  }

  mv "$RULES_DIR/google_ipv4.txt" "$RULES_DIR/google_ipv4.missing"
  if stop_wg_routes_strict; then
    fail 'a missing old IPv4 snapshot must block strict cleanup while the interface exists'
    return 1
  fi
  mv "$RULES_DIR/google_ipv4.missing" "$RULES_DIR/google_ipv4.txt"

  interface_state=unknown
  if stop_wg_routes_strict; then
    fail 'an unreadable WireGuard interface state must block strict cleanup'
    return 1
  fi
  interface_state=absent
  mv "$RULES_DIR/google_ipv6.txt" "$RULES_DIR/google_ipv6.missing"
  stop_wg_routes_strict || {
    fail 'an absent interface proves project routes are absent without requiring snapshot files'
    return 1
  }
  mv "$RULES_DIR/google_ipv6.missing" "$RULES_DIR/google_ipv6.txt"
  interface_state=present

  fail_show4=1
  ip_calls=''
  stop_wg_routes_strict && {
    fail 'a failed IPv4 route query must fail strict cleanup'
    return 1
  }
  assert_eq '0' "$route6_present" \
    'an IPv4 query failure must not prevent IPv6 cleanup from continuing' || return 1

  fail_show4=0
  fail_delete4=1
  route4_present=1
  route6_present=1
  ip_calls=''
  stop_wg_routes_strict && {
    fail 'a failed IPv4 deletion must fail strict cleanup'
    return 1
  }
  assert_eq '0' "$route6_present" \
    'an IPv4 deletion failure must not prevent IPv6 cleanup from continuing' || return 1

  fail_delete4=0
  sticky4=1
  route4_present=1
  route6_present=1
  stop_wg_routes_strict && {
    fail 'a route that remains after a successful delete command must fail verification'
    return 1
  }
  assert_eq '0' "$route6_present" \
    'a residual IPv4 route must not prevent IPv6 cleanup from continuing' || return 1

  sticky4=0
  route4_present=1
  route6_present=1
  stop_wg_routes_strict || {
    fail 'strict cleanup should pass after both route families are actually absent'
    return 1
  }
  assert_eq '0' "$route4_present" 'strict cleanup should remove the IPv4 route' || return 1
  assert_eq '0' "$route6_present" 'strict cleanup should remove the IPv6 route'
}

test_wireguard_runtime_avoids_route_readbacks() {
  local body name
  for name in apply_wg_routes wait_for_wg_ready run_self_check test_quiet cmd_heal; do
    body="$(function_body "$MANAGER_SCRIPT" "$name")"
    [ -n "$body" ] || {
      fail "could not extract WireGuard runtime function: $name"
      return 1
    }
    assert_not_contains "$body" 'wireguard_routes_local_ok' \
      "$name must not gate on parsed route output" || return 1
    assert_not_contains "$body" 'wireguard_global_routes_local_ok' \
      "$name must not gate on parsed global state output" || return 1
    assert_not_contains "$body" 'route_uses_wg' \
      "$name must not parse route-get output" || return 1
  done

  body="$(function_body "$MANAGER_SCRIPT" apply_wg_routes)"
  assert_contains "$body" 'ip -4 route replace' \
    'precise WireGuard apply must retain the actual IPv4 route writes' || return 1
  assert_contains "$body" 'ip -6 route replace' \
    'precise WireGuard apply must retain the actual IPv6 route writes'
}

test_wireguard_scope_selects_precise_or_global_writes() {
  source_without_main "$MANAGER_SCRIPT"
  local trace_file trace
  trace_file="$(mktemp)"
  : > "$trace_file"
  load_config() { :; }
  validate_rules_file() { :; }
  wg_interface_is_wireguard() { return 0; }
  stop_wg_routes() { printf 'stop\n' >> "$trace_file"; }
  apply_wg_global_routes() { printf 'global-write\n' >> "$trace_file"; }
  route_file_lines() {
    case "$1" in
      *google_ipv4.txt) printf '8.8.8.0/24\n' ;;
      *google_ipv6.txt) printf '2001:4860::/32\n' ;;
    esac
  }
  ip() { printf 'ip:%s\n' "$*" >> "$trace_file"; }
  WG_IFACE=warp-vps-wg
  RULES_DIR=/unused

  WARP_SCOPE=google
  apply_wg_routes || {
    fail 'precise Google WireGuard route writes should succeed'
    return 1
  }
  trace="$(< "$trace_file")"
  assert_contains "$trace" 'ip:-4 route replace 8.8.8.0/24 dev warp-vps-wg' \
    'precise WireGuard must write Google IPv4 routes' || return 1
  assert_contains "$trace" 'ip:-6 route replace 2001:4860::/32 dev warp-vps-wg' \
    'precise WireGuard must write Google IPv6 routes' || return 1
  assert_not_contains "$trace" 'global-write' \
    'precise WireGuard must not use the global writer' || return 1

  : > "$trace_file"
  WARP_SCOPE=global
  apply_wg_routes || {
    fail 'global WireGuard writes should succeed'
    return 1
  }
  trace="$(< "$trace_file")"
  assert_contains "$trace" 'global-write' \
    'global WireGuard must use the global writer' || return 1
  assert_not_contains "$trace" 'ip:-4 route replace 8.8.8.0/24' \
    'global WireGuard must not write Google-only IPv4 routes'
}

test_wireguard_global_apply_uses_owned_policy_state() {
  source_without_main "$MANAGER_SCRIPT"
  WARP_SCOPE=global
  WG_IFACE=warp-vps-wg
  NFT_CONF=/tmp/warp-vps-test-global.nft
  local events=''
  stop_wg_global_routes() { events="${events}stop-global"$'\n'; }
  enable_wg_global_src_valid_mark() { events="${events}enable-src-valid-mark"$'\n'; }
  render_wg_global_nft_conf() { events="${events}render-global-nft"$'\n'; }
  nft() { events="${events}nft:$*"$'\n'; }
  wg() { events="${events}wg:$*"$'\n'; }
  ip() { events="${events}ip:$*"$'\n'; }
  wireguard_global_routes_local_ok() {
    events="${events}unexpected-global-readback"$'\n'
    return 1
  }

  apply_wg_global_routes || {
    fail 'the complete global WireGuard policy should apply successfully'
    return 1
  }
  assert_contains "$events" 'stop-global' \
    'global WireGuard apply must first clear its previous owned policy state' || return 1
  assert_contains "$events" 'enable-src-valid-mark' \
    'global WireGuard apply must include packet marks in strict reverse-path checks' || return 1
  assert_contains "$events" 'render-global-nft' \
    'global WireGuard apply must render its reply-mark table' || return 1
  assert_contains "$events" 'nft:-c -f /tmp/warp-vps-test-global.nft' \
    'global WireGuard apply must syntax-check its nftables state before activation' || return 1
  assert_contains "$events" 'nft:-f /tmp/warp-vps-test-global.nft' \
    'global WireGuard apply must activate the checked nftables state' || return 1
  assert_contains "$events" 'wg:set warp-vps-wg fwmark 51888' \
    'global WireGuard apply must assign the project fwmark' || return 1
  assert_contains "$events" 'ip:-4 route replace default dev warp-vps-wg table 51888' \
    'global WireGuard apply must own its IPv4 default in table 51888' || return 1
  assert_contains "$events" 'ip:-6 route replace default dev warp-vps-wg table 51888' \
    'global WireGuard apply must own its IPv6 default in table 51888' || return 1
  assert_contains "$events" \
    'ip:-4 rule add priority 18000 table main suppress_prefixlength 0' \
    'global IPv4 policy must consult non-default main routes first' || return 1
  assert_contains "$events" \
    'ip:-6 rule add priority 18000 table main suppress_prefixlength 0' \
    'global IPv6 policy must consult non-default main routes first' || return 1
  assert_contains "$events" \
    'ip:-4 rule add not fwmark 51888 table 51888 priority 18001' \
    'unmarked IPv4 traffic must use the project global table' || return 1
  assert_contains "$events" \
    'ip:-6 rule add not fwmark 51888 table 51888 priority 18001' \
    'unmarked IPv6 traffic must use the project global table' || return 1
  assert_not_contains "$events" 'unexpected-global-readback' \
    'successful global writes must not be rejected by parsing human-readable state'
}

test_wireguard_global_apply_write_failures_cleanup() {
  run_failure() {
    local failed_write="$1"
    (
      source_without_main "$MANAGER_SCRIPT"
      WARP_SCOPE=global
      WG_IFACE=warp-vps-wg
      NFT_CONF=/tmp/warp-vps-test-global.nft
      local cleanup_calls=0
      stop_wg_global_routes() {
        cleanup_calls=$((cleanup_calls + 1))
        printf 'EVENT:cleanup:%s\n' "$cleanup_calls"
      }
      enable_wg_global_src_valid_mark() { return 0; }
      render_wg_global_nft_conf() { :; }
      nft() {
        if [ "$failed_write" = nft ] && [ "$*" = '-f /tmp/warp-vps-test-global.nft' ]; then
          return 1
        fi
        return 0
      }
      wg() { return 0; }
      ip() {
        if [ "$failed_write" = ip-rule ] \
          && [ "$*" = '-4 rule add priority 18000 table main suppress_prefixlength 0' ]; then
          return 1
        fi
        return 0
      }
      apply_wg_global_routes
    )
  }

  local output rc=0
  output="$(run_failure nft 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'a failed nft activation must fail global WireGuard apply'
    return 1
  }
  assert_contains "$output" 'EVENT:cleanup:2' \
    'a failed nft activation must clean partial global state' || return 1

  rc=0
  output="$(run_failure ip-rule 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'a failed ip-rule write must fail global WireGuard apply'
    return 1
  }
  assert_contains "$output" 'EVENT:cleanup:2' \
    'a failed ip-rule write must clean partial global state'
}

test_wireguard_global_reply_mark_and_stop_contract() {
  source_without_main "$MANAGER_SCRIPT"
  WG_IFACE=warp-vps-wg
  NFT_CONF=/dev/stdout
  local rendered events=''
  nft() {
    case "$*" in
      'list table inet warp_vps_global') return 1 ;;
      *) events="${events}nft:$*"$'\n' ;;
    esac
  }
  chmod() { :; }
  rendered="$(render_wg_global_nft_conf)"
  assert_contains "$rendered" 'add table inet warp_vps_global' \
    'global WireGuard must use its dedicated nftables table' || return 1
  assert_contains "$rendered" \
    'add chain inet warp_vps_global prerouting { type filter hook prerouting priority mangle; policy accept; }' \
    'global WireGuard must restore bypass marks before reverse-path filtering' || return 1
  assert_contains "$rendered" \
    'add chain inet warp_vps_global output { type route hook output priority mangle; policy accept; }' \
    'global WireGuard must mark replies in an output route chain' || return 1
  assert_contains "$rendered" \
    'add chain inet warp_vps_global postrouting { type filter hook postrouting priority mangle; policy accept; }' \
    'global WireGuard must save the tunnel endpoint mark after route selection' || return 1
  assert_contains "$rendered" \
    'add rule inet warp_vps_global prerouting ct mark 51888 meta mark set ct mark' \
    'global WireGuard must restore saved marks on incoming packets' || return 1
  assert_contains "$rendered" \
    'iifname != "lo" iifname != "warp-vps-wg" fib daddr type local ct direction original meta mark set 51888 ct mark set meta mark' \
    'new native inbound connections must save the bypass mark before reverse-path filtering' || return 1
  assert_contains "$rendered" \
    'add rule inet warp_vps_global output ct mark 51888 meta mark set ct mark' \
    'replies to native inbound connections must restore the bypass mark' || return 1
  assert_contains "$rendered" \
    'add rule inet warp_vps_global postrouting meta l4proto udp meta mark 51888 ct mark set meta mark' \
    'WireGuard endpoint packets must save their fwmark in conntrack' || return 1

  events=''
  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = nft ]; then return 0; fi
    builtin command "$@"
  }
  ip() { events="${events}ip:$*"$'\n'; return 1; }
  nft() {
    events="${events}nft:$*"$'\n'
    [ "$*" != 'list table inet warp_vps_global' ] || return 0
  }
  wg_interface_is_wireguard() { return 0; }
  wg() { events="${events}wg:$*"$'\n'; }
  stop_wg_global_routes
  assert_contains "$events" \
    'ip:-4 rule del not fwmark 51888 table 51888 priority 18001' \
    'global stop must delete the owned IPv4 global rule' || return 1
  assert_contains "$events" \
    'ip:-6 rule del not fwmark 51888 table 51888 priority 18001' \
    'global stop must delete the owned IPv6 global rule' || return 1
  assert_contains "$events" \
    'ip:-4 rule del table main suppress_prefixlength 0 priority 18000' \
    'global stop must delete the owned IPv4 main-suppression rule' || return 1
  assert_contains "$events" \
    'ip:-6 rule del table main suppress_prefixlength 0 priority 18000' \
    'global stop must delete the owned IPv6 main-suppression rule' || return 1
  assert_contains "$events" 'ip:-4 route del default dev warp-vps-wg table 51888' \
    'global stop must delete the owned IPv4 table default' || return 1
  assert_contains "$events" 'ip:-6 route del default dev warp-vps-wg table 51888' \
    'global stop must delete the owned IPv6 table default' || return 1
  assert_contains "$events" 'nft:delete table inet warp_vps_global' \
    'global stop must remove its dedicated nftables table' || return 1
  assert_contains "$events" 'wg:set warp-vps-wg fwmark off' \
    'global stop must clear the project WireGuard fwmark'
}

test_wireguard_global_src_valid_mark_boundary() {
  source_without_main "$MANAGER_SCRIPT"
  local temp_mark
  temp_mark="$(mktemp)"
  WG_GLOBAL_SRC_VALID_MARK_PATH="$temp_mark"
  printf '0\n' > "$temp_mark"

  if wg_global_src_valid_mark_ok; then
    fail 'a disabled src_valid_mark must fail the global WireGuard boundary check'
    return 1
  fi
  enable_wg_global_src_valid_mark || {
    fail 'global WireGuard should enable src_valid_mark through the kernel control file'
    return 1
  }
  wg_global_src_valid_mark_ok || {
    fail 'the enabled src_valid_mark must pass the global WireGuard boundary check'
    return 1
  }
  chmod 0444 "$temp_mark"
  enable_wg_global_src_valid_mark || {
    fail 'an already enabled read-only src_valid_mark must not block global WireGuard'
    return 1
  }
}

test_wireguard_global_cleanup_ownership_is_exact() {
  source_without_main "$MANAGER_SCRIPT"
  local rules4 rules6
  rules4=$'18000: from all lookup 100\n18001: from all lookup 101'
  rules6="$rules4"
  ip() {
    case "$*" in
      '-4 rule show') printf '%s\n' "$rules4" ;;
      '-6 rule show') printf '%s\n' "$rules6" ;;
      *) return 1 ;;
    esac
  }

  wg_global_policy_rules_absent || {
    fail 'unrelated policy rules that reuse the priorities must not count as project state'
    return 1
  }

  rules4='18001: not from all fwmark 0xcab0 lookup 51888'
  rules6='18001: not from all fwmark 51888 lookup 51888'
  if wg_global_policy_rules_absent; then
    fail 'the exact project policy rules must be found during cleanup'
    return 1
  fi

  rules4='18001: from all fwmark 51888 lookup 51888'
  rules6="$rules4"
  if ! wg_global_policy_rules_absent; then
    fail 'cleanup must not claim an unrelated positive-fwmark rule'
    return 1
  fi
}

test_status_reports_backend_and_route_scope() {
  source_without_main "$MANAGER_SCRIPT"
  local lines=''
  require_root() { :; }
  load_config() { :; }
  section() { :; }
  info_line() { lines="${lines}$1"$'\n'; }
  print_rule_summary() { :; }
  run_self_check() { :; }
  mask_repo_url() { printf 'https://example.invalid/project\n'; }
  REPO_RAW_BASE=https://example.invalid/project
  WG_IFACE=warp-vps-wg
  WARP_SOCKS_PORT=24000
  REDSOCKS_PORT=24001

  WARP_MODE=wireguard
  WARP_SCOPE=global
  cmd_status >/dev/null
  assert_contains "$lines" 'WireGuard' 'status must identify the WireGuard backend' || return 1
  assert_contains "$lines" '全局' 'status must identify the global routing scope' || return 1

  lines=''
  WARP_SCOPE=google
  cmd_status >/dev/null
  assert_contains "$lines" 'Google' 'status must identify precise Google routing' || return 1

  lines=''
  WARP_MODE=socks
  WARP_SCOPE=global
  cmd_status >/dev/null
  assert_contains "$lines" 'Socks5' 'status must identify the Socks5 backend' || return 1
  assert_contains "$lines" '公网 IPv4 TCP' \
    'global Socks status must state its actual traffic boundary'
}

test_wireguard_global_runtime_avoids_state_output_parsers() {
  source_without_main "$MANAGER_SCRIPT"
  WARP_MODE=wireguard
  WARP_SCOPE=global
  WG_IFACE=warp-vps-wg
  REPO_RAW_BASE=https://example.invalid/project
  local parser_calls=0

  require_root() { :; }
  load_config() { :; }
  unit_ready() { return 0; }
  required_runtime_units_ready() { return 0; }
  service_active() { return 0; }
  wg_interface_is_wireguard() { return 0; }
  socks_table_absent() { return 0; }
  run_external_diagnostics() { return 0; }
  print_rule_summary() { :; }
  mask_repo_url() { printf '%s\n' "$1"; }
  wireguard_global_routes_local_ok() {
    parser_calls=$((parser_calls + 1))
    return 1
  }
  wg_global_nft_rules_local_ok() {
    parser_calls=$((parser_calls + 1))
    return 1
  }
  wg_global_policy_rules_present() {
    parser_calls=$((parser_calls + 1))
    return 1
  }
  wg_global_default_routes_present() {
    parser_calls=$((parser_calls + 1))
    return 1
  }

  run_self_check >/dev/null || {
    fail 'status rejected global WireGuard because a display parser failed'
    return 1
  }
  cmd_status >/dev/null || {
    fail 'status command rejected global WireGuard because a display parser failed'
    return 1
  }
  cmd_test >/dev/null || {
    fail 'test command rejected global WireGuard because a display parser failed'
    return 1
  }
  test_quiet || {
    fail 'quiet health rejected global WireGuard because a display parser failed'
    return 1
  }
  cmd_heal >/dev/null || {
    fail 'health repair rejected global WireGuard because a display parser failed'
    return 1
  }
  assert_eq '0' "$parser_calls" \
    'global WireGuard status and health must not parse nft or ip-rule display text'
}

test_socks_nft_render_blocks_google_quic_only() {
  source_without_main "$MANAGER_SCRIPT"
  WARP_SCOPE=google
  RULES_DIR=/unused
  NFT_CONF=/dev/stdout
  REDSOCKS_UID=987
  REDSOCKS_PORT=23456
  validate_rules_file() { :; }
  join_rules() {
    case "$1" in
      *google_ipv4.txt) printf '8.8.8.0/24' ;;
      *google_ipv6.txt) printf '2001:4860::/32' ;;
    esac
  }
  table_exists() { return 1; }
  chmod() { :; }

  local rendered udp_reject_rules
  rendered="$(render_nft_conf)"
  assert_contains "$rendered" 'ip daddr @google4 meta l4proto tcp counter redirect to :23456' \
    'Socks must keep the Google IPv4 TCP redirect' || return 1
  assert_contains "$rendered" \
    'ip daddr @google4 udp dport 443 counter reject with icmpx type admin-prohibited' \
    'Socks must reject Google IPv4 UDP/443' || return 1
  assert_contains "$rendered" 'ip6 daddr @google6 counter reject' \
    'Socks must keep the Google IPv6 reject' || return 1
  udp_reject_rules="$(grep -E 'add rule inet warp_vps output_filter .*udp.*(drop|reject)' <<< "$rendered")"
  assert_eq \
    'add rule inet warp_vps output_filter ip daddr @google4 udp dport 443 counter reject with icmpx type admin-prohibited' \
    "$udp_reject_rules" \
    'Socks must reject only Google IPv4 UDP/443'
}

test_socks_runtime_accepts_v0111_rule_shape() {
  source_without_main "$MANAGER_SCRIPT"
  WARP_MODE=socks
  WARP_SOCKS_PORT=24000
  REDSOCKS_PORT=24001
  REPO_RAW_BASE=https://example.invalid/project
  local parsed_rule_chains=0 scope

  require_root() { :; }
  load_config() { :; }
  unit_ready() { return 0; }
  required_runtime_units_ready() { return 0; }
  service_active() { return 0; }
  wait_for_socks_listen() { return 0; }
  redsocks_local_ready() { return 0; }
  socks_wireguard_routes_absent() { return 0; }
  warp_proxy_local_ready() { return 0; }
  run_external_diagnostics() { return 0; }
  print_rule_summary() { :; }
  mask_repo_url() { printf '%s\n' "$1"; }
  nft() {
    case "$*" in
      'list table inet warp_vps') return 0 ;;
      'list chain inet warp_vps output_nat')
        parsed_rule_chains=$((parsed_rule_chains + 1))
        printf '%s\n' 'ip daddr @google4 meta l4proto tcp redirect to :24001'
        ;;
      'list chain inet warp_vps output_filter')
        parsed_rule_chains=$((parsed_rule_chains + 1))
        # v0.1.11 rejected Google IPv6 but had no Google UDP/443 rule.
        printf '%s\n' 'ip6 daddr @google6 reject with icmpx type admin-prohibited'
        ;;
      *) return 1 ;;
    esac
  }

  for scope in google global; do
    WARP_SCOPE="$scope"
    run_self_check >/dev/null || {
      fail "status rejected a healthy Socks runtime with legacy rules in $scope scope"
      return 1
    }
    cmd_status >/dev/null || {
      fail "status command rejected legacy Socks rules in $scope scope"
      return 1
    }
    cmd_test >/dev/null || {
      fail "test command rejected legacy Socks rules in $scope scope"
      return 1
    }
    test_quiet || {
      fail "quiet health rejected legacy Socks rules in $scope scope"
      return 1
    }
    cmd_heal >/dev/null || {
      fail "health repair rejected legacy Socks rules in $scope scope"
      return 1
    }
  done
  assert_eq '0' "$parsed_rule_chains" \
    'status, test, quiet health and heal must not parse individual nft rules'
}

test_socks_global_nft_redirects_public_ipv4_tcp() {
  source_without_main "$MANAGER_SCRIPT"
  WARP_SCOPE=global
  RULES_DIR=/unused
  NFT_CONF=/dev/stdout
  REDSOCKS_UID=987
  REDSOCKS_PORT=23456
  validate_rules_file() { :; }
  join_rules() {
    case "$1" in
      *google_ipv4.txt) printf '8.8.8.0/24' ;;
      *google_ipv6.txt) printf '2001:4860::/32' ;;
    esac
  }
  table_exists() { return 1; }
  chmod() { :; }

  local rendered uid_line loopback_line private_line reply_line redirect_line
  rendered="$(render_nft_conf)"
  assert_contains "$rendered" 'meta skuid 987 return' \
    'global Socks rules must keep the redsocks loop exclusion' || return 1
  assert_contains "$rendered" 'oifname "lo" return' \
    'global Socks rules must keep loopback traffic native' || return 1
  assert_contains "$rendered" \
    'ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8' \
    'global Socks rules must keep the existing private and special IPv4 exclusion' || return 1
  assert_contains "$rendered" 'ct direction reply return' \
    'global Socks rules must keep replies to inbound connections on the native path' || return 1
  if ! grep -Eq \
    'add rule inet warp_vps output_nat (meta nfproto ipv4|ip daddr 0\.0\.0\.0/0) meta l4proto tcp counter redirect to :23456' \
    <<< "$rendered"; then
    fail 'global Socks rules must redirect all remaining public IPv4 TCP traffic'
    return 1
  fi
  assert_not_contains "$rendered" \
    'ip daddr @google4 meta l4proto tcp counter redirect to :23456' \
    'global Socks redirect must not remain limited to Google IPv4' || return 1
  assert_contains "$rendered" \
    'ip daddr @google4 udp dport 443 counter reject with icmpx type admin-prohibited' \
    'global Socks must retain the existing Google QUIC rejection' || return 1
  assert_contains "$rendered" 'ip6 daddr @google6 counter reject' \
    'global Socks must retain the existing Google IPv6 rejection' || return 1

  uid_line="$(line_number "$rendered" 'meta skuid 987 return')"
  loopback_line="$(line_number "$rendered" 'oifname "lo" return')"
  private_line="$(line_number "$rendered" 'ip daddr { 0.0.0.0/8')"
  reply_line="$(line_number "$rendered" 'ct direction reply return')"
  redirect_line="$(awk '/add rule inet warp_vps output_nat (meta nfproto ipv4|ip daddr 0\.0\.0\.0\/0) meta l4proto tcp/ { print NR; exit }' <<< "$rendered")"
  if [ -z "$redirect_line" ] || [ "$uid_line" -ge "$redirect_line" ] \
    || [ "$loopback_line" -ge "$redirect_line" ] || [ "$private_line" -ge "$redirect_line" ] \
    || [ "$reply_line" -ge "$redirect_line" ]; then
    fail 'every global Socks bypass must precede the catch-all IPv4 TCP redirect'
    return 1
  fi
}

test_wireguard_apply_clears_stale_socks_table() {
  source_without_main "$MANAGER_SCRIPT"
  local table_present=1 delete_fails=0 delete_calls=0 route_calls=0
  WARP_MODE=wireguard
  REPO_RAW_BASE="$DEFAULT_REPO_RAW_BASE"
  ETC_DIR=/unused
  load_config() { :; }
  validate_repo_raw_base() { :; }
  install() { :; }
  command() {
    [ "${1:-}" = '-v' ] && [ "${2:-}" = nft ] && return 0
    builtin command "$@"
  }
  nft() {
    case "$*" in
      'list tables')
        [ "$table_present" -eq 1 ] && printf 'table inet warp_vps\n'
        return 0
        ;;
      'delete table inet warp_vps')
        delete_calls=$((delete_calls + 1))
        [ "$delete_fails" -eq 0 ] || return 1
        table_present=0
        ;;
      *) return 1 ;;
    esac
  }
  apply_wg_routes() {
    [ "$table_present" -eq 0 ] || return 1
    route_calls=$((route_calls + 1))
  }

  apply_rules || {
    fail 'WireGuard rule application should remove a stale Socks nftables table'
    return 1
  }
  assert_eq '1' "$delete_calls" \
    'the shared WireGuard apply boundary should delete the stale Socks table once' || return 1
  assert_eq '1' "$route_calls" \
    'WireGuard routes should apply only after the stale Socks table is absent' || return 1

  table_present=1
  delete_fails=1
  if clear_socks_table_for_wireguard; then
    fail 'a failed stale Socks table deletion must remain a local WireGuard apply error'
    return 1
  fi

  table_present=0
  delete_fails=0
  route_calls=0
  command() {
    [ "${1:-}" = '-v' ] && [ "${2:-}" = nft ] && return 1
    builtin command "$@"
  }
  apply_rules || {
    fail 'a clean precise WireGuard apply should work without the optional nft command'
    return 1
  }
  assert_eq '1' "$route_calls" \
    'precise WireGuard routes should still apply when no Socks cleanup tool is installed' || return 1
  unset -f command
}

test_mode_switch_rejects_live_opposite_backend() {
  source_without_main "$MANAGER_SCRIPT"
  load_config() { :; }

  WG_IFACE=warp-vps-wg
  WARP_MODE=wireguard
  WARP_SCOPE=google
  wg_interface_is_wireguard() { return 0; }
  rule_probe_ip() {
    case "$2" in
      4) printf '8.8.8.0\n' ;;
      6) printf '2001:4860::\n' ;;
    esac
  }
  route_uses_wg4() { return 0; }
  route_uses_wg6() { return 0; }
  wg_default_routes_absent() { return 0; }
  wg_global_routes_absent() { return 0; }
  socks_table_absent() { return 1; }
  if test_quiet; then
    fail 'WireGuard local state must reject a live old Socks nft table'
    return 1
  fi
  socks_table_absent() { return 0; }
  test_quiet || {
    fail 'WireGuard local state should pass after the old Socks table is absent'
    return 1
  }
  socks_table_absent() { return 2; }
  test_quiet || {
    fail 'an unreadable opposite-backend query must not fail an otherwise healthy WireGuard runtime'
    return 1
  }

  WARP_MODE=socks
  WG_IFACE=warp-vps-wg
  WARP_SOCKS_PORT=23456
  REDSOCKS_PORT=23457
  wait_for_socks_listen() { return 0; }
  redsocks_local_ready() { return 0; }
  service_active() { return 0; }
  table_exists() { return 0; }
  socks_nft_rules_local_ok() { return 0; }
  wg_interface_absent() { return 1; }
  rule_probe_ip() { printf '8.8.8.0\n'; }
  local socks_google_route_iface=warp-vps-wg
  ip() {
    case "$*" in
      '-4 route get 8.8.8.0') printf '8.8.8.0 dev %s\n' "$socks_google_route_iface" ;;
      '-4 route show default') printf 'default dev eth0\n' ;;
      '-6 route show default') return 0 ;;
      *) return 1 ;;
    esac
  }
  if test_quiet; then
    fail 'Socks status must reject Google routes still pointing at a dormant WireGuard interface'
    return 1
  fi
  socks_google_route_iface=eth0
  test_quiet || {
    fail 'a dormant WireGuard interface is harmless once Google and default routes use native interfaces'
    return 1
  }
  socks_wireguard_routes_absent() { return 2; }
  test_quiet || {
    fail 'an unreadable opposite-backend query must not fail an otherwise healthy Socks runtime'
    return 1
  }
}

test_opposite_backend_checks_preserve_three_states() {
  source_without_main "$MANAGER_SCRIPT"
  local rc=0 failures=0 warnings=0

  nft() { return 1; }
  rc=0
  socks_table_absent || rc=$?
  assert_eq '2' "$rc" \
    'an nftables query error must be distinct from a confirmed stale Socks table' || return 1
  clear_socks_table_for_wireguard || {
    fail 'an unreadable optional nftables query must not block precise WireGuard activation'
    return 1
  }

  command() {
    [ "$1" = '-v' ] || return 1
    [ "$2" != nft ] && builtin command "$@"
  }
  rc=0
  socks_table_absent || rc=$?
  assert_eq '2' "$rc" \
    'a missing nft userspace command cannot prove that an old kernel table is absent' || return 1
  if ! clear_socks_table_for_wireguard; then
    fail 'a clean precise WireGuard activation must not require the optional nft command'
    return 1
  fi
  unset -f command

  rule_probe_ip() { return 1; }
  rc=0
  socks_wireguard_routes_absent || rc=$?
  assert_eq '2' "$rc" \
    'a route query error must be distinct from a confirmed stale WireGuard route' || return 1

  section() { :; }
  info_line() { :; }
  ok_line() { :; }
  fail_line() { failures=$((failures + 1)); }
  warn_line() { warnings=$((warnings + 1)); }
  unit_ready() { return 0; }
  wg_interface_is_wireguard() { return 0; }
  socks_table_absent() { return 2; }
  WARP_MODE=wireguard
  WARP_SCOPE=google
  WG_IFACE=warp-vps-wg
  run_self_check || {
    fail 'status must remain usable when only the opposite-backend query is unreadable'
    return 1
  }
  assert_eq '0' "$failures" \
    'opposite-backend query uncertainty must not be reported as a confirmed local failure' || return 1
  [ "$warnings" -gt 0 ] || {
    fail 'opposite-backend query uncertainty should remain visible as a warning'
    return 1
  }

  failures=0
  warnings=0
  wait_for_socks_listen() { return 0; }
  redsocks_local_ready() { return 0; }
  table_exists() { return 0; }
  socks_wireguard_routes_absent() { return 2; }
  WARP_MODE=socks
  WARP_SCOPE=google
  WARP_SOCKS_PORT=23456
  REDSOCKS_PORT=23457
  run_self_check || {
    fail 'Socks status must remain usable when only the opposite-backend query is unreadable'
    return 1
  }
  assert_eq '0' "$failures" \
    'Socks route-query uncertainty must not be reported as a confirmed local failure' || return 1
  [ "$warnings" -gt 0 ] || {
    fail 'Socks route-query uncertainty should remain visible as a warning'
  }
}

test_ssh_peer_route_uses_rule_check_status() {
  source_without_main "$MANAGER_SCRIPT"
  local die_calls=0
  local die_message=''

  ssh_peer_ip() { printf '203.0.113.10\n'; }
  die() {
    die_calls=$((die_calls + 1))
    die_message="$1"
    return 1
  }
  ip_in_google_rules() { return 0; }

  if ! protect_ssh_peer_route; then
    fail 'an SSH peer outside the Google rules should be allowed'
    return 1
  fi
  assert_eq '0' "$die_calls" 'a safe SSH peer must not be blocked' || return 1

  ip_in_google_rules() { return 2; }
  if protect_ssh_peer_route; then
    fail 'an SSH peer inside the Google rules should be blocked'
    return 1
  fi
  assert_eq '1' "$die_calls" 'a matching SSH peer should stop WireGuard setup' || return 1
  assert_contains "$die_message" '当前 SSH 来源 IP 命中 Google 规则' \
    'the blocked path should explain the route risk'
}

test_existing_warp_registration_is_reused() {
  source_without_main "$MANAGER_SCRIPT"
  local registration_checks=0
  local registration_creates=0
  local command_calls=''

  warp-cli() { :; }
  systemctl() { return 0; }
  sleep() { :; }
  wait_for_warp_proxy_ready() { return 0; }
  inspect_warp_registration() {
    registration_checks=$((registration_checks + 1))
    WARP_REGISTRATION_STATE=present
  }
  create_warp_registration() {
    registration_creates=$((registration_creates + 1))
  }
  try_warp_command() {
    command_calls="${command_calls}$*\n"
    return 0
  }

  WARP_SOCKS_PORT=23456
  configure_warp_runtime
  assert_eq '1' "$registration_checks" \
    'an existing WARP registration should be inspected once' || return 1
  assert_eq '0' "$registration_creates" \
    'an existing WARP registration must not be replaced' || return 1
  assert_contains "$command_calls" 'mode proxy' \
    'the existing client should be switched to proxy mode' || return 1
  assert_contains "$command_calls" 'proxy port 23456' \
    'the existing client should be assigned the project port' || return 1

  registration_checks=0
  registration_creates=0
  command_calls=''
  inspect_warp_registration() {
    registration_checks=$((registration_checks + 1))
    WARP_REGISTRATION_STATE=missing
  }
  create_warp_registration() {
    registration_creates=$((registration_creates + 1))
    WARP_REGISTRATION_STATE=present
    return 0
  }

  configure_warp_runtime
  assert_eq '1' "$registration_checks" \
    'a missing registration should be identified before proxy configuration' || return 1
  assert_eq '1' "$registration_creates" \
    'only a confirmed missing registration should create a registration'
}

test_warp_registration_has_three_states() {
  source_without_main "$MANAGER_SCRIPT"
  sleep() { :; }

  timeout() {
    case "$*" in
      *'registration show'*) printf 'Registration ID: existing\n'; return 0 ;;
      *) return 1 ;;
    esac
  }
  inspect_warp_registration
  assert_eq 'present' "$WARP_REGISTRATION_STATE" \
    'a successful registration show should be present' || return 1

  timeout() {
    case "$*" in
      *'registration show'*) printf 'Registration Missing due to: no registration\n'; return 0 ;;
      *) return 1 ;;
    esac
  }
  inspect_warp_registration
  assert_eq 'missing' "$WARP_REGISTRATION_STATE" \
    'missing output must win even when warp-cli exits zero' || return 1

  timeout() {
    printf 'IPC unavailable\n'
    return 1
  }
  inspect_warp_registration
  assert_eq 'unknown' "$WARP_REGISTRATION_STATE" \
    'IPC errors must remain unknown instead of creating a new registration'
}

test_warp_command_errors_defer_to_real_readiness() {
  source_without_main "$MANAGER_SCRIPT"
  local registration_creates=0

  warp-cli() { :; }
  systemctl() { return 0; }
  sleep() { :; }
  inspect_warp_registration() { WARP_REGISTRATION_STATE=unknown; }
  create_warp_registration() {
    registration_creates=$((registration_creates + 1))
  }
  try_warp_command() { return 1; }
  wait_for_warp_proxy_ready() { return 0; }

  WARP_SOCKS_PORT=23456
  configure_warp_runtime || {
    fail 'command exit codes must not override a working listener and SOCKS trace'
    return 1
  }
  assert_eq '0' "$registration_creates" \
    'an unknown registration state must not trigger speculative registration'
}

test_socks_local_readiness_rejects_unowned_or_invalid_listeners() {
  source_without_main "$MANAGER_SCRIPT"
  local listener_pid="$$" python_rc=0 python_args='' python_body='' python3_path
  python3_path="$(command -v python3)"
  systemctl() {
    case "$1" in
      is-active) return 0 ;;
      show)
        printf 'MainPID=%s\nControlGroup=/system.slice/warp-svc.service\n' "$$"
        ;;
      *) return 1 ;;
    esac
  }
  ss() {
    printf 'LISTEN 0 1024 127.0.0.1:24000 0.0.0.0:* users:(("listener",pid=%s,fd=7))\n' \
      "$listener_pid"
  }

  service_owns_listening_port warp-svc.service 24000 || {
    fail 'the systemd main PID should prove ownership of its listening port'
    return 1
  }
  listener_pid=99999999
  if service_owns_listening_port warp-svc.service 24000; then
    fail 'an unrelated listener PID must not be accepted as the project service'
    return 1
  fi

  python3() {
    python_args="$*"
    python_body="$(command cat)"
    return "$python_rc"
  }
  socks5_greeting_ok 24000 || {
    fail 'a successful local SOCKS5 greeting should be accepted'
    return 1
  }
  assert_eq '- 24000' "$python_args" 'the greeting must target only the configured loopback port' || return 1
  assert_contains "$python_body" 'while len(response) < 2' \
    'the local greeting must read a fragmented two-byte TCP response completely' || return 1
  assert_contains "$python_body" 'bytes(response) != b"\x05\x00"' \
    'the local check must require a real SOCKS5 no-auth response' || return 1
  python_rc=1
  if socks5_greeting_ok 24000; then
    fail 'a non-SOCKS listener must not be accepted as WARP Local Proxy'
    return 1
  fi

  python3() {
    local client_code
    client_code="$(command cat)"
    WARP_TEST_CLIENT_CODE="$client_code" "$python3_path" - <<'PY'
import os
import socket
import sys
import threading
import time

server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(1)
listen_port = server.getsockname()[1]

def serve():
    connection, _ = server.accept()
    with connection:
        request = bytearray()
        while len(request) < 3:
            chunk = connection.recv(3 - len(request))
            if not chunk:
                return
            request.extend(chunk)
        connection.sendall(b"\x05")
        time.sleep(0.05)
        connection.sendall(b"\x00")
    server.close()

thread = threading.Thread(target=serve, daemon=True)
thread.start()
sys.argv = ["-", str(listen_port)]
try:
    exec(compile(os.environ["WARP_TEST_CLIENT_CODE"], "<socks-client>", "exec"))
finally:
    thread.join(timeout=2)
PY
  }
  socks5_greeting_ok 24000 || {
    fail 'a valid SOCKS5 reply split across two TCP reads must still pass'
    return 1
  }

  WARP_SOCKS_PORT=24000
  service_owns_listening_port() { return 0; }
  socks5_greeting_ok() { return 1; }
  if warp_proxy_local_ready; then
    fail 'WARP local readiness must include the SOCKS5 protocol check'
    return 1
  fi
}

test_reused_socks_port_conflict_stops_before_runtime_mutation() {
  source_without_main "$INSTALL_SCRIPT"
  local root event output rc=0
  root="$(mktemp -d)"
  event="$root/events"
  CONFIG_FILE="$root/config.env"
  printf 'WARP_MODE=socks\nWARP_SOCKS_PORT=24000\nREDSOCKS_PORT=24001\n' > "$CONFIG_FILE"
  : > "$event"

  INSTALL_NONINTERACTIVE=1
  INSTALL_MODE_OPTION=socks
  INSTALL_SWAP_OPTION=none
  INSTALL_SOCKS_PORT_OPTION=''
  require_root() { :; }
  require_systemd() { :; }
  validate_repo_raw_base() { :; }
  read_project_mode() { printf 'socks\n'; }
  read_project_warp_port() { printf '24000\n'; }
  read_project_redsocks_port() { printf '24001\n'; }
  collect_swap_choice() { SWAP_ACTION=none; SWAP_SIZE_MB=0; }
  acquire_operation_lock() { :; }
  capture_service_ownership() { :; }
  read_previous_wireguard_runtime() { PREVIOUS_MODE=socks; }
  stage_project_files() { PROJECT_STAGE_DIR="$root/stage"; }
  validate_existing_config() { :; }
  backup_project_files() { return 0; }
  apply_swap_choice() { :; }
  install_dependencies() { :; }
  validate_staged_rules() { return 0; }
  disable_new_packaged_redsocks_service() { :; }
  preflight_nft_nat() { :; }
  port_in_use() { [ "$1" = 24000 ]; }
  current_socks_backend_local_ready() { return 1; }
  current_socks_backend_owns_port() { return 0; }
  if project_port_conflicts 24000 24000 current_socks_backend_owns_port; then
    fail 'an owned reusable port must remain repairable when its SOCKS greeting is temporarily invalid'
    return 1
  fi
  current_socks_backend_owns_port() { return 1; }
  project_port_conflicts 24000 24000 current_socks_backend_owns_port || {
    fail 'an unowned listener on the reusable port must be treated as a real conflict'
    return 1
  }
  ensure_redsocks_user() { printf 'ensure-redsocks\n' >> "$event"; }
  quiesce_health_automation() { printf 'quiesce\n' >> "$event"; }
  log() { :; }

  output="$(main 2>&1)" || rc=$?
  assert_eq '1' "$rc" 'an unowned process on the reusable WARP port must fail installation' || return 1
  assert_contains "$output" '已被其他进程占用' \
    'the deterministic local conflict should have an actionable error' || return 1
  assert_eq '' "$(< "$event")" \
    'the port conflict must stop before user creation, old-runtime quiesce or rule changes'
}

test_socks_waits_use_wall_clock_deadlines() {
  source_without_main "$MANAGER_SCRIPT"
  local probes=0 sleeps=0 rc=0
  WARP_SOCKS_PORT=24000
  warp_proxy_local_ready() {
    probes=$((probes + 1))
    SECONDS=$((SECONDS + 2))
    return 1
  }
  sleep() {
    sleeps=$((sleeps + 1))
    SECONDS=$((SECONDS + $1))
  }

  SECONDS=0
  wait_for_socks_listen 8 || rc=$?
  assert_eq '1' "$rc" 'an unavailable local proxy must fail at its deadline' || return 1
  [ "$probes" -le 4 ] || {
    fail "an 8-second deadline performed too many 2-second probes: $probes"
    return 1
  }
  [ "$sleeps" -le 3 ] || {
    fail "the wait loop exceeded its wall-clock sleep budget: $sleeps"
    return 1
  }
  assert_contains "$(function_body "$MANAGER_SCRIPT" wait_for_redsocks_ready)" \
    'deadline=$((SECONDS + max_wait))' \
    'redsocks readiness must use the same wall-clock deadline boundary'
}

test_swap_failure_returns_to_selection() {
  source_without_main "$INSTALL_SCRIPT"
  local create_calls=0
  local create_sizes=''
  local prompt_calls=0

  SWAP_ACTION=create
  SWAP_SIZE_MB=1024
  create_swap_file() {
    create_calls=$((create_calls + 1))
    create_sizes="${create_sizes} $1"
    [ "$create_calls" -ge 2 ]
  }
  mem_available_mb() { printf '512\n'; }
  prompt_swap_creation() {
    prompt_calls=$((prompt_calls + 1))
    SWAP_ACTION=create
    SWAP_SIZE_MB=2048
  }

  apply_swap_choice >/dev/null
  assert_eq '2' "$create_calls" 'Swap creation should retry after returning to selection' || return 1
  assert_eq '1' "$prompt_calls" 'a failed Swap creation should reopen the selection prompt' || return 1
  assert_eq ' 1024 2048' "$create_sizes" 'the retry should use the newly selected Swap size'
}

test_unconfirmed_swap_cleanup_stops_all_install_paths() {
  source_without_main "$INSTALL_SCRIPT"
  local path call_log output calls rc
  call_log="$(mktemp)"
  create_swap_file() {
    printf 'create\n' >> "$call_log"
    return 2
  }
  mem_available_mb() { printf '512\n'; }
  prompt_swap_creation() {
    printf 'prompt\n' >> "$call_log"
    SWAP_ACTION=none
  }

  for path in implicit interactive; do
    : > "$call_log"
    SWAP_ACTION=create
    SWAP_SIZE_MB=1024
    INSTALL_SWAP_EXPLICIT=0
    case "$path" in
      implicit) INSTALL_NONINTERACTIVE=1 ;;
      interactive) INSTALL_NONINTERACTIVE=0 ;;
    esac
    rc=0
    output="$(apply_swap_choice 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] || {
      fail "$path Swap cleanup uncertainty must stop installation"
      return 1
    }
    calls="$(< "$call_log")"
    assert_eq 'create' "$calls" \
      "$path cleanup uncertainty must neither continue nor retry Swap creation" || return 1
    assert_contains "$output" '无法确认本次创建已完整撤销' \
      "$path cleanup uncertainty must report the unresolved state" || return 1
    assert_not_contains "$output" '已撤销本次创建；本次继续安装' \
      "$path cleanup uncertainty must not claim that rollback succeeded" || return 1
    assert_not_contains "$output" '请重新选择' \
      "$path cleanup uncertainty must not return to the interactive selection"
  done
}

test_swap_defaults_to_one_gig() {
  source_without_main "$INSTALL_SCRIPT"

  read_input() { printf -v "$1" '%s' ''; }
  max_creatable_swap_mb() { printf '16384\n'; }
  format_gb() { printf '%sM' "$1"; }

  prompt_swap_creation 512 >/dev/null
  assert_eq 'create' "$SWAP_ACTION" 'empty Swap input should select creation' || return 1
  assert_eq '1024' "$SWAP_SIZE_MB" 'empty Swap input should default to 1G'
}

test_no_swap_defaults_to_one_gig_even_with_sufficient_memory() {
  source_without_main "$INSTALL_SCRIPT"
  local prompt_calls=0
  mem_available_mb() { printf '4096\n'; }
  swap_total_mb() { printf '0\n'; }
  swap_free_mb() { printf '0\n'; }
  prompt_swap_creation() {
    prompt_calls=$((prompt_calls + 1))
    SWAP_ACTION=create
    SWAP_SIZE_MB=1024
  }

  collect_swap_choice
  assert_eq '1' "$prompt_calls" \
    'a no-Swap host should receive the 1G default even when memory exceeds 1G' || return 1
  assert_eq 'create' "$SWAP_ACTION" 'the default no-Swap action should create Swap' || return 1
  assert_eq '1024' "$SWAP_SIZE_MB" 'the default installation should select exactly 1G Swap'
}

test_swap_creation_works_with_older_coreutils() {
  local body
  body="$(function_body "$INSTALL_SCRIPT" create_swap_file)"
  assert_not_contains "$body" 'status=progress' \
    'Swap creation must not require dd status=progress from newer coreutils'
}

test_custom_swap_is_decimal_and_rollback_releases_space() {
  source_without_main "$INSTALL_SCRIPT"
  local answer_index=0
  local answers=('3' '08')

  read_input() {
    printf -v "$1" '%s' "${answers[$answer_index]}"
    answer_index=$((answer_index + 1))
  }
  max_creatable_swap_mb() { printf '16384\n'; }
  format_gb() { printf '%sM' "$1"; }

  prompt_swap_creation 512 >/dev/null
  assert_eq 'create' "$SWAP_ACTION" 'a valid custom Swap choice should be accepted' || return 1
  assert_eq '8192' "$SWAP_SIZE_MB" '08 must be parsed as decimal 8G' || return 1
  assert_file_matches "$INSTALL_SCRIPT" ': > "\$SWAP_FILE"' \
    'failed Swap rollback must release the allocated disk blocks' || return 1
  assert_file_matches "$INSTALL_SCRIPT" '\$1 != swap_file' \
    'failed Swap rollback must remove its own fstab entry' || return 1

  local body swapoff_line fstab_write_line
  body="$(function_body "$INSTALL_SCRIPT" rollback_swap_file)"
  swapoff_line="$(line_number "$body" 'swapoff "$SWAP_FILE"')"
  fstab_write_line="$(line_number "$body" 'install -m 0644 "$cleaned_fstab" /etc/fstab')"
  if [ -z "$swapoff_line" ] || [ -z "$fstab_write_line" ] \
    || [ "$swapoff_line" -ge "$fstab_write_line" ]; then
    fail 'Swap rollback must stop the live Swap before changing its boot record'
    return 1
  fi
}

test_swap_state_reader_and_rollback_failure_contract() {
  source_without_main "$INSTALL_SCRIPT"
  local state_root listed_file absent_file missing_file rc body
  local move_line final_proc_line final_fstab_line final_file_line success_line
  state_root="$(mktemp -d)"
  listed_file="${state_root}/listed"
  absent_file="${state_root}/absent"
  missing_file="${state_root}/missing"
  SWAP_FILE=/swapfile-warp-vps-manager
  printf 'Filename Type Size Used Priority\n%s file 1024 0 -2\n' "$SWAP_FILE" > "$listed_file"
  printf 'Filename Type Size Used Priority\n' > "$absent_file"

  rc=0
  swap_file_listed_in "$listed_file" || rc=$?
  assert_eq '0' "$rc" 'the Swap state reader must identify a listed managed file' || return 1
  rc=0
  swap_file_listed_in "$absent_file" || rc=$?
  assert_eq '1' "$rc" 'the Swap state reader must distinguish confirmed absence' || return 1
  rc=0
  swap_file_listed_in "$missing_file" || rc=$?
  assert_eq '2' "$rc" 'an unreadable Swap state source must remain unknown' || return 1

  body="$(function_body "$INSTALL_SCRIPT" rollback_swap_file)"
  assert_contains "$body" $'log "无法创建 Swap 回滚目录，已保留当前 Swap 状态：$backup_dir"\n    return 1' \
    'a missing rollback directory must report rollback failure' || return 1
  assert_contains "$body" $'log "无法备份 /etc/fstab，已保留当前 Swap 状态"\n        return 1' \
    'an unavailable fstab backup must report rollback failure' || return 1
  assert_contains "$body" $'log "无法生成清理后的 /etc/fstab，已保留当前 Swap 状态"\n        return 1' \
    'an unavailable cleaned fstab must report rollback failure' || return 1
  assert_contains "$body" '*) log "无法读取 /etc/fstab，已保留当前 Swap 状态"; return 1 ;;' \
    'an unreadable fstab state must report rollback failure' || return 1
  assert_contains "$body" $'log "无法停用 $SWAP_FILE，已保留当前 fstab 记录和文件，避免破坏正在使用的 Swap"\n        return 1' \
    'a failed swapoff must report rollback failure' || return 1
  assert_contains "$body" '*) log "无法读取 /proc/swaps，已保留当前 Swap 状态"; return 1 ;;' \
    'an unreadable live Swap state must report rollback failure' || return 1
  assert_contains "$body" $'log "无法恢复 /etc/fstab，已保留 Swap 文件；请检查：${backup_dir}/fstab.before-warp-vps"\n      return 1' \
    'a failed fstab replacement must report rollback failure' || return 1

  assert_contains "$body" $'log "无法释放失败 Swap 占用的磁盘空间：$SWAP_FILE"\n      return 1' \
    'a failed Swap truncation must report rollback failure' || return 1
  assert_contains "$body" $'log "Swap 空间已释放，但无法移动零长度占位文件：$SWAP_FILE"\n      return 1' \
    'a failed placeholder move must report rollback failure' || return 1
  assert_contains "$body" $'swap_file_listed_in /proc/swaps || state_rc=$?\n  [ "$state_rc" -eq 1 ] || { log "无法确认失败 Swap 已停用"; return 1; }' \
    'rollback success must require confirmed absence from /proc/swaps' || return 1
  assert_contains "$body" $'swap_file_listed_in /etc/fstab || state_rc=$?\n  [ "$state_rc" -eq 1 ] || { log "无法确认失败 Swap 的 fstab 记录已清除"; return 1; }' \
    'rollback success must require confirmed absence from /etc/fstab' || return 1
  assert_contains "$body" $'if [ -e "$SWAP_FILE" ]; then\n    log "失败 Swap 文件仍存在：$SWAP_FILE"\n    return 1' \
    'rollback success must require the managed Swap path to be absent' || return 1

  move_line="$(line_number "$body" 'mv "$SWAP_FILE"')"
  final_proc_line="$(awk -v pattern='swap_file_listed_in /proc/swaps' \
    'index($0, pattern) { line=NR } END { print line }' <<< "$body")"
  final_fstab_line="$(awk -v pattern='swap_file_listed_in /etc/fstab' \
    'index($0, pattern) { line=NR } END { print line }' <<< "$body")"
  final_file_line="$(awk -v pattern='if [ -e "$SWAP_FILE" ]; then' \
    'index($0, pattern) { line=NR } END { print line }' <<< "$body")"
  success_line="$(awk '$0 == "  return 0" { line=NR } END { print line }' <<< "$body")"
  if [ -z "$move_line" ] || [ -z "$final_proc_line" ] || [ -z "$final_fstab_line" ] \
    || [ -z "$final_file_line" ] || [ -z "$success_line" ] \
    || [ "$move_line" -ge "$final_proc_line" ] \
    || [ "$final_proc_line" -ge "$final_fstab_line" ] \
    || [ "$final_fstab_line" -ge "$final_file_line" ] \
    || [ "$final_file_line" -ge "$success_line" ]; then
    fail 'rollback may return success only after all three post-cleanup states are reverified'
    return 1
  fi
}

test_noninteractive_swap_choices_and_failure_are_bounded() {
  source_without_main "$INSTALL_SCRIPT"
  swap_total_mb() { printf '%s\n' "$mock_swap_total"; }
  max_creatable_swap_mb() { printf '%s\n' "$mock_max_swap"; }
  local mock_swap_total=0 mock_max_swap=4096 output output_file rc=0 option
  output_file="$(mktemp)"

  parse_install_options --non-interactive
  collect_swap_choice
  assert_eq 'create' "$SWAP_ACTION" 'noninteractive no-Swap default must create Swap' || return 1
  assert_eq '1024' "$SWAP_SIZE_MB" 'noninteractive default Swap must be exactly 1G' || return 1
  assert_eq '0' "${INSTALL_SWAP_EXPLICIT:-unset}" \
    'an omitted --swap option must remain distinguishable from explicit auto' || return 1

  parse_install_options --non-interactive --swap 2
  collect_swap_choice
  assert_eq '2048' "$SWAP_SIZE_MB" 'an explicit Swap value must be interpreted as GiB' || return 1
  assert_eq '1' "${INSTALL_SWAP_EXPLICIT:-unset}" \
    'an explicit Swap size must retain its strict failure policy' || return 1

  parse_install_options --non-interactive --swap none
  collect_swap_choice >/dev/null
  assert_eq 'none' "$SWAP_ACTION" '--swap none must skip creation without prompting' || return 1

  mock_swap_total=512
  parse_install_options --non-interactive --swap 2
  collect_swap_choice
  assert_eq 'none' "$SWAP_ACTION" 'an existing Swap must never be duplicated' || return 1

  mock_swap_total=0
  mock_max_swap=512
  parse_install_options --non-interactive
  rc=0
  collect_swap_choice > "$output_file" 2>&1 || rc=$?
  output="$(< "$output_file")"
  assert_eq '0' "$rc" 'insufficient disk for implicit 1G Swap must not block installation' || return 1
  assert_eq 'none' "$SWAP_ACTION" \
    'an unavailable implicit Swap allocation must continue without Swap' || return 1
  assert_contains "$output" 'Swap' 'the implicit disk-space skip must remain visible' || return 1

  for option in auto 2; do
    parse_install_options --non-interactive --swap "$option"
    rc=0
    output="$(collect_swap_choice 2>&1)" || rc=$?
    assert_eq '1' "$rc" \
      "explicit --swap $option must still fail when disk space is insufficient" || return 1
    assert_contains "$output" '--swap none' \
      "the explicit --swap $option error must identify the skip option" || return 1
  done

  mock_max_swap=4096
  parse_install_options --non-interactive
  collect_swap_choice
  SWAP_ACTION=create
  SWAP_SIZE_MB=1024
  create_swap_file() { return 1; }
  prompt_swap_creation() { printf 'PROMPTED\n'; }
  rc=0
  apply_swap_choice > "$output_file" 2>&1 || rc=$?
  output="$(< "$output_file")"
  assert_eq '0' "$rc" 'an implicit Swap creation failure must not block installation' || return 1
  assert_eq 'none' "$SWAP_ACTION" \
    'an implicit creation failure must leave installation on the no-Swap path' || return 1
  assert_not_contains "$output" 'PROMPTED' \
    'a noninteractive implicit Swap failure must not fall back to an input prompt' || return 1
  assert_contains "$output" 'Swap' 'the implicit creation failure must remain visible' || return 1

  for option in auto 2; do
    parse_install_options --non-interactive --swap "$option"
    collect_swap_choice
    rc=0
    output="$(apply_swap_choice 2>&1)" || rc=$?
    assert_eq '1' "$rc" \
      "an explicit --swap $option creation failure must still propagate" || return 1
    assert_not_contains "$output" 'PROMPTED' \
      "an explicit --swap $option failure must not read input" || return 1
  done
}

evaluate_gemini_fixture() {
  local homepage_fixture="$1"
  local rpc_fixture="$2"
  local expected="$3"
  local actual

  actual="$(evaluate_gemini_unlock "$(cat "$homepage_fixture")" "$(cat "$rpc_fixture")")"
  assert_eq "$expected" "$actual" "Gemini fixtures $(basename "$homepage_fixture") / $(basename "$rpc_fixture")"
}

test_gemini_fixtures() {
  source_without_main "$MANAGER_SCRIPT"
  declare -F evaluate_gemini_unlock >/dev/null || {
    fail 'evaluate_gemini_unlock is missing'
    return 1
  }

  evaluate_gemini_fixture \
    "${FIXTURE_DIR}/gemini/available.html" \
    "${FIXTURE_DIR}/gemini/available-k4wwud.txt" \
    'yes|位置：North York, ON, Canada' || return 1
  evaluate_gemini_fixture \
    "${FIXTURE_DIR}/gemini/china.html" \
    "${FIXTURE_DIR}/gemini/china-k4wwud.txt" \
    'no|位置：Beijing, Beijing, China；个人版不可用，Workspace 账号例外' || return 1
  evaluate_gemini_fixture \
    "${FIXTURE_DIR}/gemini/unavailable.html" \
    "${FIXTURE_DIR}/gemini/unavailable-k4wwud.txt" \
    'no|位置：North York, ON, Canada；当前出口地区受限' || return 1
  evaluate_gemini_fixture \
    "${FIXTURE_DIR}/gemini/unknown.html" \
    "${FIXTURE_DIR}/gemini/unknown-k4wwud.txt" \
    'unknown|位置响应无法解析' || return 1
  evaluate_gemini_fixture \
    "${FIXTURE_DIR}/gemini/available.html" \
    "${FIXTURE_DIR}/gemini/empty-k4wwud.txt" \
    'unknown|请求失败或未返回完整响应' || return 1
  evaluate_gemini_fixture \
    "${FIXTURE_DIR}/gemini/generic.html" \
    "${FIXTURE_DIR}/gemini/available-k4wwud.txt" \
    'unknown|页面特征不明确' || return 1
  evaluate_gemini_fixture \
    "${FIXTURE_DIR}/gemini/available.html" \
    "${FIXTURE_DIR}/gemini/malformed-inner-k4wwud.txt" \
    'unknown|位置响应无法解析' || return 1
  evaluate_gemini_fixture \
    "${FIXTURE_DIR}/gemini/old-false-marker.html" \
    "${FIXTURE_DIR}/gemini/available-k4wwud.txt" \
    'unknown|页面特征不明确' || return 1
  evaluate_gemini_fixture \
    "${FIXTURE_DIR}/gemini/conflicting.html" \
    "${FIXTURE_DIR}/gemini/available-k4wwud.txt" \
    'unknown|页面特征冲突'
}

evaluate_youtube_fixture() {
  local fixture="$1"
  local expected="$2"
  local actual

  actual="$(evaluate_youtube_premium_unlock "$(cat "$fixture")")"
  assert_eq "$expected" "$actual" "YouTube fixture $(basename "$fixture")"
}

test_youtube_fixtures() {
  source_without_main "$MANAGER_SCRIPT"
  declare -F evaluate_youtube_premium_unlock >/dev/null || {
    fail 'evaluate_youtube_premium_unlock is missing'
    return 1
  }

  evaluate_youtube_fixture \
    "${FIXTURE_DIR}/youtube/available-us-google-cn.html" \
    'yes|地区：US' || return 1
  evaluate_youtube_fixture \
    "${FIXTURE_DIR}/youtube/available-us-unrelated-country.html" \
    'yes|地区：US' || return 1
  evaluate_youtube_fixture \
    "${FIXTURE_DIR}/youtube/available-us.html" \
    'yes|地区：US' || return 1
  evaluate_youtube_fixture \
    "${FIXTURE_DIR}/youtube/available-us-generic-adfree.html" \
    'yes|地区：US' || return 1
  evaluate_youtube_fixture \
    "${FIXTURE_DIR}/youtube/conflicting-region.html" \
    'unknown|地区信息冲突' || return 1
  evaluate_youtube_fixture \
    "${FIXTURE_DIR}/youtube/conflicting-signals.html" \
    'unknown|页面特征冲突' || return 1
  evaluate_youtube_fixture \
    "${FIXTURE_DIR}/youtube/region-cn.html" \
    'no|地区：CN' || return 1
  evaluate_youtube_fixture \
    "${FIXTURE_DIR}/youtube/unavailable-us.html" \
    'no|地区：US' || return 1
  assert_eq \
    'no|地区：未知' \
    "$(evaluate_youtube_premium_unlock 'Premium is not available in your country')" \
    'an explicit unavailable response without a region must say that the region is unknown' || return 1
  evaluate_youtube_fixture \
    "${FIXTURE_DIR}/youtube/region-only.html" \
    'unknown|页面特征不明确' || return 1
  evaluate_youtube_fixture \
    "${FIXTURE_DIR}/youtube/offer-without-region.html" \
    'unknown|未取到地区' || return 1
  assert_eq \
    'unknown|网络连接失败' \
    "$(evaluate_youtube_premium_unlock '')" \
    'empty YouTube response should remain unknown'
}

test_native_egress_selection() {
  source_without_main "$MANAGER_SCRIPT"
  local mock_v4_defaults mock_v6_defaults mock_v4_addresses mock_v6_addresses
  local output rc=0
  mock_v4_defaults=$'default via 192.0.2.1 dev eth0 proto dhcp metric 100\ndefault via 192.0.2.2 dev eth1 proto dhcp metric 200'
  mock_v6_defaults='default via 2001:db8:1::1 dev eth6 proto ra metric 100'
  mock_v4_addresses=$'2: eth0    inet 198.51.100.10/24 brd 198.51.100.255 scope global eth0\n2: eth0    inet 198.51.100.11/24 brd 198.51.100.255 scope global secondary eth0'
  mock_v6_addresses=$'3: eth6    inet6 2001:db8:1::10/64 scope global dynamic\n3: eth6    inet6 2001:db8:1::11/64 scope global secondary dynamic'
  ip() {
    case "$*" in
      '-4 route show table main default') [ -z "$mock_v4_defaults" ] || printf '%s\n' "$mock_v4_defaults" ;;
      '-6 route show table main default') [ -z "$mock_v6_defaults" ] || printf '%s\n' "$mock_v6_defaults" ;;
      *'-o -4 addr show'*|*'-o -4 address show'*)
        [ -z "$mock_v4_addresses" ] || printf '%s\n' "$mock_v4_addresses"
        ;;
      *'-o -6 addr show'*|*'-o -6 address show'*)
        [ -z "$mock_v6_addresses" ] || printf '%s\n' "$mock_v6_addresses"
        ;;
      *) return 1 ;;
    esac
  }

  output="$(select_native_egress)" || {
    fail 'a default interface with global IPv4 addresses must be selectable'
    return 1
  }
  assert_eq '4|eth0|198.51.100.10' "$output" \
    'native selection must use the first global IPv4 on the first IPv4 default interface' || return 1

  mock_v4_defaults=''
  mock_v4_addresses=''
  output="$(select_native_egress)" || {
    fail 'an IPv6-only default interface with a global address must be selectable'
    return 1
  }
  assert_eq '6|eth6|2001:db8:1::10' "$output" \
    'native selection must fall back to the first global IPv6 only when IPv4 is unavailable' || return 1

  mock_v4_defaults='default via 192.0.2.1 dev eth0'
  mock_v6_defaults='default via 2001:db8:1::1 dev eth6'
  mock_v4_addresses=''
  mock_v6_addresses=''
  rc=0
  output="$(select_native_egress 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'native selection must fail when neither default interface has a global address'
    return 1
  }
  : "$output"
}

test_native_unlock_trace_behavior() {
  source_without_main "$MANAGER_SCRIPT"
  local request_log output calls trace_state rc=0
  request_log="$(mktemp)"
  trace_state=off
  select_native_egress() { printf '4|eth0|198.51.100.10\n'; }
  native_https_request() {
    printf '%s\n' "$*" >> "$request_log"
    case "$*" in
      *cdn-cgi/trace*)
        case "$trace_state" in
          fail) return 28 ;;
          off) printf 'ip=203.0.113.8\nloc=US\nwarp=off\n' ;;
          on|plus) printf 'ip=203.0.113.8\nloc=US\nwarp=%s\n' "$trace_state" ;;
        esac
        ;;
      *BardChatUi/data/batchexecute*|*K4WWud*)
        cat "${FIXTURE_DIR}/gemini/available-k4wwud.txt"
        ;;
      *gemini.google.com*)
        cat "${FIXTURE_DIR}/gemini/available.html"
        ;;
      *youtube.com/premium*)
        cat "${FIXTURE_DIR}/youtube/unavailable-us.html"
        ;;
      *) return 1 ;;
    esac
  }

  output="$(run_native_unlock_checks)" || {
    fail 'ordinary service results must remain advisory for the native check'
    return 1
  }
  calls="$(< "$request_log")"
  assert_contains "$output" '203.0.113.8' 'native trace output must show the observed public IP' || return 1
  assert_contains "$output" 'US' 'native trace output must show the observed Cloudflare region' || return 1
  assert_contains "$output" 'Gemini：可用' 'native Gemini output must reuse the existing parser' || return 1
  assert_contains "$output" 'YouTube Premium：不可用（地区：US）' \
    'native YouTube output must reuse the existing parser and parsed region' || return 1
  assert_contains "$calls" 'gemini.google.com' 'the native check must request Gemini through the native transport' || return 1
  assert_contains "$calls" 'youtube.com/premium' 'the native check must request YouTube through the native transport' || return 1

  : > "$request_log"
  trace_state=fail
  output="$(run_native_unlock_checks)" || {
    fail 'a failed Cloudflare trace request must not block the service checks'
    return 1
  }
  calls="$(< "$request_log")"
  assert_contains "$calls" 'gemini.google.com' \
    'Gemini must still run when Cloudflare trace is unavailable' || return 1
  assert_contains "$calls" 'youtube.com/premium' \
    'YouTube must still run when Cloudflare trace is unavailable' || return 1
  assert_contains "$output" 'Gemini' 'trace failure must still print the Gemini result' || return 1
  assert_contains "$output" 'YouTube Premium' 'trace failure must still print the YouTube result' || return 1

  for trace_state in on plus; do
    : > "$request_log"
    rc=0
    output="$(run_native_unlock_checks 2>&1)" || rc=$?
    calls="$(< "$request_log")"
    assert_not_contains "$calls" 'gemini.google.com' \
      "warp=$trace_state must stop before Gemini because the bypass failed" || return 1
    assert_not_contains "$calls" 'youtube.com/premium' \
      "warp=$trace_state must stop before YouTube because the bypass failed" || return 1
    assert_contains "$output" '旁路失败' \
      "warp=$trace_state must report the native bypass failure" || return 1
    : "$rc"
  done
}

test_native_https_request_mode_and_environment_contract() {
  source_without_main "$MANAGER_SCRIPT"
  local transport_log output recorded
  transport_log="$(mktemp)"
  http_proxy='http://lower-http.invalid:8080'
  https_proxy='http://lower-https.invalid:8080'
  all_proxy='socks5://lower-all.invalid:1080'
  HTTP_PROXY='http://upper-http.invalid:8080'
  HTTPS_PROXY='http://upper-https.invalid:8080'
  ALL_PROXY='socks5://upper-all.invalid:1080'
  UNLOCK_CONNECT_TIMEOUT=3
  UNLOCK_MAX_TIME=7
  timeout() {
    {
      printf 'proxy|%s|%s|%s|%s|%s|%s\n' \
        "${http_proxy-}" "${https_proxy-}" "${all_proxy-}" \
        "${HTTP_PROXY-}" "${HTTPS_PROXY-}" "${ALL_PROXY-}"
      printf 'outer|%s|%s|%s|%s|%s\n' \
        "${1-}" "${2-}" "${3-}" "${4-}" "${5-}"
      printf 'request|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "${7-}" "${8-}" "${9-}" "${10-}" "${11-}" "${12-}" \
        "${13-}" "${14-}" "${15-}" "${16-}" "${17-}" "${18-}"
    } >> "$transport_log"
    printf 'native-body\n'
  }

  WARP_MODE=wireguard
  WARP_SCOPE=global
  NATIVE_FAMILY=4
  NATIVE_IFACE=eth0
  NATIVE_SOURCE_IP=198.51.100.10
  output="$(native_https_request POST 'https://example.invalid/path?q=1' 'x=1')"
  assert_eq 'native-body' "$output" 'the native wrapper must return the transport response body' || return 1
  recorded="$(< "$transport_log")"
  assert_contains "$recorded" 'proxy||||||' \
    'the native transport process must receive no lower- or upper-case proxy endpoint' || return 1
  assert_contains "$recorded" 'outer|-k|1|7|python3|-c' \
    'the native transport must have a bounded outer process deadline' || return 1
  assert_contains "$recorded" \
    'request|POST|https://example.invalid/path?q=1|x=1|4|198.51.100.10|eth0|51888|wireguard|0|0|3|7' \
    'WireGuard global mode must pass source binding, interface and bypass mark to Python' || return 1

  : > "$transport_log"
  WARP_MODE=socks
  WARP_SCOPE=global
  REDSOCKS_USER=warp-redsocks
  REDSOCKS_UID=991
  NATIVE_FAMILY=6
  NATIVE_IFACE=eth6
  NATIVE_SOURCE_IP=2001:db8:1::10
  id() { [ "$*" = '-g warp-redsocks' ] && printf '992\n'; }
  output="$(native_https_request GET 'https://example.invalid/v6')"
  assert_eq 'native-body' "$output" 'the Socks native wrapper must return the response body' || return 1
  recorded="$(< "$transport_log")"
  assert_contains "$recorded" \
    'request|GET|https://example.invalid/v6||6|2001:db8:1::10||0|socks|991|992|3|7' \
    'Socks mode must pass the exempt uid/gid without a WireGuard interface or mark' || return 1

  assert_eq 'http://lower-http.invalid:8080' "$http_proxy" \
    'ignoring proxy variables for one request must not mutate the caller environment' || return 1
  assert_eq 'http://upper-http.invalid:8080' "$HTTP_PROXY" \
    'ignoring upper-case proxy variables must remain scoped to the transport process'
}

test_native_https_request_socket_redirect_and_deadline_contract() {
  local body drop_line resolve_line socket_line bind_line connect_line tls_line
  body="$(function_body "$MANAGER_SCRIPT" native_https_request)"
  [ -n "$body" ] || {
    fail 'could not extract native_https_request'
    return 1
  }

  drop_line="$(line_number "$body" 'os.setresuid(target_uid, target_uid, target_uid)')"
  resolve_line="$(line_number "$body" 'addresses = socket.getaddrinfo(')"
  socket_line="$(line_number "$body" 'raw_socket = socket.socket(af, socktype, protocol)')"
  bind_line="$(line_number "$body" 'raw_socket.bind((source_ip, 0))')"
  connect_line="$(line_number "$body" 'raw_socket.connect(sockaddr)')"
  tls_line="$(line_number "$body" 'context.wrap_socket(raw_socket, server_hostname=self.host)')"
  for name in drop_line resolve_line socket_line bind_line connect_line tls_line; do
    [ -n "${!name}" ] || {
      fail "native socket boundary is missing: $name"
      return 1
    }
  done
  if [ "$drop_line" -ge "$resolve_line" ] || [ "$drop_line" -ge "$socket_line" ]; then
    fail 'Socks mode must drop supplementary groups and uid/gid before DNS resolution and socket creation'
    return 1
  fi
  if [ "$socket_line" -ge "$bind_line" ] || [ "$bind_line" -ge "$connect_line" ] \
    || [ "$connect_line" -ge "$tls_line" ]; then
    fail 'the native socket must bind its source before connect and validate TLS only after connecting'
    return 1
  fi

  assert_contains "$body" 'os.setgroups([])' \
    'Socks privilege drop must clear supplementary groups' || return 1
  assert_contains "$body" 'socket.SO_BINDTODEVICE' \
    'WireGuard native requests must bind the selected native interface' || return 1
  assert_contains "$body" 'socket.SO_MARK' \
    'WireGuard global native requests must carry the project bypass mark' || return 1
  assert_contains "$body" 'raw_socket.bind((source_ip, 0, 0, 0))' \
    'IPv6 native requests must bind the selected IPv6 source address' || return 1
  assert_contains "$body" 'ssl.create_default_context()' \
    'native HTTPS must retain system certificate verification' || return 1
  assert_contains "$body" 'server_hostname=self.host' \
    'native HTTPS must validate TLS against the current redirect host' || return 1

  assert_contains "$body" 'for redirect_count in range(6):' \
    'native HTTPS must cap the redirect chain' || return 1
  assert_contains "$body" 'parsed.scheme != "https"' \
    'native redirects must reject a downgrade to cleartext HTTP' || return 1
  assert_contains "$body" 'parsed.username or parsed.password' \
    'native redirects must reject credential-bearing URLs' || return 1
  assert_contains "$body" 'status in (301, 302, 303, 307, 308)' \
    'native HTTPS must recognize only the intended redirect statuses' || return 1
  assert_contains "$body" 'urllib.parse.urljoin(current_url, location)' \
    'relative redirects must resolve against the current HTTPS URL' || return 1
  assert_contains "$body" 'status in (301, 302, 303) and current_method == "POST"' \
    '301/302/303 redirects must convert POST to GET without changing 307/308 semantics' || return 1
  assert_contains "$body" 'max_response_bytes = 8 * 1024 * 1024' \
    'native HTTPS must bound response memory' || return 1

  assert_contains "$body" 'timeout -k 1 "$UNLOCK_MAX_TIME" python3' \
    'native HTTPS must retain the outer wall-clock deadline' || return 1
  assert_contains "$body" 'deadline = time.monotonic() + max_time' \
    'redirects and address retries must share one monotonic deadline' || return 1
  assert_contains "$body" 'return min(connect_timeout, remaining)' \
    'each socket operation must use the smaller connect or remaining deadline' || return 1
  assert_contains "$body" 'raw_socket.settimeout(operation_timeout())' \
    'connect must have a socket timeout' || return 1
  assert_contains "$body" 'self.sock.settimeout(operation_timeout())' \
    'TLS response reads must have a socket timeout'
}

test_native_unlock_command_is_explicit_and_root_scoped() {
  source_without_main "$MANAGER_SCRIPT"
  local calls=''
  require_root() { calls="${calls}root "; }
  load_config() { calls="${calls}config "; }
  run_native_unlock_checks() { calls="${calls}native "; }

  cmd_native_unlock_check
  assert_eq 'root config native ' "$calls" \
    'the native unlock command must load its routing context only after the root boundary'
}

test_status_and_test_do_not_run_unlock_checks() {
  local body
  for body in \
    "$(function_body "$MANAGER_SCRIPT" cmd_test)" \
    "$(function_body "$MANAGER_SCRIPT" cmd_status)" \
    "$(function_body "$MANAGER_SCRIPT" run_self_check)"; do
    [ -n "$body" ] || {
      fail 'could not extract the status/test source call chain'
      return 1
    }
    assert_not_contains "$body" 'run_unlock_checks' \
      'status and test must not run the external unlock probes' || return 1
    assert_not_contains "$body" 'run_native_unlock_checks' \
      'status and test must not run the native-exit unlock probes' || return 1
  done

  body="$(function_body "$MANAGER_SCRIPT" cmd_unlock_check)"
  assert_contains "$body" 'run_unlock_checks' \
    'unlock-check should remain the explicit command for external unlock probes' || return 1
  body="$(function_body "$MANAGER_SCRIPT" cmd_native_unlock_check)"
  assert_contains "$body" 'run_native_unlock_checks' \
    'native-unlock-check should remain the only explicit native-exit probe command'
}

test_local_runtime_paths_do_not_depend_on_external_probes() {
  local body name
  for name in test_quiet wait_for_wg_ready wait_for_warp_proxy_ready \
    warp_proxy_local_ready socks5_greeting_ok \
    restart_wireguard_runtime reload_runtime_after_update cmd_heal; do
    body="$(function_body "$MANAGER_SCRIPT" "$name")"
    [ -n "$body" ] || {
      fail "could not extract local runtime function: $name"
      return 1
    }
    assert_not_contains "$body" 'google_http_probe' \
      "$name must not run Google HTTP probes" || return 1
    assert_not_contains "$body" 'socks_ok' \
      "$name must not run the Cloudflare trace probe" || return 1
    assert_not_contains "$body" 'wg_handshake_recent' \
      "$name must not gate on a WireGuard handshake" || return 1
    assert_not_contains "$body" 'run_external_diagnostics' \
      "$name must not run external diagnostics" || return 1
    assert_not_contains "$body" 'run_native_unlock_checks' \
      "$name must not run native-exit unlock probes" || return 1
  done

  for name in run_final_self_check start_previous_runtime; do
    body="$(function_body "$INSTALL_SCRIPT" "$name")"
    assert_not_contains "$body" '"$BIN_PATH" status' \
      "$name must not turn diagnostic status output into an install or rollback gate" \
      || return 1
    assert_not_contains "$body" '"$BIN_PATH" test' \
      "$name must not call external diagnostics" || return 1
  done

  body="$(function_body "$MANAGER_SCRIPT" test_quiet)"
  assert_contains "$body" 'wait_for_socks_listen 8' \
    'the Socks local check must require its local WARP listener' || return 1
  assert_contains "$body" 'redsocks_local_ready' \
    'the Socks local check must require a redsocks listener owned by its project service' || return 1
  assert_contains "$body" 'table_exists' \
    'the Socks local check must require the project nft table' || return 1
  assert_not_contains "$body" 'socks_nft_rules_local_ok' \
    'the Socks local check must not parse individual nft rules' || return 1

  body="$(function_body "$MANAGER_SCRIPT" run_self_check)"
  assert_not_contains "$body" 'google_http_probe' \
    'status must not call Google HTTP probes' || return 1
  assert_not_contains "$body" 'socks_ok' \
    'status must not call the Cloudflare trace probe' || return 1
  assert_not_contains "$body" 'wg_handshake_recent' \
    'status must not display a non-actionable handshake warning' || return 1
  assert_not_contains "$body" 'nft list chain' \
    'status must not parse human-readable nft rule output' || return 1
  assert_not_contains "$body" 'wireguard_global_routes_local_ok' \
    'status must not parse global WireGuard nft or ip-rule output'
}

test_cmd_test_returns_only_local_status() {
  source_without_main "$MANAGER_SCRIPT"
  require_root() { :; }
  load_config() { :; }
  run_self_check() { return 0; }
  run_external_diagnostics() { return 1; }
  cmd_test || {
    fail 'external diagnostic failure must not fail warp-vps test when local state is healthy'
    return 1
  }

  run_self_check() { return 1; }
  run_external_diagnostics() { return 0; }
  if cmd_test; then
    fail 'external success must not hide a failed local runtime check'
    return 1
  fi
}

test_status_and_healthy_timer_stay_local() {
  source_without_main "$MANAGER_SCRIPT"
  local external_calls=0 handshake_calls=0 repair_calls=0

  WARP_MODE=wireguard
  WARP_SCOPE=google
  WG_IFACE=warp-vps-wg
  require_root() { :; }
  load_config() { :; }
  unit_ready() { return 0; }
  wg_interface_is_wireguard() { return 0; }
  rule_probe_ip() {
    case "$2" in
      4) printf '8.8.8.0\n' ;;
      6) printf '2001:4860::\n' ;;
    esac
  }
  route_uses_wg4() { return 0; }
  route_uses_wg6() { return 0; }
  wg_default_routes_absent() { return 0; }
  wg_global_routes_absent() { return 0; }
  socks_table_absent() { return 0; }
  google_http_probe() { external_calls=$((external_calls + 1)); return 6; }
  socks_ok() { external_calls=$((external_calls + 1)); return 1; }
  run_external_diagnostics() { external_calls=$((external_calls + 1)); return 1; }
  wg_handshake_recent() { handshake_calls=$((handshake_calls + 1)); return 1; }

  run_self_check >/dev/null || {
    fail 'a missing WireGuard handshake must not fail an otherwise healthy local status'
    return 1
  }
  assert_eq '0' "$external_calls" \
    'status must not run HTTP, DNS or Cloudflare trace probes' || return 1
  assert_eq '0' "$handshake_calls" \
    'status must not query or display a non-actionable handshake observation' || return 1

  required_runtime_units_ready() { return 0; }
  test_quiet() { return 0; }
  restart_wireguard_runtime() { repair_calls=$((repair_calls + 1)); return 0; }
  cmd_heal >/dev/null || {
    fail 'health check must accept a healthy local runtime without external probes'
    return 1
  }
  assert_eq '0' "$external_calls" \
    'a healthy timer check must not run external probes' || return 1
  assert_eq '0' "$repair_calls" \
    'external uncertainty must not trigger self-healing'
}

test_http_probe_accepts_http_error_responses() {
  source_without_main "$MANAGER_SCRIPT"
  local curl_calls='' simulated_http_status=429 arg
  curl() {
    curl_calls="${curl_calls}$*\n"
    for arg in "$@"; do
      case "$arg" in
        --fail|--fail-with-body|-*[fF]*) return 22 ;;
      esac
    done
    [ "$simulated_http_status" -eq 429 ] || return 1
    return 0
  }
  google_http_probe -4 || {
    fail 'an HTTP error response should still prove network reachability'
    return 1
  }
  assert_not_contains "$curl_calls" ' -f' \
    'the connectivity probe must not convert HTTP 429 into a transport failure' || return 1
  assert_not_contains "$curl_calls" '--fail' \
    'the connectivity probe must not use a long curl failure option for HTTP 429'
}

test_install_unlock_check_is_post_success_and_nonblocking() {
  local body complete_line disarm_line success_line unlock_line
  body="$(function_body "$INSTALL_SCRIPT" main)"
  complete_line="$(line_number "$body" 'INSTALL_COMPLETE=1')"
  disarm_line="$(line_number "$body" 'trap - EXIT')"
  success_line="$(line_number "$body" 'WARP VPS Manager 安装完成')"
  unlock_line="$(line_number "$body" '"$BIN_PATH" unlock-check || true')"
  for name in complete_line disarm_line success_line unlock_line; do
    [ -n "${!name}" ] || {
      fail "installer post-success marker is missing: $name"
      return 1
    }
  done
  if [ "$complete_line" -ge "$disarm_line" ] \
    || [ "$disarm_line" -ge "$success_line" ] \
    || [ "$success_line" -ge "$unlock_line" ]; then
    fail 'unlock-check must run only after completion, trap disarm and success output'
    return 1
  fi
  assert_not_contains "$body" '"$BIN_PATH" status' \
    'installer completion must not be blocked by diagnostic status output' || return 1
  assert_not_contains "$body" '"$BIN_PATH" native-unlock-check' \
    'the native-exit unlock check must remain manual and never join installation completion'
}

test_old_runtime_restore_does_not_call_status() {
  source_without_main "$INSTALL_SCRIPT"
  PREVIOUS_MODE=socks
  PREVIOUS_WG_IFACE=warp-vps-wg
  CONFIG_FILE="${FIXTURE_DIR}/config/socks-mode.env"
  local manager_calls='' started_units=''

  manager_mock() {
    manager_calls="${manager_calls}$1\n"
    case "$1" in install-systemd) return 0 ;; status) return 1 ;; *) return 1 ;; esac
  }
  BIN_PATH=manager_mock
  systemctl() { [ "$*" = 'daemon-reload' ]; }
  enable_and_start_unit() {
    started_units="${started_units}$1\n"
    return 0
  }
  valid_port() { return 0; }
  port_in_use() { return 0; }
  restore_health_automation() { return 0; }

  start_previous_runtime || {
    fail 'old runtime recovery must follow successful service actions without status gating'
    return 1
  }
  assert_contains "$started_units" 'warp-svc.service' \
    'old Socks recovery must start the WARP backend' || return 1
  assert_contains "$started_units" 'warp-vps-redsocks.service' \
    'old Socks recovery must start redsocks' || return 1
  assert_contains "$started_units" 'warp-vps.service' \
    'old Socks recovery must start routing' || return 1
  assert_not_contains "$manager_calls" 'status' \
    'old runtime recovery must not invoke diagnostic status'
}

test_generator_validates_google_cloud_subtraction() {
  python3 - "$GENERATOR_SCRIPT" <<'PY'
import ipaddress
import runpy
import sys

module = runpy.run_path(sys.argv[1])
subtract_many = module["subtract_many"]
validate_source_ranges = module["validate_source_ranges"]
validate_output_ranges = module["validate_output_ranges"]
validate_metadata_counts = module["validate_metadata_counts"]

goog4 = [ipaddress.ip_network("10.0.0.0/8")]
goog6 = [ipaddress.ip_network("2001:db8::/32")]
cloud4 = [ipaddress.ip_network("10.0.0.0/9")]
cloud6 = [ipaddress.ip_network("2001:db8::/33")]
out4 = subtract_many(goog4, cloud4)
out6 = subtract_many(goog6, cloud6)
assert out4 == [ipaddress.ip_network("10.128.0.0/9")]
assert out6 == [ipaddress.ip_network("2001:db8:8000::/33")]
validate_source_ranges("goog.json", goog4, goog6)
validate_source_ranges("cloud.json", cloud4, cloud6)
validate_output_ranges("IPv4", out4, goog4, cloud4)
validate_output_ranges("IPv6", out6, goog6, cloud6)
validate_metadata_counts(
    {"ipv4_count": len(out4), "ipv6_count": len(out6)}, out4, out6
)

for call in (
    lambda: validate_source_ranges("goog.json", [], goog6),
    lambda: validate_output_ranges("IPv4", [], goog4, cloud4),
    lambda: validate_output_ranges("IPv4", cloud4, goog4, cloud4),
    lambda: validate_metadata_counts({"ipv4_count": 0, "ipv6_count": 1}, out4, out6),
):
    try:
        call()
    except ValueError:
        pass
    else:
        raise AssertionError("generator validation unexpectedly accepted invalid data")
PY
}

test_rule_metadata_counts_gate_install_and_update() {
  local stage
  stage="$(mktemp -d)"
  mkdir -p "$stage/bin" "$stage/rules"
  printf '#!/usr/bin/env bash\n:\n' > "$stage/install.sh"
  printf '#!/usr/bin/env bash\n:\n' > "$stage/bin/warp-vps"
  printf '8.8.8.0/24\n' > "$stage/rules/google_ipv4.txt"
  printf '2001:4860::/32\n' > "$stage/rules/google_ipv6.txt"
  printf '{"ipv4_count": 1, "ipv6_count": 1}\n' > "$stage/rules/rules.meta.json"

  source_without_main "$INSTALL_SCRIPT"
  validate_staged_rules "$stage" || {
    fail 'installer should accept matching dual-stack rule metadata'
    return 1
  }
  source_without_main "$MANAGER_SCRIPT"
  validate_update_stage "$stage" || {
    fail 'updater should accept matching dual-stack rule metadata'
    return 1
  }

  printf '{"ipv4_count": 2, "ipv6_count": 1}\n' > "$stage/rules/rules.meta.json"
  if validate_staged_rules "$stage" >/dev/null 2>&1; then
    fail 'installer accepted a mixed rule snapshot with wrong IPv4 metadata'
    return 1
  fi
  if validate_update_stage "$stage" >/dev/null 2>&1; then
    fail 'updater accepted a mixed rule snapshot with wrong IPv4 metadata'
    return 1
  fi

  printf '{"ipv4_count": true, "ipv6_count": 1}\n' > "$stage/rules/rules.meta.json"
  if validate_staged_rules "$stage" >/dev/null 2>&1; then
    fail 'installer accepted a JSON boolean as an integer rule count'
    return 1
  fi
  if validate_update_stage "$stage" >/dev/null 2>&1; then
    fail 'updater accepted a JSON boolean as an integer rule count'
    return 1
  fi

  printf '{"ipv4_count": 1, "ipv6_count": 1}\n' > "$stage/rules/rules.meta.json"
  printf '8.8.8.1/24\n' > "$stage/rules/google_ipv4.txt"
  if validate_staged_rules "$stage" >/dev/null 2>&1; then
    fail 'installer accepted a non-canonical IPv4 CIDR'
    return 1
  fi
  if validate_update_stage "$stage" >/dev/null 2>&1; then
    fail 'updater accepted a non-canonical IPv4 CIDR'
    return 1
  fi

  printf '8.8.8.0/24\n' > "$stage/rules/google_ipv4.txt"
  printf '#!/usr/bin/env bash\nif then\n' > "$stage/install.sh"
  if validate_update_stage "$stage" >/dev/null 2>&1; then
    fail 'updater ignored a failed staged installer syntax check'
    return 1
  fi
}

test_update_rollback_restores_existing_and_missing_files() {
  source_without_main "$MANAGER_SCRIPT"
  local root stage backup label
  root="$(mktemp -d)"
  stage="$root/stage"
  backup="$root/backup"
  APP_DIR="$root/app"
  RULES_DIR="$APP_DIR/rules"
  BIN_PATH="$root/warp-vps"
  mkdir -p "$APP_DIR/bin" "$RULES_DIR" "$stage/bin" "$stage/rules"
  printf 'old-install\n' > "$APP_DIR/install.sh"

  backup_current_installation "$backup" || {
    fail 'update rollback fixture could not back up a sparse existing installation'
    return 1
  }
  printf 'new-install\n' > "$stage/install.sh"
  printf 'new-manager\n' > "$stage/bin/warp-vps"
  printf '8.8.8.0/24\n' > "$stage/rules/google_ipv4.txt"
  printf '2001:4860::/32\n' > "$stage/rules/google_ipv6.txt"
  printf '{"ipv4_count":1,"ipv6_count":1}\n' > "$stage/rules/rules.meta.json"
  activate_update_stage "$stage" || {
    fail 'update rollback fixture could not activate the staged files'
    return 1
  }
  restore_update_backup "$backup" || {
    fail 'update rollback could not restore a sparse previous installation'
    return 1
  }

  assert_eq 'old-install' "$(< "$APP_DIR/install.sh")" \
    'rollback must restore a file that existed before the update' || return 1
  for label in \
    "$APP_DIR/bin/warp-vps" \
    "$RULES_DIR/google_ipv4.txt" \
    "$RULES_DIR/google_ipv6.txt" \
    "$RULES_DIR/rules.meta.json" \
    "$BIN_PATH"; do
    if [ -e "$label" ] || [ -L "$label" ]; then
      fail "rollback left a newly introduced update file live: $label"
      return 1
    fi
  done
  for label in app-manager rules-ipv4 rules-ipv6 rules-meta command; do
    [ -f "$backup/failed-new/$label" ] || {
      fail "rollback did not preserve the displaced new file for diagnostics: $label"
      return 1
    }
  done
}

test_update_accepts_legacy_socks_runtime() {
  source_without_main "$MANAGER_SCRIPT"
  local manager_calls='' exact_rule_checks=0 activated=0 maintenance_finished=0
  WARP_MODE=socks
  WARP_SCOPE=google
  WARP_SOCKS_PORT=24000
  STATE_DIR=/unused/state
  APP_DIR=/unused/app
  RULES_DIR=/unused/app/rules

  require_root() { :; }
  load_config() { :; }
  section() { :; }
  info_line() { :; }
  ok_line() { :; }
  install() { return 0; }
  download_update_asset() { :; }
  validate_update_stage() { :; }
  backup_current_installation() { :; }
  begin_runtime_maintenance() { return 0; }
  finish_runtime_maintenance() { maintenance_finished=$((maintenance_finished + 1)); }
  service_active() { return 1; }
  socks_table_absent() { return 0; }
  socks_nft_rules_local_ok() {
    exact_rule_checks=$((exact_rule_checks + 1))
    return 1
  }
  activate_update_stage() { activated=$((activated + 1)); }
  restore_update_backup() { printf 'UNEXPECTED:restore\n'; return 0; }
  warp_proxy_local_ready() { return 0; }
  wait_for_redsocks_ready() { return 0; }
  systemctl() { return 0; }
  manager_mock() {
    manager_calls="${manager_calls}$1\n"
    case "$1" in
      stop-rules|install-systemd) return 0 ;;
      # This models an old release whose status rejects missing QUIC/IPv6 rules.
      status) return 1 ;;
      *) return 1 ;;
    esac
  }
  BIN_PATH=manager_mock

  cmd_update >/dev/null || {
    fail 'legacy Socks rules must not block an otherwise successful update'
    return 1
  }
  assert_eq '1' "$activated" 'the cross-version update must activate the new files' || return 1
  assert_eq '1' "$maintenance_finished" \
    'the successful cross-version update must restore health automation' || return 1
  assert_eq '0' "$exact_rule_checks" \
    'update must not inspect the old release rule shape' || return 1
  assert_not_contains "$manager_calls" 'status' \
    'update must not invoke a diagnostic status gate'
}

test_update_rolls_back_activation_and_service_write_failures() {
  run_failure() {
    local scenario="$1"
    (
      source_without_main "$MANAGER_SCRIPT"
      local route_start_calls=0
      WARP_MODE=socks
      WARP_SCOPE=google
      WARP_SOCKS_PORT=24000
      STATE_DIR=/unused/state
      APP_DIR=/unused/app
      RULES_DIR=/unused/app/rules

      require_root() { :; }
      load_config() { :; }
      section() { :; }
      info_line() { :; }
      ok_line() { :; }
      warn_line() { :; }
      install() { return 0; }
      download_update_asset() { :; }
      validate_update_stage() { :; }
      backup_current_installation() { :; }
      begin_runtime_maintenance() { return 0; }
      finish_runtime_maintenance() { :; }
      service_active() { return 1; }
      socks_table_absent() { return 0; }
      activate_update_stage() {
        printf 'EVENT:activate\n'
        [ "$scenario" != activation ]
      }
      restore_update_backup() {
        printf 'EVENT:restore-files\n'
        return 0
      }
      warp_proxy_local_ready() { return 0; }
      wait_for_redsocks_ready() { return 0; }
      systemctl() {
        if [ "$*" = 'start warp-vps.service' ]; then
          route_start_calls=$((route_start_calls + 1))
          if [ "$scenario" = service ] && [ "$route_start_calls" -eq 1 ]; then
            printf 'EVENT:new-service-start-failed\n'
            return 1
          fi
        fi
        return 0
      }
      manager_mock() {
        case "$1" in stop-rules|install-systemd|status) return 0 ;; *) return 1 ;; esac
      }
      BIN_PATH=manager_mock
      cmd_update
    )
  }

  local output rc=0
  output="$(run_failure activation 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'an update activation write failure must fail the transaction'
    return 1
  }
  assert_contains "$output" 'EVENT:restore-files' \
    'an activation write failure must restore the previous files' || return 1
  assert_contains "$output" '已恢复旧文件和原运行态' \
    'an activation write failure must restore the old runtime' || return 1

  rc=0
  output="$(run_failure service 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'an update service start failure must fail the transaction'
    return 1
  }
  assert_contains "$output" 'EVENT:new-service-start-failed' \
    'the service failure fixture must reach the new routing service' || return 1
  assert_contains "$output" 'EVENT:restore-files' \
    'a new service start failure must restore the previous files' || return 1
  assert_contains "$output" '已恢复旧版本和原运行态' \
    'a new service start failure must restore the old runtime'
}

test_wireguard_update_rollback_uses_interface_boundary() {
  run_wireguard_rollback() {
    local interface_cleanup_rc="$1"
    (
      source_without_main "$MANAGER_SCRIPT"
      local reload_calls=0
      WARP_MODE=wireguard
      WARP_SCOPE=google
      WG_IFACE=warp-vps-wg
      STATE_DIR=/unused/state
      APP_DIR=/unused/app
      RULES_DIR=/unused/app/rules

      require_root() { :; }
      load_config() { :; }
      section() { :; }
      info_line() { :; }
      ok_line() { :; }
      warn_line() { :; }
      install() { return 0; }
      download_update_asset() { :; }
      validate_update_stage() { :; }
      backup_current_installation() { :; }
      begin_runtime_maintenance() { return 0; }
      finish_runtime_maintenance() { :; }
      service_active() { return 1; }
      activate_update_stage() { return 0; }
      reload_runtime_after_update() {
        reload_calls=$((reload_calls + 1))
        [ "$reload_calls" -gt 1 ]
      }
      stop_wg_routes_strict() {
        printf 'UNEXPECTED:strict-route-shape-check\n'
        return 1
      }
      remove_wireguard_interface() {
        printf 'EVENT:remove-interface\n'
        return "$interface_cleanup_rc"
      }
      restore_update_backup() {
        printf 'EVENT:restore-old-files\n'
        return 0
      }
      systemctl() { return 0; }
      manager_mock() {
        case "$1" in stop-rules|install-systemd) return 0 ;; *) return 1 ;; esac
      }
      BIN_PATH=manager_mock
      cmd_update
    )
  }

  local output rc=0 cleanup_line restore_line
  output="$(run_wireguard_rollback 0 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'a failed new WireGuard runtime must still report the update as failed after rollback'
    return 1
  }
  assert_contains "$output" 'EVENT:remove-interface' \
    'WireGuard update rollback must tear down the staged interface' || return 1
  assert_contains "$output" 'EVENT:restore-old-files' \
    'old files should be restored after the staged interface is gone' || return 1
  assert_not_contains "$output" 'UNEXPECTED:strict-route-shape-check' \
    'WireGuard update rollback must not depend on old CIDR or display-parser shape' || return 1
  cleanup_line="$(line_number "$output" 'EVENT:remove-interface')"
  restore_line="$(line_number "$output" 'EVENT:restore-old-files')"
  if [ -z "$cleanup_line" ] || [ -z "$restore_line" ] || [ "$cleanup_line" -ge "$restore_line" ]; then
    fail 'the staged WireGuard interface must disappear before old files are restored'
    return 1
  fi

  rc=0
  output="$(run_wireguard_rollback 1 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'a WireGuard interface cleanup failure must stop update rollback'
    return 1
  }
  assert_contains "$output" 'EVENT:remove-interface' \
    'the failed cleanup fixture must reach the interface boundary' || return 1
  assert_not_contains "$output" 'EVENT:restore-old-files' \
    'old files must not be restored while the staged WireGuard interface is still live'
}

test_restart_and_update_restore_required_units() {
  local restart_body reload_body heal_body update_body rollback_body
  restart_body="$(function_body "$MANAGER_SCRIPT" cmd_restart)"
  reload_body="$(function_body "$MANAGER_SCRIPT" reload_runtime_after_update)"
  heal_body="$(function_body "$MANAGER_SCRIPT" cmd_heal)"
  update_body="$(function_body "$MANAGER_SCRIPT" cmd_update)"

  assert_contains "$restart_body" 'systemctl enable ' \
    'restart should re-enable disabled project units' || return 1
  assert_contains "$restart_body" 'configure_warp_runtime' \
    'Socks restart should restore mode, port and connection' || return 1
  assert_not_contains "$restart_body" 'ensure_health_timer' \
    'restart must not release the healer before local validation finishes' || return 1
  assert_contains "$restart_body" 'finish_runtime_maintenance' \
    'restart should restore the auxiliary timer only after local validation' || return 1
  assert_contains "$restart_body" 'begin_runtime_maintenance' \
    'restart must quiesce the automatic healer before changing the data plane' || return 1

  assert_contains "$reload_body" 'configure_warp_runtime' \
    'update reload should restore the WARP local proxy' || return 1
  assert_not_contains "$reload_body" 'ensure_health_timer' \
    'update reload must keep the healer paused until the caller finishes validation' || return 1
  assert_contains "$heal_body" 'required_runtime_units_ready' \
    'health checks should repair disabled units instead of declaring success' || return 1

  assert_contains "$update_body" 'if ! activate_update_stage "$stage"' \
    'update activation failures must be caught' || return 1
  assert_contains "$update_body" 'restore_update_backup "$backup"' \
    'a partial update activation must restore the previous files' || return 1

  local stop_line activate_line interface_cleanup_line restore_line
  stop_line="$(line_number "$update_body" '"$BIN_PATH" stop-rules')"
  activate_line="$(line_number "$update_body" 'activate_update_stage "$stage"')"
  if [ -z "$stop_line" ] || [ -z "$activate_line" ] || [ "$stop_line" -ge "$activate_line" ]; then
    fail 'update must remove the old snapshot routes before replacing the rule files'
    return 1
  fi
  rollback_body="$(awk '/更新后运行态重新加载失败，正在恢复旧版本/ { found=1 } found { print }' <<< "$update_body")"
  interface_cleanup_line="$(line_number "$rollback_body" 'remove_wireguard_interface')"
  restore_line="$(line_number "$rollback_body" 'restore_update_backup "$backup"')"
  if [ -z "$interface_cleanup_line" ] || [ -z "$restore_line" ] \
    || [ "$interface_cleanup_line" -ge "$restore_line" ]; then
    fail 'WireGuard update rollback must remove the staged interface before restoring old files'
  fi
  assert_not_contains "$rollback_body" 'stop_wg_routes_strict' \
    'update rollback must not parse the staged or previous route snapshot'
}

test_update_reuses_healthy_backends() {
  source_without_main "$MANAGER_SCRIPT"
  local configure_calls=0 restart_wg_calls=0 systemctl_calls='' manager_calls=''

  manager_mock() {
    manager_calls="${manager_calls}$1\n"
    case "$1" in install-systemd) return 0 ;; status) return 1 ;; *) return 1 ;; esac
  }
  BIN_PATH=manager_mock
  WG_IFACE=warp-vps-wg
  WARP_SOCKS_PORT=24000
  service_active() { return 0; }
  wg_interface_is_wireguard() { return 0; }
  warp_proxy_local_ready() { return 0; }
  wait_for_redsocks_ready() { return 0; }
  configure_warp_runtime() { configure_calls=$((configure_calls + 1)); }
  restart_wireguard_runtime() { restart_wg_calls=$((restart_wg_calls + 1)); }
  systemctl() { systemctl_calls="${systemctl_calls}$*\n"; }

  WARP_MODE=wireguard
  reload_runtime_after_update || {
    fail 'a healthy WireGuard backend should reload project files in place'
    return 1
  }
  assert_eq '0' "$restart_wg_calls" \
    'an update must not restart a healthy WireGuard interface' || return 1
  assert_not_contains "$systemctl_calls" 'restart wg-quick@warp-vps-wg.service' \
    'an update must keep the healthy interface while route-service startup reselects its endpoint' || return 1
  assert_not_contains "$manager_calls" 'status' \
    'a healthy WireGuard update must not invoke diagnostic status' || return 1

  WARP_MODE=socks
  systemctl_calls=''
  reload_runtime_after_update || {
    fail 'a healthy Socks backend should reload project files in place'
    return 1
  }
  assert_eq '0' "$configure_calls" \
    'an update must not re-register or reconnect a healthy WARP SOCKS backend' || return 1
  assert_not_contains "$manager_calls" 'status' \
    'a healthy Socks update must not invoke diagnostic status'
}

test_update_repairs_only_missing_backends() {
  source_without_main "$MANAGER_SCRIPT"
  local configure_calls=0 restart_wg_calls=0 manager_calls=''

  manager_mock() {
    manager_calls="${manager_calls}$1\n"
    case "$1" in install-systemd) return 0 ;; status) return 1 ;; *) return 1 ;; esac
  }
  BIN_PATH=manager_mock
  WG_IFACE=warp-vps-wg
  WARP_SOCKS_PORT=24000
  systemctl() { return 0; }
  service_active() { return 0; }
  wg_interface_is_wireguard() { return 1; }
  restart_wireguard_runtime() { restart_wg_calls=$((restart_wg_calls + 1)); }

  WARP_MODE=wireguard
  reload_runtime_after_update || return 1
  assert_eq '1' "$restart_wg_calls" \
    'an update should rebuild WireGuard only when its local interface is missing' || return 1

  WARP_MODE=socks
  warp_proxy_local_ready() { return 1; }
  wait_for_redsocks_ready() { return 0; }
  configure_warp_runtime() { configure_calls=$((configure_calls + 1)); }
  reload_runtime_after_update || return 1
  assert_eq '1' "$configure_calls" \
    'an update should configure WARP SOCKS only when its local listener is missing' || return 1
  assert_not_contains "$manager_calls" 'status' \
    'backend repair success must not depend on diagnostic status'
}

test_socks_runtime_configuration_and_update_order() {
  local configure_body
  configure_body="$(function_body "$MANAGER_SCRIPT" configure_warp_runtime)"
  assert_not_contains "$configure_body" '--now' \
    'WARP runtime configuration must not combine enablement with an implicit restart' || return 1

  source_without_main "$MANAGER_SCRIPT"
  local systemctl_calls='' manager_calls='' redsocks_line routing_line
  manager_mock() {
    manager_calls="${manager_calls}$1\n"
    case "$1" in install-systemd) return 0 ;; status) return 1 ;; *) return 1 ;; esac
  }
  BIN_PATH=manager_mock
  WARP_MODE=socks
  WARP_SOCKS_PORT=24000
  service_active() { return 0; }
  warp_proxy_local_ready() { return 0; }
  wait_for_redsocks_ready() { return 0; }
  systemctl() {
    systemctl_calls="${systemctl_calls}$*"$'\n'
    return 0
  }

  reload_runtime_after_update || {
    fail 'healthy Socks update reload should restore the local data plane'
    return 1
  }
  redsocks_line="$(line_number "$systemctl_calls" 'restart warp-vps-redsocks.service')"
  routing_line="$(line_number "$systemctl_calls" 'start warp-vps.service')"
  if [ -z "$redsocks_line" ] || [ -z "$routing_line" ] \
    || [ "$redsocks_line" -ge "$routing_line" ]; then
    fail 'Socks update reload must start redsocks before enabling transparent routing'
    return 1
  fi
  assert_not_contains "$manager_calls" 'status' \
    'Socks update reload must not invoke diagnostic status'
}

test_restart_reuses_healthy_backends() {
  source_without_main "$MANAGER_SCRIPT"
  local restart_wg_calls=0 configure_calls=0 maintenance_finished=0 systemctl_calls=''
  require_root() { :; }
  load_config() { :; }
  begin_runtime_maintenance() { :; }
  finish_runtime_maintenance() { maintenance_finished=$((maintenance_finished + 1)); }
  run_self_check() { return 0; }
  service_active() { return 0; }
  wg_interface_is_wireguard() { return 0; }
  warp_proxy_local_ready() { return 0; }
  wait_for_redsocks_ready() { return 0; }
  restart_wireguard_runtime() { restart_wg_calls=$((restart_wg_calls + 1)); }
  configure_warp_runtime() { configure_calls=$((configure_calls + 1)); }
  systemctl() { systemctl_calls="${systemctl_calls}$*\n"; return 0; }

  WARP_MODE=wireguard
  WARP_SCOPE=google
  WG_IFACE=warp-vps-wg
  cmd_restart >/dev/null || return 1
  assert_eq '0' "$restart_wg_calls" \
    'restart must keep a healthy WireGuard interface for runtime endpoint reselection' || return 1
  assert_not_contains "$systemctl_calls" 'restart wg-quick@warp-vps-wg.service' \
    'restart must preserve a healthy WireGuard backend' || return 1

  WARP_MODE=socks
  WARP_SOCKS_PORT=24000
  cmd_restart >/dev/null || return 1
  assert_eq '0' "$configure_calls" \
    'restart must not reconnect or re-register a healthy WARP SOCKS backend' || return 1
  assert_eq '2' "$maintenance_finished" \
    'each successful restart should restore maintenance automation after local validation'
}

test_restart_repairs_wireguard_unit_interface_mismatch() {
  source_without_main "$MANAGER_SCRIPT"
  local unit_active=0 link_present=1 identity_valid=1 restart_calls=0 maintenance_finished=0
  require_root() { :; }
  load_config() { :; }
  section() { :; }
  info_line() { :; }
  begin_runtime_maintenance() { :; }
  finish_runtime_maintenance() { maintenance_finished=$((maintenance_finished + 1)); }
  run_self_check() { return 0; }
  service_active() { [ "$unit_active" -eq 1 ]; }
  wg_interface_exists() { [ "$link_present" -eq 1 ]; }
  wg_interface_is_wireguard() { [ "$identity_valid" -eq 1 ]; }
  restart_wireguard_runtime() {
    restart_calls=$((restart_calls + 1))
    unit_active=1
    link_present=1
    identity_valid=1
  }
  systemctl() { return 0; }

  WARP_MODE=wireguard
  WARP_SCOPE=google
  WG_IFACE=warp-vps-wg
  cmd_restart >/dev/null || {
    fail 'restart should repair an inactive WireGuard unit with a stale interface'
    return 1
  }
  assert_eq '1' "$restart_calls" \
    'unit/interface disagreement must rebuild the WireGuard backend' || return 1

  unit_active=1
  link_present=0
  identity_valid=0
  cmd_restart >/dev/null || {
    fail 'restart should repair an active unit whose WireGuard interface is missing'
    return 1
  }
  assert_eq '2' "$restart_calls" \
    'a missing interface must rebuild the WireGuard backend even when systemd says active' || return 1

  unit_active=1
  link_present=1
  identity_valid=0
  cmd_restart >/dev/null || {
    fail 'restart should replace a same-name dummy link with the project WireGuard interface'
    return 1
  }
  assert_eq '3' "$restart_calls" \
    'a same-name non-WireGuard link must rebuild the WireGuard backend' || return 1

  unit_active=1
  link_present=1
  identity_valid=1
  cmd_restart >/dev/null || return 1
  assert_eq '3' "$restart_calls" \
    'a consistent healthy WireGuard backend must not be rebuilt' || return 1
  assert_eq '4' "$maintenance_finished" \
    'all successful restart paths must restore maintenance automation'
}

test_wireguard_identity_rejects_dummy_and_heals() {
  source_without_main "$MANAGER_SCRIPT"
  local identity_valid=0 wg_calls='' output rc=0 restart_calls=0 body name
  for name in apply_wg_routes wait_for_wg_ready test_quiet run_self_check \
    cmd_restart reload_runtime_after_update cmd_heal; do
    body="$(function_body "$MANAGER_SCRIPT" "$name")"
    assert_contains "$body" 'wg_interface_is_wireguard' \
      "$name must verify the interface type instead of trusting a same-name link" || return 1
  done
  WARP_MODE=wireguard
  WARP_SCOPE=google
  WG_IFACE=warp-vps-wg
  require_root() { :; }
  load_config() { :; }
  unit_ready() { return 0; }
  required_runtime_units_ready() { return 0; }
  service_active() { return 0; }
  wg_interface_exists() { return 0; }
  wg() {
    wg_calls="${wg_calls}$*"$'\n'
    [ "$*" = 'show warp-vps-wg' ] && [ "$identity_valid" -eq 1 ]
  }
  rule_probe_ip() {
    case "$2" in 4) printf '8.8.8.0\n' ;; 6) printf '2001:4860::\n' ;; esac
  }
  route_uses_wg4() { return 0; }
  route_uses_wg6() { return 0; }
  wg_default_routes_absent() { return 0; }
  wg_global_routes_absent() { return 0; }
  socks_table_absent() { return 0; }
  wireguard_routes_local_ok() { return 0; }
  systemctl() { return 0; }
  restart_wireguard_runtime() {
    restart_calls=$((restart_calls + 1))
    identity_valid=1
  }
  log() { :; }
  warn() { :; }

  output="$(run_self_check)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'status must reject a same-name dummy link as the WireGuard data plane'
    return 1
  }
  assert_contains "$output" '同名网卡不存在或不是 WireGuard' \
    'status should identify the local interface-type mismatch' || return 1
  if test_quiet; then
    fail 'the quiet local test must reject a same-name dummy link'
    return 1
  fi
  assert_contains "$wg_calls" 'show warp-vps-wg' \
    'WireGuard identity must be checked through the local wg interface query' || return 1
  assert_not_contains "$wg_calls" 'latest-handshakes' \
    'interface identity must not become a handshake or external readiness gate' || return 1

  cmd_heal || {
    fail 'health repair should replace a same-name dummy link'
    return 1
  }
  assert_eq '1' "$restart_calls" \
    'health repair must rebuild a backend whose link is not a WireGuard interface' || return 1
  test_quiet || fail 'the rebuilt WireGuard identity should pass the local test'
}

test_socks_heal_waits_for_redsocks_before_routing() {
  source_without_main "$MANAGER_SCRIPT"
  local event_log events output rc=0 listener_ok=1 post_repair=0
  event_log="$(mktemp)"
  : > "$event_log"
  record_event() { printf '%s\n' "$1" >> "$event_log"; }
  require_root() { :; }
  load_config() { :; }
  WARP_MODE=socks
  WARP_SOCKS_PORT=24000
  REDSOCKS_PORT=24001
  required_runtime_units_ready() { [ "$post_repair" -eq 1 ]; }
  test_quiet() { [ "$post_repair" -eq 1 ]; }
  socks_wireguard_routes_absent() { return 0; }
  service_active() {
    case "$1" in
      warp-svc.service) return 0 ;;
      warp-vps-redsocks.service|warp-vps.service) return 1 ;;
      *) return 1 ;;
    esac
  }
  warp_proxy_local_ready() { return 0; }
  redsocks_local_ready() { [ "$post_repair" -eq 1 ]; }
  render_redsocks_conf() { record_event 'render-redsocks'; }
  wait_for_redsocks_ready() {
    record_event 'wait-listener:24001'
    [ "$listener_ok" -eq 1 ] || return 1
    post_repair=1
  }
  systemctl() {
    record_event "systemctl:$*"
    return 0
  }

  cmd_heal >/dev/null || {
    fail 'Socks heal should recover redsocks before restoring routing'
    return 1
  }
  events="$(< "$event_log")"
  local render_line redsocks_line wait_line routing_line
  render_line="$(line_number "$events" 'render-redsocks')"
  redsocks_line="$(line_number "$events" 'systemctl:restart warp-vps-redsocks.service')"
  wait_line="$(line_number "$events" 'wait-listener:24001')"
  routing_line="$(line_number "$events" 'systemctl:restart warp-vps.service')"
  if [ -z "$render_line" ] || [ -z "$redsocks_line" ] || [ -z "$wait_line" ] \
    || [ -z "$routing_line" ] || [ "$render_line" -ge "$redsocks_line" ] \
    || [ "$redsocks_line" -ge "$wait_line" ] || [ "$wait_line" -ge "$routing_line" ]; then
    fail 'Socks heal must render, restart redsocks, confirm its listener, then restore routing'
    return 1
  fi

  : > "$event_log"
  listener_ok=0
  post_repair=0
  rc=0
  output="$(cmd_heal 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'Socks heal must fail when the restarted redsocks listener never appears'
    return 1
  }
  events="$(< "$event_log")"
  assert_contains "$output" '没有正确监听，未重新加载分流规则' \
    'the failed heal should explain why routing remained disabled' || return 1
  assert_not_contains "$events" 'systemctl:restart warp-vps.service' \
    'Socks heal must not reactivate transparent routing without a redsocks listener'
}

test_heal_ignores_auxiliary_timer_drift() {
  source_without_main "$MANAGER_SCRIPT"
  local restart_wg_calls=0 systemctl_calls=''

  require_root() { :; }
  load_config() { :; }
  WARP_MODE=wireguard
  WG_IFACE=warp-vps-wg
  required_runtime_units_ready() { return 0; }
  test_quiet() { return 0; }
  service_active() { return 0; }
  wg_interface_is_wireguard() { return 0; }
  socks_table_absent() { return 0; }
  wireguard_routes_local_ok() { return 0; }
  restart_wireguard_runtime() { restart_wg_calls=$((restart_wg_calls + 1)); }
  systemctl() { systemctl_calls="${systemctl_calls}$*\n"; }
  log() { :; }
  warn() { :; }

  cmd_heal || return 1
  assert_eq '0' "$restart_wg_calls" \
    'timer-only drift must not restart a healthy WireGuard backend' || return 1
  assert_not_contains "$systemctl_calls" 'restart warp-vps.service' \
    'timer-only drift must not reload healthy routing rules' || return 1
  assert_eq '' "$systemctl_calls" \
    'an auxiliary timer state must not enter the data-plane repair path'
}

test_health_timer_failure_does_not_block_data_plane() {
  (
    source_without_main "$INSTALL_SCRIPT"
    systemctl() { return 1; }
    log() { :; }
    enable_health_timer
  ) || {
    fail 'installer must not tear down a healthy data plane when only the health timer fails'
    return 1
  }

  source_without_main "$MANAGER_SCRIPT"
  local output
  WARP_MODE=wireguard
  WARP_SCOPE=google
  WG_IFACE=warp-vps-wg
  unit_ready() { [ "$1" != 'warp-vps-health.timer' ]; }
  wg_interface_is_wireguard() { return 0; }
  rule_probe_ip() {
    case "$2" in 4) printf '8.8.8.0\n' ;; 6) printf '2001:4860::\n' ;; esac
  }
  route_uses_wg4() { return 0; }
  route_uses_wg6() { return 0; }
  wg_default_routes_absent() { return 0; }
  wg_global_routes_absent() { return 0; }
  socks_table_absent() { return 0; }

  output="$(run_self_check)" || {
    fail 'status must remain successful when only the auxiliary health timer is unavailable'
    return 1
  }
  assert_contains "$output" '自动健康检查未启用；不影响当前分流' \
    'status should describe the timer as auxiliary instead of reporting a data-plane failure'
}

test_uninstall_cleans_both_rule_backends_and_keeps_custom_wg_path() {
  source_without_main "$MANAGER_SCRIPT"
  CONFIG_FILE="${FIXTURE_DIR}/config/custom-wireguard.env"
  unset WARP_MODE WG_IFACE WG_CONFIG MANAGED_WARP_SVC MANAGED_REDSOCKS_BIN REDSOCKS_BIN || true
  load_uninstall_config
  assert_eq 'wireguard' "$WARP_MODE" 'uninstall should read the stored mode' || return 1
  assert_eq 'custom-wg' "$WG_IFACE" 'uninstall should read the stored interface' || return 1
  assert_eq '/etc/wireguard/custom-wg.conf' "$WG_CONFIG" \
    'uninstall should preserve the configured WireGuard path' || return 1

  local route_stops=0
  WARP_MODE=socks
  stop_wg_routes() { route_stops=$((route_stops + 1)); }
  uninstall_nft_table_exists() { return 1; }
  ip() { :; }
  nft() { :; }
  stop_rules_for_uninstall
  assert_eq '1' "$route_stops" \
    'every uninstall must clear stale project WireGuard routes' || return 1

  local systemctl_calls=''
  systemctl() {
    systemctl_calls="${systemctl_calls}$*\n"
    return 0
  }
  uninstall_unit_is_active() { return 1; }
  uninstall_unit_is_enabled() { return 1; }
  WG_IFACE=warp-vps-wg
  stop_project_units_for_uninstall
  assert_contains "$systemctl_calls" \
    'stop warp-vps-health.timer\nstop warp-vps-health.service\nstop warp-vps-health.timer\ndisable warp-vps-health.timer' \
    'uninstall must quiesce the timer before stopping an in-flight health service' || return 1
  assert_contains "$systemctl_calls" \
    'stop warp-vps-redsocks.service\ndisable warp-vps-redsocks.service\nstop wg-quick@warp-vps-wg.service\ndisable wg-quick@warp-vps-wg.service' \
    'uninstall must stop each backend independently'
}

test_uninstall_precise_wireguard_does_not_require_nft() {
  source_without_main "$MANAGER_SCRIPT"
  local route_stops=0 global_checks=0
  WARP_MODE=wireguard
  WARP_SCOPE=google

  command() {
    [ "$1" = '-v' ] || return 1
    case "$2" in
      ip) return 0 ;;
      nft) return 1 ;;
      *) builtin command "$@" ;;
    esac
  }
  stop_wg_routes() { route_stops=$((route_stops + 1)); }
  wg_global_routes_absent() {
    global_checks=$((global_checks + 1))
    return 2
  }

  stop_rules_for_uninstall || {
    fail 'precise WireGuard uninstall must not require the optional nft command'
    return 1
  }
  assert_eq '1' "$route_stops" \
    'precise WireGuard uninstall must still remove its owned routes' || return 1
  assert_eq '0' "$global_checks" \
    'precise WireGuard uninstall must not query unrelated global nft state' || return 1
  unset -f command
}

test_uninstall_quiesces_health_before_backends() {
  source_without_main "$MANAGER_SCRIPT"
  WG_IFACE=warp-vps-wg
  local backend_stop_calls=0 health_active=1 redsocks_active=1 redsocks_enabled=1
  local systemctl_calls='' unexpected_systemctl_calls=0
  local timer_active=1 timer_enabled=1 timer_stuck=0

  systemctl() {
    systemctl_calls="${systemctl_calls}$*\n"
    case "$*" in
      'stop warp-vps-health.timer') [ "$timer_stuck" -eq 1 ] || timer_active=0 ;;
      'stop warp-vps-health.service')
        health_active=0
        timer_active=1
        timer_enabled=1
        ;;
      'disable warp-vps-health.timer') timer_enabled=0 ;;
      'stop warp-vps.service') backend_stop_calls=$((backend_stop_calls + 1)) ;;
      'disable warp-vps.service') ;;
      'stop warp-vps-redsocks.service')
        backend_stop_calls=$((backend_stop_calls + 1))
        redsocks_active=0
        ;;
      'disable warp-vps-redsocks.service') redsocks_enabled=0 ;;
      'stop wg-quick@warp-vps-wg.service')
        backend_stop_calls=$((backend_stop_calls + 1))
        return 5
        ;;
      'disable wg-quick@warp-vps-wg.service')
        return 5
        ;;
      'disable --now warp-vps-redsocks.service wg-quick@warp-vps-wg.service')
        backend_stop_calls=$((backend_stop_calls + 1))
        return 5
        ;;
      *)
        unexpected_systemctl_calls=$((unexpected_systemctl_calls + 1))
        return 64
        ;;
    esac
    return 0
  }
  uninstall_unit_is_active() {
    case "$1" in
      warp-vps-health.timer) [ "$timer_active" -eq 1 ] ;;
      warp-vps-health.service) [ "$health_active" -eq 1 ] ;;
      warp-vps-redsocks.service) [ "$redsocks_active" -eq 1 ] ;;
      *) return 1 ;;
    esac
  }
  uninstall_unit_is_enabled() {
    case "$1" in
      warp-vps-health.timer) [ "$timer_enabled" -eq 1 ] ;;
      warp-vps-redsocks.service) [ "$redsocks_enabled" -eq 1 ] ;;
      *) return 1 ;;
    esac
  }

  stop_project_units_for_uninstall || {
    fail 'uninstall should quiesce a healer that reactivates its timer while exiting'
    return 1
  }
  assert_contains "$systemctl_calls" \
    'stop warp-vps-health.timer\nstop warp-vps-health.service\nstop warp-vps-health.timer\ndisable warp-vps-health.timer' \
    'uninstall must stop the timer again after the healer exits' || return 1
  assert_contains "$systemctl_calls" \
    'stop warp-vps-redsocks.service\ndisable warp-vps-redsocks.service\nstop wg-quick@warp-vps-wg.service\ndisable wg-quick@warp-vps-wg.service' \
    'a missing WireGuard unit must not prevent an installed redsocks unit from stopping' || return 1
  assert_not_contains "$systemctl_calls" \
    'disable --now warp-vps-redsocks.service wg-quick@warp-vps-wg.service' \
    'uninstall must not batch an installed backend with a potentially missing backend' || return 1
  assert_eq '3' "$backend_stop_calls" \
    'uninstall may stop common and backend units only after health automation is quiescent' || return 1
  assert_eq '0' "$unexpected_systemctl_calls" \
    'uninstall regression must model every systemctl operation' || return 1

  timer_active=1
  timer_enabled=1
  health_active=1
  timer_stuck=1
  backend_stop_calls=0
  if ( stop_project_units_for_uninstall >/dev/null 2>&1 ); then
    fail 'uninstall must fail before backend teardown when the timer remains active'
    return 1
  fi
  assert_eq '0' "$backend_stop_calls" \
    'uninstall must not touch backends while health automation remains active'
}

test_uninstall_scope_is_explicit_and_vnc_safe() {
  source_without_main "$MANAGER_SCRIPT"

  local answer_index=0
  local answers=('invalid' '')
  read_input() {
    printf -v "$1" '%s' "${answers[$answer_index]}"
    answer_index=$((answer_index + 1))
  }
  resolve_uninstall_scope 2>/dev/null || return 1
  assert_eq '0' "$UNINSTALL_REMOVE_DEPENDENCIES" \
    'empty interactive choice should keep dependencies' || return 1
  assert_eq '2' "$answer_index" 'invalid uninstall input should be asked again' || return 1

  answer_index=0
  answers=('2')
  resolve_uninstall_scope 2>/dev/null || return 1
  assert_eq '1' "$UNINSTALL_REMOVE_DEPENDENCIES" \
    'interactive option 2 should remove dependencies' || return 1

  local prompt_calls=0
  read_input() {
    prompt_calls=$((prompt_calls + 1))
    return 1
  }
  resolve_uninstall_scope --yes || return 1
  assert_eq '0' "$UNINSTALL_REMOVE_DEPENDENCIES" '--yes should keep dependencies' || return 1
  resolve_uninstall_scope all || return 1
  assert_eq '1' "$UNINSTALL_REMOVE_DEPENDENCIES" 'all should remove dependencies' || return 1
  assert_eq '0' "$prompt_calls" 'non-interactive uninstall modes must not read input' || return 1

  local rc=0
  resolve_uninstall_scope unknown 2>/dev/null || rc=$?
  assert_eq '2' "$rc" 'unknown uninstall options must fail with usage status' || return 1
  rc=0
  resolve_uninstall_scope --yes extra 2>/dev/null || rc=$?
  assert_eq '2' "$rc" 'extra uninstall options must not be ignored'
}

test_uninstall_deactivation_reaches_inactive_state() {
  source_without_main "$MANAGER_SCRIPT"

  local nft_active=1
  local iface_active=1
  local routes_active=1
  WARP_MODE=socks
  WG_IFACE=warp-vps-wg
  WG_CONFIG="${FIXTURE_DIR}/config/custom-wireguard.env"
  MANAGED_WARP_SVC=0
  UNINSTALL_WIREGUARD_PRESENT=0
  UNINSTALL_RUNTIME_IDENTIFIED=1

  systemctl() { return 0; }
  uninstall_unit_is_active() { return 1; }
  uninstall_unit_is_enabled() { return 1; }
  stop_wg_routes() { routes_active=0; }
  uninstall_nft_table_exists() { [ "$nft_active" -eq 1 ]; }
  nft() {
    if [ "$*" = 'delete table inet warp_vps' ]; then
      nft_active=0
    fi
  }
  ip() {
    case "$*" in
      'link delete dev warp-vps-wg') iface_active=0 ;;
      *) return 0 ;;
    esac
  }
  uninstall_wg_interface_exists() { [ "$iface_active" -eq 1 ]; }
  wg-quick() { return 1; }
  ok_line() { :; }

  deactivate_runtime_for_uninstall
  assert_eq '0' "$nft_active" 'uninstall must leave the nftables table absent' || return 1
  assert_eq '0' "$routes_active" 'uninstall must remove project WireGuard routes' || return 1
  assert_eq '0' "$iface_active" 'uninstall must leave the project WireGuard interface absent' || return 1
  assert_eq '1' "$UNINSTALL_WIREGUARD_PRESENT" \
    'a discovered WireGuard runtime must remain marked for config backup'
}

test_uninstall_rejects_rules_that_remain_active() {
  source_without_main "$MANAGER_SCRIPT"

  WARP_MODE=socks
  WG_IFACE=warp-vps-wg
  WG_CONFIG=/etc/wireguard/warp-vps-wg.conf
  MANAGED_WARP_SVC=0
  UNINSTALL_RUNTIME_IDENTIFIED=1
  systemctl() { return 0; }
  uninstall_unit_is_active() { return 1; }
  uninstall_unit_is_enabled() { return 1; }
  ip() { return 0; }
  uninstall_wg_interface_exists() { return 1; }
  stop_wg_routes() { :; }
  uninstall_nft_table_exists() { return 0; }
  nft() { return 0; }

  local output rc=0
  output="$(deactivate_runtime_for_uninstall 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'uninstall accepted an nftables table that remained active'
    return 1
  }
  assert_contains "$output" '仍在生效' \
    'persistent rule failure should explain why uninstall stopped'
}

test_uninstall_fails_closed_without_runtime_identity() {
  source_without_main "$MANAGER_SCRIPT"

  WARP_MODE=socks
  WG_IFACE=warp-vps-wg
  WG_CONFIG=/etc/wireguard/warp-vps-wg.conf
  MANAGED_WARP_SVC=0
  UNINSTALL_RUNTIME_IDENTIFIED=0
  systemctl() { return 0; }
  uninstall_unit_is_active() { return 1; }
  uninstall_unit_is_enabled() { return 1; }
  ip() { return 0; }
  uninstall_wg_interface_exists() { return 1; }
  stop_wg_routes() { :; }
  nft() { return 0; }
  uninstall_nft_table_exists() { return 1; }

  local output rc=0
  output="$(deactivate_runtime_for_uninstall 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'uninstall reported success without config, unit, or live runtime identity'
    return 1
  }
  assert_contains "$output" '无法排除未知的自定义 WireGuard 网卡' \
    'missing runtime identity should fail closed instead of assuming the default interface'
}

test_socks_uninstall_stops_known_rules_before_missing_ip_failure() {
  source_without_main "$MANAGER_SCRIPT"

  local nft_active=1
  local systemctl_calls=''
  WARP_MODE=socks
  WG_IFACE=warp-vps-wg
  WG_CONFIG=/etc/wireguard/warp-vps-wg.conf
  MANAGED_WARP_SVC=0
  UNINSTALL_RUNTIME_IDENTIFIED=1
  systemctl() {
    systemctl_calls="${systemctl_calls}$*\n"
    return 0
  }
  uninstall_unit_is_active() { return 1; }
  uninstall_unit_is_enabled() { return 1; }
  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = 'ip' ]; then
      return 1
    fi
    builtin command "$@"
  }
  uninstall_nft_table_exists() { [ "$nft_active" -eq 1 ]; }
  nft() {
    if [ "$*" = 'delete table inet warp_vps' ]; then
      nft_active=0
    fi
  }
  ok_line() { :; }

  deactivate_runtime_for_uninstall
  assert_eq '0' "$nft_active" 'Socks nftables rules must be removed even when ip is missing' || return 1
  assert_contains "$systemctl_calls" 'stop warp-vps-health.timer' \
    'health automation must stop before optional WireGuard inspection'
}

test_uninstall_state_queries_fail_closed() {
  source_without_main "$MANAGER_SCRIPT"

  systemctl() { return 1; }
  local output rc=0
  output="$(uninstall_unit_is_active warp-vps.service 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'a failed systemd query was treated as an inactive service'
    return 1
  }
  assert_contains "$output" '无法查询 systemd' \
    'systemd query failures should stop uninstall' || return 1

  nft() { return 1; }
  rc=0
  output="$(uninstall_nft_table_exists 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'a failed nftables query was treated as an absent table'
    return 1
  }
  assert_contains "$output" '无法读取 nftables' \
    'nftables query failures should stop uninstall' || return 1

  nft() { printf 'table inet warp_vps\n'; }
  grep() { return 2; }
  rc=0
  output="$(uninstall_nft_table_exists 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'an nftables parser failure was treated as an absent table'
    return 1
  }
  assert_contains "$output" '无法解析 nftables' \
    'nftables parser failures should stop uninstall' || return 1
  unset -f grep

  ip() { return 1; }
  WG_IFACE=warp-vps-wg
  rc=0
  output="$(uninstall_wg_interface_exists 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'a failed link query was treated as an absent WireGuard interface'
    return 1
  }
  assert_contains "$output" '无法读取网卡' \
    'link query failures should stop uninstall' || return 1

  ip() { printf '1: lo: <LOOPBACK>\n'; }
  awk() { return 2; }
  rc=0
  output="$(uninstall_wg_interface_exists 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'a link parser failure was treated as an absent WireGuard interface'
    return 1
  }
  assert_contains "$output" '无法解析网卡' \
    'link parser failures should stop uninstall'
}

test_uninstall_missing_unit_is_already_disabled() {
  source_without_main "$MANAGER_SCRIPT"

  local is_enabled_calls=0
  systemctl() {
    case "${1:-}" in
      show) printf 'LoadState=not-found\nActiveState=inactive\n' ;;
      is-enabled)
        is_enabled_calls=$((is_enabled_calls + 1))
        return 1
        ;;
      *) return 1 ;;
    esac
  }

  local rc=0
  uninstall_unit_is_enabled warp-vps.service || rc=$?
  assert_eq '1' "$rc" 'a missing unit should be treated as already disabled' || return 1
  assert_eq '0' "$is_enabled_calls" \
    'a missing unit should not require an is-enabled query'
}

test_uninstall_orders_teardown_before_dependencies_and_deletion() {
  local body resolve_line deactivate_line dependency_line delete_line swap_line
  body="$(function_body "$MANAGER_SCRIPT" cmd_uninstall)"
  resolve_line="$(line_number "$body" 'resolve_uninstall_scope')"
  deactivate_line="$(line_number "$body" 'deactivate_runtime_for_uninstall')"
  dependency_line="$(line_number "$body" 'uninstall_project_dependencies')"
  delete_line="$(line_number "$body" 'remove_file_if_exists "$REDSOCKS_FALLBACK_BIN"')"
  swap_line="$(line_number "$body" 'uninstall_managed_swap')"
  if [ -z "$resolve_line" ] || [ -z "$deactivate_line" ] \
    || [ -z "$dependency_line" ] || [ -z "$delete_line" ] || [ -z "$swap_line" ]; then
    fail 'uninstall phase boundaries are incomplete'
    return 1
  fi
  if [ "$resolve_line" -ge "$deactivate_line" ] || [ "$deactivate_line" -ge "$dependency_line" ] \
    || [ "$dependency_line" -ge "$delete_line" ] || [ "$delete_line" -ge "$swap_line" ]; then
    fail 'uninstall must resolve input, deactivate rules, uninstall dependencies, then delete files'
    return 1
  fi

  local main_body
  main_body="$(function_body "$MANAGER_SCRIPT" main)"
  assert_contains "$main_body" 'cmd_uninstall "$@"' \
    'main must forward uninstall options instead of silently ignoring them'
}

test_uninstall_permanently_deletes_owned_paths_without_backup() {
  source_without_main "$MANAGER_SCRIPT"

  local root file_path tree_path dynamic_dir output rc=0
  root="$(mktemp -d)"
  file_path="${root}/managed-file"
  tree_path="${root}/managed-tree"
  dynamic_dir="${root}/dynamic-config-path"
  : > "$file_path"
  mkdir -p "${tree_path}/nested" "$dynamic_dir"
  : > "${tree_path}/nested/state"

  remove_file_if_exists "$file_path"
  if [ -e "$file_path" ] || [ -L "$file_path" ]; then
    fail 'uninstall file deletion left the managed file behind'
    return 1
  fi

  output="$(remove_file_if_exists "$dynamic_dir" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'a dynamic file path was recursively accepted as a directory'
    return 1
  }
  [ -d "$dynamic_dir" ] || {
    fail 'a dynamic file path recursively deleted a directory'
    return 1
  }
  assert_contains "$output" '无法永久删除文件' \
    'directory rejection should identify the failed file deletion' || return 1

  remove_tree_if_exists "$tree_path"
  if [ -e "$tree_path" ] || [ -L "$tree_path" ]; then
    fail 'uninstall tree deletion left the fixed project directory behind'
    return 1
  fi
  remove_tree_if_exists "$root"

  local uninstall_body file_body tree_body swap_body
  uninstall_body="$(function_body "$MANAGER_SCRIPT" cmd_uninstall)"
  file_body="$(function_body "$MANAGER_SCRIPT" remove_file_if_exists)"
  tree_body="$(function_body "$MANAGER_SCRIPT" remove_tree_if_exists)"
  swap_body="$(function_body "$MANAGER_SCRIPT" uninstall_managed_swap)"
  assert_contains "$file_body" 'rm -f -- "$path"' \
    'file deletion should be permanent and non-recursive' || return 1
  assert_not_contains "$file_body" 'rm -rf' \
    'dynamic file paths must never use recursive deletion' || return 1
  assert_contains "$tree_body" 'rm -rf -- "$path"' \
    'fixed project directories should be permanently deleted' || return 1
  assert_contains "$uninstall_body" 'managed_wireguard_config_owned' \
    'WireGuard config deletion must require project ownership evidence' || return 1
  assert_contains "$uninstall_body" 'if [ "$remove_wg_config" -eq 1 ]' \
    'only an owned WireGuard config may enter permanent deletion' || return 1
  assert_not_contains "$uninstall_body" 'BACKUP_ROOT' \
    'uninstall must not create a backup root' || return 1
  assert_not_contains "$swap_body" 'backup' \
    'managed Swap uninstall must not create an fstab or Swap backup'
}

test_uninstall_wireguard_config_requires_project_account_match() {
  source_without_main "$MANAGER_SCRIPT"

  local root ownership_body
  assert_eq '/var/lib/warp-vps-manager/wgcf/wgcf-account.toml' "$WGCF_ACCOUNT" \
    'the manager must resolve its project-owned wgcf account path' || return 1
  root="$(mktemp -d)"
  WGCF_ACCOUNT="${root}/wgcf-account.toml"
  WG_CONFIG="${root}/warp-vps-wg.conf"
  printf 'private_key = "project-private-key="\n' > "$WGCF_ACCOUNT"
  printf '[Interface]\nPrivateKey = project-private-key=\n' > "$WG_CONFIG"
  managed_wireguard_config_owned || {
    fail 'a WireGuard config matching the project wgcf account should be owned'
    return 1
  }

  printf "private_key = 'different-private-key='\n" > "$WGCF_ACCOUNT"
  if managed_wireguard_config_owned; then
    fail 'a WireGuard config with a different private key was claimed as project-owned'
    return 1
  fi

  ownership_body="$(function_body "$MANAGER_SCRIPT" managed_wireguard_config_owned)"
  assert_contains "$ownership_body" 'hmac.compare_digest' \
    'WireGuard ownership must compare keys without printing them' || return 1
  assert_not_contains "$ownership_body" 'print(' \
    'WireGuard ownership must not expose private keys' || return 1
  remove_tree_if_exists "$root"
}

test_uninstall_rejects_unowned_wireguard_config_in_project_tree() {
  source_without_main "$MANAGER_SCRIPT"

  local root output production_remove_tree alias_path rc=0
  root="$(mktemp -d)"
  production_remove_tree="$(declare -f remove_tree_if_exists)"
  ETC_DIR="${root}/etc"
  APP_DIR="${root}/app"
  STATE_DIR="${root}/state"
  mkdir -p "$ETC_DIR" "$APP_DIR" "$STATE_DIR"
  WG_CONFIG="${ETC_DIR}/nested/../unowned.conf"
  wireguard_config_in_project_tree || {
    fail 'an unowned WireGuard path inside a project tree was not detected'
    return 1
  }
  WG_CONFIG="${root}/outside.conf"
  if wireguard_config_in_project_tree; then
    fail 'an external WireGuard path was mistaken for a project-tree path'
    return 1
  fi
  : > "${ETC_DIR}/aliased.conf"
  alias_path="${root}/project-alias"
  ln -s "$ETC_DIR" "$alias_path"
  WG_CONFIG="${alias_path}/aliased.conf"
  wireguard_config_in_project_tree || {
    fail 'an external symlink into a project tree bypassed the deletion boundary'
    return 1
  }
  WG_CONFIG="${ETC_DIR}/unowned.conf"
  : > "$WG_CONFIG"

  require_root() { :; }
  load_uninstall_config() {
    WARP_MODE=wireguard
    WG_IFACE=warp-vps-wg
    WG_CONFIG="${ETC_DIR}/unowned.conf"
    MANAGED_WARP_SVC=0
    UNINSTALL_WIREGUARD_PRESENT=1
    UNINSTALL_RUNTIME_IDENTIFIED=1
  }
  recover_uninstall_runtime_from_unit() { :; }
  managed_wireguard_config_owned() { return 1; }
  deactivate_runtime_for_uninstall() { printf 'unexpected-deactivation\n'; }
  remove_file_if_exists() { printf 'unexpected-delete:%s\n' "$1"; }
  remove_tree_if_exists() { printf 'unexpected-delete:%s\n' "$1"; }
  uninstall_managed_swap() { printf 'unexpected-delete:swap\n'; }
  systemctl() { :; }

  output="$(cmd_uninstall --yes 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'uninstall accepted an unowned WireGuard config inside a deletion tree'
    return 1
  }
  assert_contains "$output" '请先将文件移到项目目录外并更新 WG_CONFIG' \
    'the ownership conflict should provide an actionable path' || return 1
  assert_not_contains "$output" 'unexpected-deactivation' \
    'ownership conflict must stop before runtime mutation' || return 1
  assert_not_contains "$output" 'unexpected-delete:' \
    'ownership conflict must stop before permanent deletion' || return 1
  eval "$production_remove_tree"
  remove_tree_if_exists "$root"
}

test_managed_swap_uninstall_verifies_state_without_backup() {
  source_without_main "$MANAGER_SCRIPT"

  local root mock_fstab_tmp events='' swap_active=1 fstab_listed=1
  root="$(command mktemp -d)"
  mock_fstab_tmp="${root}/fstab.tmp"
  managed_swap_listed_in() {
    case "$1" in
      /proc/swaps) [ "$swap_active" -eq 1 ] ;;
      /etc/fstab) [ "$fstab_listed" -eq 1 ] ;;
      *) return 1 ;;
    esac
  }
  swapoff() {
    events="${events}swapoff\n"
    swap_active=0
  }
  mktemp() { printf '%s\n' "$mock_fstab_tmp"; }
  awk() {
    events="${events}awk\n"
    printf 'cleaned fstab\n'
  }
  install() {
    events="${events}install\n"
    fstab_listed=0
  }
  rm() {
    events="${events}rm\n"
    command rm "$@"
  }
  remove_file_if_exists() { events="${events}delete-swap\n"; }
  info_line() { :; }

  uninstall_managed_swap
  assert_eq 'swapoff\nawk\ninstall\nrm\ndelete-swap\n' "$events" \
    'Swap uninstall must deactivate, rewrite, remove its temp file, then delete the Swap file' \
    || return 1
  [ ! -e "$mock_fstab_tmp" ] || {
    fail 'Swap uninstall left its transient fstab file behind'
    return 1
  }
  remove_tree_if_exists "$root"
  unset -f awk install mktemp rm swapoff

  local output rc=0 swap_body
  managed_swap_listed_in() { die "无法读取 Swap 状态文件：$1"; }
  remove_file_if_exists() { printf 'unexpected-delete\n'; }
  output="$(uninstall_managed_swap 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'Swap uninstall continued after a state query failure'
    return 1
  }
  assert_not_contains "$output" 'unexpected-delete' \
    'Swap state query failure must stop before permanent deletion' || return 1

  swap_body="$(function_body "$MANAGER_SCRIPT" uninstall_managed_swap)"
  assert_contains "$swap_body" 'swapoff "$MANAGED_SWAP_FILE" || die' \
    'Swap deactivation failure must stop permanent deletion' || return 1
  assert_contains "$swap_body" 'if ! awk' \
    'fstab generation failure must stop permanent deletion' || return 1
  assert_contains "$swap_body" 'if ! install' \
    'fstab replacement failure must stop permanent deletion'
}

test_all_dependency_packages_are_explicit_and_scoped() {
  source_without_main "$MANAGER_SCRIPT"

  local package_calls=''
  local apt_purged=0
  dpkg-query() {
    if [ "$apt_purged" -eq 0 ]; then
      printf 'cloudflare-warp\tinstalled\nredsocks\tconfig-files\nwireguard-tools\tunpacked\n'
    fi
  }
  apt-get() {
    package_calls="$*"
    apt_purged=1
    return 0
  }
  uninstall_apt_dependencies
  assert_contains "$package_calls" 'DPkg::Lock::Timeout=1200' \
    'APT all uninstall should wait for the dpkg lock' || return 1
  assert_contains "$package_calls" 'APT::Get::AutomaticRemove=false' \
    'APT all uninstall should disable automatic removals' || return 1
  assert_contains "$package_calls" 'purge -y cloudflare-warp redsocks wireguard-tools' \
    'APT all uninstall should purge the three dedicated runtime packages' || return 1
  assert_not_contains "$package_calls" 'autoremove' 'APT all uninstall must not autoremove' || return 1
  assert_not_contains "$package_calls" 'curl' 'APT all uninstall must keep shared curl' || return 1
  assert_not_contains "$package_calls" 'python' 'APT all uninstall must keep shared Python' || return 1
  assert_not_contains "$package_calls" 'iproute' 'APT all uninstall must keep shared iproute' || return 1

  package_calls=''
  local rpm_removed=0
  rpm() {
    if [ "$rpm_removed" -eq 0 ]; then
      printf 'cloudflare-warp\nredsocks\nwireguard-tools\n'
    fi
  }
  dnf() {
    package_calls="$*"
    rpm_removed=1
    return 0
  }
  uninstall_rpm_dependencies
  assert_contains "$package_calls" \
    '-y --setopt=clean_requirements_on_remove=False remove cloudflare-warp redsocks wireguard-tools' \
    'RPM all uninstall should use a DNF4/DNF5-compatible no-autoremove setting' || return 1
  assert_not_contains "$package_calls" '--noautoremove' \
    'RPM all uninstall must not use the DNF4-only noautoremove spelling' || return 1
  assert_not_contains "$package_calls" ' autoremove ' 'RPM all uninstall must not run an autoremove command'
}

test_dependency_services_stop_independently() {
  source_without_main "$MANAGER_SCRIPT"
  local dependency_calls=0 redsocks_active=0 redsocks_missing=1
  local systemctl_calls='' unexpected_systemctl_calls=0 warp_active=1 warp_missing=0

  systemctl() {
    systemctl_calls="${systemctl_calls}$*\n"
    case "$*" in
      'stop warp-svc.service')
        [ "$warp_missing" -eq 1 ] && return 5
        warp_active=0
        ;;
      'disable warp-svc.service') [ "$warp_missing" -eq 0 ] || return 5 ;;
      'stop redsocks.service')
        [ "$redsocks_missing" -eq 1 ] && return 5
        redsocks_active=0
        ;;
      'disable redsocks.service') [ "$redsocks_missing" -eq 0 ] || return 5 ;;
      'disable --now warp-svc.service redsocks.service') return 5 ;;
      *)
        unexpected_systemctl_calls=$((unexpected_systemctl_calls + 1))
        return 64
        ;;
    esac
    return 0
  }
  uninstall_unit_is_active() {
    case "$1" in
      warp-svc.service) [ "$warp_missing" -eq 0 ] && [ "$warp_active" -eq 1 ] ;;
      redsocks.service) [ "$redsocks_missing" -eq 0 ] && [ "$redsocks_active" -eq 1 ] ;;
      *) return 1 ;;
    esac
  }
  command() {
    case "$*" in
      '-v apt-get'|'-v dpkg-query') return 0 ;;
      *) return 1 ;;
    esac
  }
  uninstall_apt_dependencies() { dependency_calls=$((dependency_calls + 1)); }

  uninstall_project_dependencies >/dev/null || {
    fail 'an installed warp-svc must stop when the vendor redsocks unit is missing'
    return 1
  }
  assert_contains "$systemctl_calls" \
    'stop warp-svc.service\ndisable warp-svc.service\nstop redsocks.service\ndisable redsocks.service' \
    'dependency services must stop independently' || return 1
  assert_not_contains "$systemctl_calls" 'disable --now warp-svc.service redsocks.service' \
    'a missing dependency service must not poison another service stop' || return 1
  assert_eq '0' "$unexpected_systemctl_calls" \
    'dependency regression must model every systemctl operation' || return 1

  systemctl_calls=''
  warp_missing=1
  warp_active=0
  redsocks_missing=0
  redsocks_active=1
  uninstall_project_dependencies >/dev/null || {
    fail 'an installed vendor redsocks service must stop when warp-svc is missing'
    return 1
  }
  assert_eq '2' "$dependency_calls" \
    'both missing-peer directions must proceed to package removal' || return 1
  assert_eq '0' "$unexpected_systemctl_calls" \
    'reverse dependency regression must model every systemctl operation'
}

test_dependency_uninstall_requires_absent_postcondition() {
  source_without_main "$MANAGER_SCRIPT"

  dpkg-query() { printf 'cloudflare-warp\tinstalled\n'; }
  apt-get() { return 0; }
  local output rc=0
  output="$(uninstall_apt_dependencies 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'APT dependency uninstall succeeded while the package remained installed'
    return 1
  }
  assert_contains "$output" '未彻底卸载软件包：cloudflare-warp' \
    'APT postcondition failure should name the remaining package' || return 1

  awk() { return 2; }
  apt-get() { printf 'APT_CALLED\n'; }
  rc=0
  output="$(uninstall_apt_dependencies 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'APT inventory parsing failure was treated as no packages installed'
    return 1
  }
  assert_contains "$output" '无法解析 dpkg' \
    'APT inventory parser failures should stop uninstall' || return 1
  assert_not_contains "$output" 'APT_CALLED' \
    'APT must not mutate packages after an inventory parser failure'
}

test_rpm_dependency_postcondition_parser_fails_closed() {
  source_without_main "$MANAGER_SCRIPT"

  local rpm_removed=0
  rpm() {
    if [ "$rpm_removed" -eq 0 ]; then
      printf 'cloudflare-warp\n'
    fi
  }
  grep() {
    case "${2:-}:${rpm_removed}" in
      cloudflare-warp:0) return 0 ;;
      cloudflare-warp:1) return 2 ;;
      *) return 1 ;;
    esac
  }
  dnf() {
    rpm_removed=1
    return 0
  }

  local output rc=0
  output="$(uninstall_rpm_dependencies 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'an RPM postcondition parser failure was treated as package absence'
    return 1
  }
  assert_contains "$output" 'RPM 已执行，但无法解析软件包状态' \
    'RPM postcondition parser failures should stop uninstall'
}

test_uninstall_scope_controls_dependency_and_fallback_cleanup() {
  source_without_main "$MANAGER_SCRIPT"

  local dependency_calls=0
  local prompt_calls=0
  local removed_paths=''
  require_root() { :; }
  read_input() {
    prompt_calls=$((prompt_calls + 1))
    return 1
  }
  load_uninstall_config() {
    WARP_MODE=socks
    WG_IFACE=warp-vps-wg
    WG_CONFIG=/etc/wireguard/warp-vps-wg.conf
    MANAGED_WARP_SVC=0
    UNINSTALL_WIREGUARD_PRESENT=0
    UNINSTALL_RUNTIME_IDENTIFIED=1
  }
  recover_uninstall_runtime_from_unit() { :; }
  managed_redsocks_fallback_exists() { return 0; }
  deactivate_runtime_for_uninstall() { :; }
  section() { :; }
  info_line() { :; }
  print_remove_target_if_exists() { :; }
  uninstall_project_dependencies() { dependency_calls=$((dependency_calls + 1)); }
  remove_file_if_exists() { removed_paths="${removed_paths}$1\n"; }
  remove_tree_if_exists() { removed_paths="${removed_paths}$1\n"; }
  uninstall_managed_swap() { :; }
  systemctl() { :; }

  cmd_uninstall --yes >/dev/null
  assert_eq '0' "$dependency_calls" 'project-only uninstall must keep dependencies' || return 1
  assert_eq '0' "$prompt_calls" '--yes must not prompt' || return 1
  assert_not_contains "$removed_paths" "$REDSOCKS_FALLBACK_BIN" \
    'project-only uninstall must keep a managed redsocks dependency' || return 1

  removed_paths=''
  cmd_uninstall all >/dev/null
  assert_eq '1' "$dependency_calls" 'all uninstall must remove dependencies' || return 1
  assert_eq '0' "$prompt_calls" 'all must not prompt' || return 1
  assert_contains "$removed_paths" "$REDSOCKS_FALLBACK_BIN" \
    'all uninstall must permanently delete an owned source-built redsocks binary'
}

test_dependency_failure_stops_before_file_deletion() {
  source_without_main "$MANAGER_SCRIPT"

  require_root() { :; }
  load_uninstall_config() {
    WARP_MODE=socks
    WG_IFACE=warp-vps-wg
    WG_CONFIG=/etc/wireguard/warp-vps-wg.conf
    MANAGED_WARP_SVC=0
    UNINSTALL_WIREGUARD_PRESENT=0
    UNINSTALL_RUNTIME_IDENTIFIED=1
  }
  recover_uninstall_runtime_from_unit() { :; }
  managed_redsocks_fallback_exists() { return 1; }
  deactivate_runtime_for_uninstall() { :; }
  section() { :; }
  info_line() { :; }
  print_remove_target_if_exists() { :; }
  uninstall_project_dependencies() { return 1; }
  remove_file_if_exists() { printf 'unexpected-delete:%s\n' "$1"; }
  remove_tree_if_exists() { printf 'unexpected-delete:%s\n' "$1"; }
  uninstall_managed_swap() { printf 'unexpected-delete:%s\n' "$MANAGED_SWAP_FILE"; }

  local output rc=0
  output="$(cmd_uninstall all 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'dependency failure was reported as a successful uninstall'
    return 1
  }
  assert_not_contains "$output" 'unexpected-delete:' \
    'dependency failure must stop before any project file is deleted' || return 1
  assert_not_contains "$output" 'WARP VPS Manager 已卸载' \
    'dependency failure must not print uninstall success'
}

test_uninstall_daemon_reload_failure_is_post_commit_warning() {
  source_without_main "$MANAGER_SCRIPT"

  require_root() { :; }
  load_uninstall_config() {
    WARP_MODE=socks
    WARP_SCOPE=google
    WG_IFACE=warp-vps-wg
    WG_CONFIG=/etc/wireguard/warp-vps-wg.conf
    MANAGED_WARP_SVC=0
    UNINSTALL_WIREGUARD_PRESENT=0
    UNINSTALL_RUNTIME_IDENTIFIED=1
  }
  recover_uninstall_runtime_from_unit() { :; }
  managed_redsocks_fallback_exists() { return 1; }
  deactivate_runtime_for_uninstall() { :; }
  section() { :; }
  info_line() { :; }
  print_remove_target_if_exists() { :; }
  uninstall_managed_swap() { :; }
  remove_file_if_exists() { :; }
  remove_tree_if_exists() { :; }
  systemctl() {
    [ "$*" != 'daemon-reload' ]
  }

  local output rc=0
  output="$(cmd_uninstall --yes 2>&1)" || rc=$?
  assert_eq '0' "$rc" \
    'daemon-reload failure after permanent deletion must not report the uninstall as uncommitted' || return 1
  assert_contains "$output" 'systemd' \
    'the post-delete daemon-reload failure should remain visible' || return 1
  assert_contains "$output" 'WARP VPS Manager 已卸载' \
    'the command must still report the already completed permanent deletion'
}

test_readme_documents_all_uninstall_modes() {
  source_without_main "$MANAGER_SCRIPT"
  assert_file_matches "$README_FILE" 'warp-vps uninstall` \| 交互永久删除项目' \
    'README should document interactive uninstall' || return 1
  assert_file_matches "$README_FILE" 'warp-vps uninstall --yes` \| 非交互永久删除项目，保留依赖' \
    'README should document direct project-only uninstall' || return 1
  assert_file_matches "$README_FILE" 'warp-vps uninstall all` \| 非交互永久删除项目及' \
    'README should document direct all uninstall' || return 1
  assert_file_matches "$README_FILE" '确认分流规则已经失效，再永久删除确认归属的项目文件，不创建卸载备份' \
    'README should document verified teardown and permanent deletion' || return 1
  assert_file_matches "$README_FILE" '无法确认由本项目创建的现有 WireGuard 配置会保留' \
    'README should document the WireGuard ownership boundary' || return 1
  assert_file_matches "$README_FILE" '若该配置位于项目目录内，卸载会要求先迁移到目录外' \
    'README should document the actionable project-tree conflict' || return 1
  assert_file_not_matches "$README_FILE" '/var/backups/warp-vps-manager/' \
    'README must not promise an uninstall backup' || return 1
  assert_file_not_matches "$README_FILE" '^[-*] 卸载不会删除系统依赖包' \
    'README must not retain the obsolete unconditional dependency promise' || return 1

  local help_output
  help_output="$(usage)"
  assert_contains "$help_output" 'uninstall --yes 非交互永久删除项目' \
    'CLI help should document permanent project-only uninstall' || return 1
  assert_contains "$help_output" 'uninstall all   非交互永久删除项目及' \
    'CLI help should document permanent all uninstall'
}

test_readme_documents_route_scope_contract() {
  assert_file_matches "$README_FILE" '默认.*精准分流 Google|精准分流 Google.*默认' \
    'README must state that fresh installation defaults to precise Google routing' || return 1
  assert_file_matches "$README_FILE" 'WARP_SCOPE|--scope (google|global)' \
    'README must document how to select a routing scope noninteractively' || return 1
  assert_file_matches "$README_FILE" '全局走 WARP.*WireGuard.*公网 IPv4、IPv6 与全部协议' \
    'README must describe the full-protocol WireGuard global scope' || return 1
  assert_file_matches "$README_FILE" '全局走 WARP.*Socks5.*公网 IPv4 TCP' \
    'README must describe the actual Socks5 global traffic boundary' || return 1
  assert_file_matches "$README_FILE" 'Google IPv4 UDP/443（QUIC）.*拒绝' \
    'README must retain the Google QUIC behavior in Socks5 mode' || return 1
  assert_file_matches "$README_FILE" 'Google IPv6.*拒绝' \
    'README must retain the Google IPv6 behavior in Socks5 mode' || return 1
  assert_file_matches "$README_FILE" 'Cloudflare STUN UDP/3478' \
    'README must name the evidence used for the interactive mode recommendation' || return 1
  assert_file_matches "$README_FILE" '未收到.*有效回包.*默认.*Socks5' \
    'README must document the fresh Socks5 default when the UDP probe gets no valid response' || return 1
  assert_file_matches "$README_FILE" 'WireGuard.*不会回退 TCP' \
    'README must explain why a failed UDP probe changes the default' || return 1
  assert_file_matches "$README_FILE" '全新非交互安装.*默认 WireGuard' \
    'README must preserve the noninteractive mode contract'
}

test_reinstall_accepts_legacy_socks_rule_cleanup() {
  source_without_main "$INSTALL_SCRIPT"
  PREVIOUS_MODE=socks
  MANAGED_WARP_SVC_VALUE=0
  BIN_PATH=/path/that/does/not/exist
  CONFIG_FILE="${FIXTURE_DIR}/config/socks-mode.env"
  local table_present=1

  systemctl() {
    case "$*" in
      'show '*) printf 'LoadState=loaded\nActiveState=inactive\n'; return 0 ;;
      'is-enabled '*) printf 'disabled\n'; return 1 ;;
      *) return 0 ;;
    esac
  }
  command() {
    case "$*" in
      '-v nft'|'-v ip') return 0 ;;
      '-v wg-quick') return 1 ;;
      *) builtin command "$@" ;;
    esac
  }
  nft() {
    case "$*" in
      'delete table inet warp_vps') return 0 ;;
      'list tables')
        [ "$table_present" -eq 0 ] || printf 'table inet warp_vps\n'
        return 0
        ;;
    esac
    return 1
  }
  ip() {
    case "$*" in
      'link show warp-vps-wg') return 1 ;;
      '-o link show') printf '1: lo: <LOOPBACK>\n'; return 0 ;;
    esac
    return 1
  }

  stop_project_runtime warp-vps-wg /etc/wireguard/warp-vps-wg.conf >/dev/null || {
    fail 'mode switching must not parse or gate on a legacy Socks nft table shape'
    return 1
  }
}

test_reinstall_quiesces_health_and_optional_backends() {
  source_without_main "$INSTALL_SCRIPT"
  PREVIOUS_MODE=socks
  MANAGED_WARP_SVC_VALUE=0
  BIN_PATH=/path/that/does/not/exist
  local common_stop_calls=0 health_active=1 health_stuck=0 log_output=''
  local redsocks_active=1 redsocks_disable_stuck=0 redsocks_enabled=1 redsocks_missing=0
  local redsocks_stop_stuck=0
  local systemctl_calls='' timer_active=1 timer_stuck=0 unexpected_systemctl_calls=0
  local wg_active=0 wg_disable_stuck=0 wg_enabled=0 wg_missing=1 wg_stop_stuck=0

  systemctl() {
    systemctl_calls="${systemctl_calls}$*\n"
    case "$*" in
      'stop warp-vps-health.timer')
        [ "$timer_stuck" -eq 1 ] || timer_active=0
        return 0
        ;;
      'stop warp-vps-health.service')
        [ "$health_stuck" -eq 1 ] || health_active=0
        timer_active=1
        return 0
        ;;
      'disable warp-vps-health.timer') return 0 ;;
      'stop warp-vps.service') common_stop_calls=$((common_stop_calls + 1)); return 0 ;;
      'disable warp-vps.service') return 0 ;;
      'stop warp-vps-redsocks.service')
        [ "$redsocks_missing" -eq 1 ] && return 5
        [ "$redsocks_stop_stuck" -eq 1 ] || redsocks_active=0
        return 0
        ;;
      'disable warp-vps-redsocks.service')
        [ "$redsocks_missing" -eq 1 ] && return 5
        [ "$redsocks_disable_stuck" -eq 1 ] || redsocks_enabled=0
        return 0
        ;;
      'stop wg-quick@warp-vps-wg.service')
        [ "$wg_missing" -eq 1 ] && return 5
        [ "$wg_stop_stuck" -eq 1 ] || wg_active=0
        return 0
        ;;
      'disable wg-quick@warp-vps-wg.service')
        [ "$wg_missing" -eq 1 ] && return 5
        [ "$wg_disable_stuck" -eq 1 ] || wg_enabled=0
        return 0
        ;;
      'disable --now warp-vps-redsocks.service wg-quick@warp-vps-wg.service') return 5 ;;
      'show warp-vps-health.timer '*)
        printf 'LoadState=loaded\n'
        if [ "$timer_active" -eq 1 ]; then printf 'ActiveState=active\n'; else printf 'ActiveState=inactive\n'; fi
        return 0
        ;;
      'show warp-vps-health.service '*)
        printf 'LoadState=loaded\n'
        if [ "$health_active" -eq 1 ]; then printf 'ActiveState=active\n'; else printf 'ActiveState=inactive\n'; fi
        return 0
        ;;
      'show warp-vps-redsocks.service '*)
        if [ "$redsocks_missing" -eq 1 ]; then printf 'LoadState=not-found\nActiveState=inactive\n'; return 0; fi
        printf 'LoadState=loaded\n'
        if [ "$redsocks_active" -eq 1 ]; then printf 'ActiveState=active\n'; else printf 'ActiveState=inactive\n'; fi
        return 0
        ;;
      'show wg-quick@warp-vps-wg.service '*)
        if [ "$wg_missing" -eq 1 ]; then printf 'LoadState=not-found\nActiveState=inactive\n'; return 0; fi
        printf 'LoadState=loaded\n'
        if [ "$wg_active" -eq 1 ]; then printf 'ActiveState=active\n'; else printf 'ActiveState=inactive\n'; fi
        return 0
        ;;
      'show '*) printf 'LoadState=loaded\nActiveState=inactive\n'; return 0 ;;
      'is-active warp-vps-health.timer')
        if [ "$timer_active" -eq 1 ]; then printf 'active\n'; return 0; fi
        printf 'inactive\n'; return 3
        ;;
      'is-active warp-vps-health.service')
        if [ "$health_active" -eq 1 ]; then printf 'active\n'; return 0; fi
        printf 'inactive\n'; return 3
        ;;
      'is-active warp-vps-redsocks.service')
        if [ "$redsocks_missing" -eq 1 ]; then printf 'unknown\n'; return 4; fi
        if [ "$redsocks_active" -eq 1 ]; then printf 'active\n'; return 0; fi
        printf 'inactive\n'; return 3
        ;;
      'is-active wg-quick@warp-vps-wg.service')
        if [ "$wg_missing" -eq 1 ]; then printf 'unknown\n'; return 4; fi
        if [ "$wg_active" -eq 1 ]; then printf 'active\n'; return 0; fi
        printf 'inactive\n'; return 3
        ;;
      'is-active '*) printf 'inactive\n'; return 3 ;;
      'is-enabled warp-vps-redsocks.service')
        if [ "$redsocks_missing" -eq 1 ]; then printf 'not-found\n'; return 4; fi
        if [ "$redsocks_enabled" -eq 1 ]; then printf 'enabled\n'; return 0; fi
        printf 'disabled\n'; return 1
        ;;
      'is-enabled wg-quick@warp-vps-wg.service')
        if [ "$wg_missing" -eq 1 ]; then printf 'not-found\n'; return 4; fi
        if [ "$wg_enabled" -eq 1 ]; then printf 'enabled\n'; return 0; fi
        printf 'disabled\n'; return 1
        ;;
      *)
        unexpected_systemctl_calls=$((unexpected_systemctl_calls + 1))
        return 64
        ;;
    esac
  }
  log() { log_output="${log_output}$*\n"; }
  nft() {
    case "$*" in
      'delete table inet warp_vps'|'list tables') return 0 ;;
      *) return 1 ;;
    esac
  }
  ip() {
    case "$*" in
      'link show warp-vps-wg') return 1 ;;
      '-o link show') printf '1: lo: <LOOPBACK>\n'; return 0 ;;
      *) return 1 ;;
    esac
  }

  stop_project_runtime warp-vps-wg /etc/wireguard/warp-vps-wg.conf >/dev/null || {
    fail 'a stopped shared health timer must not block a mode switch only because it remains enabled'
    return 1
  }
  assert_contains "$systemctl_calls" \
    'stop warp-vps-health.timer\nstop warp-vps-health.service\nstop warp-vps-health.timer' \
    'runtime teardown must stop the timer before the healer and stop it again after the healer exits' || return 1
  assert_contains "$systemctl_calls" \
    'stop warp-vps-redsocks.service\ndisable warp-vps-redsocks.service\nstop wg-quick@warp-vps-wg.service\ndisable wg-quick@warp-vps-wg.service' \
    'an installed Socks backend must stop before the missing WireGuard unit is handled' || return 1
  assert_not_contains "$systemctl_calls" \
    'disable --now warp-vps-redsocks.service wg-quick@warp-vps-wg.service' \
    'an installed backend must not share a systemctl batch with a potentially missing backend' || return 1
  assert_not_contains "$systemctl_calls" 'is-enabled warp-vps-health.timer' \
    'the shared health timer enabled state must not be a transition blocker' || return 1
  assert_not_contains "$systemctl_calls" 'is-enabled warp-vps.service' \
    'the shared routing service enabled state must not be a transition blocker' || return 1
  assert_eq '1' "$common_stop_calls" \
    'shared routing must stop only after health automation is quiescent' || return 1

  timer_active=1
  health_active=1
  redsocks_active=1
  redsocks_enabled=0
  stop_project_runtime warp-vps-wg /etc/wireguard/warp-vps-wg.conf >/dev/null || {
    fail 'an active but already disabled Socks backend must still be stopped'
    return 1
  }

  timer_active=1
  health_active=1
  PREVIOUS_MODE=wireguard
  redsocks_missing=1
  wg_missing=0
  wg_active=1
  wg_enabled=1
  stop_project_runtime warp-vps-wg /etc/wireguard/warp-vps-wg.conf >/dev/null || {
    fail 'an installed WireGuard backend must stop when the redsocks unit is missing'
    return 1
  }

  timer_active=1
  health_active=1
  PREVIOUS_MODE=socks
  redsocks_missing=0
  redsocks_active=1
  redsocks_enabled=1
  wg_active=1
  wg_enabled=1
  stop_project_runtime warp-vps-wg /etc/wireguard/warp-vps-wg.conf >/dev/null || {
    fail 'cleanup must independently stop both backends after a partial mode switch'
    return 1
  }

  timer_active=1
  health_active=1
  redsocks_missing=1
  wg_missing=1
  stop_project_runtime warp-vps-wg /etc/wireguard/warp-vps-wg.conf >/dev/null || {
    fail 'missing optional backend units must be an idempotent cleanup success'
    return 1
  }

  timer_active=1
  health_active=1
  timer_stuck=1
  redsocks_missing=0
  wg_missing=1
  common_stop_calls=0
  log_output=''
  if stop_project_runtime warp-vps-wg /etc/wireguard/warp-vps-wg.conf >/dev/null; then
    fail 'an active health timer after the second stop must block a mode switch'
    return 1
  fi
  assert_eq '0' "$common_stop_calls" \
    'the installer must not touch the data plane while health automation can still revive it' || return 1
  assert_contains "$log_output" 'warp-vps-health.timer' \
    'an active timer failure must identify the timer' || return 1

  timer_active=1
  health_active=1
  timer_stuck=0
  health_stuck=1
  common_stop_calls=0
  log_output=''
  if stop_project_runtime warp-vps-wg /etc/wireguard/warp-vps-wg.conf >/dev/null; then
    fail 'an active health service after the stop must block a mode switch'
    return 1
  fi
  assert_eq '0' "$common_stop_calls" \
    'the installer must not touch the data plane while the healer is still active' || return 1
  assert_contains "$log_output" 'warp-vps-health.service' \
    'an active healer failure must identify the health service' || return 1

  timer_active=1
  health_active=1
  health_stuck=0
  redsocks_active=1
  redsocks_enabled=0
  redsocks_stop_stuck=1
  log_output=''
  if stop_project_runtime warp-vps-wg /etc/wireguard/warp-vps-wg.conf >/dev/null; then
    fail 'an active old redsocks backend must block a mode switch'
    return 1
  fi
  assert_contains "$log_output" 'warp-vps-redsocks.service' \
    'an active redsocks failure must identify the old backend' || return 1
  assert_contains "$log_output" '仍在运行' \
    'an active redsocks failure must report the active state' || return 1

  timer_active=1
  health_active=1
  redsocks_stop_stuck=0
  redsocks_active=0
  redsocks_enabled=1
  redsocks_disable_stuck=1
  log_output=''
  if stop_project_runtime warp-vps-wg /etc/wireguard/warp-vps-wg.conf >/dev/null; then
    fail 'an enabled old redsocks backend must still block a mode switch'
    return 1
  fi
  assert_contains "$log_output" 'warp-vps-redsocks.service' \
    'an enabled redsocks failure must identify the old backend' || return 1
  assert_contains "$log_output" '仍保持启用' \
    'an enabled redsocks failure must report the enabled state' || return 1

  timer_active=1
  health_active=1
  redsocks_disable_stuck=0
  redsocks_enabled=0
  wg_missing=0
  wg_active=1
  wg_stop_stuck=1
  log_output=''
  if stop_project_runtime warp-vps-wg /etc/wireguard/warp-vps-wg.conf >/dev/null; then
    fail 'an active old WireGuard backend must block a mode switch'
    return 1
  fi
  assert_contains "$log_output" 'wg-quick@warp-vps-wg.service' \
    'an active WireGuard failure must identify the old backend' || return 1

  timer_active=1
  health_active=1
  wg_stop_stuck=0
  wg_active=0
  wg_enabled=1
  wg_disable_stuck=1
  log_output=''
  if stop_project_runtime warp-vps-wg /etc/wireguard/warp-vps-wg.conf >/dev/null; then
    fail 'an enabled old WireGuard backend must block a mode switch'
    return 1
  fi
  assert_contains "$log_output" 'wg-quick@warp-vps-wg.service' \
    'an enabled WireGuard failure must identify the old backend' || return 1
  assert_eq '0' "$unexpected_systemctl_calls" \
    'mode-switch regression must model every systemctl operation'
}

test_main_executes_bidirectional_mode_switches() {
  source_without_main "$INSTALL_SCRIPT"
  local target_mode previous_mode unlock_rc events backend_reusable prepare_calls udp_probe_log
  target_mode=wireguard
  previous_mode=socks
  unlock_rc=124
  events=''
  backend_reusable=0
  prepare_calls=0
  udp_probe_log="$(mktemp)"
  record_main_event() { events="${events}$1"$'\n'; }
  INSTALL_NONINTERACTIVE=1
  INSTALL_MODE_OPTION="$target_mode"
  INSTALL_SWAP_OPTION=none
  INSTALL_SOCKS_PORT_OPTION=''
  unset WARP_SOCKS_PORT || true

  require_root() { :; }
  require_systemd() { :; }
  validate_repo_raw_base() { :; }
  acquire_operation_lock() { record_main_event 'lock:acquire'; }
  release_operation_lock() { record_main_event 'lock:release'; }
  read_input() { fail 'the noninteractive main transaction must not read input'; }
  prompt_install_mode() { fail 'the noninteractive main transaction must not prompt for a mode'; }
  probe_outbound_udp() { printf 'probe\n' >> "$udp_probe_log"; return 1; }
  collect_swap_choice() { :; }
  read_project_warp_port() {
    [ "$previous_mode" = socks ] || return 1
    printf '24000\n'
  }
  read_project_redsocks_port() {
    [ "$previous_mode" = socks ] || return 1
    printf '24001\n'
  }
  prompt_warp_port() { fail 'the noninteractive main transaction must not prompt for a port'; }
  find_free_port() {
    if [ -n "${1:-}" ]; then printf '25001\n'; else printf '25000\n'; fi
  }
  port_in_use() { return 1; }
  capture_service_ownership() { :; }
  read_previous_wireguard_runtime() {
    PREVIOUS_MODE="$previous_mode"
    PREVIOUS_WG_IFACE=warp-vps-wg
    PREVIOUS_WG_CONFIG=/etc/wireguard/warp-vps-wg.conf
  }
  stage_project_files() { :; }
  validate_existing_config() { :; }
  backup_project_files() { :; }
  stop_project_runtime() { record_main_event "stop:${PREVIOUS_MODE}"; }
  activate_project_files() { :; }
  write_config_file() { record_main_event "target-config:$2"; }
  write_config() { record_main_event "config:$1"; }
  apply_swap_choice() { :; }
  install_dependencies() { record_main_event "deps:$1"; }
  disable_new_packaged_redsocks_service() { :; }
  preflight_nft_nat() { :; }
  ensure_redsocks_user() { :; }
  redsocks_path() { printf '/usr/sbin/redsocks\n'; }
  mark_managed_redsocks_if_current() { :; }
  current_backend_reusable() { [ "$backend_reusable" -eq 1 ]; }
  quiesce_health_automation() {
    record_main_event 'health:quiesce'
    HEALTH_AUTOMATION_PAUSED=1
  }
  prepare_target_backend() {
    prepare_calls=$((prepare_calls + 1))
    [ "$INSTALL_BACKEND_REUSED" -eq 0 ] || return 0
    if [ "$1" = wireguard ]; then
      if [ "$TARGET_CONFIG_PREPARED" -eq 0 ]; then
        record_main_event 'manager:setup-wireguard'
        TARGET_CONFIG_PREPARED=1
      fi
      [ "$INSTALL_RUNTIME_TOUCHED" -eq 1 ] || return 0
      record_main_event 'manager:preflight-wireguard'
      TARGET_BACKEND_PREPARED=1
    else
      record_main_event 'manager:configure-warp'
      TARGET_BACKEND_PREPARED=1
    fi
  }
  pause_project_routing() { record_main_event "pause:${PREVIOUS_MODE}"; INSTALL_RUNTIME_TOUCHED=1; }
  id() {
    case "$1" in
      -u) printf '991\n' ;;
      -gn) printf 'root\n' ;;
      *) return 1 ;;
    esac
  }
  manager_mock() {
    record_main_event "manager:$1"
    [ "$1" != unlock-check ] || return "$unlock_rc"
  }
  BIN_PATH=manager_mock
  systemctl() { record_main_event "systemctl:$*"; }
  enable_project_unit() { record_main_event "enable:$1"; }
  enable_health_timer() { :; }
  run_final_self_check() { record_main_event 'self-check'; }
  log() { :; }

  if ! main >/dev/null; then
    fail 'Socks-to-WireGuard switching must stay successful when automatic unlock times out'
    return 1
  fi
  assert_contains "$events" 'stop:socks' \
    'Socks-to-WireGuard must stop the previous Socks runtime' || return 1
  assert_contains "$events" 'config:wireguard' \
    'Socks-to-WireGuard must write the WireGuard target mode' || return 1
  assert_contains "$events" 'deps:wireguard' \
    'Socks-to-WireGuard must install WireGuard dependencies' || return 1
  assert_contains "$events" 'manager:setup-wireguard' \
    'Socks-to-WireGuard must prepare the WireGuard config' || return 1
  assert_contains "$events" 'manager:preflight-wireguard' \
    'Socks-to-WireGuard must run the local WireGuard preflight' || return 1
  local stop_socks_line preflight_line
  stop_socks_line="$(line_number "$events" 'stop:socks')"
  preflight_line="$(line_number "$events" 'manager:preflight-wireguard')"
  if [ -z "$stop_socks_line" ] || [ -z "$preflight_line" ] \
    || [ "$stop_socks_line" -ge "$preflight_line" ]; then
    fail 'WireGuard route preflight must wait until stale Socks routing is stopped'
    return 1
  fi
  assert_contains "$events" 'enable:wg-quick@warp-vps-wg.service' \
    'Socks-to-WireGuard must enable the WireGuard target unit' || return 1
  assert_not_contains "$events" 'manager:configure-warp' \
    'Socks-to-WireGuard must not configure the Socks target' || return 1
  assert_contains "$events" 'lock:acquire' \
    'the installer must serialize the transition before inspecting live ownership' || return 1
  assert_contains "$events" 'lock:release' \
    'a successful install must release its operation lock before the nonblocking unlock check' || return 1
  assert_eq '1' "$(grep -o 'stop:' <<< "$events" | wc -l | tr -d ' ')" \
    'a timed-out post-success unlock check must not trigger installation cleanup' || return 1

  target_mode=socks
  INSTALL_MODE_OPTION="$target_mode"
  previous_mode=wireguard
  unlock_rc=1
  events=''
  INSTALL_COMPLETE=0
  INSTALL_CLEANUP_ARMED=0
  INSTALL_BACKEND_REUSED=0
  INSTALL_RUNTIME_TOUCHED=0
  INSTALL_FILES_ACTIVATED=0
  TARGET_BACKEND_PREPARED=0
  TARGET_CONFIG_PREPARED=0
  TARGET_PREP_STARTED=0
  HEALTH_AUTOMATION_PAUSED=0
  PREVIOUS_HEALTH_TIMER_ACTIVE=0
  if ! main >/dev/null; then
    fail 'WireGuard-to-Socks switching must stay successful when automatic unlock cannot confirm'
    return 1
  fi
  assert_contains "$events" 'stop:wireguard' \
    'WireGuard-to-Socks must stop the previous WireGuard runtime' || return 1
  assert_contains "$events" 'config:socks' \
    'WireGuard-to-Socks must write the Socks target mode' || return 1
  assert_contains "$events" 'deps:socks' \
    'WireGuard-to-Socks must install Socks dependencies' || return 1
  assert_contains "$events" 'manager:configure-warp' \
    'WireGuard-to-Socks must configure the Socks target' || return 1
  assert_contains "$events" 'enable:warp-vps-redsocks.service' \
    'WireGuard-to-Socks must enable the redsocks target unit' || return 1
  assert_not_contains "$events" 'manager:setup-wireguard' \
    'WireGuard-to-Socks must not prepare the WireGuard target' || return 1
  assert_eq '1' "$(grep -o 'stop:' <<< "$events" | wc -l | tr -d ' ')" \
    'a failed post-success unlock check must not trigger installation cleanup' || return 1

  target_mode=wireguard
  INSTALL_MODE_OPTION="$target_mode"
  previous_mode=wireguard
  backend_reusable=1
  prepare_calls=0
  events=''
  INSTALL_COMPLETE=0
  INSTALL_CLEANUP_ARMED=0
  INSTALL_BACKEND_REUSED=0
  INSTALL_RUNTIME_TOUCHED=0
  INSTALL_FILES_ACTIVATED=0
  TARGET_BACKEND_PREPARED=0
  TARGET_CONFIG_PREPARED=0
  TARGET_PREP_STARTED=0
  HEALTH_AUTOMATION_PAUSED=0
  PREVIOUS_HEALTH_TIMER_ACTIVE=0
  if ! main >/dev/null; then
    fail 'a healthy same-mode WireGuard reinstall should reload local files in place'
    return 1
  fi
  assert_contains "$events" 'pause:wireguard' \
    'same-mode reinstall should pause only routing rules' || return 1
  assert_not_contains "$events" 'stop:wireguard' \
    'same-mode reinstall must not stop the healthy WireGuard backend' || return 1
  assert_not_contains "$events" 'manager:preflight-wireguard' \
    'same-mode reinstall should defer endpoint reselection to route-service startup' || return 1
  assert_eq '1' "$prepare_calls" \
    'main should pass through the target preparation gate exactly once' || return 1

  target_mode=socks
  INSTALL_MODE_OPTION="$target_mode"
  previous_mode=socks
  backend_reusable=1
  prepare_calls=0
  events=''
  read_project_warp_port() { printf '24000\n'; }
  read_project_redsocks_port() { printf '24001\n'; }
  INSTALL_COMPLETE=0
  INSTALL_CLEANUP_ARMED=0
  INSTALL_BACKEND_REUSED=0
  INSTALL_RUNTIME_TOUCHED=0
  INSTALL_FILES_ACTIVATED=0
  TARGET_BACKEND_PREPARED=0
  TARGET_CONFIG_PREPARED=0
  TARGET_PREP_STARTED=0
  HEALTH_AUTOMATION_PAUSED=0
  PREVIOUS_HEALTH_TIMER_ACTIVE=0
  if ! main >/dev/null; then
    fail 'a healthy same-mode Socks reinstall should reuse warp-svc and reload project redsocks'
    return 1
  fi
  assert_contains "$events" 'pause:socks' \
    'same-mode Socks reinstall should pause only project routing' || return 1
  assert_contains "$events" 'systemctl:restart warp-vps-redsocks.service' \
    'same-mode Socks reinstall must reload the newly activated redsocks unit and config' || return 1
  assert_not_contains "$events" 'manager:configure-warp' \
    'same-mode Socks reuse must not reconnect or re-register warp-svc' || return 1
  assert_eq '' "$(< "$udp_probe_log")" \
    'noninteractive main transactions must not run the interactive UDP probe'
}

test_reinstall_mode_switch_uses_the_main_install_path() {
  local body prepare_body stop_line config_line deps_line rules_line prepare_line
  body="$(function_body "$INSTALL_SCRIPT" main)"
  prepare_body="$(function_body "$INSTALL_SCRIPT" prepare_target_backend)"
  stop_line="$(line_number "$body" 'stop_project_runtime "$PREVIOUS_WG_IFACE"')"
  config_line="$(line_number "$body" 'write_config "$selected_mode"')"
  deps_line="$(line_number "$body" 'install_dependencies "$selected_mode"')"
  rules_line="$(line_number "$body" 'validate_staged_rules "$PROJECT_STAGE_DIR"')"
  prepare_line="$(line_number "$body" 'prepare_target_backend "$selected_mode"')"
  for name in stop_line config_line deps_line rules_line prepare_line; do
    [ -n "${!name}" ] || {
      fail "mode-switch step is missing from the installer: $name"
      return 1
    }
  done
  if [ "$deps_line" -ge "$rules_line" ] || [ "$rules_line" -ge "$prepare_line" ] \
    || [ "$prepare_line" -ge "$stop_line" ] \
    || [ "$stop_line" -ge "$config_line" ]; then
    fail 'target dependencies and backend must prepare before the old mode stops, then live config may activate'
    return 1
  fi
  assert_contains "$prepare_body" 'setup-wireguard' \
    'WireGuard target preparation must use the staged manager' || return 1
  assert_contains "$prepare_body" 'preflight-wireguard' \
    'WireGuard target preparation must create and locally validate the interface' || return 1
  assert_contains "$prepare_body" 'configure-warp' \
    'Socks target preparation must happen before an opposite backend is stopped' || return 1
  assert_file_matches "$README_FILE" 'warp-vps reinstall --scope (global|google)` \| 保持运行模式' \
    'README should document the safe reinstall default' || return 1
  assert_file_matches "$README_FILE" 'warp-vps switch wireguard` \| 切换到 WireGuard' \
    'README should document the supported Socks-to-WireGuard switch' || return 1
  assert_file_matches "$README_FILE" 'warp-vps switch socks.*` \| 切换到 Socks5' \
    'README should document the supported reverse switch'
}

test_reinstall_reuses_healthy_backends_without_external_setup() {
  source_without_main "$INSTALL_SCRIPT"
  local staged_calls=0
  PREVIOUS_MODE=wireguard
  PREVIOUS_WG_IFACE=warp-vps-wg
  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = ip ]; then return 0; fi
    builtin command "$@"
  }
  project_unit_active() { return 0; }
  project_wg_interface_present() { return 0; }
  wg() { [ "$*" = 'show warp-vps-wg' ]; }
  target_wireguard_config_valid() { return 0; }
  current_backend_reusable wireguard 0 '' || {
    fail 'an active same-mode WireGuard interface should be reusable'
    return 1
  }
  INSTALL_BACKEND_REUSED=1
  prepare_target_backend wireguard || return 1
  assert_eq '0' "$staged_calls" \
    'healthy WireGuard reuse must skip wgcf and wg-quick preflight' || return 1

  PREVIOUS_MODE=socks
  current_socks_backend_local_ready() { return 0; }
  current_backend_reusable socks 24000 24000 || {
    fail 'an existing same-port WARP SOCKS listener should be reusable'
    return 1
  }
  current_socks_backend_local_ready() { return 1; }
  if current_backend_reusable socks 24000 24000; then
    fail 'an owned but protocol-invalid WARP SOCKS listener must enter the repair path'
    return 1
  fi
  if current_backend_reusable socks 25000 24000; then
    fail 'a requested SOCKS port change must not be mistaken for backend reuse'
    return 1
  fi
}

test_wireguard_reuse_requires_real_kernel_device() {
  source_without_main "$INSTALL_SCRIPT"
  local config_validation_calls=0
  PREVIOUS_MODE=wireguard
  PREVIOUS_WG_IFACE=warp-vps-wg
  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = ip ]; then return 0; fi
    builtin command "$@"
  }
  project_unit_active() { return 0; }
  project_wg_interface_present() { return 0; }
  wg() {
    [ "$*" = 'show warp-vps-wg' ] || return 2
    return 1
  }
  target_wireguard_config_valid() {
    config_validation_calls=$((config_validation_calls + 1))
    return 0
  }

  if current_backend_reusable wireguard 0 ''; then
    fail 'an active wg-quick unit and same-name IP link must not prove a reusable WireGuard device'
    return 1
  fi
  assert_eq '0' "$config_validation_calls" \
    'kernel WireGuard identity must be confirmed before validating reuse of its disk config'
}

test_wireguard_target_preflight_waits_for_old_socks_teardown() {
  source_without_main "$INSTALL_SCRIPT"
  local root event_log events setup_line preflight_line
  root="$(mktemp -d)"
  event_log="$root/events"
  PROJECT_STAGE_DIR="$root/stage"
  TARGET_CONFIG_FILE="$PROJECT_STAGE_DIR/config.env"
  mkdir -p "$PROJECT_STAGE_DIR/bin" "$PROJECT_STAGE_DIR/rules"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\\n" "$1" >> "$WARP_TEST_EVENT_LOG"' \
    > "$PROJECT_STAGE_DIR/bin/warp-vps"
  chmod 0755 "$PROJECT_STAGE_DIR/bin/warp-vps"
  : > "$event_log"
  export WARP_TEST_EVENT_LOG="$event_log"
  PREVIOUS_MODE=socks
  INSTALL_BACKEND_REUSED=0
  INSTALL_RUNTIME_TOUCHED=0
  TARGET_CONFIG_PREPARED=0
  TARGET_BACKEND_PREPARED=0

  prepare_target_backend wireguard || {
    fail 'WireGuard target setup should prepare local config while old Socks remains live'
    return 1
  }
  events="$(< "$event_log")"
  assert_contains "$events" 'setup-wireguard' \
    'the pre-transition phase must prepare WireGuard config' || return 1
  assert_not_contains "$events" 'preflight-wireguard' \
    'WireGuard route preflight must not run while old Socks routing is live' || return 1
  assert_eq '1' "$TARGET_CONFIG_PREPARED" \
    'the prepared WireGuard config should be remembered across the transition' || return 1
  assert_eq '0' "$TARGET_BACKEND_PREPARED" \
    'config generation alone must not mark route preflight complete' || return 1

  INSTALL_RUNTIME_TOUCHED=1
  prepare_target_backend wireguard || {
    fail 'WireGuard route preflight should run after old Socks teardown'
    return 1
  }
  events="$(< "$event_log")"
  setup_line="$(line_number "$events" 'setup-wireguard')"
  preflight_line="$(line_number "$events" 'preflight-wireguard')"
  if [ -z "$setup_line" ] || [ -z "$preflight_line" ] || [ "$setup_line" -ge "$preflight_line" ]; then
    fail 'WireGuard setup must precede its post-teardown route preflight'
    return 1
  fi
  assert_eq '1' "$(grep -c '^setup-wireguard$' "$event_log")" \
    'post-teardown preflight must reuse the already generated WireGuard config' || return 1
  assert_eq '1' "$TARGET_BACKEND_PREPARED" \
    'successful post-teardown preflight should mark the target ready'
}

test_active_wireguard_invalid_config_keeps_live_backend() {
  source_without_main "$INSTALL_SCRIPT"
  PREVIOUS_MODE=wireguard
  PREVIOUS_WG_IFACE=warp-vps-wg
  command() {
    if [ "${1:-}" = '-v' ] && [ "${2:-}" = ip ]; then return 0; fi
    builtin command "$@"
  }
  project_unit_active() { return 0; }
  project_wg_interface_present() { return 0; }
  wg() { [ "$*" = 'show warp-vps-wg' ]; }
  target_wireguard_config_valid() { return 1; }

  local output rc=0 main_body reusable_line quiesce_line stop_line
  output="$({ current_backend_reusable wireguard 0 ''; printf 'EVENT:teardown\n'; } 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'an invalid on-disk config for an active WireGuard backend must reject reinstall'
    return 1
  }
  assert_contains "$output" '保持当前流量不变' \
    'the operator should be told that the active backend was preserved' || return 1
  assert_not_contains "$output" 'EVENT:teardown' \
    'invalid active WireGuard config must fail before any teardown' || return 1

  main_body="$(function_body "$INSTALL_SCRIPT" main)"
  reusable_line="$(line_number "$main_body" 'current_backend_reusable')"
  quiesce_line="$(line_number "$main_body" 'quiesce_health_automation')"
  stop_line="$(line_number "$main_body" 'stop_project_runtime')"
  if [ -z "$reusable_line" ] || [ -z "$quiesce_line" ] || [ -z "$stop_line" ] \
    || [ "$reusable_line" -ge "$quiesce_line" ] || [ "$reusable_line" -ge "$stop_line" ]; then
    fail 'active WireGuard config validation must precede every live-runtime transition'
    return 1
  fi
}

test_wireguard_reuse_probe_unknown_falls_through_to_teardown() {
  source_without_main "$INSTALL_SCRIPT"
  local die_calls=0
  PREVIOUS_MODE=wireguard
  PREVIOUS_WG_IFACE=warp-vps-wg
  project_unit_active() { return 2; }
  project_wg_interface_present() { return 2; }
  die() { die_calls=$((die_calls + 1)); return 1; }

  if current_backend_reusable wireguard 0 ''; then
    fail 'an unreadable WireGuard reuse probe must not claim the backend is reusable'
    return 1
  fi
  assert_eq '0' "$die_calls" \
    'reuse-probe uncertainty should fall through to the real teardown boundary instead of blocking early'
}

test_wireguard_prepared_target_cleanup_removes_real_interface() {
  source_without_main "$INSTALL_SCRIPT"
  local events='' interface_present=1
  TARGET_MODE=wireguard
  TARGET_PREP_STARTED=1
  INSTALL_RUNTIME_TOUCHED=1
  PROJECT_STAGE_DIR=/staged-target-does-not-exist
  TARGET_CONFIG_FILE=/staged-target-does-not-exist/config.env
  WG_IFACE=warp-vps-wg
  WG_CONFIG=/etc/wireguard/warp-vps-wg.conf

  systemctl() {
    events="${events}systemctl:$*"$'\n'
    return 0
  }
  project_wg_interface_present() {
    [ "$interface_present" -eq 1 ]
  }
  wg-quick() {
    events="${events}wg-quick:$*"$'\n'
    return 1
  }
  ip() {
    events="${events}ip:$*"$'\n'
    if [ "$*" = 'link delete dev warp-vps-wg' ]; then
      interface_present=0
    fi
    return 0
  }

  cleanup_prepared_target wireguard || {
    fail 'prepared-target cleanup should delete a WireGuard interface that is still present'
    return 1
  }
  assert_contains "$events" 'wg-quick:down /etc/wireguard/warp-vps-wg.conf' \
    'WireGuard cleanup should first use the configured wg-quick identity' || return 1
  assert_contains "$events" 'ip:link delete dev warp-vps-wg' \
    'WireGuard cleanup should fall back to deleting a still-present kernel interface' || return 1
  assert_eq '0' "$interface_present" \
    'successful prepared-target cleanup must leave the project interface absent' || return 1

  events=''
  interface_present=1
  ip() {
    events="${events}ip:$*"$'\n'
    return 0
  }
  if cleanup_prepared_target wireguard; then
    fail 'prepared-target cleanup must fail when the WireGuard interface remains present'
    return 1
  fi
  assert_contains "$events" 'ip:link delete dev warp-vps-wg' \
    'the persistent-interface fixture must reach the real delete boundary'
}

test_runtime_restore_avoids_duplicate_cleanup_and_always_restores_health() {
  source_without_main "$INSTALL_SCRIPT"
  local events=''
  TARGET_MODE=wireguard
  TARGET_PREP_STARTED=1
  INSTALL_RUNTIME_TOUCHED=1
  INSTALL_FILES_ACTIVATED=1
  INSTALL_BACKEND_REUSED=0
  PROJECT_BACKUP_DIR=/rollback-fixture-does-not-exist
  WG_IFACE=warp-vps-wg
  WG_CONFIG=/etc/wireguard/warp-vps-wg.conf

  stop_project_runtime() {
    events="${events}stop-project-runtime"$'\n'
    return 0
  }
  cleanup_prepared_target() {
    events="${events}duplicate-target-cleanup"$'\n'
    return 0
  }
  restore_project_files() {
    events="${events}restore-project-files"$'\n'
    return 0
  }
  restore_health_automation() {
    events="${events}restore-health"$'\n'
    return 0
  }
  systemctl() { return 0; }

  restore_previous_runtime || {
    fail 'a successful activated-file rollback should restore the previous runtime'
    return 1
  }
  assert_contains "$events" 'stop-project-runtime' \
    'activated target runtime must be stopped before old files are restored' || return 1
  assert_not_contains "$events" 'duplicate-target-cleanup' \
    'the same target runtime must not be cleaned twice after stop_project_runtime succeeds' || return 1
  assert_contains "$events" 'restore-health' \
    'activated-file rollback without an old config must restore health automation' || return 1

  events=''
  INSTALL_RUNTIME_TOUCHED=0
  INSTALL_FILES_ACTIVATED=0
  cleanup_prepared_target() { return 0; }
  restore_prepared_target_files() {
    events="${events}restore-prepared-files-failed"$'\n'
    return 1
  }
  if restore_previous_runtime; then
    fail 'a prepared-file restore failure must remain visible to rollback'
    return 1
  fi
  assert_contains "$events" 'restore-prepared-files-failed' \
    'the failure fixture must reach prepared-file restoration' || return 1
  assert_contains "$events" 'restore-health' \
    'health automation must still be restored when prepared-file restoration fails'
}

test_untouched_wireguard_preparation_restores_files_without_runtime_cleanup() {
  source_without_main "$INSTALL_SCRIPT"
  local events=''
  TARGET_MODE=wireguard
  TARGET_PREP_STARTED=1
  INSTALL_RUNTIME_TOUCHED=0
  INSTALL_FILES_ACTIVATED=0
  PROJECT_STAGE_DIR=/staged-but-not-live

  systemctl() {
    events="${events}runtime-systemctl:$*"$'\n'
    return 1
  }
  project_wg_interface_present() {
    events="${events}runtime-interface-probe"$'\n'
    return 2
  }
  restore_prepared_target_files() {
    events="${events}restore-prepared-files"$'\n'
  }
  restore_health_automation() {
    events="${events}restore-health"$'\n'
  }

  restore_previous_runtime || {
    fail 'a WireGuard setup failure before runtime mutation must preserve the old runtime'
    return 1
  }
  assert_contains "$events" 'restore-prepared-files' \
    'pre-runtime WireGuard artifacts must still be restored' || return 1
  assert_contains "$events" 'restore-health' \
    'the paused health timer must be restored after target preparation fails' || return 1
  assert_not_contains "$events" 'runtime-systemctl:' \
    'pre-runtime WireGuard failure must not stop a target service that never started' || return 1
  assert_not_contains "$events" 'runtime-interface-probe' \
    'pre-runtime WireGuard failure must not probe an interface that was never created'
}

test_touched_wireguard_rollback_still_runs_runtime_cleanup() {
  source_without_main "$INSTALL_SCRIPT"
  local events=''
  TARGET_MODE=wireguard
  TARGET_PREP_STARTED=1
  INSTALL_RUNTIME_TOUCHED=1
  INSTALL_FILES_ACTIVATED=0
  PROJECT_BACKUP_DIR=/rollback-fixture-does-not-exist

  cleanup_prepared_target() {
    events="${events}cleanup-target-runtime"$'\n'
    return 1
  }
  restore_project_files() {
    events="${events}restore-project-files"$'\n'
  }
  systemctl() {
    events="${events}systemctl:$*"$'\n'
  }
  restore_health_automation() {
    events="${events}restore-health"$'\n'
  }

  if restore_previous_runtime; then
    fail 'a real target-runtime cleanup failure must remain visible to rollback'
    return 1
  fi
  assert_contains "$events" 'cleanup-target-runtime' \
    'rollback must clean WireGuard runtime after the transition touched it' || return 1
  assert_contains "$events" 'restore-project-files' \
    'runtime rollback must still restore the previous project files' || return 1
  assert_contains "$events" 'systemctl:daemon-reload' \
    'runtime rollback must reload the restored service files'
}

test_target_preparation_failure_keeps_old_runtime_running() {
  source_without_main "$INSTALL_SCRIPT"
  require_root() { :; }
  require_systemd() { :; }
  validate_repo_raw_base() { :; }
  acquire_operation_lock() { :; }
  release_operation_lock() { :; }
  prompt_install_mode() { printf 'wireguard\n'; }
  collect_swap_choice() { :; }
  capture_service_ownership() { :; }
  read_previous_wireguard_runtime() {
    PREVIOUS_MODE=socks
    PREVIOUS_WG_IFACE=warp-vps-wg
    PREVIOUS_WG_CONFIG=/etc/wireguard/warp-vps-wg.conf
  }
  stage_project_files() { PROJECT_STAGE_DIR=/staged; }
  backup_project_files() { PROJECT_BACKUP_DIR=/rollback; }
  apply_swap_choice() { :; }
  install_dependencies() { :; }
  validate_staged_rules() { :; }
  write_config_file() { :; }
  current_backend_reusable() { return 1; }
  quiesce_health_automation() {
    printf 'EVENT:health-quiesced\n'
    HEALTH_AUTOMATION_PAUSED=1
  }
  prepare_target_backend() { printf 'EVENT:prepare-failed\n'; return 1; }
  restore_previous_runtime() { printf 'EVENT:restore-old\n'; }
  pause_project_routing() { printf 'EVENT:pause-old\n'; }
  stop_project_runtime() { printf 'EVENT:stop-old\n'; }
  activate_project_files() { printf 'EVENT:activate-live\n'; }

  local output rc=0
  output="$(main 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'failed target preparation must fail the requested switch'
    return 1
  }
  assert_contains "$output" 'EVENT:prepare-failed' \
    'the failure scenario must reach target preparation' || return 1
  assert_contains "$output" 'EVENT:restore-old' \
    'the armed trap must restore pre-transition health automation' || return 1
  assert_contains "$output" '旧模式未停止' \
    'the installer should tell the operator that the old runtime stayed up' || return 1
  assert_not_contains "$output" 'EVENT:stop-old' \
    'a target preparation failure must not stop the old backend' || return 1
  assert_not_contains "$output" 'EVENT:pause-old' \
    'a target preparation failure must not pause old routing rules' || return 1
  assert_not_contains "$output" 'EVENT:activate-live' \
    'a target preparation failure must not replace live project files'
}

test_service_activation_failure_invokes_old_runtime_restore() {
  source_without_main "$INSTALL_SCRIPT"
  require_root() { :; }
  require_systemd() { :; }
  validate_repo_raw_base() { :; }
  acquire_operation_lock() { :; }
  release_operation_lock() { :; }
  prompt_install_mode() { printf 'wireguard\n'; }
  collect_swap_choice() { :; }
  capture_service_ownership() { :; }
  read_previous_wireguard_runtime() {
    PREVIOUS_MODE=socks
    PREVIOUS_WG_IFACE=warp-vps-wg
    PREVIOUS_WG_CONFIG=/etc/wireguard/warp-vps-wg.conf
  }
  stage_project_files() { PROJECT_STAGE_DIR=/staged; }
  backup_project_files() { PROJECT_BACKUP_DIR=/rollback; }
  apply_swap_choice() { :; }
  install_dependencies() { :; }
  validate_staged_rules() { :; }
  write_config_file() { :; }
  write_config() { :; }
  current_backend_reusable() { return 1; }
  quiesce_health_automation() { HEALTH_AUTOMATION_PAUSED=1; }
  prepare_target_backend() { TARGET_BACKEND_PREPARED=1; printf 'EVENT:prepared\n'; }
  stop_project_runtime() { printf 'EVENT:stop-old\n'; }
  activate_project_files() { printf 'EVENT:activate-live\n'; }
  manager_mock() { [ "$1" = install-systemd ]; }
  BIN_PATH=manager_mock
  systemctl() { :; }
  enable_project_unit() {
    if [ "$1" = warp-vps.service ]; then
      die "EVENT:routing-service-start-failed"
    fi
  }
  enable_health_timer() { :; }
  run_final_self_check() { printf 'UNEXPECTED:final-status-gate\n'; return 1; }
  restore_previous_runtime() { printf 'EVENT:restore-old\n'; }

  local output rc=0
  output="$(main 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'a routing service start failure must fail the new installation'
    return 1
  }
  assert_contains "$output" 'EVENT:stop-old' 'the scenario must enter the transition' || return 1
  assert_contains "$output" 'EVENT:activate-live' 'the scenario must activate target files' || return 1
  assert_contains "$output" 'EVENT:routing-service-start-failed' \
    'the scenario must fail on the actual systemd start action' || return 1
  assert_contains "$output" 'EVENT:restore-old' \
    'the armed failure trap must restore the previous runtime after a service start failure' \
    || return 1
  assert_not_contains "$output" 'UNEXPECTED:final-status-gate' \
    'a real service start failure must stop before any diagnostic final gate' || return 1
  assert_contains "$output" '已恢复安装前的项目运行态' \
    'successful rollback should be reported explicitly'
}

test_partial_activation_failure_invokes_old_runtime_restore() {
  source_without_main "$INSTALL_SCRIPT"
  require_root() { :; }
  require_systemd() { :; }
  validate_repo_raw_base() { :; }
  acquire_operation_lock() { :; }
  release_operation_lock() { :; }
  prompt_install_mode() { printf 'wireguard\n'; }
  collect_swap_choice() { :; }
  capture_service_ownership() { :; }
  read_previous_wireguard_runtime() {
    PREVIOUS_MODE=socks
    PREVIOUS_WG_IFACE=warp-vps-wg
    PREVIOUS_WG_CONFIG=/etc/wireguard/warp-vps-wg.conf
  }
  stage_project_files() { PROJECT_STAGE_DIR=/staged; }
  backup_project_files() { PROJECT_BACKUP_DIR=/rollback; }
  apply_swap_choice() { :; }
  install_dependencies() { :; }
  validate_staged_rules() { :; }
  write_config_file() { :; }
  current_backend_reusable() { return 1; }
  quiesce_health_automation() { HEALTH_AUTOMATION_PAUSED=1; }
  prepare_target_backend() { TARGET_BACKEND_PREPARED=1; printf 'EVENT:prepared\n'; }
  stop_project_runtime() { printf 'EVENT:stop-old\n'; }
  activate_project_files() { printf 'EVENT:partial-activate\n'; return 1; }
  restore_previous_runtime() { printf 'EVENT:restore-old\n'; }
  manager_mock() { printf 'EVENT:manager:%s\n' "$1"; }
  BIN_PATH=manager_mock

  local output rc=0
  output="$(main 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'a partial file activation failure must fail installation'
    return 1
  }
  assert_contains "$output" 'EVENT:stop-old' \
    'the scenario must cross the protected runtime transition' || return 1
  assert_contains "$output" 'EVENT:partial-activate' \
    'the scenario must reach partial target activation' || return 1
  assert_contains "$output" 'EVENT:restore-old' \
    'partial activation must invoke the previous-runtime rollback' || return 1
  assert_not_contains "$output" 'EVENT:manager:install-systemd' \
    'service activation must not continue after target file activation fails'
}

test_reused_socks_post_restart_failure_restores_old_redsocks() {
  source_without_main "$INSTALL_SCRIPT"
  local root event_log output events rc=0
  local rollback_phase=0
  root="$(mktemp -d)"
  event_log="$root/events"
  : > "$event_log"
  PROJECT_STAGE_DIR="$root/stage"
  PROJECT_BACKUP_DIR="$root/rollback"
  CONFIG_FILE="$root/config.env"
  mkdir -p "$PROJECT_STAGE_DIR" "$PROJECT_BACKUP_DIR"
  printf 'WARP_MODE=socks\nWARP_SOCKS_PORT=24000\nREDSOCKS_PORT=24001\n' > "$CONFIG_FILE"
  printf 'old-config\n' > "$PROJECT_BACKUP_DIR/config.env"

  record_event() { printf '%s\n' "$1" >> "$event_log"; }
  require_root() { :; }
  require_systemd() { :; }
  validate_repo_raw_base() { :; }
  read_project_mode() { printf 'socks\n'; }
  prompt_install_mode() { printf 'socks\n'; }
  collect_swap_choice() { :; }
  read_project_warp_port() { printf '24000\n'; }
  read_project_redsocks_port() { printf '24001\n'; }
  prompt_warp_port() { printf '24000\n'; }
  acquire_operation_lock() { :; }
  release_operation_lock() { :; }
  capture_service_ownership() { :; }
  read_previous_wireguard_runtime() {
    PREVIOUS_MODE=socks
    PREVIOUS_WG_IFACE=warp-vps-wg
    PREVIOUS_WG_CONFIG=/etc/wireguard/warp-vps-wg.conf
  }
  stage_project_files() { :; }
  validate_existing_config() { :; }
  backup_project_files() { :; }
  apply_swap_choice() { :; }
  install_dependencies() { :; }
  validate_staged_rules() { :; }
  disable_new_packaged_redsocks_service() { :; }
  preflight_nft_nat() { :; }
  port_in_use() { return 0; }
  current_socks_backend_owns_port() { return 0; }
  current_redsocks_backend_owns_port() { return 0; }
  ensure_redsocks_user() { :; }
  redsocks_path() { printf '/usr/sbin/redsocks\n'; }
  mark_managed_redsocks_if_current() { :; }
  id() {
    case "$1" in
      -u) printf '991\n' ;;
      -gn) printf 'root\n' ;;
      *) return 1 ;;
    esac
  }
  write_config_file() { :; }
  write_config() { :; }
  current_backend_reusable() { return 0; }
  quiesce_health_automation() {
    HEALTH_AUTOMATION_PAUSED=1
    HEALTH_AUTOMATION_TOUCHED=1
  }
  prepare_target_backend() { :; }
  pause_project_routing() {
    INSTALL_RUNTIME_TOUCHED=1
    record_event 'new:pause-routing'
  }
  activate_project_files() { record_event 'new:activate-files'; }
  manager_mock() {
    if [ "$rollback_phase" -eq 1 ]; then
      record_event "rollback:manager:$1"
    else
      record_event "new:manager:$1"
    fi
    return 0
  }
  BIN_PATH=manager_mock
  systemctl() {
    if [ "$rollback_phase" -eq 1 ]; then
      record_event "rollback:systemctl:$*"
    else
      record_event "new:systemctl:$*"
      if [ "$*" = 'restart warp-vps-redsocks.service' ]; then
        rollback_phase=1
        return 1
      fi
    fi
    return 0
  }
  enable_health_timer() { :; }
  run_final_self_check() {
    record_event 'unexpected:final-status-gate'
    return 1
  }
  project_unit_stopped() { return 0; }
  project_nft_table_absent() { return 0; }
  restore_project_files() { record_event 'rollback:restore-files'; }

  output="$(main 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'a redsocks restart failure must fail the reused Socks reinstall'
    return 1
  }
  events="$(< "$event_log")"
  assert_contains "$events" 'new:systemctl:restart warp-vps-redsocks.service' \
    'the scenario must fail while reloading the new project redsocks unit' || return 1
  assert_contains "$events" 'rollback:systemctl:stop warp-vps-redsocks.service' \
    'rollback must stop the newly reloaded project redsocks unit' || return 1
  assert_not_contains "$events" 'rollback:systemctl:stop warp-svc.service' \
    'rollback must not stop the reused warp-svc backend' || return 1
  assert_contains "$events" 'rollback:systemctl:start warp-vps-redsocks.service' \
    'rollback must start the restored old redsocks unit' || return 1
  assert_not_contains "$events" 'unexpected:final-status-gate' \
    'a real redsocks restart failure must stop before any diagnostic final gate' || return 1

  local stop_line restore_line start_line
  stop_line="$(line_number "$events" 'rollback:systemctl:stop warp-vps-redsocks.service')"
  restore_line="$(line_number "$events" 'rollback:restore-files')"
  start_line="$(line_number "$events" 'rollback:systemctl:start warp-vps-redsocks.service')"
  if [ -z "$stop_line" ] || [ -z "$restore_line" ] || [ -z "$start_line" ] \
    || [ "$stop_line" -ge "$restore_line" ] || [ "$restore_line" -ge "$start_line" ]; then
    fail 'Socks rollback must stop new redsocks, restore old files, then start old redsocks'
    return 1
  fi
  assert_contains "$output" '已恢复安装前的项目运行态' \
    'the post-restart failure should report successful old-runtime restoration'
}

test_reinstall_stops_previous_custom_wireguard_runtime() {
  source_without_main "$INSTALL_SCRIPT"
  CONFIG_FILE="${FIXTURE_DIR}/config/custom-wireguard.env"
  read_previous_wireguard_runtime
  assert_eq 'custom-wg' "$PREVIOUS_WG_IFACE" \
    'reinstall should read the previous project interface' || return 1
  assert_eq '/etc/wireguard/custom-wg.conf' "$PREVIOUS_WG_CONFIG" \
    'reinstall should read the previous project WireGuard path' || return 1

  local systemctl_calls='' wg_calls='' ip_calls='' link_exists=1
  MANAGED_WARP_SVC_VALUE=0
  BIN_PATH=/path/that/does/not/exist
  systemctl() {
    systemctl_calls="${systemctl_calls}$*\n"
    case "$*" in
      'show '*) printf 'LoadState=loaded\nActiveState=inactive\n'; return 0 ;;
      'is-enabled '*) printf 'disabled\n'; return 1 ;;
      *) return 0 ;;
    esac
  }
  wg-quick() {
    wg_calls="${wg_calls}$*\n"
    return 1
  }
  nft() {
    case "$*" in
      'delete table inet warp_vps'|'list tables') return 0 ;;
      *) return 1 ;;
    esac
  }
  ip() {
    ip_calls="${ip_calls}$*\n"
    case "$*" in
      'link show custom-wg') [ "$link_exists" -eq 1 ] ;;
      'link delete dev custom-wg') link_exists=0 ;;
      '-o link show')
        printf '1: lo: <LOOPBACK>\n'
        [ "$link_exists" -eq 0 ] || printf '7: custom-wg: <POINTOPOINT>\n'
        return 0
        ;;
      *) return 1 ;;
    esac
  }

  stop_project_runtime "$PREVIOUS_WG_IFACE" "$PREVIOUS_WG_CONFIG"
  assert_contains "$systemctl_calls" 'wg-quick@custom-wg.service' \
    'reinstall must disable the previous custom WireGuard unit' || return 1
  assert_contains "$wg_calls" 'down /etc/wireguard/custom-wg.conf' \
    'reinstall must stop the previous custom WireGuard config' || return 1
  assert_contains "$ip_calls" 'link delete dev custom-wg' \
    'reinstall must delete a stuck previous custom interface'
}

test_wireguard_uninstall_has_interface_fallback() {
  source_without_main "$MANAGER_SCRIPT"
  local link_exists=1
  local ip_calls=''

  WARP_MODE=wireguard
  WG_IFACE=custom-wg
  WG_CONFIG="${FIXTURE_DIR}/config/custom-wireguard.env"
  wg-quick() { return 1; }
  uninstall_wg_interface_exists() { [ "$link_exists" -eq 1 ]; }
  ip() {
    ip_calls="${ip_calls}$*\n"
    if [ "$1 $2 $3" = 'link delete dev' ]; then
      link_exists=0
    fi
  }
  info_line() { :; }

  ensure_wireguard_down_for_uninstall
  assert_contains "$ip_calls" 'link delete dev custom-wg' \
    'uninstall should delete its dedicated interface when wg-quick cannot'
}

test_wgcf_mips_and_s390x_asset_mapping() {
  source_without_main "$MANAGER_SCRIPT"
  local test_arch=''
  uname() { printf '%s\n' "$test_arch"; }

  test_arch=mips
  assert_eq 'wgcf_2.2.32_linux_mips_softfloat' "$(wgcf_asset_spec)" 'mips wgcf asset' || return 1
  test_arch=mipsel
  assert_eq 'wgcf_2.2.32_linux_mipsle_softfloat' "$(wgcf_asset_spec)" 'mipsel wgcf asset' || return 1
  test_arch=mips64
  assert_eq 'wgcf_2.2.32_linux_mips64_softfloat' "$(wgcf_asset_spec)" 'mips64 wgcf asset' || return 1
  test_arch=mips64el
  assert_eq 'wgcf_2.2.32_linux_mips64le_softfloat' "$(wgcf_asset_spec)" 'mips64el wgcf asset' || return 1
  test_arch=s390x
  assert_eq 'wgcf_2.2.32_linux_s390x' "$(wgcf_asset_spec)" 's390x wgcf asset'
}

test_main_is_the_single_public_update_source() {
  assert_file_matches "$INSTALL_SCRIPT" \
    'DEFAULT_REPO_RAW_BASE="https://raw\.githubusercontent\.com/mqfut123/warp-vps-manager/main"' \
    'installer default source should be main' || return 1
  assert_file_matches "$README_FILE" \
    'raw\.githubusercontent\.com/mqfut123/warp-vps-manager/main/install\.sh' \
    'README install command should use main' || return 1
  assert_file_not_matches "$README_FILE" \
    'raw\.githubusercontent\.com/mqfut123/warp-vps-manager/v[0-9]' \
    'README must not present a tag URL that later installs main'
}

test_logs_follow_custom_wireguard_interface() {
  local body
  body="$(function_body "$MANAGER_SCRIPT" cmd_logs)"
  assert_contains "$body" 'load_uninstall_config' \
    'logs should read the stored interface without requiring a complete config' || return 1
  assert_contains "$body" 'wg-quick@${WG_IFACE}.service' \
    'logs should follow the configured WireGuard unit'
}

test_no_project_version_or_commit_api_gate() {
  assert_file_not_matches "$INSTALL_SCRIPT" 'APP_VERSION' 'installer must not carry a project version gate' || return 1
  local legacy_lines legacy_ignored_lines
  legacy_lines="$(grep -Ec 'APP_VERSION' "$MANAGER_SCRIPT" || true)"
  legacy_ignored_lines="$(grep -Ec '^[[:space:]]*APP_VERSION\) : ;;[[:space:]]*$' "$MANAGER_SCRIPT" || true)"
  assert_eq '1' "$legacy_lines" 'manager should mention APP_VERSION only for legacy config parsing' || return 1
  assert_eq '1' "$legacy_ignored_lines" 'legacy APP_VERSION must be explicitly ignored' || return 1
  assert_file_not_matches "$MANAGER_SCRIPT" 'APP_VERSION=|APP_VERSION="\$value"|\$\{?APP_VERSION' \
    'manager must not write, assign, or use APP_VERSION' || return 1
  assert_file_not_matches "$INSTALL_SCRIPT" 'resolve_github_raw_base|api\.github\.com/repos/.*/commits/' \
    'installer must not require GitHub commit API resolution' || return 1
  assert_file_not_matches "$MANAGER_SCRIPT" 'resolve_github_raw_base|api\.github\.com/repos/.*/commits/' \
    'updates must not require GitHub commit API resolution'
}

test_no_sha_gate() {
  local install_fetch update_fetch wgcf_install
  install_fetch="$(function_body "$INSTALL_SCRIPT" fetch_asset)"
  update_fetch="$(function_body "$MANAGER_SCRIPT" download_update_asset)"
  wgcf_install="$(function_body "$MANAGER_SCRIPT" install_wgcf_binary)"
  assert_not_contains "$install_fetch" 'sha256' \
    'installer project downloads must not be blocked by an embedded project snapshot hash' || return 1
  assert_not_contains "$update_fetch" 'sha256' \
    'project updates must not be blocked by an embedded project snapshot hash' || return 1
  assert_contains "$wgcf_install" 'checksums.txt' \
    'the pinned upstream wgcf binary must use its matching official checksum manifest' || return 1
  assert_contains "$wgcf_install" 'sha256sum' \
    'the pinned upstream wgcf binary must be verified before activation'
}

test_public_install_contract_and_downloads_are_bounded() {
  local install_fetch update_fetch rpm_install
  install_fetch="$(function_body "$INSTALL_SCRIPT" fetch_asset)"
  update_fetch="$(function_body "$MANAGER_SCRIPT" download_update_asset)"
  rpm_install="$(function_body "$INSTALL_SCRIPT" refresh_cloudflare_rpm_repo)"
  assert_contains "$install_fetch" '--connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT"' \
    'installer project downloads must have a connection deadline' || return 1
  assert_contains "$install_fetch" '--max-time "$DOWNLOAD_MAX_TIME"' \
    'installer project downloads must have an overall deadline' || return 1
  assert_contains "$update_fetch" '--connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT"' \
    'update downloads must have a connection deadline' || return 1
  assert_contains "$update_fetch" '--max-time "$DOWNLOAD_MAX_TIME"' \
    'update downloads must have an overall deadline' || return 1
  assert_contains "$rpm_install" '--connect-timeout "$DOWNLOAD_CONNECT_TIMEOUT"' \
    'RPM key and repository downloads must have a connection deadline' || return 1
  assert_contains "$rpm_install" '--max-time "$DOWNLOAD_MAX_TIME"' \
    'RPM key and repository downloads must have an overall deadline' || return 1
  assert_contains "$rpm_install" 'rpm --import "$key_tmp"' \
    'RPM key import must use the completed local download' || return 1
  assert_not_contains "$rpm_install" 'rpm --import https://' \
    'RPM must not perform an unbounded remote key import' || return 1
  assert_file_matches "$README_FILE" \
    '^bash <\(curl -fsSL https://raw\.githubusercontent\.com/mqfut123/warp-vps-manager/main/install\.sh\)$' \
    'README must show the single Bash process-substitution installer' || return 1
  assert_file_not_matches "$README_FILE" 'bash -o pipefail -c|curl[^<]*\|[[:space:]]*bash|bash -s -- --install --non-interactive' \
    'README must not publish pipeline wrappers or additional remote install entries' || return 1
  local public_install_count
  public_install_count="$(
    grep -Ec 'raw\.githubusercontent\.com/mqfut123/warp-vps-manager/main/install\.sh' "$README_FILE"
  )"
  assert_eq '1' "$public_install_count" \
    'README must contain exactly one public remote install command' || return 1
  assert_file_matches "$README_FILE" 'warp-vps switch wireguard' \
    'README must document noninteractive mode switching' || return 1
  assert_file_matches "$README_FILE" 'Google IPv4 UDP/443（QUIC）.*拒绝' \
    'README must document the scoped Google QUIC reject' || return 1
  assert_file_matches "$README_FILE" '其他 Google IPv4 UDP 端口和非 Google 目标 UDP 不受影响' \
    'README must not imply that Socks blocks every UDP packet' || return 1
  assert_file_not_matches "$README_FILE" 'IPv4 UDP( 和 QUIC|/QUIC) 使用 VPS 原生出口' \
    'README must not describe Google QUIC as using the native VPS exit'
}

run_test 'install mode retries after invalid input' test_install_mode_reprompts
run_test 'explicit install mode numbers remain stable' test_install_mode_keeps_explicit_numbers
run_test 'fresh install mode default follows UDP evidence' test_fresh_install_mode_default_follows_udp_probe
run_test 'reinstall keeps the current mode by default' test_reinstall_keeps_current_mode_by_default
run_test 'outbound UDP probe requires a valid STUN response' test_outbound_udp_probe_requires_valid_stun_response
run_test 'route scope prompt defaults to precise Google routing' test_route_scope_prompt_and_defaults
run_test 'route scope config remains backward compatible' test_route_scope_config_is_backward_compatible
run_test 'existing config validation precedes runtime mutation' test_existing_config_validation_precedes_runtime_mutation
run_test 'WireGuard config ignores unused Socks fields' test_wireguard_config_does_not_require_socks_fields
run_test 'SOCKS port retries after a stray backslash' test_warp_port_reprompts
run_test 'reinstall can reuse its current SOCKS port' test_existing_project_port_is_reusable
run_test 'SOCKS port checks ignore UDP-only listeners' test_port_checks_only_tcp
run_test 'noninteractive SOCKS port selection is deterministic' test_noninteractive_socks_port_selection
run_test 'stdin execution works without BASH_SOURCE' test_stdin_execution_without_bash_source
run_test 'installer routes fresh and installed entrypoints' test_installer_entrypoint_routes_fresh_and_installed_hosts
run_test 'installer noninteractive options are strict' test_installer_noninteractive_option_contract
run_test 'installer semantic conflicts stop before side effects' test_installer_rejects_semantic_conflicts_before_side_effects
run_test 'installed-host detection requires command and config' test_project_installation_detection_requires_command_and_config
run_test 'installer noninteractive entry never reads TTY' test_installer_noninteractive_entry_never_reads_tty
run_test 'real no-TTY installer requests return immediately' test_real_no_tty_installer_requests_are_bounded
run_test 'management menu maps public actions and recovers' test_installer_menu_maps_public_actions_and_recovers
run_test 'rollback accepts originally absent files that remain absent' test_restore_helpers_accept_already_absent_new_files
run_test 'terminal menu actions do not run stale code' test_installer_menu_terminal_actions_do_not_run_stale_code
run_test 'manager menu entry preserves explicit CLI dispatch' test_manager_menu_entry_preserves_explicit_cli_dispatch
run_test 'manager noninteractive commands reject bad arguments' test_manager_noninteractive_commands_and_strict_arguments
run_test 'non-TTY no-argument manager invocation is immediate usage' test_manager_no_argument_non_tty_is_immediate_usage
run_test 'menu contract reuses switching and is documented' test_menu_contract_is_documented_without_a_second_switch_path
run_test 'all interactive input precedes installation side effects' test_inputs_precede_side_effects
run_test 'installer operation lock bounds live mutation' test_installer_operation_lock_bounds_live_mutation
run_test 'manager operation lock policies preserve availability and status' test_manager_operation_lock_policies
run_test 'project assets stage before the old runtime stops' test_assets_are_staged_before_runtime_stops
run_test 'staged rules validate before the old runtime stops' test_staged_rules_are_validated_before_runtime_stops
run_test 'failed installation stops only project runtime' test_failed_install_arms_runtime_cleanup
run_test 'installed services are reusable instead of blanket blockers' test_existing_services_are_reusable
run_test 'installer records and respects service ownership' test_installer_captures_service_ownership
run_test 'installer systemd query errors fail closed' test_installer_systemd_query_errors_fail_closed
run_test 'absent optional systemd units do not block mode switches' test_installer_absent_systemd_units_are_not_query_failures
run_test 'systemd state checks support old Key=Value output' test_systemd_state_checks_support_old_key_value_output
run_test 'new packaged redsocks is stopped before WARP installation' test_redsocks_cleanup_precedes_warp_install
run_test 'managed redsocks ownership requires marker and binary evidence' test_managed_redsocks_requires_two_ownership_signals
run_test 'uninstall only stops a managed WARP service' test_managed_warp_service_ownership
run_test 'package manager selection is capability based' test_package_manager_detection_is_capability_based
run_test 'Ubuntu derivatives prefer UBUNTU_CODENAME' test_ubuntu_codename_takes_precedence
run_test 'apt WireGuard dependencies are mode specific' test_apt_wireguard_dependencies_are_minimal
run_test 'existing Cloudflare APT source refreshes before updates' test_existing_cloudflare_apt_repo_refreshes_before_updates
run_test 'RPM WireGuard dependencies are mode specific' test_rpm_wireguard_dependencies_are_minimal
run_test 'RPM existing repo bootstraps refresh tools before WireGuard dependencies' test_rpm_existing_repo_bootstraps_refresh_tools_before_wireguard
run_test 'Socks dependencies are mode specific' test_socks_dependencies_are_mode_specific
run_test 'complete mode dependencies skip package-manager access' test_complete_mode_dependencies_skip_package_manager
run_test 'incomplete dependencies use the current package candidate' test_incomplete_dependencies_use_current_package_candidate
run_test 'WireGuard dependencies exclude Socks-only tools' test_wireguard_dependencies_do_not_require_socks_tools
run_test 'WireGuard dependency reuse requires its systemd template' test_wireguard_dependency_reuse_requires_systemd_template
run_test 'WARP reuse requires both CLI and service unit' test_warp_client_reuse_requires_cli_and_unit
run_test 'RPM redsocks uses the Fedora package or source build path' test_rpm_redsocks_uses_fedora_package_or_source
run_test 'iptables CLI is not an installation dependency' test_no_iptables_package_dependency
run_test 'WireGuard support uses a real runtime preflight' test_wireguard_uses_runtime_capability
run_test 'wgcf fixed release atomically replaces old executables' test_wgcf_fixed_binary_replaces_old_copy_atomically
run_test 'WireGuard generation recovers from partial state' test_wireguard_config_generation_is_retryable
run_test 'WireGuard endpoint candidates preserve hostname config' test_wireguard_endpoint_candidates_preserve_hostname_config
run_test 'WireGuard endpoint selection falls back and requires dual stack' test_wireguard_endpoint_selection_falls_back_and_requires_dual_stack
run_test 'WireGuard endpoint selection requires handshake and receive' test_wireguard_endpoint_selection_requires_handshake_and_receive
run_test 'WireGuard route startup cleans failed data planes' test_start_rules_validates_wireguard_and_cleans_failures
run_test 'WireGuard preflight uses verified route startup' test_wireguard_preflight_uses_start_rules_and_cleans_interface
run_test 'WireGuard route startup is the lifecycle boundary' test_wireguard_start_rules_is_the_lifecycle_boundary
run_test 'WireGuard route failures clean partial state' test_wireguard_route_failures_cleanup
run_test 'WireGuard routes do not require native IPv6' test_wireguard_routes_work_without_native_ipv6
run_test 'WireGuard route cleanup handles each IP family independently' test_wireguard_route_cleanup_is_dual_stack_independent
run_test 'WireGuard strict cleanup verifies actual dual-stack route state' test_wireguard_strict_cleanup_checks_actual_route_state
run_test 'WireGuard runtime avoids route readback gates' test_wireguard_runtime_avoids_route_readbacks
run_test 'WireGuard scope selects precise or global writes' test_wireguard_scope_selects_precise_or_global_writes
run_test 'WireGuard global apply uses owned policy state' test_wireguard_global_apply_uses_owned_policy_state
run_test 'WireGuard global write failures clean partial state' test_wireguard_global_apply_write_failures_cleanup
run_test 'WireGuard global reply mark and stop are symmetric' test_wireguard_global_reply_mark_and_stop_contract
run_test 'WireGuard global enables marked reverse-path checks' test_wireguard_global_src_valid_mark_boundary
run_test 'WireGuard global cleanup ownership is exact' test_wireguard_global_cleanup_ownership_is_exact
run_test 'status reports backend and route scope' test_status_reports_backend_and_route_scope
run_test 'WireGuard global runtime avoids display parsers' test_wireguard_global_runtime_avoids_state_output_parsers
run_test 'Socks nft output blocks only Google QUIC' test_socks_nft_render_blocks_google_quic_only
run_test 'Socks runtime accepts the v0.1.11 rule shape' test_socks_runtime_accepts_v0111_rule_shape
run_test 'Socks global nft redirects public IPv4 TCP' test_socks_global_nft_redirects_public_ipv4_tcp
run_test 'WireGuard apply clears stale Socks nft state' test_wireguard_apply_clears_stale_socks_table
run_test 'mode switches reject a live opposite backend' test_mode_switch_rejects_live_opposite_backend
run_test 'opposite backend checks preserve conflict absent and unknown states' test_opposite_backend_checks_preserve_three_states
run_test 'SSH peer protection preserves the rule-check status' test_ssh_peer_route_uses_rule_check_status
run_test 'existing WARP registration is reused safely' test_existing_warp_registration_is_reused
run_test 'WARP registration distinguishes present missing and unknown' test_warp_registration_has_three_states
run_test 'WARP readiness wins over intermediate command exit codes' test_warp_command_errors_defer_to_real_readiness
run_test 'Socks readiness rejects unowned and invalid listeners' test_socks_local_readiness_rejects_unowned_or_invalid_listeners
run_test 'reused Socks port conflicts stop before runtime mutation' test_reused_socks_port_conflict_stops_before_runtime_mutation
run_test 'Socks readiness waits use wall-clock deadlines' test_socks_waits_use_wall_clock_deadlines
run_test 'failed Swap creation returns to selection' test_swap_failure_returns_to_selection
run_test 'uncertain Swap cleanup stops implicit and interactive installation' test_unconfirmed_swap_cleanup_stops_all_install_paths
run_test 'empty Swap choice defaults to 1G' test_swap_defaults_to_one_gig
run_test 'no-Swap hosts default to 1G even with sufficient memory' test_no_swap_defaults_to_one_gig_even_with_sufficient_memory
run_test 'Swap creation supports older coreutils' test_swap_creation_works_with_older_coreutils
run_test 'custom Swap uses decimal input and releases failed allocation' test_custom_swap_is_decimal_and_rollback_releases_space
run_test 'Swap rollback preserves unknown state and reverifies cleanup' test_swap_state_reader_and_rollback_failure_contract
run_test 'noninteractive Swap choices and failures are bounded' test_noninteractive_swap_choices_and_failure_are_bounded
run_test 'Gemini parser is covered by offline fixtures' test_gemini_fixtures
run_test 'YouTube parser is covered by offline fixtures' test_youtube_fixtures
run_test 'native egress selection prefers the first IPv4 and supports IPv6-only hosts' test_native_egress_selection
run_test 'native unlock trace failures remain advisory except for confirmed WARP paths' test_native_unlock_trace_behavior
run_test 'native HTTPS passes mode boundaries and ignores proxy environments' test_native_https_request_mode_and_environment_contract
run_test 'native HTTPS bounds sockets redirects responses and deadlines' test_native_https_request_socket_redirect_and_deadline_contract
run_test 'native unlock command is explicit and root scoped' test_native_unlock_command_is_explicit_and_root_scoped
run_test 'status and test do not run unlock probes' test_status_and_test_do_not_run_unlock_checks
run_test 'local runtime paths avoid external probes' test_local_runtime_paths_do_not_depend_on_external_probes
run_test 'test exit status follows only local state' test_cmd_test_returns_only_local_status
run_test 'status and healthy timer checks remain local' test_status_and_healthy_timer_stay_local
run_test 'HTTP probes accept error responses as reachable' test_http_probe_accepts_http_error_responses
run_test 'install unlock check is post-success and nonblocking' test_install_unlock_check_is_post_success_and_nonblocking
run_test 'old runtime restore does not call status' test_old_runtime_restore_does_not_call_status
run_test 'Google rule generation validates cloud subtraction' test_generator_validates_google_cloud_subtraction
run_test 'rule metadata counts gate install and update' test_rule_metadata_counts_gate_install_and_update
run_test 'update rollback restores existing and missing files' test_update_rollback_restores_existing_and_missing_files
run_test 'update accepts legacy Socks runtime' test_update_accepts_legacy_socks_runtime
run_test 'update rolls back activation and service failures' test_update_rolls_back_activation_and_service_write_failures
run_test 'WireGuard update rollback uses the interface boundary' test_wireguard_update_rollback_uses_interface_boundary
run_test 'restart update and heal restore required units' test_restart_and_update_restore_required_units
run_test 'updates reuse healthy mode backends' test_update_reuses_healthy_backends
run_test 'updates repair only missing mode backends' test_update_repairs_only_missing_backends
run_test 'Socks runtime setup and update reload preserve service order' test_socks_runtime_configuration_and_update_order
run_test 'restart reuses healthy mode backends' test_restart_reuses_healthy_backends
run_test 'restart repairs WireGuard unit-interface mismatch' test_restart_repairs_wireguard_unit_interface_mismatch
run_test 'WireGuard identity rejects and repairs same-name dummy links' test_wireguard_identity_rejects_dummy_and_heals
run_test 'Socks heal waits for redsocks before routing' test_socks_heal_waits_for_redsocks_before_routing
run_test 'auxiliary timer drift does not touch healthy backends' test_heal_ignores_auxiliary_timer_drift
run_test 'health timer failure does not block the data plane' test_health_timer_failure_does_not_block_data_plane
run_test 'uninstall clears both rule backends and keeps custom WireGuard paths' test_uninstall_cleans_both_rule_backends_and_keeps_custom_wg_path
run_test 'precise WireGuard uninstall does not require nftables' test_uninstall_precise_wireguard_does_not_require_nft
run_test 'uninstall quiesces health before backend teardown' test_uninstall_quiesces_health_before_backends
run_test 'uninstall scopes are explicit and VNC safe' test_uninstall_scope_is_explicit_and_vnc_safe
run_test 'uninstall deactivation reaches inactive state' test_uninstall_deactivation_reaches_inactive_state
run_test 'uninstall rejects rules that remain active' test_uninstall_rejects_rules_that_remain_active
run_test 'uninstall fails closed without runtime identity' test_uninstall_fails_closed_without_runtime_identity
run_test 'Socks uninstall clears known rules before missing ip handling' test_socks_uninstall_stops_known_rules_before_missing_ip_failure
run_test 'uninstall state queries fail closed' test_uninstall_state_queries_fail_closed
run_test 'missing uninstall units are already disabled' test_uninstall_missing_unit_is_already_disabled
run_test 'uninstall teardown precedes dependencies and permanent deletion' test_uninstall_orders_teardown_before_dependencies_and_deletion
run_test 'uninstall permanently deletes owned paths without backup' test_uninstall_permanently_deletes_owned_paths_without_backup
run_test 'uninstall requires project account ownership for WireGuard config deletion' test_uninstall_wireguard_config_requires_project_account_match
run_test 'uninstall rejects unowned WireGuard config inside project trees' test_uninstall_rejects_unowned_wireguard_config_in_project_tree
run_test 'managed Swap uninstall verifies state without backup' test_managed_swap_uninstall_verifies_state_without_backup
run_test 'all dependency packages are explicit and scoped' test_all_dependency_packages_are_explicit_and_scoped
run_test 'dependency services stop independently' test_dependency_services_stop_independently
run_test 'dependency uninstall requires an absent postcondition' test_dependency_uninstall_requires_absent_postcondition
run_test 'RPM dependency postcondition parsing fails closed' test_rpm_dependency_postcondition_parser_fails_closed
run_test 'uninstall scope controls dependency and fallback cleanup' test_uninstall_scope_controls_dependency_and_fallback_cleanup
run_test 'dependency failure stops before file deletion' test_dependency_failure_stops_before_file_deletion
run_test 'post-delete daemon reload failure is only a warning' test_uninstall_daemon_reload_failure_is_post_commit_warning
run_test 'README documents all uninstall modes' test_readme_documents_all_uninstall_modes
run_test 'README documents route scope behavior' test_readme_documents_route_scope_contract
run_test 'reinstall accepts legacy Socks cleanup' test_reinstall_accepts_legacy_socks_rule_cleanup
run_test 'reinstall quiesces health and optional backends' test_reinstall_quiesces_health_and_optional_backends
run_test 'main executes both mode switches and ignores unlock failures' test_main_executes_bidirectional_mode_switches
run_test 'mode switching reuses the main install path' test_reinstall_mode_switch_uses_the_main_install_path
run_test 'healthy reinstall reuses its backend without external setup' test_reinstall_reuses_healthy_backends_without_external_setup
run_test 'WireGuard reuse requires a real kernel device' test_wireguard_reuse_requires_real_kernel_device
run_test 'WireGuard target preflight waits for old Socks teardown' test_wireguard_target_preflight_waits_for_old_socks_teardown
run_test 'active WireGuard invalid config keeps the live backend' test_active_wireguard_invalid_config_keeps_live_backend
run_test 'WireGuard reuse probe uncertainty falls through to teardown' test_wireguard_reuse_probe_unknown_falls_through_to_teardown
run_test 'WireGuard prepared-target cleanup removes the real interface' test_wireguard_prepared_target_cleanup_removes_real_interface
run_test 'runtime restore avoids duplicate cleanup and always restores health' test_runtime_restore_avoids_duplicate_cleanup_and_always_restores_health
run_test 'untouched WireGuard preparation restores files without runtime cleanup' test_untouched_wireguard_preparation_restores_files_without_runtime_cleanup
run_test 'touched WireGuard rollback still runs runtime cleanup' test_touched_wireguard_rollback_still_runs_runtime_cleanup
run_test 'target preparation failure keeps the old runtime running' test_target_preparation_failure_keeps_old_runtime_running
run_test 'partial activation failure restores the old runtime' test_partial_activation_failure_invokes_old_runtime_restore
run_test 'service activation failure restores the old runtime' test_service_activation_failure_invokes_old_runtime_restore
run_test 'reused Socks post-restart failure restores old redsocks' test_reused_socks_post_restart_failure_restores_old_redsocks
run_test 'reinstall stops the previous custom WireGuard runtime' test_reinstall_stops_previous_custom_wireguard_runtime
run_test 'WireGuard uninstall can delete its stuck interface' test_wireguard_uninstall_has_interface_fallback
run_test 'wgcf maps MIPS and s390x assets' test_wgcf_mips_and_s390x_asset_mapping
run_test 'main is the single public project source' test_main_is_the_single_public_update_source
run_test 'logs follow the configured WireGuard interface' test_logs_follow_custom_wireguard_interface
run_test 'project version and GitHub commit API gates are absent' test_no_project_version_or_commit_api_gate
run_test 'project SHA gates are absent and wgcf checksum is verified' test_no_sha_gate
run_test 'public installer and bounded downloads are documented' test_public_install_contract_and_downloads_are_bounded

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
