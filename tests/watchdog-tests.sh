#!/usr/bin/env bash

set -eu

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT=""
TEST_COUNT=0

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

pass() {
  TEST_COUNT=$((TEST_COUNT + 1))
  printf 'ok %d - %s\n' "$TEST_COUNT" "$1"
}

setup_test_env() {
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/openclaw-watchdog-test.XXXXXX")"
  export TMP_ROOT
  export HOME="$TMP_ROOT/home"
  mkdir -p "$HOME" "$TMP_ROOT/bin" "$HOME/.openclaw"

  export WATCHDOG_LOG_DIR="$TMP_ROOT/logs"
  export WATCHDOG_LOG_FILE="$WATCHDOG_LOG_DIR/watchdog.log"
  export WATCHDOG_STATE_FILE="$WATCHDOG_LOG_DIR/watchdog.state"
  export WATCHDOG_LOCK_DIR="$WATCHDOG_LOG_DIR/watchdog.lock"
  export WATCHDOG_LOCK_INFO_FILE="$WATCHDOG_LOG_DIR/watchdog.lock.info"
  export WATCHDOG_CONFIG_FILE="$HOME/.openclaw/openclaw.json"
  export WATCHDOG_GATEWAY_PLIST="$TMP_ROOT/ai.openclaw.gateway.plist"
  export WATCHDOG_CURL_BIN="$TMP_ROOT/bin/curl"
  export WATCHDOG_LSOF_BIN="$TMP_ROOT/bin/lsof"
  export WATCHDOG_OPENCLAW_BIN="$TMP_ROOT/bin/openclaw"
  export WATCHDOG_LAUNCHCTL_BIN="$TMP_ROOT/bin/launchctl"
  export WATCHDOG_ID_BIN="$TMP_ROOT/bin/id"
  export WATCHDOG_YES_BIN="$TMP_ROOT/bin/yes"
  export WATCHDOG_SLEEP_BIN="$TMP_ROOT/bin/sleep"
  export WATCHDOG_DATE_BIN="$TMP_ROOT/bin/date"
  export WATCHDOG_JQ_BIN="jq"
  export WATCHDOG_RM_BIN="rm"
  export WATCHDOG_PERL_BIN="perl"
  export WATCHDOG_TIMEOUT_SHELL_BIN="/bin/bash"
  export WATCHDOG_CHAT_ID="123456789"
  export WATCHDOG_ALERT_WINDOW_SECONDS=600
  export WATCHDOG_CHECK_WAIT_SECONDS=0
  export WATCHDOG_MAX_LOG_LINES=1000
  export WATCHDOG_RESTART_TIMEOUT_SECONDS=30
  export WATCHDOG_DOCTOR_TIMEOUT_SECONDS=180
  export WATCHDOG_NUCLEAR_TIMEOUT_SECONDS=30
  export WATCHDOG_LOCK_STALE_SECONDS=900
  export MOCK_HEALTH_STATE_FILE="$TMP_ROOT/mock-health"
  export MOCK_OPENCLAW_LOG="$TMP_ROOT/openclaw-calls.log"
  export MOCK_TELEGRAM_LOG="$TMP_ROOT/telegram.log"
  export MOCK_LAUNCHCTL_LOG="$TMP_ROOT/launchctl.log"
  export MOCK_LSOF_STATE="$TMP_ROOT/lsof-state"
  export MOCK_RESTART_BEHAVIOR="$TMP_ROOT/restart-behavior"

  cat > "$WATCHDOG_CONFIG_FILE" <<EOF
{
  "channels": {
    "telegram": {
      "accounts": [
        { "token": "abc123" }
      ]
    }
  }
}
EOF

  cat > "$WATCHDOG_CURL_BIN" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "$1" = "-sf" ]; then
  state="$(cat "$MOCK_HEALTH_STATE_FILE" 2>/dev/null || printf 'down')"
  if [ "$state" = "up" ]; then
    exit 0
  fi
  exit 1
fi
if [ "$1" = "-fsS" ]; then
  printf '%s\n' "$*" >> "$MOCK_TELEGRAM_LOG"
  exit 0
fi
exit 1
EOF

  cat > "$WATCHDOG_LSOF_BIN" <<'EOF'
#!/usr/bin/env bash
set -eu
state="$(cat "$MOCK_LSOF_STATE" 2>/dev/null || printf 'down')"
[ "$state" = "up" ]
EOF

  cat > "$WATCHDOG_OPENCLAW_BIN" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$MOCK_OPENCLAW_LOG"
if [ "$1" = "gateway" ] && [ "$2" = "restart" ]; then
  mode="$(cat "${TMP_ROOT}/heal-on" 2>/dev/null || printf 'never')"
  behavior="$(cat "$MOCK_RESTART_BEHAVIOR" 2>/dev/null || printf 'normal')"
  if [ "$behavior" = "timeout" ]; then
    sleep 5
  fi
  if [ "$mode" = "restart" ]; then
    printf 'up' > "$MOCK_HEALTH_STATE_FILE"
  fi
  exit 0
fi
if [ "$1" = "doctor" ] && [ "$2" = "--fix" ]; then
  mode="$(cat "${TMP_ROOT}/heal-on" 2>/dev/null || printf 'never')"
  if [ "$mode" = "doctor" ]; then
    printf 'up' > "$MOCK_HEALTH_STATE_FILE"
  fi
  exit 0
fi
exit 0
EOF

  cat > "$WATCHDOG_LAUNCHCTL_BIN" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$MOCK_LAUNCHCTL_LOG"
mode="$(cat "${TMP_ROOT}/heal-on" 2>/dev/null || printf 'never')"
if [ "$1" = "bootstrap" ] && [ "$mode" = "nuclear" ]; then
  printf 'up' > "$MOCK_HEALTH_STATE_FILE"
fi
exit 0
EOF

  cat > "$WATCHDOG_ID_BIN" <<'EOF'
#!/usr/bin/env bash
printf '501\n'
EOF

  cat > "$WATCHDOG_YES_BIN" <<'EOF'
#!/usr/bin/env bash
printf 'y\n'
EOF

  cat > "$WATCHDOG_SLEEP_BIN" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF

  cat > "$WATCHDOG_DATE_BIN" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "${1:-}" = "-u" ] && [ "${2:-}" = "+%Y-%m-%dT%H:%M:%SZ" ]; then
  printf '%s\n' "${MOCK_NOW_ISO:-2026-03-09T19:00:00Z}"
  exit 0
fi
if [ "${1:-}" = "+%Y-%m-%d %H:%M:%S" ]; then
  printf '%s\n' "${MOCK_NOW_LOG:-2026-03-09 19:00:00}"
  exit 0
fi
if [ "${1:-}" = "-j" ] && [ "${2:-}" = "-u" ] && [ "${3:-}" = "-f" ]; then
  input="$5"
  case "$input" in
    2026-03-09T18:30:00Z) printf '1741545000\n' ;;
    2026-03-09T18:40:00Z) printf '1741545600\n' ;;
    2026-03-09T18:50:00Z) printf '1741546200\n' ;;
    2026-03-09T18:51:00Z) printf '1741546260\n' ;;
    2026-03-09T19:00:00Z) printf '1741546800\n' ;;
    2026-03-09T19:20:00Z) printf '1741548000\n' ;;
    *) exit 1 ;;
  esac
  exit 0
fi
exit 1
EOF

  chmod 755 "$WATCHDOG_CURL_BIN" "$WATCHDOG_LSOF_BIN" "$WATCHDOG_OPENCLAW_BIN" \
    "$WATCHDOG_LAUNCHCTL_BIN" "$WATCHDOG_ID_BIN" "$WATCHDOG_YES_BIN" \
    "$WATCHDOG_SLEEP_BIN" "$WATCHDOG_DATE_BIN"

  printf 'down' > "$MOCK_HEALTH_STATE_FILE"
  printf 'down' > "$MOCK_LSOF_STATE"
  printf 'normal' > "$MOCK_RESTART_BEHAVIOR"
  : > "$MOCK_OPENCLAW_LOG"
  : > "$MOCK_TELEGRAM_LOG"
  : > "$MOCK_LAUNCHCTL_LOG"
  . "$REPO_DIR/openclaw-watchdog.sh"
}

teardown_test_env() {
  rm -rf "$TMP_ROOT"
}

run_test() {
  local name="$1"
  shift
  setup_test_env
  "$@"
  pass "$name"
  teardown_test_env
}

test_health_detection() {
  printf 'up' > "$MOCK_HEALTH_STATE_FILE"
  watchdog_gateway_healthy || fail "primary health check should succeed"
  printf 'down' > "$MOCK_HEALTH_STATE_FILE"
  printf 'up' > "$MOCK_LSOF_STATE"
  if watchdog_gateway_healthy; then
    fail "open port alone should not count as healthy"
  fi
  [ "$WATCHDOG_LAST_ERROR" = "health endpoint failed while port 18789 is still listening" ] || fail "port-only failure should explain why health failed"
  printf 'down' > "$MOCK_LSOF_STATE"
  if watchdog_gateway_healthy; then
    fail "gateway should be down when both checks fail"
  fi
}

test_healing_ladder_stops_on_success() {
  printf 'doctor' > "$TMP_ROOT/heal-on"
  watchdog_load_state
  watchdog_handle_failure "healthy"
  grep -q '^gateway restart$' "$MOCK_OPENCLAW_LOG" || fail "restart step should run first"
  grep -q '^doctor --fix$' "$MOCK_OPENCLAW_LOG" || fail "doctor step should run second"
  if grep -q 'bootstrap' "$MOCK_LAUNCHCTL_LOG"; then
    fail "nuclear step should not run after doctor succeeds"
  fi
  grep -q 'Method: doctor' "$MOCK_TELEGRAM_LOG" || fail "heal alert should mention method"
}

test_telegram_format_and_rate_limit() {
  WATCHDOG_STATE_LAST_ALERT_SENT="2026-03-09T18:51:00Z"
  watchdog_save_state
  watchdog_load_state
  watchdog_send_telegram "first"
  if [ -s "$MOCK_TELEGRAM_LOG" ]; then
    fail "alert should be rate limited inside the window"
  fi

  export MOCK_NOW_ISO="2026-03-09T19:20:00Z"
  export MOCK_NOW_LOG="2026-03-09 19:20:00"
  watchdog_load_state
  watchdog_send_telegram "second"
  grep -q 'text=second' "$MOCK_TELEGRAM_LOG" || fail "alert payload should include message text"
}

test_missing_chat_id_is_logged() {
  WATCHDOG_CHAT_ID=""
  watchdog_send_telegram "first" || true
  grep -q 'WATCHDOG_CHAT_ID is not configured' "$WATCHDOG_LOG_FILE" || fail "missing chat id should be logged"
  if [ -s "$MOCK_TELEGRAM_LOG" ]; then
    fail "telegram should not be called without a configured chat id"
  fi
}

test_state_read_write() {
  WATCHDOG_STATE_LAST_HEALTHY="2026-03-09T18:30:00Z"
  WATCHDOG_STATE_LAST_ALERT_SENT="2026-03-09T18:40:00Z"
  WATCHDOG_STATE_CONSECUTIVE_FAILURES="3"
  WATCHDOG_STATE_LAST_HEAL_METHOD="restart"
  WATCHDOG_STATE_STATUS="healing"
  watchdog_save_state
  watchdog_state_defaults
  watchdog_load_state
  [ "$WATCHDOG_STATE_LAST_HEALTHY" = "2026-03-09T18:30:00Z" ] || fail "last healthy should persist"
  [ "$WATCHDOG_STATE_CONSECUTIVE_FAILURES" = "3" ] || fail "failure count should persist"
  [ "$WATCHDOG_STATE_LAST_HEAL_METHOD" = "restart" ] || fail "heal method should persist"
  [ "$WATCHDOG_STATE_STATUS" = "healing" ] || fail "status should persist"
}

test_stale_lock_recovery() {
  mkdir -p "$WATCHDOG_LOCK_DIR"
  cat > "$WATCHDOG_LOCK_INFO_FILE" <<EOF
pid=999999
started_at=2026-03-09T18:30:00Z
EOF
  printf 'up' > "$MOCK_HEALTH_STATE_FILE"
  watchdog_main
  grep -q 'Removing stale watchdog lock' "$WATCHDOG_LOG_FILE" || fail "stale lock should be reclaimed"
  grep -q 'Gateway healthy' "$WATCHDOG_LOG_FILE" || fail "watchdog should continue after clearing stale lock"
  [ ! -d "$WATCHDOG_LOCK_DIR" ] || fail "lock directory should be cleaned up on exit"
}

test_restart_timeout_falls_through_to_doctor() {
  printf 'doctor' > "$TMP_ROOT/heal-on"
  printf 'timeout' > "$MOCK_RESTART_BEHAVIOR"
  WATCHDOG_RESTART_TIMEOUT_SECONDS=1
  watchdog_load_state
  watchdog_handle_failure "healthy"
  grep -q 'Healing step timed out for restart after 1s' "$WATCHDOG_LOG_FILE" || fail "restart timeout should be logged"
  grep -q '^doctor --fix$' "$MOCK_OPENCLAW_LOG" || fail "doctor should run after a timed out restart"
  grep -q 'Method: doctor' "$MOCK_TELEGRAM_LOG" || fail "doctor recovery should still alert"
}

test_log_rotation() {
  mkdir -p "$WATCHDOG_LOG_DIR"
  i=1
  while [ "$i" -le 1105 ]; do
    printf 'line %s\n' "$i" >> "$WATCHDOG_LOG_FILE"
    i=$((i + 1))
  done
  watchdog_rotate_logs
  lines="$(wc -l < "$WATCHDOG_LOG_FILE" | tr -d ' ')"
  [ "$lines" = "1000" ] || fail "log should rotate to 1000 lines"
  head_line="$(head -n 1 "$WATCHDOG_LOG_FILE")"
  [ "$head_line" = "line 106" ] || fail "oldest lines should be trimmed"
}

test_fast_path_healthy() {
  printf 'up' > "$MOCK_HEALTH_STATE_FILE"
  watchdog_main
  grep -q 'Gateway healthy' "$WATCHDOG_LOG_FILE" || fail "healthy run should log fast path"
  if [ -s "$MOCK_OPENCLAW_LOG" ]; then
    fail "healthy run should not invoke healing steps"
  fi
}

test_missing_or_corrupt_state_config_and_no_network() {
  mkdir -p "$WATCHDOG_LOG_DIR"
  printf '{bad json\n' > "$WATCHDOG_STATE_FILE"
  rm -f "$WATCHDOG_CONFIG_FILE"
  cat > "$WATCHDOG_CURL_BIN" <<'EOF'
#!/usr/bin/env bash
set -eu
if [ "$1" = "-sf" ]; then
  exit 1
fi
if [ "$1" = "-fsS" ]; then
  exit 1
fi
exit 1
EOF
  chmod 755 "$WATCHDOG_CURL_BIN"
  . "$REPO_DIR/openclaw-watchdog.sh"
  watchdog_main
  grep -q 'State file is corrupt' "$WATCHDOG_LOG_FILE" || fail "corrupt state should be handled"
  grep -q 'Telegram token unavailable' "$WATCHDOG_LOG_FILE" || fail "missing config should be logged"
}

run_test "health detection" test_health_detection
run_test "healing ladder" test_healing_ladder_stops_on_success
run_test "telegram rate limiting" test_telegram_format_and_rate_limit
run_test "missing chat id" test_missing_chat_id_is_logged
run_test "state read write" test_state_read_write
run_test "stale lock recovery" test_stale_lock_recovery
run_test "restart timeout fallback" test_restart_timeout_falls_through_to_doctor
run_test "log rotation" test_log_rotation
run_test "healthy fast path" test_fast_path_healthy
run_test "edge cases" test_missing_or_corrupt_state_config_and_no_network

printf '1..%d\n' "$TEST_COUNT"
