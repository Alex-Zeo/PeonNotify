#!/usr/bin/env bash
# lib/config.sh - Configuration loader and platform detection
# Reads peon.json and exports shell variables for other modules

PEON_BASE_DIR="${PEON_BASE_DIR:-$HOME/.claude}"
PEON_CONFIG_FILE="${PEON_BASE_DIR}/config/peon.json"
PEON_STATE_DIR="${PEON_BASE_DIR}/state"
PEON_LOG_DIR="${PEON_BASE_DIR}/logs"
PEON_SOUNDS_DIR="${PEON_BASE_DIR}/sounds"

# ── Platform Detection ──────────────────────────────────────────────
_detect_platform() {
  if [[ -n "${PEON_PLATFORM_OVERRIDE:-}" && "$PEON_PLATFORM_OVERRIDE" != "null" ]]; then
    echo "$PEON_PLATFORM_OVERRIDE"
    return
  fi
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)
      if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "wsl"
      else
        echo "linux"
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*) echo "windows" ;;
    *) echo "unknown" ;;
  esac
}

# ── JSON Parsing (no jq dependency) ─────────────────────────────────
# Minimal JSON value extractor using grep/sed for portability
# Falls back to jq if available
_json_get() {
  local file="$1" key="$2"
  if command -v jq &>/dev/null; then
    jq -r ".$key // empty" "$file" 2>/dev/null
  else
    # Fallback: basic grep extraction for simple keys
    (grep -o "\"$key\"[[:space:]]*:[[:space:]]*[^,}]*" "$file" 2>/dev/null \
      | head -1 \
      | sed 's/.*:[[:space:]]*//' \
      | sed 's/^"//' \
      | sed 's/"$//' \
      | sed 's/[[:space:]]*$//') || true
  fi
}

# Extract a JSON array of strings as newline-delimited list
_json_get_array() {
  local file="$1" key="$2"
  if command -v jq &>/dev/null; then
    jq -r ".${key}[]? // empty" "$file" 2>/dev/null
  else
    # Fallback: extract array contents between [ and ]
    local in_array=false
    local found_key=false
    while IFS= read -r line; do
      if [[ "$line" =~ \"$key\" ]]; then
        found_key=true
        continue
      fi
      if $found_key && [[ "$line" =~ \[ ]]; then
        in_array=true
        continue
      fi
      if $in_array; then
        [[ "$line" =~ \] ]] && break
        echo "$line" | sed 's/.*"\(.*\)".*/\1/' | grep -v '^[[:space:]]*$'
      fi
    done < "$file"
  fi
}

# ── Load Configuration ──────────────────────────────────────────────
peon_load_config() {
  if [[ ! -f "$PEON_CONFIG_FILE" ]]; then
    # Defaults if no config exists
    PEON_ENABLED=true
    PEON_VOLUME=0.6
    PEON_MUTE=false
    PEON_COOLDOWN_MS=1500
    PEON_LOG_LEVEL=info
    PEON_LOG_MAX_LINES=5000
    PEON_SOUND_PACK=peon
    return 0
  fi

  PEON_ENABLED=$(_json_get "$PEON_CONFIG_FILE" "enabled")
  PEON_VOLUME=$(_json_get "$PEON_CONFIG_FILE" "volume")
  PEON_MUTE=$(_json_get "$PEON_CONFIG_FILE" "mute")
  PEON_COOLDOWN_MS=$(_json_get "$PEON_CONFIG_FILE" "cooldown_ms")
  PEON_LOG_LEVEL=$(_json_get "$PEON_CONFIG_FILE" "log_level")
  PEON_LOG_MAX_LINES=$(_json_get "$PEON_CONFIG_FILE" "log_max_lines")
  PEON_SOUND_PACK=$(_json_get "$PEON_CONFIG_FILE" "sound_pack")
  PEON_PLATFORM_OVERRIDE=$(_json_get "$PEON_CONFIG_FILE" "platform_override")

  # Apply defaults for missing values
  PEON_ENABLED="${PEON_ENABLED:-true}"
  PEON_VOLUME="${PEON_VOLUME:-0.6}"
  PEON_MUTE="${PEON_MUTE:-false}"
  PEON_COOLDOWN_MS="${PEON_COOLDOWN_MS:-1500}"
  PEON_LOG_LEVEL="${PEON_LOG_LEVEL:-info}"
  PEON_LOG_MAX_LINES="${PEON_LOG_MAX_LINES:-5000}"
  PEON_SOUND_PACK="${PEON_SOUND_PACK:-peon}"

  PEON_PLATFORM=$(_detect_platform)
}

# ── Cooldown Management ─────────────────────────────────────────────
# Uses filesystem timestamps to enforce per-event cooldowns
_cooldown_file() {
  echo "${PEON_STATE_DIR}/cooldown_${1}"
}

peon_check_cooldown() {
  local event_key="$1"
  local cooldown_ms="${2:-$PEON_COOLDOWN_MS}"

  [[ "$cooldown_ms" == "0" ]] && return 0  # No cooldown

  local cf
  cf=$(_cooldown_file "$event_key")

  if [[ -f "$cf" ]]; then
    local last_ms now_ms diff
    last_ms=$(cat "$cf" 2>/dev/null || echo 0)
    if command -v gdate &>/dev/null; then
      now_ms=$(gdate +%s%3N)
    elif date +%s%3N &>/dev/null 2>&1; then
      now_ms=$(date +%s%3N)
    else
      now_ms=$(( $(date +%s) * 1000 ))
    fi
    diff=$(( now_ms - last_ms ))
    (( diff < cooldown_ms )) && return 1
  fi
  return 0
}

peon_set_cooldown() {
  local event_key="$1"
  mkdir -p "$PEON_STATE_DIR" 2>/dev/null
  local cf
  cf=$(_cooldown_file "$event_key")
  if command -v gdate &>/dev/null; then
    gdate +%s%3N > "$cf"
  elif date +%s%3N &>/dev/null 2>&1; then
    date +%s%3N > "$cf"
  else
    echo "$(( $(date +%s) * 1000 ))" > "$cf"
  fi
}

# ── Sound File Resolution ───────────────────────────────────────────
# Returns a random sound file path for an event key, or empty if none configured
peon_resolve_sound() {
  local event_key="$1"
  local sounds_dir="${PEON_SOUNDS_DIR}/${PEON_SOUND_PACK}"

  [[ ! -f "$PEON_CONFIG_FILE" ]] && return 0

  local sounds=()
  if command -v jq &>/dev/null; then
    while IFS= read -r s; do
      [[ -n "$s" ]] && sounds+=("$s")
    done < <(jq -r ".event_sounds.\"${event_key}\"[]? // empty" "$PEON_CONFIG_FILE" 2>/dev/null)
  else
    while IFS= read -r s; do
      [[ -n "$s" ]] && sounds+=("$s")
    done < <(_json_get_array "$PEON_CONFIG_FILE" "$event_key")
  fi

  (( ${#sounds[@]} == 0 )) && return 0

  local chosen="${sounds[$((RANDOM % ${#sounds[@]}))]}"
  local full_path="${sounds_dir}/${chosen}"

  if [[ -f "$full_path" ]]; then
    echo "$full_path"
  else
    echo ""
  fi
}

# ── Event-specific Cooldown Lookup ──────────────────────────────────
peon_get_event_cooldown() {
  local event_key="$1"
  if command -v jq &>/dev/null && [[ -f "$PEON_CONFIG_FILE" ]]; then
    local val
    val=$(jq -r ".event_cooldowns.\"${event_key}\" // empty" "$PEON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && echo "$val" && return
  fi
  echo "${PEON_COOLDOWN_MS}"
}
