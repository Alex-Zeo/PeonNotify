#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════╗
# ║  peon-docguard.sh — Documentation Maintenance Hook              ║
# ║                                                                  ║
# ║  Accumulate+Flush architecture:                                  ║
# ║    PostToolUse  → append to session manifest (~1ms, no AI)       ║
# ║    Stop         → score, generate, apply docs (one AI call)      ║
# ║                                                                  ║
# ║  Manual usage:                                                   ║
# ║    peon-docguard.sh --flush      Flush all pending manifests     ║
# ║    peon-docguard.sh --dry-run    Preview without writing         ║
# ║                                                                  ║
# ║  Targets: CHANGELOG.md, CLAUDE.md, README.md, memory/MEMORY.md  ║
# ╚══════════════════════════════════════════════════════════════════╝

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source Libraries ────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/docguard.sh"

# ── Initialize ──────────────────────────────────────────────────────
peon_load_config

# ── Check Enabled ──────────────────────────────────────────────────
_dg_get() {
  local key="$1" default="$2"
  if command -v jq &>/dev/null && [[ -f "$PEON_CONFIG_FILE" ]]; then
    local val
    val=$(jq -r ".docguard.${key} // empty" "$PEON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && echo "$val" && return
  fi
  echo "$default"
}

DG_ENABLED=$(_dg_get "enabled" "false")

# ── Manual Invocation (--flush / --dry-run) ────────────────────────
# Handle flags BEFORE reading stdin to avoid blocking on terminal input
if [[ "${1:-}" == "--flush" || "${1:-}" == "--dry-run" ]]; then
  DRY_RUN="false"
  [[ "${1:-}" == "--dry-run" ]] && DRY_RUN="true"

  # Allow manual flush even if docguard is disabled (for stale manifests)
  local_state="${PEON_STATE_DIR:-$HOME/.claude/state}"
  found_any=false
  for manifest in "${local_state}"/docguard_manifest_*; do
    [[ ! -f "$manifest" ]] && continue
    found_any=true
    # Extract session_id from filename for logging
    local_sid="${manifest##*_manifest_}"
    export PEON_SESSION_ID="${local_sid}"
    echo "[DocGuard] Processing manifest: $(basename "$manifest")"
    docguard_flush "$manifest" "$DRY_RUN"
  done
  if [[ "$found_any" == "false" ]]; then
    echo "[DocGuard] No pending manifests found."
  fi
  exit 0
fi

# ── Normal hook flow requires enabled ──────────────────────────────
if [[ "$DG_ENABLED" != "true" ]]; then
  exit 0
fi

# ── Read Hook Input (JSON on stdin) ────────────────────────────────
_DG_INPUT=""
if [[ ! -t 0 ]]; then
  _DG_INPUT=$(head -c 65536)
fi

[[ -z "$_DG_INPUT" ]] && exit 0

# ── Extract Fields ─────────────────────────────────────────────────
_dg_field() {
  local key="$1"
  if command -v jq &>/dev/null; then
    echo "$_DG_INPUT" | jq -r ".$key // empty" 2>/dev/null || true
  else
    echo "$_DG_INPUT" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null \
      | head -1 | sed 's/.*":\s*"//' | sed 's/"$//' || true
  fi
}

_dg_extract_file_path() {
  if command -v jq &>/dev/null; then
    echo "$_DG_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true
  else
    echo "$_DG_INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null \
      | head -1 | sed 's/.*":\s*"//' | sed 's/"$//' || true
  fi
}

HOOK_EVENT=$(_dg_field "hook_event_name")
SESSION_ID=$(_dg_field "session_id")
TOOL_NAME=$(_dg_field "tool_name")

export PEON_SESSION_ID="${SESSION_ID:-unknown}"

# ── Route by Event ─────────────────────────────────────────────────
case "$HOOK_EVENT" in

  PostToolUse)
    FILE_PATH=$(_dg_extract_file_path)
    [[ -z "$FILE_PATH" ]] && exit 0
    docguard_accumulate "$FILE_PATH" "$TOOL_NAME"
    ;;

  Stop|SessionEnd)
    MANIFEST=$(_docguard_manifest_path)
    docguard_flush "$MANIFEST" "false"

    # Play completion sound
    source "${SCRIPT_DIR}/lib/player.sh" 2>/dev/null || true
    SOUND=$(peon_resolve_sound "codeguard_pass" 2>/dev/null || true)
    [[ -n "${SOUND:-}" ]] && peon_play "$SOUND" 2>/dev/null || true
    ;;

  SessionStart)
    # W2: Check for stale manifests from crashed sessions
    docguard_check_stale
    ;;

  *)
    exit 0
    ;;
esac

exit 0
