#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════╗
# ║  peon-watchdog.sh — Claude Code Memory Leak Detector            ║
# ║                                                                  ║
# ║  Usage: Registered as UserPromptSubmit hook.                     ║
# ║  Monitors RSS of parent Claude Code process.                     ║
# ║  Warns at threshold, kills + flags restart at critical.          ║
# ╚══════════════════════════════════════════════════════════════════╝

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source Libraries ────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/player.sh"

# ── Initialize ──────────────────────────────────────────────────────
peon_load_config

# ── Read Hook Input (consume stdin to prevent pipe block) ──────────
INPUT=""
if [[ ! -t 0 ]]; then
  INPUT=$(head -c 65536)
fi

# ── Config Helpers ──────────────────────────────────────────────────
_wd_get() {
  local key="$1" default="${2:-}"
  if command -v jq &>/dev/null && [[ -f "$PEON_CONFIG_FILE" ]]; then
    local val
    val=$(jq -r ".watchdog.${key} // empty" "$PEON_CONFIG_FILE" 2>/dev/null)
    if [[ -n "$val" ]]; then
      echo "$val"
      return
    fi
  fi
  echo "$default"
}

# ── Check if watchdog is enabled ────────────────────────────────────
WD_ENABLED=$(_wd_get "enabled" "true")
if [[ "$WD_ENABLED" != "true" ]]; then
  exit 0
fi

WD_WARN_MB=$(_wd_get "warn_mb" "800")
WD_KILL_MB=$(_wd_get "kill_mb" "1200")
WD_WARN_SOUND=$(_wd_get "warn_sound" "me_not_that_kind_of_orc.mp3")
WD_KILL_SOUND=$(_wd_get "kill_sound" "peon_death.mp3")
WD_WARN_COOLDOWN=$(_wd_get "warn_cooldown_sec" "300")
WD_AUTO_RESTART=$(_wd_get "auto_restart" "true")

# ── Find Claude Code PID ───────────────────────────────────────────
CLAUDE_PID="${PPID:-}"

if [[ -z "$CLAUDE_PID" || "$CLAUDE_PID" == "1" ]]; then
  peon_log debug "watchdog.no_ppid"
  exit 0
fi

# Verify PPID is actually a Claude process (safety check before kill)
PPID_CMD=$(ps -o args= -p "$CLAUDE_PID" 2>/dev/null || true)
if [[ -z "$PPID_CMD" ]]; then
  exit 0
fi
if [[ "$PPID_CMD" != *"claude"* && "$PPID_CMD" != *"node"* ]]; then
  peon_log debug "watchdog.ppid_not_claude" "pid=$CLAUDE_PID" "cmd=$PPID_CMD"
  exit 0
fi

# ── Read RSS ────────────────────────────────────────────────────────
RSS_KB=$(ps -o rss= -p "$CLAUDE_PID" 2>/dev/null | tr -d ' ')
if [[ -z "$RSS_KB" ]]; then
  exit 0
fi
RSS_MB=$(( RSS_KB / 1024 ))

# ── Check Thresholds ───────────────────────────────────────────────
if (( RSS_MB < WD_WARN_MB )); then
  peon_log debug "watchdog.ok" "pid=$CLAUDE_PID" "rss_mb=$RSS_MB"
  exit 0
fi

# ── Kill Threshold ──────────────────────────────────────────────────
if (( RSS_MB >= WD_KILL_MB )); then
  peon_log warn "watchdog.kill" "pid=$CLAUDE_PID" "rss_mb=$RSS_MB" "kill_mb=$WD_KILL_MB"

  # Read session info for restart
  SESSION_FILE="${HOME}/.claude/sessions/${CLAUDE_PID}.json"
  SESSION_ID=""
  SESSION_CWD=""
  if [[ -f "$SESSION_FILE" ]] && command -v jq &>/dev/null; then
    SESSION_ID=$(jq -r '.sessionId // empty' "$SESSION_FILE" 2>/dev/null || true)
    SESSION_CWD=$(jq -r '.cwd // empty' "$SESSION_FILE" 2>/dev/null || true)
  fi

  # Write restart flag for peon-claude wrapper
  if [[ "$WD_AUTO_RESTART" == "true" ]]; then
    RESTART_FILE="${PEON_STATE_DIR}/watchdog_restart.json"
    mkdir -p "$PEON_STATE_DIR" 2>/dev/null
    cat > "$RESTART_FILE" <<EOJSON
{"pid":$CLAUDE_PID,"sessionId":"${SESSION_ID}","cwd":"${SESSION_CWD}","rss_mb":$RSS_MB,"killed_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOJSON
  fi

  # Play kill sound synchronously (brief, before process dies)
  KILL_SOUNDS_DIR="${PEON_SOUNDS_DIR}/${PEON_SOUND_PACK}"
  KILL_SOUND_PATH="${KILL_SOUNDS_DIR}/${WD_KILL_SOUND}"
  if [[ -f "$KILL_SOUND_PATH" && "$PEON_MUTE" != "true" ]]; then
    peon_play "$KILL_SOUND_PATH"
    sleep 0.5
  fi

  # Kill the Claude process
  kill -TERM "$CLAUDE_PID" 2>/dev/null || true

  exit 0
fi

# ── Warn Threshold ──────────────────────────────────────────────────
# Check warn cooldown
COOLDOWN_FILE="${PEON_STATE_DIR}/cooldown_watchdog_warn"
if [[ -f "$COOLDOWN_FILE" ]]; then
  LAST_WARN=$(cat "$COOLDOWN_FILE" 2>/dev/null || echo 0)
  NOW=$(date +%s)
  DIFF=$(( NOW - LAST_WARN ))
  if (( DIFF < WD_WARN_COOLDOWN )); then
    exit 0
  fi
fi

peon_log warn "watchdog.warn" "pid=$CLAUDE_PID" "rss_mb=$RSS_MB" "warn_mb=$WD_WARN_MB"

# Play warn sound
SOUNDS_DIR="${PEON_SOUNDS_DIR}/${PEON_SOUND_PACK}"
WARN_SOUND_PATH="${SOUNDS_DIR}/${WD_WARN_SOUND}"
if [[ -f "$WARN_SOUND_PATH" && "$PEON_MUTE" != "true" ]]; then
  peon_play "$WARN_SOUND_PATH"
fi

# Set warn cooldown
mkdir -p "$PEON_STATE_DIR" 2>/dev/null
date +%s > "$COOLDOWN_FILE"

# Output to Claude Code UI via stdout
echo "[Watchdog] RSS ${RSS_MB}MB exceeds warning threshold (${WD_WARN_MB}MB). Consider restarting."

exit 0
