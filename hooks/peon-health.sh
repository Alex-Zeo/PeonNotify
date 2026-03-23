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

# ── 6. Settings Integration ─────────────────────────────────────────
echo "│"
echo "├─ Claude Code Integration"
SETTINGS_FILE="${HOME}/.claude/settings.local.json"
if [[ -f "$SETTINGS_FILE" ]]; then
  _pass "settings.local.json exists"
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

# ── 7. State & Logs ────────────────────────────────────────────────
echo "│"
echo "├─ State & Logs"
mkdir -p "${PEON_STATE_DIR}" "${PEON_LOG_DIR}" 2>/dev/null
_pass "State dir: ${PEON_STATE_DIR}"
_pass "Log dir: ${PEON_LOG_DIR}"

if [[ -f "${PEON_LOG_DIR}/peon.log" ]]; then
  local_lines=$(wc -l < "${PEON_LOG_DIR}/peon.log" 2>/dev/null || echo 0)
  echo "│  Log entries: ${local_lines}"
fi

# ── 8. Play Test ────────────────────────────────────────────────────
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
