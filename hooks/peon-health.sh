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

_pass() { echo "  ✅ $1"; ((PASS++)); }
_fail() { echo "  ❌ $1"; ((FAIL++)); }
_warn() { echo "  ⚠️  $1"; ((WARN++)); }

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
    ((FOUND++))
  else
    ((MISSING++))
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

# ── 5. Settings Integration ─────────────────────────────────────────
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
else
  _warn "No settings.local.json found at ${SETTINGS_FILE}"
fi

# ── 6. State & Logs ────────────────────────────────────────────────
echo "│"
echo "├─ State & Logs"
mkdir -p "${PEON_STATE_DIR}" "${PEON_LOG_DIR}" 2>/dev/null
_pass "State dir: ${PEON_STATE_DIR}"
_pass "Log dir: ${PEON_LOG_DIR}"

if [[ -f "${PEON_LOG_DIR}/peon.log" ]]; then
  local_lines=$(wc -l < "${PEON_LOG_DIR}/peon.log" 2>/dev/null || echo 0)
  echo "│  Log entries: ${local_lines}"
fi

# ── 7. Play Test ────────────────────────────────────────────────────
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
