#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════╗
# ║  peon-watchdog.sh — Claude Code Memory Watchdog v2              ║
# ║                                                                  ║
# ║  Modes:                                                          ║
# ║    (default)   Hook mode — UserPromptSubmit, checks PPID +      ║
# ║                aggregate + system pressure                       ║
# ║    --cron      Periodic mode — launchd, aggregate + system only  ║
# ║    --status    Diagnostic — print current memory state and exit  ║
# ║                                                                  ║
# ║  v1 only checked single-process RSS. v2 adds:                   ║
# ║    • Aggregate RSS across all Claude sessions                    ║
# ║    • System free memory (vm_stat / /proc/meminfo)               ║
# ║    • Process tree walking (children/subagents)                   ║
# ║    • Info-level heartbeat logging for observability              ║
# ╚══════════════════════════════════════════════════════════════════╝

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source Libraries ────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/player.sh"

# ── Initialize ──────────────────────────────────────────────────────
peon_load_config

# ── Mode Detection ──────────────────────────────────────────────────
WD_MODE="hook"
case "${1:-}" in
  --cron)   WD_MODE="cron" ;;
  --status) WD_MODE="status" ;;
esac

# ── Read Hook Input (hook mode only) ───────────────────────────────
if [[ "$WD_MODE" == "hook" ]]; then
  INPUT=""
  if [[ ! -t 0 ]]; then
    INPUT=$(head -c 65536)
  fi
  if command -v jq &>/dev/null && [[ -n "$INPUT" ]]; then
    _WD_SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null || true)
  else
    _WD_SESSION_ID=$(echo "$INPUT" | grep -o '"session_id"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null | head -1 | sed 's/.*":\s*"//' | sed 's/"$//' || true)
  fi
  export PEON_SESSION_ID="${_WD_SESSION_ID:-unknown}"
else
  export PEON_SESSION_ID="watchdog-${WD_MODE}"
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
if [[ "$WD_ENABLED" != "true" && "$WD_MODE" != "status" ]]; then
  exit 0
fi

# ── Load Config ─────────────────────────────────────────────────────
# Per-process thresholds
WD_WARN_MB=$(_wd_get "warn_mb" "500")
WD_KILL_MB=$(_wd_get "kill_mb" "800")

# Aggregate thresholds (all Claude processes combined)
WD_TOTAL_WARN_MB=$(_wd_get "total_warn_mb" "1500")
WD_TOTAL_KILL_MB=$(_wd_get "total_kill_mb" "2500")

# System free memory thresholds
WD_SYS_FREE_WARN=$(_wd_get "system_free_mb_warn" "512")
WD_SYS_FREE_KILL=$(_wd_get "system_free_mb_kill" "256")

# Process tree walking
WD_INCLUDE_CHILDREN=$(_wd_get "include_children" "true")

# Sounds and behavior
WD_WARN_SOUND=$(_wd_get "warn_sound" "me_not_that_kind_of_orc.mp3")
WD_KILL_SOUND=$(_wd_get "kill_sound" "peon_death.mp3")
WD_WARN_COOLDOWN=$(_wd_get "warn_cooldown_sec" "300")
WD_AUTO_RESTART=$(_wd_get "auto_restart" "true")

# ── Helper: Process Tree RSS (KB) ──────────────────────────────────
# Walks the process tree to include child/subagent memory.
# Uses iterative BFS to avoid bash recursion limits.
_wd_tree_rss_kb() {
  local root_pid="$1"
  local total=0

  # Start BFS queue with root
  local queue="$root_pid"
  local visited=" "

  while [[ -n "$queue" ]]; do
    # Pop first PID from queue
    local current="${queue%% *}"
    if [[ "$queue" == *" "* ]]; then
      queue="${queue#* }"
    else
      queue=""
    fi

    # Skip if already visited (handles cycles/duplicates)
    case "$visited" in
      *" ${current} "*) continue ;;
    esac
    visited="${visited}${current} "

    # Add this process's RSS
    local rss
    rss=$(ps -o rss= -p "$current" 2>/dev/null | tr -d ' ' || true)
    total=$(( total + ${rss:-0} ))

    # Enqueue children
    if [[ "$WD_INCLUDE_CHILDREN" == "true" ]]; then
      local children
      children=$(pgrep -P "$current" 2>/dev/null || true)
      if [[ -n "$children" ]]; then
        local child
        while IFS= read -r child; do
          [[ -n "$child" ]] && queue="${queue:+${queue} }${child}"
        done <<< "$children"
      fi
    fi
  done

  echo "$total"
}

# ── Helper: Aggregate Claude Stats ─────────────────────────────────
# Returns: total_kb:session_count:largest_pid:largest_tree_kb
# Uses tree RSS per session, deduplicates across trees.
_wd_aggregate() {
  local total=0
  local count=0
  local largest_pid=""
  local largest_kb=0
  local all_visited=" "

  local pid
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue

    # Calculate tree RSS for this session, tracking globally visited PIDs
    local tree_total=0
    local queue="$pid"

    while [[ -n "$queue" ]]; do
      local current="${queue%% *}"
      if [[ "$queue" == *" "* ]]; then
        queue="${queue#* }"
      else
        queue=""
      fi

      case "$all_visited" in
        *" ${current} "*) continue ;;
      esac
      all_visited="${all_visited}${current} "

      local rss
      rss=$(ps -o rss= -p "$current" 2>/dev/null | tr -d ' ' || true)
      rss=${rss:-0}
      total=$(( total + rss ))
      tree_total=$(( tree_total + rss ))

      if [[ "$WD_INCLUDE_CHILDREN" == "true" ]]; then
        local children
        children=$(pgrep -P "$current" 2>/dev/null || true)
        if [[ -n "$children" ]]; then
          local child
          while IFS= read -r child; do
            [[ -n "$child" ]] && queue="${queue:+${queue} }${child}"
          done <<< "$children"
        fi
      fi
    done

    count=$(( count + 1 ))
    if (( tree_total > largest_kb )); then
      largest_kb=$tree_total
      largest_pid=$pid
    fi
  done < <(pgrep -x claude 2>/dev/null || true)

  echo "${total}:${count}:${largest_pid}:${largest_kb}"
}

# ── Helper: System Free Memory (MB) ────────────────────────────────
# macOS: free + inactive pages via vm_stat
# Linux: MemAvailable from /proc/meminfo
_wd_system_free_mb() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    local page_size vmstat free_p inactive_p
    page_size=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
    vmstat=$(vm_stat 2>/dev/null || true)
    free_p=$(echo "$vmstat" | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
    inactive_p=$(echo "$vmstat" | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
    echo $(( (${free_p:-0} + ${inactive_p:-0}) * ${page_size} / 1024 / 1024 ))
  else
    awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0
  fi
}

# ── Helper: Find Claude Ancestor PID ───────────────────────────────
# Hooks run inside an intermediary shell (zsh/sh -c "...").
# Walking PPID alone gives the shell's RSS (~2MB), not Claude's.
# This walks up the process tree to find the actual claude process.
_wd_find_claude_ancestor() {
  local pid=$$
  local depth=0
  while [[ -n "$pid" && "$pid" != "1" && "$pid" != "0" ]] && (( depth < 10 )); do
    local comm
    comm=$(ps -o comm= -p "$pid" 2>/dev/null | tr -d ' ' || true)
    if [[ "$comm" == "claude" ]]; then
      echo "$pid"
      return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ' || true)
    depth=$(( depth + 1 ))
  done
  return 1
}

# ── Helper: System Total RAM (MB) ──────────────────────────────────
_wd_system_total_mb() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    local bytes
    bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    echo $(( bytes / 1024 / 1024 ))
  else
    awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0
  fi
}

# ── Helper: Play Sound ─────────────────────────────────────────────
_wd_play_sound() {
  local sound_name="$1"
  local sounds_dir="${PEON_SOUNDS_DIR}/${PEON_SOUND_PACK}"
  local path="${sounds_dir}/${sound_name}"
  if [[ -f "$path" && "$PEON_MUTE" != "true" ]]; then
    peon_play "$path"
  fi
}

# ── Helper: Read Session Info from PID ─────────────────────────────
# Claude Code writes ~/.claude/sessions/{PID}.json with sessionId + cwd.
_wd_read_session_info() {
  local pid="$1"
  local session_file="${HOME}/.claude/sessions/${pid}.json"
  local sid="" cwd=""

  if [[ -f "$session_file" ]] && command -v jq &>/dev/null; then
    sid=$(jq -r '.sessionId // empty' "$session_file" 2>/dev/null || true)
    cwd=$(jq -r '.cwd // empty' "$session_file" 2>/dev/null || true)
  fi

  echo "${sid}:${cwd}"
}

# ── Helper: Write Restart Flag ─────────────────────────────────────
_wd_write_restart() {
  local target_pid="$1" rss_mb="$2" reason="$3" session_id="$4" session_cwd="$5"
  [[ "$WD_AUTO_RESTART" != "true" ]] && return 0

  local restart_file="${PEON_STATE_DIR}/watchdog_restart.json"
  mkdir -p "$PEON_STATE_DIR" 2>/dev/null

  if command -v jq &>/dev/null; then
    jq -n --argjson pid "$target_pid" --argjson rss "$rss_mb" \
      --arg reason "$reason" --arg sid "$session_id" --arg cwd "$session_cwd" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{pid:$pid, sessionId:$sid, cwd:$cwd, rss_mb:$rss, reason:$reason, killed_at:$ts}' \
      > "$restart_file" 2>/dev/null
  else
    cat > "$restart_file" <<EOJSON
{"pid":${target_pid},"sessionId":"${session_id}","cwd":"${session_cwd}","rss_mb":${rss_mb},"reason":"${reason}","killed_at":"$(date -u +%Y-%m-%dT%H:%M:%SZ)"}
EOJSON
  fi
}

# ── Helper: Kill a Claude Process ──────────────────────────────────
_wd_kill() {
  local target_pid="$1" rss_mb="$2" reason="$3"

  peon_log warn "watchdog.kill" "pid=$target_pid" "rss_mb=$rss_mb" "reason=$reason"

  # Read session info from Claude's PID-keyed session file
  local session_info
  session_info=$(_wd_read_session_info "$target_pid")
  local session_id="${session_info%%:*}"
  local session_cwd="${session_info#*:}"

  _wd_write_restart "$target_pid" "$rss_mb" "$reason" "$session_id" "$session_cwd"

  # Play kill sound synchronously (brief, before process dies)
  _wd_play_sound "$WD_KILL_SOUND"
  sleep 0.5

  # Spawn autonomous restarter BEFORE killing (detached from process tree).
  # Works whether or not peon-claude wrapper is in use:
  #   - If peon-claude wraps the session, it consumes watchdog_restart.json
  #     and the autonomous restarter sees the flag gone → exits.
  #   - If claude is run directly, peon-claude isn't there, so the
  #     autonomous restarter opens a new Terminal and resumes the session.
  if [[ "$WD_AUTO_RESTART" == "true" && -n "$session_id" ]]; then
    local _restart_cwd="${session_cwd:-$HOME}"
    local _restart_log="${PEON_STATE_DIR}/watchdog_restart.log"
    (
      # Wait for the claude process to actually die
      _wait=0
      while kill -0 "$target_pid" 2>/dev/null && (( _wait < 30 )); do
        sleep 1
        (( ++_wait ))
      done
      sleep 2  # Grace period for cleanup

      # Check if peon-claude wrapper consumed the restart flag
      if [[ ! -f "${PEON_STATE_DIR}/watchdog_restart.json" ]]; then
        # Wrapper handled it — nothing to do
        exit 0
      fi

      # No wrapper — restart autonomously
      echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Autonomous restart: session=${session_id} rss=${rss_mb}MB reason=${reason}" >> "$_restart_log"

      if [[ "$(uname -s)" == "Darwin" ]]; then
        osascript -e "
          tell application \"Terminal\"
            activate
            do script \"cd '${_restart_cwd}' && echo '[Watchdog] Resuming session killed at ${rss_mb}MB RSS (${reason})...' && sleep 1 && claude --resume '${session_id}'\"
          end tell
        " 2>/dev/null || true
      elif command -v tmux &>/dev/null; then
        tmux new-session -d -s "claude-resume-$$" \
          "cd '${_restart_cwd}' && echo '[Watchdog] Resuming session...' && sleep 1 && claude --resume '${session_id}'" 2>/dev/null || true
      else
        echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] Manual restart needed: cd '${_restart_cwd}' && claude --resume '${session_id}'" >> "$_restart_log"
      fi

      # Clean up restart flag (we handled it)
      rm -f "${PEON_STATE_DIR}/watchdog_restart.json" 2>/dev/null
    ) &>/dev/null &
    disown
  fi

  # Kill the Claude process
  kill -TERM "$target_pid" 2>/dev/null || true
}

# ── Helper: Warn Cooldown ──────────────────────────────────────────
_wd_warn_cooled_down() {
  local cooldown_file="${PEON_STATE_DIR}/cooldown_watchdog_warn"
  if [[ -f "$cooldown_file" ]]; then
    local last_warn now diff
    last_warn=$(cat "$cooldown_file" 2>/dev/null || echo 0)
    now=$(date +%s)
    diff=$(( now - last_warn ))
    (( diff < WD_WARN_COOLDOWN )) && return 1
  fi
  return 0
}

_wd_set_warn_cooldown() {
  mkdir -p "$PEON_STATE_DIR" 2>/dev/null
  date +%s > "${PEON_STATE_DIR}/cooldown_watchdog_warn"
}

# ══════════════════════════════════════════════════════════════════════
# ── Status Mode ────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════
if [[ "$WD_MODE" == "status" ]]; then
  AGG=$(_wd_aggregate)
  IFS=: read -r agg_kb agg_count agg_largest_pid agg_largest_kb <<< "$AGG"
  SYS_FREE=$(_wd_system_free_mb)
  SYS_TOTAL=$(_wd_system_total_mb)

  echo ""
  echo "╔══════════════════════════════════════════╗"
  echo "║   Peon Watchdog — Memory Status          ║"
  echo "╚══════════════════════════════════════════╝"
  echo ""
  echo "  Enabled:            $WD_ENABLED"
  echo "  Include children:   $WD_INCLUDE_CHILDREN"
  echo ""
  echo "  Thresholds:"
  echo "    Per-process:      warn=${WD_WARN_MB}MB  kill=${WD_KILL_MB}MB"
  echo "    Aggregate:        warn=${WD_TOTAL_WARN_MB}MB  kill=${WD_TOTAL_KILL_MB}MB"
  echo "    System free:      warn=${WD_SYS_FREE_WARN}MB  kill=${WD_SYS_FREE_KILL}MB"
  echo ""
  echo "  System:             ${SYS_TOTAL}MB total, ${SYS_FREE}MB available (free+inactive)"
  echo "  Claude sessions:    ${agg_count}"
  echo "  Aggregate RSS:      $(( agg_kb / 1024 ))MB (tree)"
  if [[ -n "$agg_largest_pid" ]]; then
    echo "  Largest session:    PID ${agg_largest_pid} — $(( agg_largest_kb / 1024 ))MB"
  fi
  echo ""

  # Per-process detail
  echo "  Per-process breakdown:"
  while IFS= read -r _pid; do
    [[ -z "$_pid" ]] && continue
    _tree_kb=$(_wd_tree_rss_kb "$_pid")
    _direct_kb=$(ps -o rss= -p "$_pid" 2>/dev/null | tr -d ' ' || echo 0)
    _tree_mb=$(( _tree_kb / 1024 ))
    _direct_mb=$(( ${_direct_kb:-0} / 1024 ))
    _children=$(( _tree_mb - _direct_mb ))
    echo "    PID ${_pid}: ${_direct_mb}MB direct + ${_children}MB children = ${_tree_mb}MB"
  done < <(pgrep -x claude 2>/dev/null || true)

  echo ""

  # Recent watchdog log entries
  echo "  Recent watchdog events (last 10):"
  if [[ -f "${PEON_LOG_DIR:-$HOME/.claude/logs}/peon.log" ]]; then
    _wd_entries=$(grep '"watchdog\.' "${PEON_LOG_DIR:-$HOME/.claude/logs}/peon.log" 2>/dev/null | tail -10 || true)
    if [[ -n "$_wd_entries" ]]; then
      echo "$_wd_entries" | while IFS= read -r line; do
        echo "    $line"
      done
    else
      echo "    (none found — watchdog may not have logged yet)"
    fi
  else
    echo "    (no log file)"
  fi
  echo ""
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════
# ── Collect Metrics ────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════

# Per-process (hook mode only — uses PPID)
PPID_RSS_MB=0
PPID_TREE_MB=0
CLAUDE_PID=""

if [[ "$WD_MODE" == "hook" ]]; then
  # Walk up the process tree to find the actual Claude process.
  # Hooks run inside an intermediary shell, so PPID is typically
  # zsh/sh (2MB), not the Claude node process (200-500MB).
  CLAUDE_PID=$(_wd_find_claude_ancestor || true)

  if [[ -z "$CLAUDE_PID" ]]; then
    # Fallback: try raw PPID (might work if Claude spawns hooks directly)
    CLAUDE_PID="${PPID:-}"
    if [[ -z "$CLAUDE_PID" || "$CLAUDE_PID" == "1" ]]; then
      peon_log info "watchdog.no_ancestor" "ppid=${PPID:-empty}"
      # Still run aggregate + system checks below
      CLAUDE_PID=""
    else
      PPID_CMD=$(ps -o args= -p "$CLAUDE_PID" 2>/dev/null || true)
      if [[ "$PPID_CMD" != *"claude"* && "$PPID_CMD" != *"node"* ]]; then
        peon_log info "watchdog.ppid_not_claude" "pid=$CLAUDE_PID" "cmd=$PPID_CMD"
        CLAUDE_PID=""
      fi
    fi
  fi

  if [[ -n "$CLAUDE_PID" ]]; then
    PPID_RSS_KB=$(ps -o rss= -p "$CLAUDE_PID" 2>/dev/null | tr -d ' ')
    if [[ -n "$PPID_RSS_KB" ]]; then
      PPID_RSS_MB=$(( PPID_RSS_KB / 1024 ))
      PPID_TREE_KB=$(_wd_tree_rss_kb "$CLAUDE_PID")
      PPID_TREE_MB=$(( PPID_TREE_KB / 1024 ))
    fi
  fi
fi

# Aggregate (all modes)
AGG=$(_wd_aggregate)
IFS=: read -r AGG_KB AGG_COUNT AGG_LARGEST_PID AGG_LARGEST_KB <<< "$AGG"
AGG_MB=$(( AGG_KB / 1024 ))
AGG_LARGEST_MB=$(( AGG_LARGEST_KB / 1024 ))

# Cron mode: exit early if no Claude sessions are running.
# Avoids 1,440 empty log entries/day when Claude Code isn't up.
if [[ "$WD_MODE" == "cron" && "$AGG_COUNT" == "0" ]]; then
  exit 0
fi

# System free memory (all modes)
SYS_FREE_MB=$(_wd_system_free_mb)

# ══════════════════════════════════════════════════════════════════════
# ── Heartbeat Log (info level — always visible) ────────────────────
# ══════════════════════════════════════════════════════════════════════
peon_log info "watchdog.check" \
  "mode=$WD_MODE" \
  "ppid_rss_mb=$PPID_RSS_MB" \
  "ppid_tree_mb=$PPID_TREE_MB" \
  "agg_mb=$AGG_MB" \
  "agg_count=$AGG_COUNT" \
  "sys_free_mb=$SYS_FREE_MB"

# ══════════════════════════════════════════════════════════════════════
# ── Kill Checks (most critical first) ─────────────────────────────
# ══════════════════════════════════════════════════════════════════════

# 1. System free memory critical — machine is about to become unusable
if (( SYS_FREE_MB > 0 && SYS_FREE_MB <= WD_SYS_FREE_KILL )); then
  KILL_TARGET="${AGG_LARGEST_PID:-${CLAUDE_PID:-}}"
  if [[ -n "$KILL_TARGET" ]]; then
    KILL_TARGET_MB=$AGG_LARGEST_MB
    [[ -z "$AGG_LARGEST_PID" ]] && KILL_TARGET_MB=$PPID_TREE_MB
    peon_log warn "watchdog.system_critical" \
      "sys_free_mb=$SYS_FREE_MB" "threshold=$WD_SYS_FREE_KILL" \
      "target_pid=$KILL_TARGET" "target_mb=$KILL_TARGET_MB"
    _wd_kill "$KILL_TARGET" "$KILL_TARGET_MB" "system_free_${SYS_FREE_MB}mb"
    echo "[Watchdog] CRITICAL: System free memory ${SYS_FREE_MB}MB < ${WD_SYS_FREE_KILL}MB. Killed PID ${KILL_TARGET}."
    exit 0
  fi
fi

# 2. Aggregate kill — all Claude sessions combined exceed budget
if (( AGG_MB >= WD_TOTAL_KILL_MB )) && [[ -n "$AGG_LARGEST_PID" ]]; then
  peon_log warn "watchdog.aggregate_kill" \
    "agg_mb=$AGG_MB" "threshold=$WD_TOTAL_KILL_MB" \
    "target_pid=$AGG_LARGEST_PID" "target_mb=$AGG_LARGEST_MB"
  _wd_kill "$AGG_LARGEST_PID" "$AGG_LARGEST_MB" "aggregate_total_${AGG_MB}mb"
  echo "[Watchdog] Aggregate RSS ${AGG_MB}MB exceeds kill threshold (${WD_TOTAL_KILL_MB}MB). Killed largest session PID ${AGG_LARGEST_PID} (${AGG_LARGEST_MB}MB)."
  exit 0
fi

# 3. Per-process kill (hook mode only — checks PPID + its children)
if [[ "$WD_MODE" == "hook" ]] && (( PPID_TREE_MB >= WD_KILL_MB )); then
  peon_log warn "watchdog.process_kill" \
    "pid=$CLAUDE_PID" "tree_mb=$PPID_TREE_MB" "threshold=$WD_KILL_MB"
  _wd_kill "$CLAUDE_PID" "$PPID_TREE_MB" "process_tree_${PPID_TREE_MB}mb"
  echo "[Watchdog] Process tree RSS ${PPID_TREE_MB}MB exceeds kill threshold (${WD_KILL_MB}MB). Killed PID ${CLAUDE_PID}."
  exit 0
fi

# ══════════════════════════════════════════════════════════════════════
# ── Warn Checks ────────────────────────────────────────────────────
# ══════════════════════════════════════════════════════════════════════

WARN_REASONS=""

# System free memory low
if (( SYS_FREE_MB > 0 && SYS_FREE_MB <= WD_SYS_FREE_WARN )); then
  WARN_REASONS="system_free=${SYS_FREE_MB}MB<${WD_SYS_FREE_WARN}MB"
fi

# Aggregate warn
if (( AGG_MB >= WD_TOTAL_WARN_MB )); then
  WARN_REASONS="${WARN_REASONS:+${WARN_REASONS}; }aggregate=${AGG_MB}MB>=${WD_TOTAL_WARN_MB}MB"
fi

# Per-process warn (hook mode only)
if [[ "$WD_MODE" == "hook" ]] && (( PPID_TREE_MB >= WD_WARN_MB )); then
  WARN_REASONS="${WARN_REASONS:+${WARN_REASONS}; }process_tree=${PPID_TREE_MB}MB>=${WD_WARN_MB}MB"
fi

if [[ -n "$WARN_REASONS" ]]; then
  if _wd_warn_cooled_down; then
    peon_log warn "watchdog.warn" \
      "reasons=$WARN_REASONS" \
      "ppid_tree_mb=$PPID_TREE_MB" \
      "agg_mb=$AGG_MB" \
      "sys_free_mb=$SYS_FREE_MB"

    _wd_play_sound "$WD_WARN_SOUND"
    _wd_set_warn_cooldown

    echo "[Watchdog] Memory warning: ${WARN_REASONS}. Consider closing sessions or restarting."
  fi
fi

exit 0
