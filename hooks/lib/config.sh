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
    # NOTE: $key is used in a regex pattern; works for simple alphanumeric keys
    # but keys with regex metacharacters (.+*?[]{}|^$) will break this path
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

# ── Profile Merging ────────────────────────────────────────────────
# Generates a merged config file when a non-default profile is active.
# Merge rules:
#   event_sounds  → REPLACE (missing keys = silent)
#   everything else → DEEP MERGE (jq * operator)
_peon_apply_profile() {
  command -v jq &>/dev/null || return 0
  [[ ! -f "$PEON_CONFIG_FILE" ]] && return 0

  # Determine active profile: env var overrides config key
  local profile="${PEON_PROFILE:-}"
  if [[ -z "$profile" ]]; then
    profile=$(jq -r '.active_profile // "default"' "$PEON_CONFIG_FILE" 2>/dev/null)
  fi
  profile="${profile:-default}"
  PEON_ACTIVE_PROFILE="$profile"

  [[ "$profile" == "default" ]] && return 0

  # Check profile exists
  local has_profile
  has_profile=$(jq -r --arg p "$profile" 'if .profiles[$p] then "yes" else "no" end' "$PEON_CONFIG_FILE" 2>/dev/null)
  if [[ "$has_profile" != "yes" ]]; then
    return 0
  fi

  # Generate merged config
  local merged_file="${PEON_STATE_DIR}/peon_merged_${profile}.json"
  mkdir -p "$PEON_STATE_DIR" 2>/dev/null

  if jq --arg p "$profile" '
    .profiles[$p] as $prof |
    # Deep merge base with profile (except event_sounds and meta keys)
    (del(.profiles, .active_profile)) * (($prof // {}) | del(.event_sounds)) |
    # Replace event_sounds entirely if profile defines it
    if ($prof | has("event_sounds"))
      then .event_sounds = $prof.event_sounds
      else .
    end
  ' "$PEON_CONFIG_FILE" > "$merged_file" 2>/dev/null; then
    if [[ -s "$merged_file" ]]; then
      PEON_CONFIG_FILE="$merged_file"
    else
      rm -f "$merged_file" 2>/dev/null
    fi
  else
    rm -f "$merged_file" 2>/dev/null
  fi
}

# ── Config Validation ──────────────────────────────────────────────
_peon_validate_config() {
  command -v jq &>/dev/null || return 0
  [[ ! -f "$PEON_CONFIG_FILE" ]] && return 0

  local known_keys="enabled volume mute cooldown_ms log_level log_max_lines sound_pack platform_override active_profile event_sounds event_cooldowns codeguard docguard watchdog profiles obsidian"
  local actual_keys
  actual_keys=$(jq -r 'keys[]' "$PEON_CONFIG_FILE" 2>/dev/null) || return 0

  local key
  while IFS= read -r key; do
    [[ -z "$key" ]] && continue
    local found=false
    local k
    for k in $known_keys; do
      if [[ "$key" == "$k" ]]; then
        found=true
        break
      fi
    done
    if [[ "$found" == "false" ]]; then
      echo "[peon] WARNING: unknown config key '$key' in $PEON_CONFIG_FILE" >&2
    fi
  done <<< "$actual_keys"
}

# ── State Garbage Collection ──────────────────────────────────────
_peon_gc_state() {
  [[ ! -d "$PEON_STATE_DIR" ]] && return 0
  # Delete metrics/backup/manifest files older than 7 days
  find "$PEON_STATE_DIR" -name 'codeguard_metrics_*' -mtime +7 -delete 2>/dev/null || true
  find "$PEON_STATE_DIR" -name 'docguard_backup_*' -mtime +7 -delete 2>/dev/null || true
  find "$PEON_STATE_DIR" -name 'docguard_manifest_*' -mtime +7 -delete 2>/dev/null || true
  find "$PEON_STATE_DIR" -name 'obsidian_manifest_*' -mtime +7 -delete 2>/dev/null || true
  find "$PEON_STATE_DIR" -name 'obsidian_response_*' -mtime +7 -delete 2>/dev/null || true
  find "$PEON_STATE_DIR" -name 'obsidian_*.failed' -mtime +30 -delete 2>/dev/null || true
  # Clean stale lock dirs older than 120 seconds
  find "$PEON_STATE_DIR" -maxdepth 1 -name '*.lk' -type d -mmin +2 -exec rmdir {} \; 2>/dev/null || true
}

# ── Load Configuration ──────────────────────────────────────────────
peon_load_config() {
  PEON_ACTIVE_PROFILE="default"

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

  # Read platform override BEFORE profile merge so env var is respected during merging
  PEON_PLATFORM_OVERRIDE=$(_json_get "$PEON_CONFIG_FILE" "platform_override")

  # Apply profile overrides (may redirect PEON_CONFIG_FILE to merged file)
  _peon_apply_profile

  PEON_ENABLED=$(_json_get "$PEON_CONFIG_FILE" "enabled")
  PEON_VOLUME=$(_json_get "$PEON_CONFIG_FILE" "volume")
  PEON_MUTE=$(_json_get "$PEON_CONFIG_FILE" "mute")
  PEON_COOLDOWN_MS=$(_json_get "$PEON_CONFIG_FILE" "cooldown_ms")
  PEON_LOG_LEVEL=$(_json_get "$PEON_CONFIG_FILE" "log_level")
  PEON_LOG_MAX_LINES=$(_json_get "$PEON_CONFIG_FILE" "log_max_lines")
  PEON_SOUND_PACK=$(_json_get "$PEON_CONFIG_FILE" "sound_pack")

  # Apply defaults for missing values
  PEON_ENABLED="${PEON_ENABLED:-true}"
  PEON_VOLUME="${PEON_VOLUME:-0.6}"
  PEON_MUTE="${PEON_MUTE:-false}"
  PEON_COOLDOWN_MS="${PEON_COOLDOWN_MS:-1500}"
  PEON_LOG_LEVEL="${PEON_LOG_LEVEL:-info}"
  PEON_LOG_MAX_LINES="${PEON_LOG_MAX_LINES:-5000}"
  PEON_SOUND_PACK="${PEON_SOUND_PACK:-peon}"

  PEON_PLATFORM=$(_detect_platform)

  # Validate config for unknown keys (warns to stderr)
  _peon_validate_config

  # Probabilistic garbage collection of stale state files (1 in 20 calls)
  if (( RANDOM % 20 == 0 )); then _peon_gc_state; fi
}

# ── Millisecond Timestamp (macOS compat) ──────────────────────────
_now_ms() {
  if command -v gdate &>/dev/null; then
    gdate +%s%3N
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

# ── Generic Config Accessor ────────────────────────────────────────
# Usage: peon_config_get <section> <key> [default]
# Centralizes jq lookups so subsystems don't duplicate _cg_get/_dg_get/_wd_get
peon_config_get() {
  local section="$1" key="$2" default="${3:-}"
  if command -v jq &>/dev/null && [[ -f "$PEON_CONFIG_FILE" ]]; then
    local val
    val=$(jq -r ".${section}.${key} // empty" "$PEON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && echo "$val" && return
  fi
  echo "$default"
}

# ── Timeout Command (macOS compat) ────────────────────────────────
peon_timeout_cmd() {
  if command -v timeout &>/dev/null; then
    echo "timeout"
  elif command -v gtimeout &>/dev/null; then
    echo "gtimeout"
  else
    echo ""
  fi
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
    now_ms=$(_now_ms)
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
  _now_ms > "$cf"
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
