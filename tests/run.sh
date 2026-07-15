#!/usr/bin/env bash
# Test doubles and variables below are consumed by functions loaded with eval.
# shellcheck disable=SC2016,SC2034,SC2329
set -uo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
INSTALL_SCRIPT="${ROOT_DIR}/install.sh"
MANAGER_SCRIPT="${ROOT_DIR}/bin/warp-vps"
README_FILE="${ROOT_DIR}/README.md"
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
    -e '/^if \[ "${BASH_SOURCE\[0\]}" = "\$0" \]; then$/,/^fi$/d' \
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
  shift
  if ( "$@" ); then
    printf 'ok - %s\n' "$name"
    passed=$((passed + 1))
  else
    printf 'not ok - %s\n' "$name" >&2
    failed=$((failed + 1))
  fi
}

test_install_mode_reprompts() {
  source_without_main "$INSTALL_SCRIPT"

  local answer_index=0
  local answers=('invalid' '')
  read_input() {
    printf -v "$1" '%s' "${answers[$answer_index]}"
    answer_index=$((answer_index + 1))
  }
  wireguard_recommended() { return 1; }

  local output
  if ! output="$(prompt_install_mode 2>/dev/null)"; then
    fail 'prompt_install_mode exited instead of asking again'
    return 1
  fi
  output="${output##*$'\n'}"
  assert_eq 'socks' "$output" 'empty retry should select the default Socks mode'
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

test_inputs_precede_side_effects() {
  local body mode_line port_line marker marker_line
  body="$(function_body "$INSTALL_SCRIPT" main)"
  [ -n "$body" ] || {
    fail 'could not extract install.sh main()'
    return 1
  }

  mode_line="$(line_number "$body" 'prompt_install_mode')"
  port_line="$(line_number "$body" 'prompt_warp_port')"
  [ -n "$mode_line" ] || {
    fail 'main() does not collect the install mode'
    return 1
  }
  [ -n "$port_line" ] || {
    fail 'main() does not collect the Socks port'
    return 1
  }

  for marker in apply_swap_choice install_dependencies preflight_nft_nat ensure_redsocks_user install_project_files write_config configure_warp; do
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

  unset -f warp-cli
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
    return 0
  }
  unit_file_exists() { return 0; }
  REDSOCKS_UNIT_PREEXISTED=1
  disable_new_packaged_redsocks_service
  assert_eq '' "$systemctl_calls" 'pre-existing redsocks.service must be preserved' || return 1

  REDSOCKS_UNIT_PREEXISTED=0
  disable_new_packaged_redsocks_service
  assert_contains "$systemctl_calls" 'disable --now redsocks.service' \
    'only a newly introduced packaged redsocks service should be disabled'
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
  assert_contains "$systemctl_calls" 'disable warp-svc' 'owned warp-svc should be disabled'
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
  assert_not_contains "$package_calls" 'cloudflare-warp' 'WireGuard mode must not install cloudflare-warp'
}

test_rpm_wireguard_dependencies_are_minimal() {
  source_without_main "$INSTALL_SCRIPT"
  declare -F pkg_install_rpm >/dev/null || {
    fail 'pkg_install_rpm is missing'
    return 1
  }

  local package_calls=''
  dnf() {
    package_calls="${package_calls}$*\n"
    return 0
  }
  yum() {
    package_calls="${package_calls}$*\n"
    return 0
  }
  enable_rhel_extra_repos() { :; }
  OS_ID=rocky
  OS_VERSION_ID=9.0
  OS_VERSION_MAJOR=9

  pkg_install_rpm wireguard dnf
  assert_contains "$package_calls" 'wireguard-tools' 'WireGuard mode should install wireguard-tools' || return 1
  assert_not_contains "$package_calls" 'nftables' 'WireGuard mode must not install nftables' || return 1
  assert_not_contains "$package_calls" 'iptables' 'WireGuard mode must not install iptables' || return 1
  assert_not_contains "$package_calls" 'redsocks' 'WireGuard mode must not install redsocks' || return 1
  assert_not_contains "$package_calls" 'cloudflare-warp' 'WireGuard mode must not install cloudflare-warp'
}

test_socks_dependencies_are_mode_specific() {
  source_without_main "$INSTALL_SCRIPT"

  local package_calls=''
  apt-get() {
    package_calls="${package_calls}$*\n"
    return 0
  }
  warp-cli() { :; }
  log() { :; }
  OS_ID=ubuntu
  OS_CODENAME=noble

  pkg_install_apt socks
  assert_contains "$package_calls" 'nftables' 'apt Socks mode should install nftables' || return 1
  assert_contains "$package_calls" 'redsocks' 'apt Socks mode should install redsocks' || return 1
  assert_not_contains "$package_calls" 'wireguard-tools' 'apt Socks mode must not install WireGuard tools' || return 1
  assert_not_contains "$package_calls" 'iptables' 'apt Socks mode must not install iptables' || return 1

  package_calls=''
  dnf() {
    package_calls="${package_calls}$*\n"
    return 0
  }
  enable_rhel_extra_repos() { :; }
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

test_rpm_redsocks_uses_fedora_package_or_source() {
  source_without_main "$INSTALL_SCRIPT"
  local package_calls=''
  local build_calls=0

  redsocks_path() { return 1; }
  mark_managed_redsocks_if_current() { :; }
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
  source_without_main "$INSTALL_SCRIPT"
  local timeout_calls=''
  local registration_checks=0
  local proxy_mode_calls=0

  systemctl() { return 0; }
  wait_for_tcp_port() { return 0; }
  sleep() { :; }
  log() { :; }
  curl() { printf 'warp=on\n'; }
  timeout() {
    timeout_calls="${timeout_calls}$*\n"
    return 0
  }
  warp_registration_missing() {
    registration_checks=$((registration_checks + 1))
    return 0
  }
  set_warp_proxy_mode() {
    proxy_mode_calls=$((proxy_mode_calls + 1))
    return 0
  }

  configure_warp 23456
  assert_eq '0' "$registration_checks" \
    'a working existing WARP proxy must not be checked for missing registration' || return 1
  assert_eq '1' "$proxy_mode_calls" 'the existing registration should be switched once' || return 1
  assert_not_contains "$timeout_calls" 'registration new' \
    'a working existing WARP proxy must not create another registration' || return 1
  assert_not_contains "$timeout_calls" ' register' \
    'a working existing WARP proxy must not use the legacy register command' || return 1

  timeout_calls=''
  registration_checks=0
  proxy_mode_calls=0
  warp_registration_missing() {
    registration_checks=$((registration_checks + 1))
    return 0
  }
  set_warp_proxy_mode() {
    proxy_mode_calls=$((proxy_mode_calls + 1))
    [ "$proxy_mode_calls" -ge 2 ]
  }

  configure_warp 23456
  assert_eq '1' "$registration_checks" \
    'registration should be inspected after proxy mode fails' || return 1
  assert_eq '2' "$proxy_mode_calls" \
    'proxy mode should be retried after a confirmed missing registration' || return 1
  assert_contains "$timeout_calls" 'registration new' \
    'only a confirmed missing registration should create a registration'
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
    'no|当前出口地区受限' || return 1
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
    'unknown|页面特征不明确'
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
  done

  body="$(function_body "$MANAGER_SCRIPT" cmd_unlock_check)"
  assert_contains "$body" 'run_unlock_checks' \
    'unlock-check should remain the explicit command for external unlock probes'
}

test_wgcf_mips_and_s390x_asset_mapping() {
  source_without_main "$MANAGER_SCRIPT"
  local test_arch=''
  uname() { printf '%s\n' "$test_arch"; }

  test_arch=mips
  assert_eq 'wgcf_2.2.31_linux_mips_softfloat' "$(wgcf_asset_spec)" 'mips wgcf asset' || return 1
  test_arch=mipsel
  assert_eq 'wgcf_2.2.31_linux_mipsle_softfloat' "$(wgcf_asset_spec)" 'mipsel wgcf asset' || return 1
  test_arch=mips64
  assert_eq 'wgcf_2.2.31_linux_mips64_softfloat' "$(wgcf_asset_spec)" 'mips64 wgcf asset' || return 1
  test_arch=mips64el
  assert_eq 'wgcf_2.2.31_linux_mips64le_softfloat' "$(wgcf_asset_spec)" 'mips64el wgcf asset' || return 1
  test_arch=s390x
  assert_eq 'wgcf_2.2.31_linux_s390x' "$(wgcf_asset_spec)" 's390x wgcf asset'
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
  assert_file_not_matches "$INSTALL_SCRIPT" 'sha256|SOURCE_SHA|expected_sha' \
    'installer downloads must not be blocked by embedded SHA comparisons' || return 1
  assert_file_not_matches "$MANAGER_SCRIPT" 'sha256|hashlib|expected_sha' \
    'manager downloads must not be blocked by embedded SHA comparisons'
}

run_test 'install mode retries after invalid input' test_install_mode_reprompts
run_test 'SOCKS port retries after a stray backslash' test_warp_port_reprompts
run_test 'all interactive input precedes installation side effects' test_inputs_precede_side_effects
run_test 'installed services are reusable instead of blanket blockers' test_existing_services_are_reusable
run_test 'installer records and respects service ownership' test_installer_captures_service_ownership
run_test 'uninstall only stops a managed WARP service' test_managed_warp_service_ownership
run_test 'package manager selection is capability based' test_package_manager_detection_is_capability_based
run_test 'Ubuntu derivatives prefer UBUNTU_CODENAME' test_ubuntu_codename_takes_precedence
run_test 'apt WireGuard dependencies are mode specific' test_apt_wireguard_dependencies_are_minimal
run_test 'RPM WireGuard dependencies are mode specific' test_rpm_wireguard_dependencies_are_minimal
run_test 'Socks dependencies are mode specific' test_socks_dependencies_are_mode_specific
run_test 'RPM redsocks uses the Fedora package or source build path' test_rpm_redsocks_uses_fedora_package_or_source
run_test 'iptables CLI is not an installation dependency' test_no_iptables_package_dependency
run_test 'WireGuard support uses a real runtime preflight' test_wireguard_uses_runtime_capability
run_test 'SSH peer protection preserves the rule-check status' test_ssh_peer_route_uses_rule_check_status
run_test 'existing WARP registration is reused safely' test_existing_warp_registration_is_reused
run_test 'failed Swap creation returns to selection' test_swap_failure_returns_to_selection
run_test 'Gemini parser is covered by offline fixtures' test_gemini_fixtures
run_test 'status and test do not run unlock probes' test_status_and_test_do_not_run_unlock_checks
run_test 'wgcf maps MIPS and s390x assets' test_wgcf_mips_and_s390x_asset_mapping
run_test 'main is the single public project source' test_main_is_the_single_public_update_source
run_test 'project version and GitHub commit API gates are absent' test_no_project_version_or_commit_api_gate
run_test 'embedded SHA gates are absent' test_no_sha_gate

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
