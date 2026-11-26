# Shared Xcode / Swift toolchain resolution.
# Prefer Xcode 26 (Swift 6.3) over /Applications/Xcode.app (often Swift 5.10).
# Searches /Applications and ~/Applications. CI uses the same Xcode_26* preference.

agent_signal_newest_developer_dir() {
  ls -d "$@" 2>/dev/null | sort | tail -n 1 || true
}

agent_signal_resolve_developer_dir() {
  if [[ -n "${DEVELOPER_DIR:-}" && -d "$DEVELOPER_DIR" ]]; then
    printf "%s\n" "$DEVELOPER_DIR"
    return 0
  fi

  local path=""
  path="$(agent_signal_newest_developer_dir \
    /Applications/Xcode_26*.app/Contents/Developer \
    "$HOME"/Applications/Xcode_26*.app/Contents/Developer \
    "$HOME"/Applications/Xcode-26*.app/Contents/Developer)"
  if [[ -z "$path" ]]; then
    path="$(agent_signal_newest_developer_dir \
      /Applications/Xcode_*.app/Contents/Developer \
      "$HOME"/Applications/Xcode_*.app/Contents/Developer \
      "$HOME"/Applications/Xcode-*.app/Contents/Developer)"
  fi
  if [[ -z "$path" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    path="/Applications/Xcode.app/Contents/Developer"
  fi
  if [[ -n "$path" ]]; then
    printf "%s\n" "$path"
  fi
}

if resolved_developer_dir="$(agent_signal_resolve_developer_dir)" \
  && [[ -n "$resolved_developer_dir" ]]; then
  export DEVELOPER_DIR="$resolved_developer_dir"
fi
