#!/usr/bin/env bash

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WATCHDOG_HOME="${WATCHDOG_HOME:-$HOME/clawd/tools/watchdog}"
WATCHDOG_LOG_DIR="${WATCHDOG_LOG_DIR:-$HOME/clawd/logs}"
WATCHDOG_LOG_FILE="${WATCHDOG_LOG_FILE:-$WATCHDOG_LOG_DIR/watchdog.log}"
WATCHDOG_STATE_FILE="${WATCHDOG_STATE_FILE:-$WATCHDOG_LOG_DIR/watchdog.state}"
WATCHDOG_LOCK_DIR="${WATCHDOG_LOCK_DIR:-$WATCHDOG_LOG_DIR/watchdog.lock}"
WATCHDOG_CONFIG_FILE="${WATCHDOG_CONFIG_FILE:-$HOME/.openclaw/openclaw.json}"
WATCHDOG_GATEWAY_PLIST="${WATCHDOG_GATEWAY_PLIST:-$HOME/Library/LaunchAgents/ai.openclaw.gateway.plist}"

WATCHDOG_OPENCLAW_BIN="${WATCHDOG_OPENCLAW_BIN:-openclaw}"
WATCHDOG_CURL_BIN="${WATCHDOG_CURL_BIN:-curl}"
WATCHDOG_JQ_BIN="${WATCHDOG_JQ_BIN:-jq}"
WATCHDOG_LSOF_BIN="${WATCHDOG_LSOF_BIN:-lsof}"
WATCHDOG_LAUNCHCTL_BIN="${WATCHDOG_LAUNCHCTL_BIN:-launchctl}"
WATCHDOG_ID_BIN="${WATCHDOG_ID_BIN:-id}"
WATCHDOG_YES_BIN="${WATCHDOG_YES_BIN:-yes}"
WATCHDOG_SLEEP_BIN="${WATCHDOG_SLEEP_BIN:-sleep}"
WATCHDOG_DATE_BIN="${WATCHDOG_DATE_BIN:-date}"
WATCHDOG_TAIL_BIN="${WATCHDOG_TAIL_BIN:-tail}"
WATCHDOG_MKDIR_BIN="${WATCHDOG_MKDIR_BIN:-mkdir}"
WATCHDOG_RMDIR_BIN="${WATCHDOG_RMDIR_BIN:-rmdir}"

WATCHDOG_HEALTH_URL="${WATCHDOG_HEALTH_URL:-http://127.0.0.1:18789/health}"
WATCHDOG_PORT="${WATCHDOG_PORT:-18789}"
WATCHDOG_CHAT_ID="${WATCHDOG_CHAT_ID:-606404649}"
WATCHDOG_ALERT_WINDOW_SECONDS="${WATCHDOG_ALERT_WINDOW_SECONDS:-600}"
WATCHDOG_CHECK_WAIT_SECONDS="${WATCHDOG_CHECK_WAIT_SECONDS:-15}"
WATCHDOG_MAX_LOG_LINES="${WATCHDOG_MAX_LOG_LINES:-1000}"

WATCHDOG_STATE_LAST_HEALTHY=""
WATCHDOG_STATE_LAST_ALERT_SENT=""
WATCHDOG_STATE_CONSECUTIVE_FAILURES="0"
WATCHDOG_STATE_LAST_HEAL_METHOD=""
WATCHDOG_STATE_STATUS="healthy"
WATCHDOG_LAST_ERROR=""

watchdog_now_iso() {
  "$WATCHDOG_DATE_BIN" -u +"%Y-%m-%dT%H:%M:%SZ"
}

watchdog_now_log() {
  "$WATCHDOG_DATE_BIN" +"%Y-%m-%d %H:%M:%S"
}

watchdog_epoch() {
  local value="$1"
  if [ -z "$value" ]; then
    echo ""
    return 0
  fi

  if "$WATCHDOG_DATE_BIN" -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$value" "+%s" >/dev/null 2>&1; then
    "$WATCHDOG_DATE_BIN" -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$value" "+%s"
    return 0
  fi

  if "$WATCHDOG_DATE_BIN" -d "$value" "+%s" >/dev/null 2>&1; then
    "$WATCHDOG_DATE_BIN" -d "$value" "+%s"
    return 0
  fi

  echo ""
}

watchdog_duration_since() {
  local since="$1"
  local since_epoch now_epoch elapsed hours minutes seconds

  since_epoch="$(watchdog_epoch "$since")"
  now_epoch="$(watchdog_epoch "$(watchdog_now_iso)")"
  if [ -z "$since_epoch" ] || [ -z "$now_epoch" ]; then
    echo "unknown"
    return 0
  fi

  elapsed=$((now_epoch - since_epoch))
  if [ "$elapsed" -lt 0 ]; then
    elapsed=0
  fi
  hours=$((elapsed / 3600))
  minutes=$(((elapsed % 3600) / 60))
  seconds=$((elapsed % 60))

  if [ "$hours" -gt 0 ]; then
    printf "%dh %dm %ds" "$hours" "$minutes" "$seconds"
  elif [ "$minutes" -gt 0 ]; then
    printf "%dm %ds" "$minutes" "$seconds"
  else
    printf "%ds" "$seconds"
  fi
}

watchdog_ensure_dirs() {
  "$WATCHDOG_MKDIR_BIN" -p "$WATCHDOG_LOG_DIR"
}

watchdog_rotate_logs() {
  watchdog_ensure_dirs || return 1
  [ -f "$WATCHDOG_LOG_FILE" ] || return 0

  local lines tmp_file
  lines="$(wc -l < "$WATCHDOG_LOG_FILE" | tr -d ' ')"
  if [ "${lines:-0}" -le "$WATCHDOG_MAX_LOG_LINES" ]; then
    return 0
  fi

  tmp_file="${WATCHDOG_LOG_FILE}.tmp.$$"
  if "$WATCHDOG_TAIL_BIN" -n "$WATCHDOG_MAX_LOG_LINES" "$WATCHDOG_LOG_FILE" > "$tmp_file"; then
    mv "$tmp_file" "$WATCHDOG_LOG_FILE"
  else
    rm -f "$tmp_file"
    return 1
  fi
}

watchdog_log() {
  local level="$1"
  shift
  local message="$*"

  watchdog_ensure_dirs || return 1
  watchdog_rotate_logs >/dev/null 2>&1 || true
  printf '[%s] [%s] %s\n' "$(watchdog_now_log)" "$level" "$message" >> "$WATCHDOG_LOG_FILE"
}

watchdog_state_defaults() {
  WATCHDOG_STATE_LAST_HEALTHY=""
  WATCHDOG_STATE_LAST_ALERT_SENT=""
  WATCHDOG_STATE_CONSECUTIVE_FAILURES="0"
  WATCHDOG_STATE_LAST_HEAL_METHOD=""
  WATCHDOG_STATE_STATUS="healthy"
}

watchdog_json_extract_fallback() {
  local field="$1"
  local file="$2"
  sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\\{0,1\\}\\([^\",}]*\\)\"\\{0,1\\}.*/\\1/p" "$file" | head -n 1
}

watchdog_load_state() {
  watchdog_state_defaults

  if [ ! -f "$WATCHDOG_STATE_FILE" ]; then
    return 0
  fi

  if command -v "$WATCHDOG_JQ_BIN" >/dev/null 2>&1; then
    if ! "$WATCHDOG_JQ_BIN" empty "$WATCHDOG_STATE_FILE" >/dev/null 2>&1; then
      watchdog_log "WARN" "State file is corrupt; resetting to defaults"
      return 0
    fi
    WATCHDOG_STATE_LAST_HEALTHY="$("$WATCHDOG_JQ_BIN" -r '.last_healthy // empty' "$WATCHDOG_STATE_FILE" 2>/dev/null)"
    WATCHDOG_STATE_LAST_ALERT_SENT="$("$WATCHDOG_JQ_BIN" -r '.last_alert_sent // empty' "$WATCHDOG_STATE_FILE" 2>/dev/null)"
    WATCHDOG_STATE_CONSECUTIVE_FAILURES="$("$WATCHDOG_JQ_BIN" -r '.consecutive_failures // 0' "$WATCHDOG_STATE_FILE" 2>/dev/null)"
    WATCHDOG_STATE_LAST_HEAL_METHOD="$("$WATCHDOG_JQ_BIN" -r '.last_heal_method // empty' "$WATCHDOG_STATE_FILE" 2>/dev/null)"
    WATCHDOG_STATE_STATUS="$("$WATCHDOG_JQ_BIN" -r '.status // "healthy"' "$WATCHDOG_STATE_FILE" 2>/dev/null)"
  else
    WATCHDOG_STATE_LAST_HEALTHY="$(watchdog_json_extract_fallback "last_healthy" "$WATCHDOG_STATE_FILE")"
    WATCHDOG_STATE_LAST_ALERT_SENT="$(watchdog_json_extract_fallback "last_alert_sent" "$WATCHDOG_STATE_FILE")"
    WATCHDOG_STATE_CONSECUTIVE_FAILURES="$(watchdog_json_extract_fallback "consecutive_failures" "$WATCHDOG_STATE_FILE")"
    WATCHDOG_STATE_LAST_HEAL_METHOD="$(watchdog_json_extract_fallback "last_heal_method" "$WATCHDOG_STATE_FILE")"
    WATCHDOG_STATE_STATUS="$(watchdog_json_extract_fallback "status" "$WATCHDOG_STATE_FILE")"
  fi

  case "$WATCHDOG_STATE_CONSECUTIVE_FAILURES" in
    ''|*[!0-9]*)
      WATCHDOG_STATE_CONSECUTIVE_FAILURES="0"
      ;;
  esac

  case "$WATCHDOG_STATE_STATUS" in
    healthy|healing|down) ;;
    *)
      WATCHDOG_STATE_STATUS="healthy"
      ;;
  esac
}

watchdog_save_state() {
  watchdog_ensure_dirs || return 1
  cat > "$WATCHDOG_STATE_FILE" <<EOF
{
  "last_healthy": "${WATCHDOG_STATE_LAST_HEALTHY}",
  "last_alert_sent": "${WATCHDOG_STATE_LAST_ALERT_SENT}",
  "consecutive_failures": ${WATCHDOG_STATE_CONSECUTIVE_FAILURES},
  "last_heal_method": "${WATCHDOG_STATE_LAST_HEAL_METHOD}",
  "status": "${WATCHDOG_STATE_STATUS}"
}
EOF
}

watchdog_extract_token() {
  if [ ! -f "$WATCHDOG_CONFIG_FILE" ]; then
    echo ""
    return 0
  fi

  if command -v "$WATCHDOG_JQ_BIN" >/dev/null 2>&1; then
    "$WATCHDOG_JQ_BIN" -r '.channels.telegram.accounts[0].token // .channels.telegram.token // empty' "$WATCHDOG_CONFIG_FILE" 2>/dev/null
    return 0
  fi

  local token
  token="$(sed -n 's/.*"accounts"[[:space:]]*:[[:space:]]*\[[^]]*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$WATCHDOG_CONFIG_FILE" | head -n 1)"
  if [ -n "$token" ]; then
    echo "$token"
    return 0
  fi

  sed -n 's/.*"telegram"[[:space:]]*:[[:space:]]*{[^}]*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$WATCHDOG_CONFIG_FILE" | head -n 1
}

watchdog_should_send_alert() {
  local now_epoch last_epoch

  now_epoch="$(watchdog_epoch "$(watchdog_now_iso)")"
  last_epoch="$(watchdog_epoch "$WATCHDOG_STATE_LAST_ALERT_SENT")"

  if [ -z "$last_epoch" ] || [ -z "$now_epoch" ]; then
    return 0
  fi

  [ $((now_epoch - last_epoch)) -ge "$WATCHDOG_ALERT_WINDOW_SECONDS" ]
}

watchdog_send_telegram() {
  local message="$1"
  local token

  token="$(watchdog_extract_token)"
  if [ -z "$token" ]; then
    watchdog_log "ERROR" "Telegram token unavailable; cannot send alert"
    return 1
  fi

  if ! watchdog_should_send_alert; then
    watchdog_log "INFO" "Telegram alert suppressed by rate limit"
    return 0
  fi

  if "$WATCHDOG_CURL_BIN" -fsS --max-time 10 \
    -X POST \
    --data-urlencode "chat_id=$WATCHDOG_CHAT_ID" \
    --data-urlencode "text=$message" \
    "https://api.telegram.org/bot${token}/sendMessage" >/dev/null 2>&1; then
    WATCHDOG_STATE_LAST_ALERT_SENT="$(watchdog_now_iso)"
    watchdog_save_state >/dev/null 2>&1 || true
    return 0
  fi

  watchdog_log "ERROR" "Telegram notification failed"
  return 1
}

watchdog_primary_health_check() {
  "$WATCHDOG_CURL_BIN" -sf --max-time 5 "$WATCHDOG_HEALTH_URL" >/dev/null 2>&1
}

watchdog_secondary_health_check() {
  "$WATCHDOG_LSOF_BIN" -i ":$WATCHDOG_PORT" >/dev/null 2>&1
}

watchdog_gateway_healthy() {
  if watchdog_primary_health_check; then
    return 0
  fi

  if watchdog_secondary_health_check; then
    return 0
  fi

  return 1
}

watchdog_run_step() {
  local method="$1"
  shift

  if "$@"; then
    watchdog_log "INFO" "Healing step started: $method"
  else
    WATCHDOG_LAST_ERROR="Command failed for ${method}"
    watchdog_log "WARN" "$WATCHDOG_LAST_ERROR"
  fi

  "$WATCHDOG_SLEEP_BIN" "$WATCHDOG_CHECK_WAIT_SECONDS"

  if watchdog_gateway_healthy; then
    WATCHDOG_STATE_LAST_HEALTHY="$(watchdog_now_iso)"
    WATCHDOG_STATE_CONSECUTIVE_FAILURES="0"
    WATCHDOG_STATE_LAST_HEAL_METHOD="$method"
    WATCHDOG_STATE_STATUS="healthy"
    watchdog_save_state
    watchdog_log "HEAL" "Gateway restored via ${method}"
    return 0
  fi

  return 1
}

watchdog_step_restart() {
  "$WATCHDOG_OPENCLAW_BIN" gateway restart
}

watchdog_step_doctor() {
  "$WATCHDOG_YES_BIN" | "$WATCHDOG_OPENCLAW_BIN" doctor --fix
}

watchdog_step_nuclear() {
  local uid
  uid="$("$WATCHDOG_ID_BIN" -u)"
  "$WATCHDOG_LAUNCHCTL_BIN" bootout "gui/${uid}" ai.openclaw.gateway >/dev/null 2>&1 || true
  "$WATCHDOG_LAUNCHCTL_BIN" bootstrap "gui/${uid}" "$WATCHDOG_GATEWAY_PLIST"
}

watchdog_attempt_heal() {
  WATCHDOG_STATE_STATUS="healing"
  watchdog_save_state

  if watchdog_run_step "restart" watchdog_step_restart; then
    return 0
  fi

  if watchdog_run_step "doctor" watchdog_step_doctor; then
    return 0
  fi

  if watchdog_run_step "nuclear" watchdog_step_nuclear; then
    return 0
  fi

  WATCHDOG_STATE_STATUS="down"
  watchdog_save_state
  return 1
}

watchdog_acquire_lock() {
  if "$WATCHDOG_MKDIR_BIN" "$WATCHDOG_LOCK_DIR" 2>/dev/null; then
    return 0
  fi
  watchdog_log "INFO" "Another watchdog run is already in progress"
  return 1
}

watchdog_release_lock() {
  "$WATCHDOG_RMDIR_BIN" "$WATCHDOG_LOCK_DIR" >/dev/null 2>&1 || true
}

watchdog_handle_healthy() {
  local previous_status="$1"
  local downtime

  downtime="$(watchdog_duration_since "$WATCHDOG_STATE_LAST_HEALTHY")"
  if [ "$previous_status" = "down" ]; then
    watchdog_send_telegram "✅ OpenClaw gateway recovered at $(watchdog_now_iso). Was down for ${downtime}."
  fi

  WATCHDOG_STATE_LAST_HEALTHY="$(watchdog_now_iso)"
  WATCHDOG_STATE_CONSECUTIVE_FAILURES="0"
  WATCHDOG_STATE_STATUS="healthy"
  watchdog_save_state
  watchdog_log "INFO" "Gateway healthy"
}

watchdog_handle_failure() {
  local previous_status="$1"
  local downtime down_since

  WATCHDOG_STATE_CONSECUTIVE_FAILURES=$((WATCHDOG_STATE_CONSECUTIVE_FAILURES + 1))
  watchdog_log "WARN" "Gateway health check failed (consecutive failures: ${WATCHDOG_STATE_CONSECUTIVE_FAILURES})"
  down_since="$WATCHDOG_STATE_LAST_HEALTHY"

  if watchdog_attempt_heal; then
    downtime="$(watchdog_duration_since "$down_since")"
    watchdog_send_telegram "🩹 OpenClaw self-healed at $(watchdog_now_iso). Method: ${WATCHDOG_STATE_LAST_HEAL_METHOD}. Downtime: ${downtime}." || true
    return 0
  fi

  if [ "$previous_status" != "down" ] || watchdog_should_send_alert; then
    downtime="$(watchdog_duration_since "$WATCHDOG_STATE_LAST_HEALTHY")"
    watchdog_send_telegram "🚨 OpenClaw gateway is DOWN. All self-heal attempts failed. Manual intervention needed. Last error: ${WATCHDOG_LAST_ERROR:-gateway still unhealthy}. Downtime: ${downtime}." || true
  fi

  return 0
}

watchdog_main() {
  watchdog_ensure_dirs || {
    printf 'Failed to create log directory: %s\n' "$WATCHDOG_LOG_DIR" >&2
    return 1
  }

  watchdog_load_state

  if ! watchdog_acquire_lock; then
    return 0
  fi
  trap watchdog_release_lock EXIT INT TERM

  local previous_status
  previous_status="$WATCHDOG_STATE_STATUS"

  if watchdog_gateway_healthy; then
    watchdog_handle_healthy "$previous_status"
    return 0
  fi

  watchdog_handle_failure "$previous_status"
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  watchdog_main "$@"
  exit $?
fi
