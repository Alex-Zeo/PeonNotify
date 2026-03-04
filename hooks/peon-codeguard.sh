#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════╗
# ║  peon-codeguard.sh — Code Quality Pipeline (PostToolUse hook)   ║
# ║                                                                  ║
# ║  Usage: echo '<json>' | peon-codeguard.sh                        ║
# ║  Runs lint + claude debug review on written/edited files.        ║
# ╚══════════════════════════════════════════════════════════════════╝

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source Libraries ────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/linter.sh"

# ── Initialize ──────────────────────────────────────────────────────
peon_load_config

# ── Load CodeGuard Config ──────────────────────────────────────────
_cg_get() {
  local key="$1" default="$2"
  if command -v jq &>/dev/null && [[ -f "$PEON_CONFIG_FILE" ]]; then
    local val
    val=$(jq -r ".codeguard.${key} // empty" "$PEON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && echo "$val" && return
  fi
  echo "$default"
}

CG_ENABLED=$(_cg_get "enabled" "true")
CG_LINT_ENABLED=$(_cg_get "lint_enabled" "true")
CG_DEBUG_ENABLED=$(_cg_get "claude_debug_enabled" "true")
CG_DEBUG_MODEL=$(_cg_get "claude_debug_model" "sonnet")
CG_LINT_TIMEOUT=$(_cg_get "lint_timeout_sec" "5")
CG_DEBUG_TIMEOUT=$(_cg_get "debug_timeout_sec" "20")

if [[ "$CG_ENABLED" != "true" ]]; then
  exit 0
fi

# ── Skip Extensions (loaded from config or defaults) ───────────────
_is_skip_extension() {
  local file="$1"
  local ext=".${file##*.}"
  ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

  local skip_exts
  if command -v jq &>/dev/null && [[ -f "$PEON_CONFIG_FILE" ]]; then
    skip_exts=$(jq -r '.codeguard.skip_extensions[]? // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  fi
  # Defaults if config doesn't have them
  skip_exts="${skip_exts:-.md .json .yaml .yml .toml .txt .csv .lock .svg .png .jpg .gif .ico .woff .woff2 .eot .ttf}"

  for skip in $skip_exts; do
    [[ "$ext" == "$skip" ]] && return 0
  done
  return 1
}

# ── Read Hook Input (JSON on stdin) ─────────────────────────────────
INPUT=""
if [[ ! -t 0 ]]; then
  INPUT=$(cat)
fi

if [[ -z "$INPUT" ]]; then
  exit 0
fi

# Extract file path from tool_input
_extract_file_path() {
  if command -v jq &>/dev/null; then
    echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true
  else
    echo "$INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null \
      | head -1 | sed 's/.*":\s*"//' | sed 's/"$//' || true
  fi
}

FILE_PATH=$(_extract_file_path)

if [[ -z "$FILE_PATH" ]]; then
  peon_log debug "codeguard.no_file_path" "input_length=${#INPUT}"
  exit 0
fi

# ── Guard: File must exist ──────────────────────────────────────────
if [[ ! -f "$FILE_PATH" ]]; then
  peon_log debug "codeguard.file_not_found" "file=$FILE_PATH"
  exit 0
fi

# ── Guard: Skip non-code files ─────────────────────────────────────
if _is_skip_extension "$FILE_PATH"; then
  peon_log debug "codeguard.skip_extension" "file=$FILE_PATH"
  exit 0
fi

export PEON_SESSION_ID="${PEON_SESSION_ID:-unknown}"

peon_log info "codeguard.start" "file=$FILE_PATH"

# ── Play Sound Helper ──────────────────────────────────────────────
_play_event_sound() {
  local event_key="$1"
  source "${SCRIPT_DIR}/lib/player.sh"
  local sound_file
  sound_file=$(peon_resolve_sound "$event_key")
  if [[ -n "$sound_file" ]]; then
    peon_play "$sound_file"
  fi
}

LINT_PASSED=true
DEBUG_RAN=false
HAD_ERRORS=false

# ── Step 1: Lint ───────────────────────────────────────────────────
if [[ "$CG_LINT_ENABLED" == "true" ]]; then
  LINT_OUTPUT=""
  if LINT_OUTPUT=$(peon_run_linter "$FILE_PATH" "$CG_LINT_TIMEOUT"); then
    peon_log info "codeguard.lint_pass" "file=$FILE_PATH"
  else
    LINT_PASSED=false
    HAD_ERRORS=true
    peon_log info "codeguard.lint_fail" "file=$FILE_PATH"
    echo ""
    echo "--- CodeGuard: Lint Errors ---"
    echo "$LINT_OUTPUT"
    echo "--- End Lint Errors ---"
    echo ""
  fi
fi

# ── Step 2: Claude Debug Review ─────────────────────────────────────
if [[ "$CG_DEBUG_ENABLED" == "true" && "$LINT_PASSED" == "true" ]]; then
  if command -v claude &>/dev/null; then
    peon_log info "codeguard.debug_start" "file=$FILE_PATH" "model=$CG_DEBUG_MODEL"

    FILE_CONTENT=$(cat "$FILE_PATH" 2>/dev/null || true)
    if [[ -n "$FILE_CONTENT" ]]; then
      # Resolve timeout command (macOS compat)
      _tmout=""
      if command -v timeout &>/dev/null; then
        _tmout="timeout ${CG_DEBUG_TIMEOUT}s"
      elif command -v gtimeout &>/dev/null; then
        _tmout="gtimeout ${CG_DEBUG_TIMEOUT}s"
      fi

      DEBUG_OUTPUT=""
      DEBUG_OUTPUT=$(unset CLAUDECODE; $_tmout claude -p \
        --model "$CG_DEBUG_MODEL" \
        --append-system-prompt "You are a code reviewer. Be concise. Only report actual bugs, security issues, or logic errors. If the code looks fine, say 'No issues found.' Do not suggest style changes." \
        "Review this code for bugs and issues:

$FILE_CONTENT" 2>&1) || {
        _cg_exit=$?
        if [[ $_cg_exit -eq 124 ]]; then
          peon_log warn "codeguard.debug_timeout" "file=$FILE_PATH" "timeout=${CG_DEBUG_TIMEOUT}s"
          echo "[CodeGuard] Debug review timed out after ${CG_DEBUG_TIMEOUT}s"
        else
          peon_log warn "codeguard.debug_error" "file=$FILE_PATH" "exit_code=$_cg_exit"
        fi
      }

      if [[ -n "$DEBUG_OUTPUT" ]]; then
        DEBUG_RAN=true
        # Check if the review found issues (not just "No issues found")
        if echo "$DEBUG_OUTPUT" | grep -qi "no issues found"; then
          peon_log info "codeguard.debug_clean" "file=$FILE_PATH"
        else
          HAD_ERRORS=true
          echo ""
          echo "--- CodeGuard: Debug Review ---"
          echo "$DEBUG_OUTPUT"
          echo "--- End Debug Review ---"
          echo ""
        fi
      fi
    fi
  else
    peon_log warn "codeguard.claude_not_found" "file=$FILE_PATH"
  fi
fi

# ── Step 3: Summary & Sound ────────────────────────────────────────
if [[ "$HAD_ERRORS" == "true" ]]; then
  if [[ "$LINT_PASSED" == "false" ]]; then
    _play_event_sound "codeguard_lint_fail"
  else
    _play_event_sound "codeguard_error"
  fi
else
  SUMMARY="lint passed"
  if [[ "$DEBUG_RAN" == "true" ]]; then
    SUMMARY="lint passed, debug review clean"
  fi
  echo "[CodeGuard] ${SUMMARY} - $(basename "$FILE_PATH")"
  _play_event_sound "codeguard_pass"
fi

peon_log info "codeguard.done" "file=$FILE_PATH" "lint_passed=$LINT_PASSED" "debug_ran=$DEBUG_RAN" "had_errors=$HAD_ERRORS"

exit 0
