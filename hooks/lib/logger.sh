#!/usr/bin/env bash
# lib/logger.sh - Structured JSON logging with rotation
# Sources: config.sh must be sourced first (for PEON_LOG_DIR, PEON_LOG_LEVEL, PEON_LOG_MAX_LINES)

PEON_LOG_FILE="${PEON_LOG_DIR:-$HOME/.claude/logs}/peon.log"

_log_level_num() {
  case "$1" in
    debug) echo 0 ;;
    info)  echo 1 ;;
    warn)  echo 2 ;;
    error) echo 3 ;;
    *)     echo 1 ;;
  esac
}

_should_log() {
  local msg_level="$1"
  local cfg_level="${PEON_LOG_LEVEL:-info}"
  [[ $(_log_level_num "$msg_level") -ge $(_log_level_num "$cfg_level") ]]
}

_rotate_log() {
  local max_lines="${PEON_LOG_MAX_LINES:-5000}"
  if [[ -f "$PEON_LOG_FILE" ]]; then
    local line_count
    line_count=$(wc -l < "$PEON_LOG_FILE" 2>/dev/null || echo 0)
    if (( line_count > max_lines )); then
      local keep=$(( max_lines / 2 ))
      tail -n "$keep" "$PEON_LOG_FILE" > "${PEON_LOG_FILE}.tmp" 2>/dev/null
      mv "${PEON_LOG_FILE}.tmp" "$PEON_LOG_FILE" 2>/dev/null
    fi
  fi
}

# peon_log <level> <event> <key=value ...>
# Emits one structured JSON line per call (wide event pattern)
peon_log() {
  local level="$1"; shift
  local event="$1"; shift

  _should_log "$level" || return 0

  mkdir -p "$(dirname "$PEON_LOG_FILE")" 2>/dev/null

  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || date -u +"%Y-%m-%dT%H:%M:%SZ")

  # Build extra fields as JSON key-value pairs
  local extras=""
  for kv in "$@"; do
    local key="${kv%%=*}"
    local val="${kv#*=}"
    # Escape quotes in value
    val="${val//\"/\\\"}"
    extras="${extras},\"${key}\":\"${val}\""
  done

  local json="{\"ts\":\"${ts}\",\"level\":\"${level}\",\"event\":\"${event}\",\"session_id\":\"${PEON_SESSION_ID:-unknown}\",\"pid\":$$${extras}}"

  echo "$json" >> "$PEON_LOG_FILE" 2>/dev/null

  # Rotate periodically (1 in 20 chance to avoid overhead)
  (( RANDOM % 20 == 0 )) && _rotate_log
}
