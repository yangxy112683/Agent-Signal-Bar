#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="$ROOT_DIR/dist/bin"
INSTALL_NAME="agent-signal-light"
LEGACY_INSTALL_NAME="agent-signal"
INSTALL_PATH="$INSTALL_DIR/$INSTALL_NAME"
LEGACY_INSTALL_PATH="$INSTALL_DIR/$LEGACY_INSTALL_NAME"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"

cd "$ROOT_DIR"

swift_tool() {
  if [[ -n "${DEVELOPER_DIR:-}" ]]; then
    swift "$@"
  elif [[ -d "$XCODE_DEVELOPER_DIR" ]]; then
    DEVELOPER_DIR="$XCODE_DEVELOPER_DIR" swift "$@"
  else
    swift "$@"
  fi
}

swift_tool build -c release --product "$INSTALL_NAME"
mkdir -p "$INSTALL_DIR"
BIN_PATH="$(swift_tool build -c release --show-bin-path)"
if [[ -x "$BIN_PATH/$INSTALL_NAME" ]]; then
  SOURCE_PATH="$BIN_PATH/$INSTALL_NAME"
elif [[ -x "$BIN_PATH/$LEGACY_INSTALL_NAME" ]]; then
  SOURCE_PATH="$BIN_PATH/$LEGACY_INSTALL_NAME"
elif [[ -x "$BIN_PATH/AgentSignalCLI" ]]; then
  SOURCE_PATH="$BIN_PATH/AgentSignalCLI"
else
  echo "error: built CLI binary not found in $BIN_PATH" >&2
  exit 1
fi
cp "$SOURCE_PATH" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"
ln -sf "$INSTALL_NAME" "$LEGACY_INSTALL_PATH"

echo "Installed $INSTALL_NAME: $INSTALL_PATH"
echo "Installed legacy alias $LEGACY_INSTALL_NAME: $LEGACY_INSTALL_PATH"
