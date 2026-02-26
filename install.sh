#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════╗
# ║  install.sh — Peon Notification System Installer                ║
# ║                                                                  ║
# ║  Usage: ./install.sh [--skip-sounds] [--dry-run]                 ║
# ║  Idempotent: safe to run multiple times.                         ║
# ╚══════════════════════════════════════════════════════════════════╝

INSTALLER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="$HOME/.claude"
SKIP_SOUNDS=false
DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --skip-sounds) SKIP_SOUNDS=true ;;
    --dry-run)     DRY_RUN=true ;;
    --help|-h)
      echo "Usage: ./install.sh [--skip-sounds] [--dry-run]"
      echo "  --skip-sounds  Skip sound file download (use your own)"
      echo "  --dry-run      Show what would be done without doing it"
      exit 0
      ;;
  esac
done

_log() { echo "  → $1"; }
_ok()  { echo "  ✅ $1"; }
_skip(){ echo "  ⏭️  $1 (already exists)"; }

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║   Peon Notification System — Installer   ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── 1. Create Directory Structure ───────────────────────────────────
echo "┌─ Creating directories..."

DIRS=(
  "${TARGET_DIR}/hooks/lib"
  "${TARGET_DIR}/config"
  "${TARGET_DIR}/sounds/peon"
  "${TARGET_DIR}/logs"
  "${TARGET_DIR}/state"
)

for dir in "${DIRS[@]}"; do
  if [[ -d "$dir" ]]; then
    _skip "$dir"
  else
    $DRY_RUN && _log "[dry-run] mkdir -p $dir" || mkdir -p "$dir"
    _ok "$dir"
  fi
done

# ── 2. Copy Hook Scripts ────────────────────────────────────────────
echo "│"
echo "├─ Installing hook scripts..."

copy_if_newer() {
  local src="$1" dst="$2"
  if [[ ! -f "$dst" ]] || [[ "$src" -nt "$dst" ]]; then
    if $DRY_RUN; then
      _log "[dry-run] cp $src → $dst"
    else
      cp "$src" "$dst"
      _ok "$(basename "$dst")"
    fi
  else
    _skip "$(basename "$dst")"
  fi
}

copy_if_newer "${INSTALLER_DIR}/hooks/peon-dispatch.sh"   "${TARGET_DIR}/hooks/peon-dispatch.sh"
copy_if_newer "${INSTALLER_DIR}/hooks/peon-health.sh"     "${TARGET_DIR}/hooks/peon-health.sh"
copy_if_newer "${INSTALLER_DIR}/hooks/lib/config.sh"      "${TARGET_DIR}/hooks/lib/config.sh"
copy_if_newer "${INSTALLER_DIR}/hooks/lib/logger.sh"      "${TARGET_DIR}/hooks/lib/logger.sh"
copy_if_newer "${INSTALLER_DIR}/hooks/lib/player.sh"      "${TARGET_DIR}/hooks/lib/player.sh"

# Set executable permissions
chmod +x "${TARGET_DIR}/hooks/peon-dispatch.sh" 2>/dev/null || true
chmod +x "${TARGET_DIR}/hooks/peon-health.sh" 2>/dev/null || true

# ── 3. Install Config (preserve existing) ───────────────────────────
echo "│"
echo "├─ Installing configuration..."

if [[ -f "${TARGET_DIR}/config/peon.json" ]]; then
  _skip "config/peon.json (preserving your settings)"
else
  if $DRY_RUN; then
    _log "[dry-run] cp config/peon.json"
  else
    cp "${INSTALLER_DIR}/config/peon.json" "${TARGET_DIR}/config/peon.json"
    _ok "config/peon.json"
  fi
fi

# ── 4. Download Sound Files ─────────────────────────────────────────
echo "│"
echo "├─ Sound files..."

SOUNDS_TARGET="${TARGET_DIR}/sounds/peon"

# Expected sound files (all referenced in config)
SOUND_FILES=(
  "ready_to_work.mp3"
  "okie_dokey.mp3"
  "zug_zug.mp3"
  "work_work.mp3"
  "ill_try.mp3"
  "be_happy_to.mp3"
  "something_need_doing.mp3"
  "hmmm.mp3"
  "yes_what.mp3"
  "me_busy.mp3"
  "leave_me_alone.mp3"
  "jobs_done.mp3"
  "work_complete.mp3"
  "more_gold_required.mp3"
  "never_mind.mp3"
)

if $SKIP_SOUNDS; then
  _log "Skipping sound downloads (--skip-sounds)"
  _log "Place your .mp3 files in: ${SOUNDS_TARGET}/"
  _log "Expected files:"
  for sf in "${SOUND_FILES[@]}"; do
    if [[ -f "${SOUNDS_TARGET}/${sf}" ]]; then
      _skip "$sf"
    else
      echo "│       └─ ❓ ${sf} (missing)"
    fi
  done
else
  _log "Checking for sound files..."
  MISSING_COUNT=0
  for sf in "${SOUND_FILES[@]}"; do
    if [[ -f "${SOUNDS_TARGET}/${sf}" ]]; then
      _skip "$sf"
    else
      (( ++MISSING_COUNT ))
    fi
  done

  if (( MISSING_COUNT > 0 )); then
    echo "│"
    echo "│  ⚠️  ${MISSING_COUNT} sound files need to be added manually."
    echo "│"
    echo "│  Sound files cannot be auto-downloaded due to licensing."
    echo "│  To get authentic WC3 Peon sounds:"
    echo "│"
    echo "│  Option A — Extract from game files:"
    echo "│    1. Use CascView or CASC Explorer on your WC3 install"
    echo "│    2. Navigate to Sound/Orc/Peon/ in the archives"
    echo "│    3. Export .wav files, convert with:"
    echo "│       for f in *.wav; do ffmpeg -i \"\$f\" -q:a 5 \"\${f%.wav}.mp3\"; done"
    echo "│    4. Rename to match: $(echo "${SOUND_FILES[*]}" | tr ' ' ', ')"
    echo "│"
    echo "│  Option B — Use soundboard sites:"
    echo "│    • 101soundboards.com/boards/warcraft-iii-orc-peon"
    echo "│    • myinstants.com (search 'warcraft peon')"
    echo "│    • Download and save as the filenames listed above"
    echo "│"
    echo "│  Option C — Generate placeholder sounds:"
    echo "│    If you have 'say' (macOS) or 'espeak' (Linux):"
    echo "│"
    cat << 'PLACEHOLDER_SCRIPT'
│    #!/bin/bash
│    SOUNDS_DIR="$HOME/.claude/sounds/peon"
│    declare -A QUOTES=(
│      [ready_to_work]="Ready to work"
│      [okie_dokey]="Okie dokey"
│      [zug_zug]="Zug zug"
│      [work_work]="Work work"
│      [ill_try]="I will try"
│      [be_happy_to]="Be happy to"
│      [something_need_doing]="Something need doing?"
│      [hmmm]="Hmmm?"
│      [yes_what]="Yes? What?"
│      [me_busy]="Me busy. Leave me alone."
│      [leave_me_alone]="Leave me alone!"
│      [jobs_done]="Jobs done!"
│      [work_complete]="Work complete"
│      [more_gold_required]="More gold is required"
│      [never_mind]="Never mind"
│    )
│    for name in "${!QUOTES[@]}"; do
│      if command -v say &>/dev/null; then
│        say -v Fred -o "/tmp/${name}.aiff" "${QUOTES[$name]}"
│        ffmpeg -i "/tmp/${name}.aiff" "$SOUNDS_DIR/${name}.mp3" -y 2>/dev/null
│      elif command -v espeak &>/dev/null; then
│        espeak "${QUOTES[$name]}" --stdout | ffmpeg -i - "$SOUNDS_DIR/${name}.mp3" -y 2>/dev/null
│      fi
│    done
PLACEHOLDER_SCRIPT
    echo "│"
    echo "│  Target directory: ${SOUNDS_TARGET}/"
  fi
fi

# ── 5. Wire Hooks into Claude Code ──────────────────────────────────
echo "│"
echo "├─ Wiring Claude Code hooks..."

SETTINGS_FILE="${HOME}/.claude/settings.local.json"

if [[ -f "$SETTINGS_FILE" ]]; then
  if grep -q "peon-dispatch" "$SETTINGS_FILE" 2>/dev/null; then
    _skip "settings.local.json already has peon hooks"
  else
    _log "⚠️  settings.local.json exists but has no peon hooks."
    _log "You have two options:"
    _log "  1. Merge manually from: ${INSTALLER_DIR}/settings.local.json"
    _log "  2. Back up and replace:"
    _log "     cp ${SETTINGS_FILE} ${SETTINGS_FILE}.backup"
    _log "     cp ${INSTALLER_DIR}/settings.local.json ${SETTINGS_FILE}"
  fi
else
  if $DRY_RUN; then
    _log "[dry-run] sed '\$HOME' → '${HOME}' in settings.local.json → $SETTINGS_FILE"
  else
    sed 's|\$HOME|'"${HOME}"'|g' "${INSTALLER_DIR}/settings.local.json" > "$SETTINGS_FILE"
    _ok "settings.local.json installed (paths expanded)"
  fi
fi

# ── 6. Verify ───────────────────────────────────────────────────────
echo "│"
echo "└─ Running health check..."
echo ""

if ! $DRY_RUN; then
  bash "${TARGET_DIR}/hooks/peon-health.sh" || true
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Installation complete!"
echo ""
echo "  Next steps:"
echo "  1. Add sound files to ~/.claude/sounds/peon/"
echo "  2. Restart Claude Code or run /hooks to verify"
echo "  3. Test: ~/.claude/hooks/peon-health.sh --play-test"
echo ""
echo "  Config:  ~/.claude/config/peon.json"
echo "  Logs:    ~/.claude/logs/peon.log"
echo "  Mute:    Set \"mute\": true in config"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
