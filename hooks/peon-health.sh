#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════╗
# ║  peon-health.sh — Diagnostic & Health Check                     ║
# ║                                                                  ║
# ║  Usage: peon-health.sh [--fix] [--play-test]                     ║
# ║  Validates config, sounds, player, and hook wiring.              ║
# ╚══════════════════════════════════════════════════════════════════╝

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/player.sh"

peon_load_config

PASS=0
FAIL=0
WARN=0

_pass() { echo "  ✅ $1"; PASS=$((PASS + 1)); }
_fail() { echo "  ❌ $1"; FAIL=$((FAIL + 1)); }
_warn() { echo "  ⚠️  $1"; WARN=$((WARN + 1)); }

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   Peon Notification System Health Check  ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── 1. Platform & Player ────────────────────────────────────────────
echo "┌─ Platform & Audio"
echo "│  Platform: ${PEON_PLATFORM}"
PLAYER_STATUS=$(peon_player_check)
if [[ $? -eq 0 ]]; then
  _pass "$PLAYER_STATUS"
else
  _fail "$PLAYER_STATUS"
fi

# ── 2. Configuration ────────────────────────────────────────────────
echo "│"
echo "├─ Configuration"
if [[ -f "$PEON_CONFIG_FILE" ]]; then
  _pass "Config file exists: ${PEON_CONFIG_FILE}"
else
  _fail "Config file missing: ${PEON_CONFIG_FILE}"
fi

echo "│  Enabled:  ${PEON_ENABLED}"
echo "│  Volume:   ${PEON_VOLUME}"
echo "│  Mute:     ${PEON_MUTE}"
echo "│  Cooldown: ${PEON_COOLDOWN_MS}ms"
echo "│  Pack:     ${PEON_SOUND_PACK}"
echo "│  Profile:  ${PEON_ACTIVE_PROFILE:-default}"
if [[ "${PEON_ACTIVE_PROFILE:-default}" != "default" ]]; then
  if [[ "$PEON_CONFIG_FILE" == *"peon_merged_"* ]]; then
    _pass "Profile '${PEON_ACTIVE_PROFILE}' merged config active"
  else
    _warn "Profile '${PEON_ACTIVE_PROFILE}' set but merge did not apply"
  fi
fi

if command -v jq &>/dev/null; then
  _pass "jq available (recommended)"
else
  _warn "jq not found — using grep fallback (install jq for reliability)"
fi

# ── 3. Sound Files ──────────────────────────────────────────────────
echo "│"
echo "├─ Sound Files"
SOUNDS_DIR="${PEON_SOUNDS_DIR}/${PEON_SOUND_PACK}"

if [[ -d "$SOUNDS_DIR" ]]; then
  _pass "Sound directory exists: ${SOUNDS_DIR}"
else
  _fail "Sound directory missing: ${SOUNDS_DIR}"
fi

# Collect all referenced sound files from config
EXPECTED_SOUNDS=()
if command -v jq &>/dev/null && [[ -f "$PEON_CONFIG_FILE" ]]; then
  while IFS= read -r s; do
    [[ -n "$s" ]] && EXPECTED_SOUNDS+=("$s")
  done < <(jq -r '.event_sounds | to_entries[] | .value[]' "$PEON_CONFIG_FILE" 2>/dev/null | sort -u)
fi

FOUND=0
MISSING=0
MISSING_FILES=()
for sound in "${EXPECTED_SOUNDS[@]}"; do
  if [[ -f "${SOUNDS_DIR}/${sound}" ]]; then
    FOUND=$((FOUND + 1))
  else
    MISSING=$((MISSING + 1))
    MISSING_FILES+=("$sound")
  fi
done

if (( FOUND > 0 )); then
  _pass "${FOUND} sound files found"
fi
if (( MISSING > 0 )); then
  _warn "${MISSING} sound files missing:"
  for mf in "${MISSING_FILES[@]}"; do
    echo "│       └─ ${mf}"
  done
fi

# ── 4. Hook Scripts ─────────────────────────────────────────────────
echo "│"
echo "├─ Hook Scripts"
DISPATCH="${SCRIPT_DIR}/peon-dispatch.sh"
if [[ -x "$DISPATCH" ]]; then
  _pass "Dispatcher is executable"
else
  _fail "Dispatcher not executable: ${DISPATCH}"
  if [[ "${1:-}" == "--fix" ]]; then
    chmod +x "$DISPATCH"
    echo "│       └─ Fixed: chmod +x applied"
  fi
fi

# ── 5. CodeGuard Pipeline ──────────────────────────────────────────
echo "│"
echo "├─ CodeGuard Pipeline"
CODEGUARD="${SCRIPT_DIR}/peon-codeguard.sh"
if [[ -x "$CODEGUARD" ]]; then
  _pass "CodeGuard script is executable"
else
  if [[ -f "$CODEGUARD" ]]; then
    _fail "CodeGuard script not executable: ${CODEGUARD}"
    if [[ "${1:-}" == "--fix" ]]; then
      chmod +x "$CODEGUARD"
      echo "│       └─ Fixed: chmod +x applied"
    fi
  else
    _warn "CodeGuard script not found: ${CODEGUARD}"
  fi
fi

# Check codeguard config
if command -v jq &>/dev/null && [[ -f "$PEON_CONFIG_FILE" ]]; then
  CG_ENABLED=$(jq -r '.codeguard.enabled // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  if [[ "$CG_ENABLED" == "true" ]]; then
    _pass "CodeGuard enabled in config"
  elif [[ "$CG_ENABLED" == "false" ]]; then
    _warn "CodeGuard disabled in config"
  else
    _warn "CodeGuard config section missing from peon.json"
  fi
fi

# Check available linters
echo "│  Available linters:"
for linter_cmd in eslint ruff flake8 shellcheck go rubocop cargo; do
  if command -v "$linter_cmd" &>/dev/null; then
    echo "│    ✅ $linter_cmd"
  else
    echo "│    ⬚  $linter_cmd (not installed)"
  fi
done

# Check validators module
VALIDATORS="${SCRIPT_DIR}/lib/validators.sh"
if [[ -f "$VALIDATORS" ]]; then
  _pass "Validators module present (lib/validators.sh)"
else
  _warn "Validators module missing — data file validation disabled"
fi

# Check validator dependencies
echo "│  Data file validators:"
if command -v jq &>/dev/null; then
  echo "│    ✅ jq (JSON validation)"
else
  echo "│    ⬚  jq (JSON validation — will try python3 fallback)"
fi
if command -v python3 &>/dev/null; then
  echo "│    ✅ python3 (JSON/YAML/TOML validation)"
  if python3 -c "import yaml" 2>/dev/null; then
    echo "│    ✅ PyYAML (YAML validation)"
  else
    echo "│    ⬚  PyYAML (pip install pyyaml for YAML validation)"
  fi
else
  echo "│    ⬚  python3 (needed for YAML/TOML validation)"
fi

# Check codeguard features
if command -v jq &>/dev/null && [[ -f "$PEON_CONFIG_FILE" ]]; then
  CG_VALIDATE=$(jq -r '.codeguard.validate_data_files // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  CG_DEDUP=$(jq -r '.codeguard.dedup_enabled // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  CG_BLOCKING=$(jq -r '.codeguard.blocking_mode // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  CG_MAX_KB=$(jq -r '.codeguard.max_file_size_kb // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  echo "│  Features: validate_data=${CG_VALIDATE:-off} dedup=${CG_DEDUP:-off} blocking=${CG_BLOCKING:-off} max_file=${CG_MAX_KB:-500}KB"
fi

# Check dedup state
DEDUP_FILE="${PEON_STATE_DIR}/codeguard_hashes"
if [[ -f "$DEDUP_FILE" ]]; then
  local_entries=$(wc -l < "$DEDUP_FILE" 2>/dev/null | tr -d ' ')
  echo "│  Dedup cache: ${local_entries} entries"
fi

# Check claude CLI for debug review
if command -v claude &>/dev/null; then
  _pass "claude CLI available (for debug review)"
else
  _warn "claude CLI not found — debug review will be skipped"
fi

# ── 6. Memory Watchdog ─────────────────────────────────────────────
echo "│"
echo "├─ Memory Watchdog"
WATCHDOG="${SCRIPT_DIR}/peon-watchdog.sh"
if [[ -x "$WATCHDOG" ]]; then
  _pass "Watchdog script is executable"
else
  if [[ -f "$WATCHDOG" ]]; then
    _fail "Watchdog script not executable: ${WATCHDOG}"
    if [[ "${1:-}" == "--fix" ]]; then
      chmod +x "$WATCHDOG"
      echo "│       └─ Fixed: chmod +x applied"
    fi
  else
    _warn "Watchdog script not found: ${WATCHDOG}"
  fi
fi

if command -v jq &>/dev/null && [[ -f "$PEON_CONFIG_FILE" ]]; then
  WD_ENABLED=$(jq -r '.watchdog.enabled // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  WD_WARN=$(jq -r '.watchdog.warn_mb // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  WD_KILL=$(jq -r '.watchdog.kill_mb // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  WD_TOTAL_WARN=$(jq -r '.watchdog.total_warn_mb // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  WD_TOTAL_KILL=$(jq -r '.watchdog.total_kill_mb // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  WD_SYS_WARN=$(jq -r '.watchdog.system_free_mb_warn // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  WD_SYS_KILL=$(jq -r '.watchdog.system_free_mb_kill // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  WD_CHILDREN=$(jq -r '.watchdog.include_children // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  WD_RESTART=$(jq -r '.watchdog.auto_restart // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  if [[ "$WD_ENABLED" == "true" ]]; then
    _pass "Watchdog enabled"
    echo "│  Per-process:  warn=${WD_WARN:-500}MB  kill=${WD_KILL:-800}MB"
    echo "│  Aggregate:    warn=${WD_TOTAL_WARN:-1500}MB  kill=${WD_TOTAL_KILL:-2500}MB"
    echo "│  System free:  warn=${WD_SYS_WARN:-512}MB  kill=${WD_SYS_KILL:-256}MB"
    echo "│  Children:     ${WD_CHILDREN:-true}  auto_restart: ${WD_RESTART:-true}"
  elif [[ "$WD_ENABLED" == "false" ]]; then
    _warn "Watchdog disabled in config"
  else
    _warn "Watchdog config section missing from peon.json"
  fi
fi

# Show system memory overview
if [[ "$(uname -s)" == "Darwin" ]]; then
  SYS_TOTAL=$(( $(sysctl -n hw.memsize 2>/dev/null || echo 0) / 1024 / 1024 ))
  PAGE_SIZE=$(sysctl -n hw.pagesize 2>/dev/null || echo 16384)
  VMSTAT=$(vm_stat 2>/dev/null || true)
  FREE_P=$(echo "$VMSTAT" | awk '/Pages free/ {gsub(/\./,"",$3); print $3}')
  INACTIVE_P=$(echo "$VMSTAT" | awk '/Pages inactive/ {gsub(/\./,"",$3); print $3}')
  SYS_FREE=$(( (${FREE_P:-0} + ${INACTIVE_P:-0}) * PAGE_SIZE / 1024 / 1024 ))
  echo "│  System RAM:   ${SYS_TOTAL}MB total, ${SYS_FREE}MB available (free+inactive)"
fi

# Show current Claude Code memory (aggregate + per-process)
if command -v pgrep &>/dev/null; then
  CLAUDE_PIDS=$(pgrep -x claude 2>/dev/null || true)
  if [[ -n "$CLAUDE_PIDS" ]]; then
    AGG_RSS=0
    SESSION_COUNT=0
    echo "│  Claude sessions:"
    while IFS= read -r cpid; do
      [[ -z "$cpid" ]] && continue
      CRSS=$(ps -o rss= -p "$cpid" 2>/dev/null | tr -d ' ' || true)
      if [[ -n "$CRSS" ]]; then
        CRSS_MB=$(( CRSS / 1024 ))
        AGG_RSS=$(( AGG_RSS + CRSS ))
        SESSION_COUNT=$(( SESSION_COUNT + 1 ))
        echo "│    PID ${cpid}: ${CRSS_MB}MB RSS"
      fi
    done <<< "$CLAUDE_PIDS"
    AGG_MB=$(( AGG_RSS / 1024 ))
    echo "│  Aggregate:    ${AGG_MB}MB across ${SESSION_COUNT} sessions"
  else
    echo "│  No Claude sessions running"
  fi
fi

if grep -q "peon-watchdog" "${HOME}/.claude/settings.local.json" 2>/dev/null; then
  _pass "Hooks reference peon-watchdog.sh"
else
  _warn "settings.local.json does not reference peon-watchdog.sh"
fi

# Check watchdog cron plist (periodic monitoring)
if [[ "$(uname -s)" == "Darwin" ]]; then
  if launchctl list com.peonnotify.watchdog-cron &>/dev/null; then
    _pass "Watchdog cron loaded (every 60s)"
  else
    _warn "Watchdog cron not loaded — periodic monitoring disabled. Run install.sh."
  fi
fi

# Show recent watchdog log activity
if [[ -f "${PEON_LOG_DIR}/peon.log" ]]; then
  WD_LOG_COUNT=$(grep -c '"watchdog\.' "${PEON_LOG_DIR}/peon.log" 2>/dev/null || echo 0)
  WD_WARN_COUNT=$(grep -c '"watchdog\.warn\|"watchdog\.kill\|"watchdog\.system_critical\|"watchdog\.aggregate_kill\|"watchdog\.process_kill' "${PEON_LOG_DIR}/peon.log" 2>/dev/null || echo 0)
  echo "│  Log activity: ${WD_LOG_COUNT} total events, ${WD_WARN_COUNT} warnings/kills"
  if (( WD_LOG_COUNT == 0 )); then
    _warn "Zero watchdog events in log — watchdog may not be firing"
  else
    _pass "Watchdog events present in log"
  fi
fi

# ── N. Obsidian Integration ──────────────────────────────────────
echo "│"
echo "├─ Obsidian Integration"
OBSIDIAN_HOOK="${SCRIPT_DIR}/peon-obsidian.sh"
if [[ -x "$OBSIDIAN_HOOK" ]]; then
  _pass "Obsidian hook script is executable"
else
  if [[ -f "$OBSIDIAN_HOOK" ]]; then
    _fail "Obsidian hook not executable: ${OBSIDIAN_HOOK}"
  else
    _warn "Obsidian hook not found: ${OBSIDIAN_HOOK}"
  fi
fi

if command -v jq &>/dev/null && [[ -f "$PEON_CONFIG_FILE" ]]; then
  OBS_ENABLED=$(jq -r '.obsidian.enabled // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  OBS_VAULT=$(jq -r '.obsidian.vault_path // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  OBS_VAULT="${OBS_VAULT/#\~/$HOME}"
  if [[ "$OBS_ENABLED" == "true" ]]; then
    _pass "Obsidian enabled"
    if [[ -d "$OBS_VAULT" ]]; then
      _pass "Vault found: ${OBS_VAULT}"
      # Count notes
      note_count=0
      note_count=$(find "$OBS_VAULT" -name '*.md' -not -path '*/.obsidian/*' 2>/dev/null | wc -l | tr -d ' ')
      echo "│  Vault notes: ${note_count}"
      # Last daily note
      last_daily=""
      last_daily=$(ls -1 "${OBS_VAULT}/daily/" 2>/dev/null | sort | tail -1 || true)
      [[ -n "$last_daily" ]] && echo "│  Last daily note: ${last_daily}"
    else
      _warn "Vault not found at ${OBS_VAULT}"
    fi
  elif [[ "$OBS_ENABLED" == "false" ]]; then
    _warn "Obsidian disabled in config (set obsidian.enabled=true to activate)"
  else
    _warn "Obsidian config section missing from peon.json"
  fi
fi

# Check launchd plist
if [[ "$(uname -s)" == "Darwin" ]]; then
  if launchctl list com.peonnotify.obsidian-cron &>/dev/null; then
    _pass "Cron job loaded (daily 9am)"
  else
    _warn "Cron job not loaded (run install.sh to set up)"
  fi
fi

if grep -q "peon-obsidian" "${HOME}/.claude/settings.local.json" 2>/dev/null; then
  _pass "Hooks reference peon-obsidian.sh"
else
  _warn "settings.local.json does not reference peon-obsidian.sh"
fi

# ── 7. Settings Integration ─────────────────────────────────────────
echo "│"
echo "├─ Claude Code Integration"
SETTINGS_FILE="${HOME}/.claude/settings.local.json"
if [[ -f "$SETTINGS_FILE" ]]; then
  _pass "settings.local.json exists"
  if grep -q '\$HOME' "$SETTINGS_FILE" 2>/dev/null; then
    _warn "settings.local.json contains literal \$HOME — hooks will not fire. Run install.sh to fix."
  fi
  if grep -q "peon-dispatch" "$SETTINGS_FILE" 2>/dev/null; then
    _pass "Hooks reference peon-dispatch.sh"
  else
    _warn "settings.local.json does not reference peon-dispatch.sh"
  fi
  if grep -q "peon-codeguard" "$SETTINGS_FILE" 2>/dev/null; then
    _pass "Hooks reference peon-codeguard.sh"
  else
    _warn "settings.local.json does not reference peon-codeguard.sh"
  fi
else
  _warn "No settings.local.json found at ${SETTINGS_FILE}"
fi

# ── 8. State & Logs ────────────────────────────────────────────────
echo "│"
echo "├─ State & Logs"
mkdir -p "${PEON_STATE_DIR}" "${PEON_LOG_DIR}" 2>/dev/null
_pass "State dir: ${PEON_STATE_DIR}"
_pass "Log dir: ${PEON_LOG_DIR}"

if [[ -f "${PEON_LOG_DIR}/peon.log" ]]; then
  local_lines=$(wc -l < "${PEON_LOG_DIR}/peon.log" 2>/dev/null || echo 0)
  echo "│  Log entries: ${local_lines}"
fi

# ── 9. Play Test ────────────────────────────────────────────────────
if [[ "${1:-}" == "--play-test" ]]; then
  echo "│"
  echo "├─ Playback Test"
  TEST_SOUND=$(peon_resolve_sound "stop")
  if [[ -n "$TEST_SOUND" ]]; then
    echo "│  Playing: $(basename "$TEST_SOUND")..."
    peon_play "$TEST_SOUND"
    _pass "Playback initiated"
  else
    _fail "No 'stop' sound resolved for test"
  fi
fi

# ── Summary ─────────────────────────────────────────────────────────
echo "│"
echo "└─ Summary: ${PASS} passed, ${FAIL} failed, ${WARN} warnings"
echo ""

if (( FAIL > 0 )); then
  echo "Run with --fix to attempt auto-repair, or --play-test to verify audio."
  exit 1
fi

exit 0
