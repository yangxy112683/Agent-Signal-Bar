#!/usr/bin/env bash
set -euo pipefail

MODE="readiness"
APP_NAME="AgentSignalLight"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DMG_PATH="$ROOT_DIR/dist/$APP_NAME-local.dmg"
PROFILE="${AGENT_SIGNAL_LIGHT_NOTARY_PROFILE:-${NOTARYTOOL_PROFILE:-}}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --readiness|readiness|check)
      MODE="readiness"
      shift
      ;;
    --submit|submit)
      MODE="submit"
      shift
      ;;
    --dmg)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "notarize_release: missing value for --dmg" >&2
        exit 2
      fi
      DMG_PATH="$2"
      shift 2
      ;;
    --profile)
      if [[ $# -lt 2 || "$2" == -* ]]; then
        echo "notarize_release: missing value for --profile" >&2
        exit 2
      fi
      PROFILE="$2"
      shift 2
      ;;
    --help|-h)
      cat <<EOF
usage: $0 [--readiness|--submit] [--dmg <path>] [--profile <notarytool-profile>]

Environment:
  AGENT_SIGNAL_LIGHT_CODE_SIGN_IDENTITY   Developer ID Application identity used by package_app.sh.
  AGENT_SIGNAL_LIGHT_NOTARY_PROFILE       xcrun notarytool keychain profile.

Typical flow:
  AGENT_SIGNAL_LIGHT_CODE_SIGN_IDENTITY="Developer ID Application: ..." ./script/package_release.sh
  AGENT_SIGNAL_LIGHT_NOTARY_PROFILE="agent-signal-light" ./script/notarize_release.sh --submit
EOF
      exit 0
      ;;
    *)
      echo "usage: $0 [--readiness|--submit] [--dmg <path>] [--profile <notarytool-profile>]" >&2
      exit 2
      ;;
  esac
done

developer_id_count() {
  security find-identity -v -p codesigning 2>/dev/null \
    | grep -c "Developer ID Application" || true
}

print_readiness() {
  local developer_ids
  developer_ids="$(developer_id_count)"
  echo "Agent Signal Bar notarization readiness"
  echo "dmg: $DMG_PATH"

  if xcrun notarytool --version >/dev/null 2>&1; then
    echo "[ok] notarytool available"
  else
    echo "[missing] notarytool unavailable; install full Xcode"
  fi

  if xcrun --find stapler >/dev/null 2>&1; then
    echo "[ok] stapler available"
  else
    echo "[missing] stapler unavailable; install full Xcode"
  fi

  if [[ "$developer_ids" -gt 0 ]]; then
    echo "[ok] Developer ID Application identities: $developer_ids"
  else
    echo "[missing] Developer ID Application identity"
  fi

  if [[ -n "$PROFILE" ]]; then
    echo "[ok] notarytool profile configured: $PROFILE"
  else
    echo "[missing] AGENT_SIGNAL_LIGHT_NOTARY_PROFILE or --profile"
  fi

  if [[ -f "$DMG_PATH" ]]; then
    if hdiutil verify "$DMG_PATH" >/dev/null 2>&1; then
      echo "[ok] DMG verifies"
    else
      echo "[missing] DMG verification failed"
    fi
  else
    echo "[missing] DMG not found; run ./script/package_release.sh"
  fi

  echo
  echo "Submit is available only after packaging with a Developer ID identity and configuring notarytool credentials."
}

submit_notarization() {
  local developer_ids
  developer_ids="$(developer_id_count)"

  if [[ "$developer_ids" -eq 0 ]]; then
    echo "notarize_release: missing Developer ID Application identity" >&2
    exit 1
  fi
  if [[ -z "$PROFILE" ]]; then
    echo "notarize_release: missing AGENT_SIGNAL_LIGHT_NOTARY_PROFILE or --profile" >&2
    exit 1
  fi
  if [[ ! -f "$DMG_PATH" ]]; then
    echo "notarize_release: DMG not found at $DMG_PATH" >&2
    exit 1
  fi

  hdiutil verify "$DMG_PATH" >/dev/null
  xcrun notarytool submit "$DMG_PATH" --keychain-profile "$PROFILE" --wait
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
  spctl --assess --type open --context context:primary-signature -v "$DMG_PATH"
  echo "Notarized DMG: $DMG_PATH"
}

case "$MODE" in
  readiness)
    print_readiness
    ;;
  submit)
    submit_notarization
    ;;
esac
