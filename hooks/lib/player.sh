#!/usr/bin/env bash
# lib/player.sh - Cross-platform audio playback engine with queue
# Sources: config.sh must be sourced first (for PEON_PLATFORM, PEON_VOLUME, PEON_MUTE)
#
# Sounds are enqueued to a file and played sequentially by a single
# background drainer process, preventing overlapping audio.

PEON_QUEUE_FILE="${PEON_STATE_DIR:-$HOME/.claude/state}/sound_queue"
PEON_QUEUE_LOCK="${PEON_STATE_DIR:-$HOME/.claude/state}/sound_queue.lk"
PEON_PLAYER_LOCK="${PEON_STATE_DIR:-$HOME/.claude/state}/sound_player.lk"

# M11: Cache detected player to avoid re-detection on every play call
_PEON_CACHED_PLAYER=""

# ── Player Detection ────────────────────────────────────────────────
_detect_player() {
  case "${PEON_PLATFORM}" in
    macos)
      echo "afplay"
      ;;
    linux)
      if command -v paplay &>/dev/null; then
        echo "paplay"
      elif command -v aplay &>/dev/null; then
        echo "aplay"
      elif command -v mpv &>/dev/null; then
        echo "mpv"
      elif command -v ffplay &>/dev/null; then
        echo "ffplay"
      else
        echo "none"
      fi
      ;;
    wsl)
      if command -v powershell.exe &>/dev/null; then
        echo "powershell"
      elif command -v mpv &>/dev/null; then
        echo "mpv"
      else
        echo "none"
      fi
      ;;
    windows)
      echo "powershell"
      ;;
    *)
      echo "none"
      ;;
  esac
}

# ── Synchronous Playback (single file) ─────────────────────────────
# Blocks until the sound finishes playing
_peon_play_sync() {
  local file="$1"
  [[ ! -f "$file" ]] && return 0

  # M11: Cache detected player across calls
  if [[ -z "$_PEON_CACHED_PLAYER" ]]; then
    _PEON_CACHED_PLAYER=$(_detect_player)
  fi
  local player="$_PEON_CACHED_PLAYER"
  local vol="${PEON_VOLUME:-0.6}"

  case "$player" in
    afplay)
      afplay -v "$vol" "$file" &>/dev/null
      ;;
    paplay)
      local pa_vol
      pa_vol=$(awk "BEGIN { printf \"%d\", $vol * 65536 }")
      paplay --volume="$pa_vol" "$file" &>/dev/null
      ;;
    aplay)
      aplay -q "$file" &>/dev/null
      ;;
    mpv)
      local mpv_vol
      mpv_vol=$(awk "BEGIN { printf \"%d\", $vol * 100 }")
      mpv --no-terminal --no-video --volume="$mpv_vol" "$file" &>/dev/null
      ;;
    ffplay)
      local ff_vol
      ff_vol=$(awk "BEGIN { printf \"%d\", $vol * 100 }")
      ffplay -nodisp -autoexit -volume "$ff_vol" "$file" &>/dev/null
      ;;
    powershell)
      local win_path
      if [[ "$PEON_PLATFORM" == "wsl" ]]; then
        win_path=$(wslpath -w "$file" 2>/dev/null || echo "$file")
      else
        win_path="$file"
      fi
      powershell.exe -NoProfile -Command "
        \$player = New-Object System.Media.SoundPlayer('$win_path');
        \$player.PlaySync()
      " &>/dev/null
      ;;
    none)
      return 1
      ;;
  esac
}

# ── Queue: atomic append ───────────────────────────────────────────
# Uses mkdir as a cross-platform atomic lock
_peon_enqueue() {
  local file="$1"
  mkdir -p "$(dirname "$PEON_QUEUE_FILE")" 2>/dev/null

  # Acquire write lock (retry briefly)
  local retries=0
  while ! mkdir "$PEON_QUEUE_LOCK" 2>/dev/null; do
    retries=$((retries + 1))
    (( retries > 20 )) && break
    sleep 0.05
  done

  echo "$file" >> "$PEON_QUEUE_FILE"
  rmdir "$PEON_QUEUE_LOCK" 2>/dev/null
}

# ── Queue: drain and play sequentially ─────────────────────────────
# Only one drainer runs at a time (player lock). Plays each queued
# sound synchronously, then loops to catch anything enqueued during
# playback. Exits when queue is empty.
_peon_drain_queue() {
  # Clean stale player lock (older than 60s = stuck/crashed)
  if [[ -d "$PEON_PLAYER_LOCK" ]]; then
    local lock_age=0
    if [[ "$(uname -s)" == "Darwin" ]]; then
      lock_age=$(( $(date +%s) - $(stat -f %m "$PEON_PLAYER_LOCK" 2>/dev/null || echo 0) ))
    else
      lock_age=$(( $(date +%s) - $(stat -c %Y "$PEON_PLAYER_LOCK" 2>/dev/null || echo 0) ))
    fi
    if (( lock_age > 60 )); then
      rmdir "$PEON_PLAYER_LOCK" 2>/dev/null
    fi
  fi

  # Try to become the drainer (non-blocking)
  mkdir "$PEON_PLAYER_LOCK" 2>/dev/null || return 0

  # Ensure lock is released on exit
  # H8: Catch HUP/TERM/INT to prevent stranded lock on signals
  trap 'rmdir "$PEON_PLAYER_LOCK" 2>/dev/null' EXIT HUP TERM INT

  while true; do
    # M9: Refresh lock mtime so stale detector (60s) doesn't break active drainer
    touch "$PEON_PLAYER_LOCK" 2>/dev/null || true

    # Atomically grab queue contents
    local items=""
    local got_lock=false

    local retries=0
    while ! mkdir "$PEON_QUEUE_LOCK" 2>/dev/null; do
      retries=$((retries + 1))
      (( retries > 20 )) && break
      sleep 0.05
    done

    if [[ -f "$PEON_QUEUE_FILE" ]] && [[ -s "$PEON_QUEUE_FILE" ]]; then
      items=$(cat "$PEON_QUEUE_FILE")
      : > "$PEON_QUEUE_FILE"
    fi
    rmdir "$PEON_QUEUE_LOCK" 2>/dev/null

    # Nothing left — done
    [[ -z "$items" ]] && break

    # M10: Cap queue to prevent burst of old sounds (keep last 10)
    local _max_queue=10
    items=$(echo "$items" | tail -n "$_max_queue")

    # Play each sound in order
    while IFS= read -r sound_file; do
      [[ -z "$sound_file" ]] && continue
      _peon_play_sync "$sound_file"
    done <<< "$items"
  done

  rmdir "$PEON_PLAYER_LOCK" 2>/dev/null
  trap - EXIT HUP TERM INT
}

# ── Public API ─────────────────────────────────────────────────────
# peon_play <file_path>
# Enqueues a sound and spawns a background drainer if needed.
# Returns immediately (non-blocking for the hook).
peon_play() {
  local file="$1"

  # Guard: muted or disabled
  [[ "$PEON_MUTE" == "true" ]] && return 0
  [[ "$PEON_ENABLED" != "true" ]] && return 0

  # Guard: file must exist
  if [[ ! -f "$file" ]]; then
    peon_log warn "player.file_missing" "path=$file"
    return 1
  fi

  _peon_enqueue "$file"

  # Spawn background drainer — if one is already running, it exits immediately
  _peon_drain_queue &
  disown 2>/dev/null
  return 0
}

# ── Player Health Check ─────────────────────────────────────────────
peon_player_check() {
  local player
  player=$(_detect_player)
  if [[ "$player" == "none" ]]; then
    echo "FAIL: No audio player found for platform '${PEON_PLATFORM}'"
    return 1
  fi
  echo "OK: player=$player platform=${PEON_PLATFORM}"
  return 0
}
