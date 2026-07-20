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
  assert_eq 'wireguard' "$output" 'empty retry should select the default WireGuard mode'
}

test_install_mode_keeps_explicit_numbers() {
  source_without_main "$INSTALL_SCRIPT"
  CONFIG_FILE="${FIXTURE_DIR}/config/missing.env"

  local answer='1'
  read_input() { printf -v "$1" '%s' "$answer"; }
  assert_eq 'socks' "$(prompt_install_mode 2>/dev/null)" \
    'explicit option 1 should remain Socks' || return 1

  answer='2'
  assert_eq 'wireguard' "$(prompt_install_mode 2>/dev/null)" \
    'explicit option 2 should remain WireGuard'
}

test_reinstall_keeps_current_mode_by_default() {
  source_without_main "$INSTALL_SCRIPT"
  read_input() { printf -v "$1" '%s' ''; }

  CONFIG_FILE="${FIXTURE_DIR}/config/socks-mode.env"
  assert_eq 'socks' "$(prompt_install_mode 2>/dev/null)" \
    'reinstalling an existing Socks setup must not switch modes on empty input' || return 1

  CONFIG_FILE="${FIXTURE_DIR}/config/custom-wireguard.env"
  assert_eq 'wireguard' "$(prompt_install_mode 2>/dev/null)" \
    'reinstalling an existing WireGuard setup must keep WireGuard on empty input'
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

test_stdin_execution_without_bash_source() {
  local file guard output body
  for file in "$INSTALL_SCRIPT" "$MANAGER_SCRIPT"; do
    guard="$(tail -n 3 "$file")"
    output="$(printf 'set -u\nmain() { printf called; }\n%s\n' "$guard" | bash)"
    assert_eq 'called' "$output" "stdin execution should call main without BASH_SOURCE: $file" || return 1
  done

  body="$(function_body "$INSTALL_SCRIPT" fetch_asset)"
  output="$(printf '%s\n' \
    'set -u' \
    'SCRIPT_SOURCE=' \
    'REPO_RAW_BASE=https://example.invalid/project/main' \
    'raw_asset_url() { printf "%s/%s\\n" "${REPO_RAW_BASE%/}" "$1"; }' \
    'curl() { printf "download:%s\\n" "$*"; }' \
    'chmod() { :; }' \
    "$body" \
    'fetch_asset bin/warp-vps /tmp/unused 0755' \
    | bash)"
  assert_contains "$output" 'https://example.invalid/project/main/bin/warp-vps' \
    'stdin execution should download assets when no script path exists'
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

test_assets_are_staged_before_runtime_stops() {
  local main_body stage_body stage_line backup_line trap_line stop_line activate_line fetch_line
  main_body="$(function_body "$INSTALL_SCRIPT" main)"
  stage_body="$(function_body "$INSTALL_SCRIPT" stage_project_files)"
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
  assert_contains "$main_body" 'restore_project_files' \
    'partial live activation must restore the installation backup' || return 1
  assert_file_matches "$INSTALL_SCRIPT" 'missing/\$label' \
    'the install backup must record files that did not exist before activation' || return 1
  assert_file_matches "$INSTALL_SCRIPT" 'mv "\$live" "\$PROJECT_BACKUP_DIR/failed-new/\$label"' \
    'rollback must move newly created files that were absent before activation' || return 1
  assert_file_matches "$INSTALL_SCRIPT" 'config_tmp="\$\{CONFIG_FILE\}\.new\.\$\$"' \
    'config writes must stage beside the live config' || return 1
  assert_file_matches "$INSTALL_SCRIPT" 'mv "\$config_tmp" "\$CONFIG_FILE"' \
    'config writes must activate atomically'
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
  if [ "$trap_line" -ge "$dependency_line" ]; then
    fail 'runtime cleanup must be armed before dependency installation can fail'
    return 1
  fi
  assert_file_matches "$INSTALL_SCRIPT" 'CLI、配置和日志会保留' \
    'failed installation cleanup should preserve diagnostics and retry entrypoints'
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
  assert_contains "$systemctl_calls" 'disable --now redsocks.service' \
    'only a newly introduced packaged redsocks service should be disabled'
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
    'WireGuard mode must not enable EPEL, CRB or PowerTools repositories'
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

test_wireguard_config_generation_is_retryable() {
  local body
  body="$(function_body "$MANAGER_SCRIPT" generate_wg_config)"
  assert_contains "$body" 'wg_config_valid "$WG_CONFIG"' \
    'an existing WireGuard config must be parsed before reuse' || return 1
  assert_contains "$body" 'register --accept-tos' \
    'wgcf registration should use its noninteractive accept-tos flag' || return 1
  assert_not_contains "$body" "printf 'yes" \
    'wgcf registration must not depend on an interactive prompt pipe' || return 1
  assert_contains "$body" 'config_tmp="${WG_CONFIG}.new.$$"' \
    'WireGuard config should be staged beside the live file' || return 1
  assert_contains "$body" 'mv "$config_tmp" "$WG_CONFIG"' \
    'a validated WireGuard config should be activated atomically' || return 1

  source_without_main "$MANAGER_SCRIPT"
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

test_wireguard_route_failures_cleanup() {
  source_without_main "$MANAGER_SCRIPT"
  WG_IFACE=warp-vps-wg
  RULES_DIR="${ROOT_DIR}/rules"
  local fail_on die_message ip_calls routes4 routes6 route_del_calls
  fail_on=''
  die_message=''
  ip_calls=''
  routes4=''
  routes6=''
  route_del_calls=0

  load_config() { :; }
  validate_rules_file() { :; }
  wg_interface_exists() { return 0; }
  protect_ssh_peer_route() { :; }
  wireguard_routes_local_ok() { return 0; }
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
      del)
        route_del_calls=$((route_del_calls + 1))
        if [ "$1" = -4 ]; then
          remove_mock_route routes4 "$4"
        else
          remove_mock_route routes6 "$4"
        fi
        ;;
      *) return 1 ;;
    esac
  }

  local failed_cidr
  for failed_cidr in 8.8.8.0/24 8.8.4.0/24 2001:4860::/32 2404:6800::/32; do
    fail_on="$failed_cidr"
    die_message=''
    ip_calls=''
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
    assert_eq '6' "$route_del_calls" \
      "a route failure at $failed_cidr should run the real dual-stack cleanup" || return 1
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
  WG_IFACE=warp-vps-wg
  RULES_DIR=/unused
  local routes4='' routes6='' ip_calls=''

  load_config() { :; }
  validate_rules_file() { :; }
  wg_interface_exists() { return 0; }
  protect_ssh_peer_route() { :; }
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

test_wireguard_local_route_boundary_is_fail_closed() {
  source_without_main "$MANAGER_SCRIPT"
  WG_IFACE=warp-vps-wg
  RULES_DIR=/unused

  ip() {
    case "$*" in
      '-4 route show default dev warp-vps-wg') return 0 ;;
      '-6 route show default dev warp-vps-wg') return 2 ;;
    esac
    return 1
  }
  if wg_default_routes_absent; then
    fail 'an IPv6 route-table query failure must not be treated as an absent default route'
    return 1
  fi
  unset -f ip

  rule_probe_ip() {
    case "$2" in
      4) printf '8.8.8.0\n' ;;
      6) printf '2001:4860::\n' ;;
    esac
  }
  route_uses_wg4() { return 0; }
  route_uses_wg6() { return 0; }
  wg_default_routes_absent() { return 0; }
  socks_table_absent() { return 0; }
  wireguard_routes_local_ok || {
    fail 'representative dual-stack routes without a project default route should pass'
    return 1
  }

  wg_default_routes_absent() { return 1; }
  if wireguard_routes_local_ok; then
    fail 'a present or unreadable default route must fail the local boundary check'
    return 1
  fi
}

test_socks_nft_render_keeps_only_ipv6_block() {
  source_without_main "$MANAGER_SCRIPT"
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

  local rendered
  rendered="$(render_nft_conf)"
  assert_contains "$rendered" 'ip daddr @google4 meta l4proto tcp counter redirect to :23456' \
    'Socks must keep the Google IPv4 TCP redirect' || return 1
  assert_contains "$rendered" 'ip6 daddr @google6 counter reject' \
    'Socks must keep the Google IPv6 reject' || return 1
  assert_not_contains "$rendered" 'udp dport 443' \
    'Socks must not block Google IPv4 UDP/443' || return 1
  assert_not_contains "$rendered" 'ip daddr @google4 meta l4proto udp' \
    'Socks must not add a replacement IPv4 UDP drop or redirect'
}

test_mode_switch_rejects_live_opposite_backend() {
  source_without_main "$MANAGER_SCRIPT"
  load_config() { :; }

  WARP_MODE=wireguard
  wg_interface_exists() { return 0; }
  rule_probe_ip() {
    case "$2" in
      4) printf '8.8.8.0\n' ;;
      6) printf '2001:4860::\n' ;;
    esac
  }
  route_uses_wg4() { return 0; }
  route_uses_wg6() { return 0; }
  wg_default_routes_absent() { return 0; }
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

  WARP_MODE=socks
  WARP_SOCKS_PORT=23456
  REDSOCKS_PORT=23457
  wait_for_socks_listen() { return 0; }
  port_listening() { return 0; }
  service_active() { return 0; }
  table_exists() { return 0; }
  socks_nft_rules_local_ok() { return 0; }
  wg_interface_absent() { return 1; }
  if test_quiet; then
    fail 'Socks local state must reject a live old project WireGuard interface'
    return 1
  fi
  wg_interface_absent() { return 0; }
  test_quiet || {
    fail 'Socks local state should pass after the old WireGuard interface is absent'
    return 1
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
    'no|地区：US' || return 1
  evaluate_youtube_fixture \
    "${FIXTURE_DIR}/youtube/region-cn.html" \
    'no|地区：CN' || return 1
  evaluate_youtube_fixture \
    "${FIXTURE_DIR}/youtube/unavailable-us.html" \
    'no|地区：US' || return 1
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

test_local_runtime_paths_do_not_depend_on_external_probes() {
  local body name
  for name in test_quiet wait_for_wg_ready wait_for_warp_proxy_ready \
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
  done

  body="$(function_body "$INSTALL_SCRIPT" run_final_self_check)"
  assert_contains "$body" '"$BIN_PATH" status' \
    'the installer final gate should call the local-only status command' || return 1
  assert_not_contains "$body" '"$BIN_PATH" test' \
    'the installer final gate must not call external diagnostics' || return 1

  body="$(function_body "$MANAGER_SCRIPT" test_quiet)"
  assert_contains "$body" 'wait_for_socks_listen 8' \
    'the Socks local check must require its local WARP listener' || return 1
  assert_contains "$body" 'port_listening "$REDSOCKS_PORT"' \
    'the Socks local check must require its redsocks listener' || return 1
  assert_contains "$body" 'socks_nft_rules_local_ok' \
    'the Socks local check must require the intended nft rules' || return 1

  body="$(function_body "$MANAGER_SCRIPT" run_self_check)"
  assert_not_contains "$body" 'google_http_probe' \
    'status must not call Google HTTP probes' || return 1
  assert_not_contains "$body" 'socks_ok' \
    'status must not call the Cloudflare trace probe'
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

test_external_probe_failures_do_not_block_local_operations() {
  source_without_main "$MANAGER_SCRIPT"
  local external_calls=0 handshake_calls=0 repair_calls=0 manager_calls=''

  WARP_MODE=wireguard
  WG_IFACE=warp-vps-wg
  require_root() { :; }
  load_config() { :; }
  unit_ready() { return 0; }
  wg_interface_exists() { return 0; }
  rule_probe_ip() {
    case "$2" in
      4) printf '8.8.8.0\n' ;;
      6) printf '2001:4860::\n' ;;
    esac
  }
  route_uses_wg4() { return 0; }
  route_uses_wg6() { return 0; }
  wg_default_routes_absent() { return 0; }
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
  assert_eq '1' "$handshake_calls" \
    'status may display one passive handshake observation without using it as a gate' || return 1

  systemctl() { return 0; }
  restart_wireguard_runtime() { return 0; }
  run_self_check() { return 0; }
  cmd_restart >/dev/null || {
    fail 'restart must follow the healthy local result when external probes are unavailable'
    return 1
  }
  assert_eq '0' "$external_calls" \
    'restart must not call an external diagnostic' || return 1

  manager_mock() {
    manager_calls="${manager_calls}$1\n"
    case "$1" in
      install-systemd|status) return 0 ;;
      *) return 1 ;;
    esac
  }
  BIN_PATH=manager_mock
  reload_runtime_after_update >/dev/null || {
    fail 'update reload must accept a healthy local status without external diagnostics'
    return 1
  }
  assert_contains "$manager_calls" 'status' \
    'update reload must validate with the local status command' || return 1
  assert_not_contains "$manager_calls" 'test' \
    'update reload must not call the external diagnostic command' || return 1

  required_runtime_units_ready() { return 0; }
  test_quiet() { return 0; }
  restart_wireguard_runtime() { repair_calls=$((repair_calls + 1)); return 0; }
  cmd_heal >/dev/null || {
    fail 'health check must accept a healthy local runtime without external probes'
    return 1
  }
  assert_eq '0' "$external_calls" \
    'health checks must not run external probes' || return 1
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
  local body check_line complete_line disarm_line success_line unlock_line
  body="$(function_body "$INSTALL_SCRIPT" main)"
  check_line="$(line_number "$body" 'run_final_self_check')"
  complete_line="$(line_number "$body" 'INSTALL_COMPLETE=1')"
  disarm_line="$(line_number "$body" 'trap - EXIT')"
  success_line="$(line_number "$body" 'WARP VPS Manager 安装完成')"
  unlock_line="$(line_number "$body" '"$BIN_PATH" unlock-check || true')"
  for name in check_line complete_line disarm_line success_line unlock_line; do
    [ -n "${!name}" ] || {
      fail "installer post-success marker is missing: $name"
      return 1
    }
  done
  if [ "$check_line" -ge "$complete_line" ] \
    || [ "$complete_line" -ge "$disarm_line" ] \
    || [ "$disarm_line" -ge "$success_line" ] \
    || [ "$success_line" -ge "$unlock_line" ]; then
    fail 'unlock-check must run only after local validation, completion, trap disarm and success output'
    return 1
  fi
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

test_restart_and_update_restore_required_units() {
  local restart_body reload_body heal_body update_body
  restart_body="$(function_body "$MANAGER_SCRIPT" cmd_restart)"
  reload_body="$(function_body "$MANAGER_SCRIPT" reload_runtime_after_update)"
  heal_body="$(function_body "$MANAGER_SCRIPT" cmd_heal)"
  update_body="$(function_body "$MANAGER_SCRIPT" cmd_update)"

  assert_contains "$restart_body" 'systemctl enable ' \
    'restart should re-enable disabled project units' || return 1
  assert_contains "$restart_body" 'configure_warp_runtime' \
    'Socks restart should restore mode, port and connection' || return 1
  assert_contains "$restart_body" 'systemctl start warp-vps-health.timer' \
    'restart should start an inactive health timer' || return 1

  assert_contains "$reload_body" 'configure_warp_runtime' \
    'update reload should restore the WARP local proxy' || return 1
  assert_contains "$reload_body" 'systemctl start warp-vps-health.timer' \
    'update reload should start an inactive health timer' || return 1
  assert_contains "$heal_body" 'required_runtime_units_ready' \
    'health checks should repair disabled units instead of declaring success' || return 1

  assert_contains "$update_body" 'if ! activate_update_stage "$stage"' \
    'update activation failures must be caught' || return 1
  assert_contains "$update_body" 'restore_update_backup "$backup"' \
    'a partial update activation must restore the previous files'
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
  assert_contains "$systemctl_calls" 'stop warp-vps-health.timer warp-vps-health.service' \
    'uninstall must stop an in-flight health service' || return 1
  assert_contains "$systemctl_calls" 'wg-quick@warp-vps-wg.service' \
    'uninstall must also stop its dedicated WireGuard unit'
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
      show) printf 'not-found\n' ;;
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

test_uninstall_orders_teardown_before_dependencies_and_files() {
  local body resolve_line deactivate_line backup_line dependency_line move_line
  body="$(function_body "$MANAGER_SCRIPT" cmd_uninstall)"
  resolve_line="$(line_number "$body" 'resolve_uninstall_scope')"
  deactivate_line="$(line_number "$body" 'deactivate_runtime_for_uninstall')"
  backup_line="$(line_number "$body" 'install -d -m 0755 "$backup_dir"')"
  dependency_line="$(line_number "$body" 'uninstall_project_dependencies')"
  move_line="$(line_number "$body" 'safe_move_if_exists "$REDSOCKS_FALLBACK_BIN"')"
  if [ -z "$resolve_line" ] || [ -z "$deactivate_line" ] || [ -z "$backup_line" ] \
    || [ -z "$dependency_line" ] || [ -z "$move_line" ]; then
    fail 'uninstall phase boundaries are incomplete'
    return 1
  fi
  if [ "$resolve_line" -ge "$deactivate_line" ] || [ "$deactivate_line" -ge "$backup_line" ] \
    || [ "$backup_line" -ge "$dependency_line" ] || [ "$dependency_line" -ge "$move_line" ]; then
    fail 'uninstall must resolve input, deactivate rules, uninstall dependencies, then move files'
    return 1
  fi

  local main_body
  main_body="$(function_body "$MANAGER_SCRIPT" main)"
  assert_contains "$main_body" 'cmd_uninstall "${@:2}"' \
    'main must forward uninstall options instead of silently ignoring them'
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
  local moved_paths=''
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
  date() { printf '20260718T120000Z\n'; }
  install() { :; }
  section() { :; }
  info_line() { :; }
  print_move_target_if_exists() { :; }
  uninstall_project_dependencies() { dependency_calls=$((dependency_calls + 1)); }
  safe_move_if_exists() { moved_paths="${moved_paths}$1\n"; }
  uninstall_managed_swap() { :; }
  systemctl() { :; }

  cmd_uninstall --yes >/dev/null
  assert_eq '0' "$dependency_calls" 'project-only uninstall must keep dependencies' || return 1
  assert_eq '0' "$prompt_calls" '--yes must not prompt' || return 1
  assert_not_contains "$moved_paths" "$REDSOCKS_FALLBACK_BIN" \
    'project-only uninstall must keep a managed redsocks dependency' || return 1

  moved_paths=''
  cmd_uninstall all >/dev/null
  assert_eq '1' "$dependency_calls" 'all uninstall must remove dependencies' || return 1
  assert_eq '0' "$prompt_calls" 'all must not prompt' || return 1
  assert_contains "$moved_paths" "$REDSOCKS_FALLBACK_BIN" \
    'all uninstall must move an owned source-built redsocks binary'
}

test_dependency_failure_stops_before_file_moves() {
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
  date() { printf '20260718T120000Z\n'; }
  install() { :; }
  section() { :; }
  info_line() { :; }
  print_move_target_if_exists() { :; }
  uninstall_project_dependencies() { return 1; }
  safe_move_if_exists() { printf 'unexpected-move:%s\n' "$1"; }

  local output rc=0
  output="$(cmd_uninstall all 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || {
    fail 'dependency failure was reported as a successful uninstall'
    return 1
  }
  assert_not_contains "$output" 'unexpected-move:' \
    'dependency failure must stop before any project file is moved' || return 1
  assert_not_contains "$output" 'WARP VPS Manager 已卸载' \
    'dependency failure must not print uninstall success'
}

test_readme_documents_all_uninstall_modes() {
  source_without_main "$MANAGER_SCRIPT"
  assert_file_matches "$README_FILE" 'warp-vps uninstall` \| 交互卸载' \
    'README should document interactive uninstall' || return 1
  assert_file_matches "$README_FILE" 'warp-vps uninstall --yes` \| 非交互卸载项目，保留依赖' \
    'README should document direct project-only uninstall' || return 1
  assert_file_matches "$README_FILE" 'warp-vps uninstall all` \| 非交互卸载项目及' \
    'README should document direct all uninstall' || return 1
  assert_file_matches "$README_FILE" '三种卸载方式都会先停止自动修复，并确认分流规则已经失效' \
    'README should promise the verified common rule teardown' || return 1
  assert_file_not_matches "$README_FILE" '^[-*] 卸载不会删除系统依赖包' \
    'README must not retain the obsolete unconditional dependency promise' || return 1

  local help_output
  help_output="$(usage)"
  assert_contains "$help_output" 'uninstall --yes' 'CLI help should document direct project-only uninstall' || return 1
  assert_contains "$help_output" 'uninstall all' 'CLI help should document direct all uninstall'
}

test_reinstall_rejects_residual_socks_rules() {
  source_without_main "$INSTALL_SCRIPT"
  PREVIOUS_MODE=socks
  MANAGED_WARP_SVC_VALUE=0
  BIN_PATH=/path/that/does/not/exist
  CONFIG_FILE="${FIXTURE_DIR}/config/socks-mode.env"
  local table_present=1

  systemctl() {
    case "$*" in
      'is-active --quiet '*|'is-enabled --quiet '*) return 1 ;;
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

  if stop_project_runtime warp-vps-wg /etc/wireguard/warp-vps-wg.conf >/dev/null; then
    fail 'a mode switch must not continue while the old Socks nft table remains'
    return 1
  fi

  table_present=0
  stop_project_runtime warp-vps-wg /etc/wireguard/warp-vps-wg.conf >/dev/null || {
    fail 'mode switching should continue once the old Socks data plane is absent'
    return 1
  }
}

test_main_executes_bidirectional_mode_switches() {
  source_without_main "$INSTALL_SCRIPT"
  local target_mode previous_mode unlock_rc events
  target_mode=wireguard
  previous_mode=socks
  unlock_rc=124
  events=''

  require_root() { :; }
  require_systemd() { :; }
  validate_repo_raw_base() { :; }
  prompt_install_mode() { printf '%s\n' "$target_mode"; }
  collect_swap_choice() { :; }
  read_project_warp_port() { return 1; }
  prompt_warp_port() { printf '25000\n'; }
  find_free_port() { printf '25001\n'; }
  port_in_use() { return 1; }
  capture_service_ownership() { :; }
  read_previous_wireguard_runtime() {
    PREVIOUS_MODE="$previous_mode"
    PREVIOUS_WG_IFACE=warp-vps-wg
    PREVIOUS_WG_CONFIG=/etc/wireguard/warp-vps-wg.conf
  }
  stage_project_files() { :; }
  backup_project_files() { :; }
  stop_project_runtime() { events="${events}stop:${PREVIOUS_MODE}\n"; }
  activate_project_files() { :; }
  write_config() { events="${events}config:$1\n"; }
  apply_swap_choice() { :; }
  install_dependencies() { events="${events}deps:$1\n"; }
  disable_new_packaged_redsocks_service() { :; }
  preflight_nft_nat() { :; }
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
  manager_mock() {
    events="${events}manager:$1\n"
    [ "$1" != unlock-check ] || return "$unlock_rc"
  }
  BIN_PATH=manager_mock
  systemctl() { events="${events}systemctl:$*\n"; }
  enable_project_unit() { events="${events}enable:$1\n"; }
  run_final_self_check() { events="${events}self-check\n"; }
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
  assert_contains "$events" 'enable:wg-quick@warp-vps-wg.service' \
    'Socks-to-WireGuard must enable the WireGuard target unit' || return 1
  assert_not_contains "$events" 'manager:configure-warp' \
    'Socks-to-WireGuard must not configure the Socks target' || return 1
  assert_eq '1' "$(grep -c '^stop:' <<< "$events")" \
    'a timed-out post-success unlock check must not trigger installation cleanup' || return 1

  target_mode=socks
  previous_mode=wireguard
  unlock_rc=1
  events=''
  INSTALL_COMPLETE=0
  INSTALL_CLEANUP_ARMED=0
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
  assert_eq '1' "$(grep -c '^stop:' <<< "$events")" \
    'a failed post-success unlock check must not trigger installation cleanup'
}

test_reinstall_mode_switch_uses_the_main_install_path() {
  local body stop_line config_line deps_line wg_line socks_line
  body="$(function_body "$INSTALL_SCRIPT" main)"
  stop_line="$(line_number "$body" 'stop_project_runtime "$PREVIOUS_WG_IFACE"')"
  config_line="$(line_number "$body" 'write_config "$selected_mode"')"
  deps_line="$(line_number "$body" 'install_dependencies "$selected_mode"')"
  wg_line="$(line_number "$body" '"$BIN_PATH" setup-wireguard')"
  socks_line="$(line_number "$body" '"$BIN_PATH" configure-warp')"
  for name in stop_line config_line deps_line wg_line socks_line; do
    [ -n "${!name}" ] || {
      fail "mode-switch step is missing from the installer: $name"
      return 1
    }
  done
  if [ "$stop_line" -ge "$config_line" ] || [ "$config_line" -ge "$deps_line" ]; then
    fail 'the previous mode must stop before target config and dependencies are activated'
    return 1
  fi
  assert_file_matches "$README_FILE" '直接回车保持当前模式' \
    'README should document the safe reinstall default' || return 1
  assert_file_matches "$README_FILE" '输入 `2` 可从 Socks5 切换到 WireGuard' \
    'README should document the supported Socks-to-WireGuard switch' || return 1
  assert_file_matches "$README_FILE" '输入 `1` 可从 WireGuard 切换到 Socks5' \
    'README should document the supported reverse switch'
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
      'is-active --quiet '*|'is-enabled --quiet '*) return 1 ;;
      *) return 0 ;;
    esac
  }
  wg-quick() {
    wg_calls="${wg_calls}$*\n"
    return 1
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
  assert_file_not_matches "$INSTALL_SCRIPT" 'sha256|SOURCE_SHA|expected_sha' \
    'installer downloads must not be blocked by embedded SHA comparisons' || return 1
  assert_file_not_matches "$MANAGER_SCRIPT" 'sha256|hashlib|expected_sha' \
    'manager downloads must not be blocked by embedded SHA comparisons'
}

run_test 'install mode retries after invalid input' test_install_mode_reprompts
run_test 'explicit install mode numbers remain stable' test_install_mode_keeps_explicit_numbers
run_test 'reinstall keeps the current mode by default' test_reinstall_keeps_current_mode_by_default
run_test 'SOCKS port retries after a stray backslash' test_warp_port_reprompts
run_test 'reinstall can reuse its current SOCKS port' test_existing_project_port_is_reusable
run_test 'SOCKS port checks ignore UDP-only listeners' test_port_checks_only_tcp
run_test 'stdin execution works without BASH_SOURCE' test_stdin_execution_without_bash_source
run_test 'all interactive input precedes installation side effects' test_inputs_precede_side_effects
run_test 'project assets stage before the old runtime stops' test_assets_are_staged_before_runtime_stops
run_test 'failed installation stops only project runtime' test_failed_install_arms_runtime_cleanup
run_test 'installed services are reusable instead of blanket blockers' test_existing_services_are_reusable
run_test 'installer records and respects service ownership' test_installer_captures_service_ownership
run_test 'new packaged redsocks is stopped before WARP installation' test_redsocks_cleanup_precedes_warp_install
run_test 'managed redsocks ownership requires marker and binary evidence' test_managed_redsocks_requires_two_ownership_signals
run_test 'uninstall only stops a managed WARP service' test_managed_warp_service_ownership
run_test 'package manager selection is capability based' test_package_manager_detection_is_capability_based
run_test 'Ubuntu derivatives prefer UBUNTU_CODENAME' test_ubuntu_codename_takes_precedence
run_test 'apt WireGuard dependencies are mode specific' test_apt_wireguard_dependencies_are_minimal
run_test 'RPM WireGuard dependencies are mode specific' test_rpm_wireguard_dependencies_are_minimal
run_test 'Socks dependencies are mode specific' test_socks_dependencies_are_mode_specific
run_test 'WARP reuse requires both CLI and service unit' test_warp_client_reuse_requires_cli_and_unit
run_test 'RPM redsocks uses the Fedora package or source build path' test_rpm_redsocks_uses_fedora_package_or_source
run_test 'iptables CLI is not an installation dependency' test_no_iptables_package_dependency
run_test 'WireGuard support uses a real runtime preflight' test_wireguard_uses_runtime_capability
run_test 'WireGuard generation recovers from partial state' test_wireguard_config_generation_is_retryable
run_test 'WireGuard route failures clean partial state' test_wireguard_route_failures_cleanup
run_test 'WireGuard routes do not require native IPv6' test_wireguard_routes_work_without_native_ipv6
run_test 'WireGuard local route boundaries fail closed' test_wireguard_local_route_boundary_is_fail_closed
run_test 'Socks nft output keeps only the IPv6 block' test_socks_nft_render_keeps_only_ipv6_block
run_test 'mode switches reject a live opposite backend' test_mode_switch_rejects_live_opposite_backend
run_test 'SSH peer protection preserves the rule-check status' test_ssh_peer_route_uses_rule_check_status
run_test 'existing WARP registration is reused safely' test_existing_warp_registration_is_reused
run_test 'WARP registration distinguishes present missing and unknown' test_warp_registration_has_three_states
run_test 'WARP readiness wins over intermediate command exit codes' test_warp_command_errors_defer_to_real_readiness
run_test 'failed Swap creation returns to selection' test_swap_failure_returns_to_selection
run_test 'custom Swap uses decimal input and releases failed allocation' test_custom_swap_is_decimal_and_rollback_releases_space
run_test 'Gemini parser is covered by offline fixtures' test_gemini_fixtures
run_test 'YouTube parser is covered by offline fixtures' test_youtube_fixtures
run_test 'status and test do not run unlock probes' test_status_and_test_do_not_run_unlock_checks
run_test 'local runtime paths avoid external probes' test_local_runtime_paths_do_not_depend_on_external_probes
run_test 'test exit status follows only local state' test_cmd_test_returns_only_local_status
run_test 'external probe failures do not block local operations' test_external_probe_failures_do_not_block_local_operations
run_test 'HTTP probes accept error responses as reachable' test_http_probe_accepts_http_error_responses
run_test 'install unlock check is post-success and nonblocking' test_install_unlock_check_is_post_success_and_nonblocking
run_test 'Google rule generation validates cloud subtraction' test_generator_validates_google_cloud_subtraction
run_test 'restart update and heal restore required units' test_restart_and_update_restore_required_units
run_test 'uninstall clears both rule backends and keeps custom WireGuard paths' test_uninstall_cleans_both_rule_backends_and_keeps_custom_wg_path
run_test 'uninstall scopes are explicit and VNC safe' test_uninstall_scope_is_explicit_and_vnc_safe
run_test 'uninstall deactivation reaches inactive state' test_uninstall_deactivation_reaches_inactive_state
run_test 'uninstall rejects rules that remain active' test_uninstall_rejects_rules_that_remain_active
run_test 'uninstall fails closed without runtime identity' test_uninstall_fails_closed_without_runtime_identity
run_test 'Socks uninstall clears known rules before missing ip handling' test_socks_uninstall_stops_known_rules_before_missing_ip_failure
run_test 'uninstall state queries fail closed' test_uninstall_state_queries_fail_closed
run_test 'missing uninstall units are already disabled' test_uninstall_missing_unit_is_already_disabled
run_test 'uninstall teardown precedes dependencies and file moves' test_uninstall_orders_teardown_before_dependencies_and_files
run_test 'all dependency packages are explicit and scoped' test_all_dependency_packages_are_explicit_and_scoped
run_test 'dependency uninstall requires an absent postcondition' test_dependency_uninstall_requires_absent_postcondition
run_test 'RPM dependency postcondition parsing fails closed' test_rpm_dependency_postcondition_parser_fails_closed
run_test 'uninstall scope controls dependency and fallback cleanup' test_uninstall_scope_controls_dependency_and_fallback_cleanup
run_test 'dependency failure stops before file moves' test_dependency_failure_stops_before_file_moves
run_test 'README documents all uninstall modes' test_readme_documents_all_uninstall_modes
run_test 'reinstall rejects residual Socks rules' test_reinstall_rejects_residual_socks_rules
run_test 'main executes both mode switches and ignores unlock failures' test_main_executes_bidirectional_mode_switches
run_test 'mode switching reuses the main install path' test_reinstall_mode_switch_uses_the_main_install_path
run_test 'reinstall stops the previous custom WireGuard runtime' test_reinstall_stops_previous_custom_wireguard_runtime
run_test 'WireGuard uninstall can delete its stuck interface' test_wireguard_uninstall_has_interface_fallback
run_test 'wgcf maps MIPS and s390x assets' test_wgcf_mips_and_s390x_asset_mapping
run_test 'main is the single public project source' test_main_is_the_single_public_update_source
run_test 'logs follow the configured WireGuard interface' test_logs_follow_custom_wireguard_interface
run_test 'project version and GitHub commit API gates are absent' test_no_project_version_or_commit_api_gate
run_test 'embedded SHA gates are absent' test_no_sha_gate

printf '\n%d passed, %d failed\n' "$passed" "$failed"
[ "$failed" -eq 0 ]
