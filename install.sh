#!/usr/bin/env bash

set -eu

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET_ROOT="${TARGET_ROOT:-$HOME/clawd/tools/watchdog}"
LOG_DIR="${LOG_DIR:-$HOME/clawd/logs}"
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
PLIST_TARGET="${PLIST_TARGET:-$LAUNCH_AGENTS_DIR/ai.openclaw.watchdog.plist}"
SOURCE_PLIST="${REPO_DIR}/ai.openclaw.watchdog.plist"

ensure_path_env() {
  local node_bin path_value

  node_bin=""
  if [ -n "${NVM_BIN:-}" ]; then
    node_bin="$NVM_BIN"
  elif [ -d "$HOME/.nvm" ]; then
    node_bin="$(find "$HOME/.nvm" -type d -path '*/bin' 2>/dev/null | head -n 1 || true)"
  fi

  path_value="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  if [ -n "$node_bin" ]; then
    path_value="${path_value}:${node_bin}"
  fi

  printf '%s' "$path_value"
}

render_plist() {
  local path_value="$1"
  sed \
    -e "s|__WATCHDOG_SCRIPT__|${TARGET_ROOT}/openclaw-watchdog.sh|g" \
    -e "s|__WATCHDOG_STDOUT__|${LOG_DIR}/watchdog-launchd.log|g" \
    -e "s|__WATCHDOG_STDERR__|${LOG_DIR}/watchdog-launchd-err.log|g" \
    -e "s|__WATCHDOG_PATH__|${path_value}|g" \
    "$SOURCE_PLIST" > "$PLIST_TARGET"
}

main() {
  if [ -e "$TARGET_ROOT/openclaw-watchdog.sh" ] || [ -e "$PLIST_TARGET" ]; then
    if [ "${FORCE:-0}" != "1" ]; then
      printf 'Existing watchdog installation detected. Refusing to clobber without FORCE=1.\n' >&2
      exit 1
    fi
  fi

  mkdir -p "$TARGET_ROOT" "$LOG_DIR" "$LAUNCH_AGENTS_DIR"

  cp "$REPO_DIR/openclaw-watchdog.sh" "$TARGET_ROOT/openclaw-watchdog.sh"
  cp "$REPO_DIR/install.sh" "$TARGET_ROOT/install.sh"
  cp "$REPO_DIR/uninstall.sh" "$TARGET_ROOT/uninstall.sh"
  cp "$REPO_DIR/README.md" "$TARGET_ROOT/README.md"
  chmod 755 "$TARGET_ROOT/openclaw-watchdog.sh" "$TARGET_ROOT/install.sh" "$TARGET_ROOT/uninstall.sh"

  render_plist "$(ensure_path_env)"

  launchctl bootout "gui/$(id -u)" ai.openclaw.watchdog >/dev/null 2>&1 || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST_TARGET"
  printf 'Installed watchdog to %s and loaded %s\n' "$TARGET_ROOT" "$PLIST_TARGET"
}

main "$@"
