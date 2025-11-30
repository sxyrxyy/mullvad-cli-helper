#!/usr/bin/env bash
set -euo pipefail

MULLVAD_BIN="${MULLVAD_BIN:-mullvad}"

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mullvad-helper"
PRIVACY_FLAG_FILE="$CONFIG_DIR/.privacy_profile_checked"

# Recommended EU countries for “good” privacy/latency mix
EU_PRESET_COUNTRIES=(de es nl se ch fr no fi dk it)

# Seconds to wait after connect before checking status
CONNECT_SLEEP="${CONNECT_SLEEP:-1}"


#######################################
# Helpers
#######################################

need_mullvad() {
  if ! command -v "$MULLVAD_BIN" >/dev/null 2>&1; then
    echo "Error: mullvad CLI not found in PATH." >&2
    echo "Install Mullvad VPN and make sure the 'mullvad' CLI is available." >&2
    exit 1
  fi
}

ensure_config_dir() {
  mkdir -p "$CONFIG_DIR"
}


#######################################
# Simple status output (no Python)
#######################################

show_status_simple() {
  echo
  echo "──── Mullvad connection status ────"
  if ! "$MULLVAD_BIN" status -v 2>/dev/null; then
    "$MULLVAD_BIN" status 2>/dev/null || true
  fi
  echo "───────────────────────────────────"
  echo
}


#######################################
# External connectivity checks
#######################################

show_ifconfig_info() {
  if command -v curl >/dev/null 2>&1; then
    echo "──── ifconfig.io (external view) ────"
    curl -s ifconfig.io/all || echo "⚠️ Failed to query ifconfig.io"
    echo
    echo "────────────────────────────────────"
    echo
  else
    echo "⚠️ 'curl' not found, skipping ifconfig.io check."
    echo
  fi
}


verify_mullvad_connected() {
  if command -v curl >/dev/null 2>&1; then
    echo "──── Mullvad external connectivity check ────"
    local out
    out=$(curl -s https://am.i.mullvad.net/connected || true)
    if [[ -n "$out" ]]; then
      echo "$out"
    else
      echo "⚠️ Failed to query https://am.i.mullvad.net/connected"
    fi
    echo "────────────────────────────────────────────"
    echo
  else
    echo "⚠️ 'curl' not found, skipping Mullvad connectivity check."
    echo
  fi
}


#######################################
# Per-run auto-connect enforcement
#######################################

ensure_auto_connect_on() {
  echo "Checking Mullvad auto-connect…"

  set +e
  local auto_connect
  auto_connect="$("$MULLVAD_BIN" auto-connect get 2>/dev/null)"
  local rc=$?
  set -e

  if [[ $rc -ne 0 || -z "$auto_connect" ]]; then
    echo "⚠️  Could not determine auto-connect state (old Mullvad version or daemon not running?)."
    echo
    return
  fi

  if [[ "$auto_connect" == *"on"* ]]; then
    echo "✅ Auto-connect is enabled."
    echo
    return
  fi

  echo "⚠️  Auto-connect appears to be OFF:"
  echo "    $auto_connect"
  echo
  read -r -p "Enable auto-connect now (connect on startup)? [y/N] " answer
  case "$answer" in
    [Yy]*)
      echo "Enabling auto-connect…"
      "$MULLVAD_BIN" auto-connect set on || echo "⚠️ Failed to enable auto-connect."
      ;;
    *)
      echo "Leaving auto-connect disabled (⚠️ you’ll start sessions without VPN)."
      ;;
  esac
  echo
}


#######################################
# Per-run lockdown enforcement
#######################################

ensure_lockdown_on() {
  echo "Checking Mullvad lockdown mode…"

  set +e
  local lockdown_state
  lockdown_state="$("$MULLVAD_BIN" lockdown-mode get 2>/dev/null)"
  local rc=$?
  set -e

  if [[ $rc -ne 0 || -z "$lockdown_state" ]]; then
    echo "⚠️  Could not determine lockdown mode state (old Mullvad version or daemon not running?)."
    echo
    return
  fi

  if [[ "$lockdown_state" == *"on"* || "$lockdown_state" == *"block"* ]]; then
    echo "✅ Lockdown mode appears to be enabled."
    echo
    return
  fi

  echo "⚠️  Mullvad lockdown mode appears to be OFF:"
  echo "    $lockdown_state"
  echo
  read -r -p "Enable lockdown mode now? [y/N] " answer
  case "$answer" in
    [Yy]*)
      echo "Enabling lockdown mode…"
      "$MULLVAD_BIN" lockdown-mode set on || echo "⚠️ Failed to enable lockdown mode."
      ;;
    *)
      echo "Leaving lockdown mode disabled (⚠️ less safe when VPN is disconnected)."
      ;;
  esac
  echo
}


#######################################
# Privacy profile (first run only)
#
# Harden:
#  - LAN access BLOCKED
#  - Protocol: WireGuard
#  - In-tunnel IPv6 ON
#  - DNS content blocking (ads/trackers/malware/gambling/adult)
#  - Quantum resistance ON (WireGuard)
#  - DAITA ON (WireGuard, if supported)
#
# Auto-connect & lockdown are enforced EVERY run separately.
#######################################


privacy_check_and_offer() {
  ensure_config_dir

  # Only do this once; afterwards we assume the user made a choice.
  if [[ -f "$PRIVACY_FLAG_FILE" ]]; then
    return
  fi

  echo "Performing one-time Mullvad privacy check (excluding auto-connect & lockdown)…"
  echo

  set +e
  local lan_state tunnel_info
  lan_state="$("$MULLVAD_BIN" lan get 2>/dev/null)"
  tunnel_info="$("$MULLVAD_BIN" tunnel get 2>/dev/null)"
  set -e

  local issues=()

  # LAN: want “block”
  if [[ "$lan_state" == *"allow"* ]]; then
    issues+=("• Local network sharing is allowed (recommended: block LAN to avoid local snooping).")
  fi

  # IPv6 in tunnel: want enabled
  if [[ "$tunnel_info" == *"IPv6: off"* ]] || [[ -z "$tunnel_info" ]]; then
    issues+=("• In-tunnel IPv6 appears disabled (recommended: enable IPv6 inside the tunnel).")
  fi

  if ((${#issues[@]} == 0)); then
    echo "✅ Mullvad core settings already look hardened (LAN, IPv6, tunnel)."
    echo
    printf 'checked\n' >"$PRIVACY_FLAG_FILE"
    return
  fi

  echo "⚠ Found settings that are not in the hardened privacy profile:"
  printf '%s\n' "${issues[@]}"
  echo
  echo "The script can apply the following recommended privacy settings:"
  cat <<'EOF'
  - mullvad lan set block
  - mullvad relay set tunnel-protocol wireguard
  - mullvad tunnel set ipv6 on
  - mullvad dns set default \
        --block-ads \
        --block-trackers \
        --block-malware \
        --block-gambling \
        --block-adult-content
  - mullvad tunnel set wireguard --quantum-resistant on
  - mullvad tunnel set wireguard --daita on
EOF
  echo

  read -r -p "Apply these privacy settings now? [y/N] " answer
  case "$answer" in
    [Yy]*)
      apply_privacy_profile
      ;;
    *)
      echo "Leaving Mullvad settings unchanged."
      ;;
  esac

  printf 'checked\n' >"$PRIVACY_FLAG_FILE"
}


apply_privacy_profile() {
  echo
  echo "Applying recommended Mullvad privacy settings…"
  echo "(This may fail if you are not logged in or the daemon is not running.)"
  echo

  set +e

  "$MULLVAD_BIN" lan set block

  # Use WireGuard as tunnel protocol
  "$MULLVAD_BIN" relay set tunnel-protocol wireguard

  # Enable in-tunnel IPv6
  "$MULLVAD_BIN" tunnel set ipv6 on

  # Strong DNS content blocking
  "$MULLVAD_BIN" dns set default \
    --block-ads \
    --block-trackers \
    --block-malware \
    --block-gambling \
    --block-adult-content

  # Extra hardening: quantum resistance + DAITA (where supported)
  "$MULLVAD_BIN" tunnel set wireguard --quantum-resistant on
  "$MULLVAD_BIN" tunnel set wireguard --daita on

  set -e

  echo "✅ Privacy profile applied (as far as supported by your Mullvad version)."
  echo
}


#######################################
# EU presets
#######################################


eu_list() {
  cat <<'EOF'
Recommended EU Mullvad country codes:

  de  - Germany
  es  - Spain
  nl  - Netherlands
  se  - Sweden
  ch  - Switzerland
  fr  - France
  no  - Norway
  fi  - Finland
  dk  - Denmark
  it  - Italy

Use:
  ./mullvad-helper.sh eu-connect          # random from list above
  ./mullvad-helper.sh eu-connect de       # force specific country
EOF
}


eu_connect() {
  local country="${1:-}"

  if [[ -z "$country" ]]; then
    local count="${#EU_PRESET_COUNTRIES[@]}"
    local idx=$((RANDOM % count))
    country="${EU_PRESET_COUNTRIES[$idx]}"
    echo "Choosing random EU location: $country"
  else
    local found=0
    for c in "${EU_PRESET_COUNTRIES[@]}"; do
      if [[ "$c" == "$country" ]]; then
        found=1
        break
      fi
    done
    if [[ $found -eq 0 ]]; then
      echo "Invalid EU country code: $country" >&2
      echo "Use one of: ${EU_PRESET_COUNTRIES[*]}" >&2
      exit 1
    fi
  fi

  echo "Setting Mullvad relay location to EU country: $country"
  "$MULLVAD_BIN" relay set location "$country"
  echo "Connecting via $country…"
  "$MULLVAD_BIN" connect

  sleep "$CONNECT_SLEEP"
  show_status_simple
  show_ifconfig_info
  verify_mullvad_connected
}


#######################################
# Main CLI actions (simple subset)
#######################################

usage() {
  cat <<EOF
Usage: $0 <command> [args...]

Commands:
  status                 Show Mullvad VPN status + connectivity check
  connect                Connect to VPN (current location) and verify
  disconnect             Disconnect VPN
  set-location <cc> [city]
                         Set relay location (country code + optional city code)

  eu-list                Show recommended EU locations
  eu-connect [cc]        Connect via a recommended EU country
                           - no cc   => random from presets
                           - with cc => that country (e.g. de, es, nl, se…)

  help                   Show this help

Notes:
  - On every run, the script checks that:
      • auto-connect is ON (offers to enable if off)
      • lockdown mode is ON (offers to enable if off)
  - On first run, it can optionally harden other Mullvad privacy defaults.

Environment:
  MULLVAD_BIN            Path to mullvad CLI (default: 'mullvad')
  CONNECT_SLEEP          Seconds to wait after connect (default: 1)
EOF
}

cmd_status() {
  show_status_simple
  verify_mullvad_connected
}

cmd_connect() {
  "$MULLVAD_BIN" connect
  sleep "$CONNECT_SLEEP"
  show_status_simple
  show_ifconfig_info
  verify_mullvad_connected
}

cmd_disconnect() {
  "$MULLVAD_BIN" disconnect
  show_status_simple
}

cmd_set_location() {
  local country="${1:-}"
  local city="${2:-}"

  if [[ -z "$country" ]]; then
    echo "Usage: $0 set-location <country_code> [city_code]" >&2
    exit 1
  fi

  if [[ -n "$city" ]]; then
    echo "Setting Mullvad relay location to: $country $city"
    "$MULLVAD_BIN" relay set location "$country" "$city"
  else
    echo "Setting Mullvad relay location to country: $country"
    "$MULLVAD_BIN" relay set location "$country"
  fi

  "$MULLVAD_BIN" relay get || true
}


main() {
  need_mullvad

  # 1) Every run: enforce auto-connect & lockdown
  ensure_auto_connect_on
  ensure_lockdown_on

  # 2) First run only: offer to harden other privacy defaults
  privacy_check_and_offer

  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    status)       cmd_status "$@" ;;
    connect)      cmd_connect "$@" ;;
    disconnect)   cmd_disconnect "$@" ;;
    set-location) cmd_set_location "$@" ;;
    eu-list)      eu_list ;;
    eu-connect)   eu_connect "$@" ;;
    help|--help|-h) usage ;;
    *)
      echo "Unknown command: $cmd" >&2
      usage
      exit 1
      ;;
  esac
}

main "$@"
