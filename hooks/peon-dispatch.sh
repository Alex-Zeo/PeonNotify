#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════╗
# ║  peon-dispatch.sh — Claude Code Notification Sound Dispatcher   ║
# ║                                                                  ║
# ║  Usage: echo '<json>' | peon-dispatch.sh                         ║
# ║  Receives hook JSON on stdin, resolves event → sound, plays it.  ║
# ╚══════════════════════════════════════════════════════════════════╝

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source Libraries ────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/player.sh"

# ── Initialize ──────────────────────────────────────────────────────
peon_load_config

if [[ "$PEON_ENABLED" != "true" ]]; then
  exit 0
fi

# ── Read Hook Input (JSON on stdin) ─────────────────────────────────
INPUT=""
if [[ ! -t 0 ]]; then
  INPUT=$(cat)
fi

# Extract fields using jq if available, else grep fallback
_field() {
  local key="$1"
  if command -v jq &>/dev/null; then
    echo "$INPUT" | jq -r ".$key // empty" 2>/dev/null || true
  else
    echo "$INPUT" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null | head -1 | sed 's/.*":\s*"//' | sed 's/"$//' || true
  fi
}

_field_raw() {
  local key="$1"
  if command -v jq &>/dev/null; then
    echo "$INPUT" | jq -r ".$key // empty" 2>/dev/null || true
  else
    echo "$INPUT" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*[^,}\"]*" 2>/dev/null | head -1 | sed 's/.*:[[:space:]]*//' || true
  fi
}

HOOK_EVENT=$(_field "hook_event_name")
SESSION_ID=$(_field "session_id")
TOOL_NAME=$(_field "tool_name")
NOTIFICATION_TYPE=$(_field "notification_type")
SOURCE=$(_field "source")
TRIGGER=$(_field "trigger")
REASON=$(_field "reason")
TOOL_SUCCESS=$(_field_raw "tool_response.success")

export PEON_SESSION_ID="${SESSION_ID:-unknown}"

# ── Event → Sound Key Mapping ──────────────────────────────────────
resolve_event_key() {
  case "$HOOK_EVENT" in

    SessionStart)
      case "$SOURCE" in
        resume)  echo "session_resume" ;;
        *)       echo "session_start" ;;
      esac
      ;;

    SessionEnd)
      echo "session_end"
      ;;

    UserPromptSubmit)
      echo "prompt_submit"
      ;;

    PreToolUse)
      case "$TOOL_NAME" in
        Bash)        echo "tool_bash" ;;
        Write|Edit)  echo "tool_write" ;;
        Task)        echo "tool_start" ;;
        *)           echo "tool_start" ;;
      esac
      ;;

    PostToolUse)
      if [[ "$TOOL_SUCCESS" == "false" ]]; then
        echo "error"
      else
        echo "tool_done"
      fi
      ;;

    PostToolUseFailure)
      echo "error"
      ;;

    Notification)
      case "$NOTIFICATION_TYPE" in
        permission_prompt)    echo "permission_prompt" ;;
        idle_prompt)          echo "idle_prompt" ;;
        *)                    echo "permission_prompt" ;;
      esac
      ;;

    Stop)
      echo "stop"
      ;;

    SubagentStop)
      echo "subagent_stop"
      ;;

    PreCompact)
      case "$TRIGGER" in
        manual) echo "compact_manual" ;;
        auto)   echo "compact_auto" ;;
        *)      echo "compact_auto" ;;
      esac
      ;;

    PermissionRequest)
      echo "permission_prompt"
      ;;

    *)
      peon_log warn "dispatch.unknown_event" "hook_event=$HOOK_EVENT"
      echo ""
      ;;
  esac
}

# ── Main Dispatch ───────────────────────────────────────────────────
EVENT_KEY=$(resolve_event_key)

if [[ -z "$EVENT_KEY" ]]; then
  exit 0
fi

# Check cooldown
COOLDOWN=$(peon_get_event_cooldown "$EVENT_KEY")
if ! peon_check_cooldown "$EVENT_KEY" "$COOLDOWN"; then
  peon_log debug "dispatch.cooldown_skip" "event_key=$EVENT_KEY" "cooldown_ms=$COOLDOWN"
  exit 0
fi

# Resolve sound file
SOUND_FILE=$(peon_resolve_sound "$EVENT_KEY")

if [[ -z "$SOUND_FILE" ]]; then
  peon_log debug "dispatch.no_sound" "event_key=$EVENT_KEY"
  exit 0
fi

# Play and log
peon_log info "dispatch.play" \
  "event_key=$EVENT_KEY" \
  "hook_event=$HOOK_EVENT" \
  "tool_name=${TOOL_NAME:-}" \
  "sound=$(basename "$SOUND_FILE")"

peon_play "$SOUND_FILE"
peon_set_cooldown "$EVENT_KEY"

exit 0
