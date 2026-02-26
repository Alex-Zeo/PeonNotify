#!/usr/bin/env bash
# lib/player.sh - Cross-platform audio playback engine
# Sources: config.sh must be sourced first (for PEON_PLATFORM, PEON_VOLUME, PEON_MUTE)

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

# ── Playback ────────────────────────────────────────────────────────
# peon_play <file_path>
# Plays audio file asynchronously (non-blocking)
# Returns 0 on success, 1 on failure
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

  local player
  player=$(_detect_player)
  local vol="${PEON_VOLUME:-0.6}"

  case "$player" in
    afplay)
      # macOS: afplay supports -v (0.0 to 1.0 maps... afplay uses 0-255 internally but -v accepts float)
      afplay -v "$vol" "$file" &>/dev/null &
      ;;
    paplay)
      # PulseAudio: volume is 0-65536, map 0.0-1.0 -> 0-65536
      local pa_vol
      pa_vol=$(awk "BEGIN { printf \"%d\", $vol * 65536 }")
      paplay --volume="$pa_vol" "$file" &>/dev/null &
      ;;
    aplay)
      # ALSA: no native volume control, play as-is
      aplay -q "$file" &>/dev/null &
      ;;
    mpv)
      local mpv_vol
      mpv_vol=$(awk "BEGIN { printf \"%d\", $vol * 100 }")
      mpv --no-terminal --no-video --volume="$mpv_vol" "$file" &>/dev/null &
      ;;
    ffplay)
      local ff_vol
      ff_vol=$(awk "BEGIN { printf \"%d\", $vol * 100 }")
      ffplay -nodisp -autoexit -volume "$ff_vol" "$file" &>/dev/null &
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
      " &>/dev/null &
      ;;
    none)
      peon_log warn "player.no_player" "platform=${PEON_PLATFORM}"
      return 1
      ;;
  esac

  # Disown the background process so the hook can exit immediately
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
