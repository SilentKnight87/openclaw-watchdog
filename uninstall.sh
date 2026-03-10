#!/usr/bin/env bash

set -eu

TARGET_ROOT="${TARGET_ROOT:-$HOME/clawd/tools/watchdog}"
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
PLIST_TARGET="${PLIST_TARGET:-$LAUNCH_AGENTS_DIR/ai.openclaw.watchdog.plist}"

main() {
  launchctl bootout "gui/$(id -u)" ai.openclaw.watchdog >/dev/null 2>&1 || true
  rm -f "$PLIST_TARGET"
  rm -rf "$TARGET_ROOT"
  printf 'Removed watchdog installation from %s\n' "$TARGET_ROOT"
}

main "$@"
