#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════╗
# ║  peon-codeguard.sh — Code Quality Pipeline (PostToolUse hook)   ║
# ║                                                                  ║
# ║  Usage: echo '<json>' | peon-codeguard.sh                        ║
# ║                                                                  ║
# ║  Two paths:                                                      ║
# ║    Code files  → lint + optional claude debug review             ║
# ║    Data files  → syntax validation (JSON, YAML, TOML)           ║
# ║                                                                  ║
# ║  Audit fixes applied: W1–W26 (see CLAUDE.md for full list)      ║
# ╚══════════════════════════════════════════════════════════════════╝

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source Libraries ────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/linter.sh"
source "${SCRIPT_DIR}/lib/validators.sh"

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
CG_VALIDATE_DATA=$(_cg_get "validate_data_files" "true")
CG_DEBUG_ENABLED=$(_cg_get "claude_debug_enabled" "true")
CG_DEBUG_MODEL=$(_cg_get "claude_debug_model" "sonnet")
CG_LINT_TIMEOUT=$(_cg_get "lint_timeout_sec" "5")
CG_DEBUG_TIMEOUT=$(_cg_get "debug_timeout_sec" "20")
CG_MAX_FILE_KB=$(_cg_get "max_file_size_kb" "500")
CG_BLOCKING=$(_cg_get "blocking_mode" "false")
CG_DEDUP=$(_cg_get "dedup_enabled" "true")
CG_REVIEW_PROMPT=$(_cg_get "review_prompt" "")
CG_SECONDARY_LINT=$(_cg_get "secondary_lint_enabled" "false")

if [[ "$CG_ENABLED" != "true" ]]; then
  exit 0
fi

# ── Skip Directories (W11) ────────────────────────────────────────
_is_skip_directory() {
  local file="$1"
  local skip_dirs=""
  if command -v jq &>/dev/null && [[ -f "$PEON_CONFIG_FILE" ]]; then
    skip_dirs=$(jq -r '.codeguard.skip_directories[]? // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  fi
  skip_dirs="${skip_dirs:-node_modules vendor dist build .git __pycache__ .next coverage .tox .mypy_cache target .venv venv}"

  for dir in $skip_dirs; do
    if [[ "$file" == *"/$dir/"* ]]; then
      return 0
    fi
  done
  return 1
}

# ── Skip Extensions ───────────────────────────────────────────────
# W10/W12: Removed .json/.yaml/.yml from skip list — they now route
# to validators instead. Added .min.js, .min.css, .map, .bundle.js.
_is_skip_extension() {
  local file="$1"
  local basename_lower
  basename_lower=$(basename "$file" | tr '[:upper:]' '[:lower:]')
  local ext=".${file##*.}"
  ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

  # W12: Skip minified/bundle/map files by name pattern
  case "$basename_lower" in
    *.min.js|*.min.css|*.bundle.js|*.bundle.css|*.chunk.js)
      return 0 ;;
  esac

  local skip_exts
  if command -v jq &>/dev/null && [[ -f "$PEON_CONFIG_FILE" ]]; then
    skip_exts=$(jq -r '.codeguard.skip_extensions[]? // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  fi
  # Note: .json, .yaml, .yml deliberately removed — handled by validators
  skip_exts="${skip_exts:-.md .txt .csv .lock .svg .png .jpg .jpeg .gif .ico .woff .woff2 .eot .ttf .map .d.ts}"

  for skip in $skip_exts; do
    [[ "$ext" == "$skip" ]] && return 0
  done
  return 1
}

# ── Data File Detection (W10) ─────────────────────────────────────
_is_data_file() {
  local file="$1"
  local ext=".${file##*.}"
  ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

  local validate_exts=""
  if command -v jq &>/dev/null && [[ -f "$PEON_CONFIG_FILE" ]]; then
    validate_exts=$(jq -r '.codeguard.validate_extensions[]? // empty' "$PEON_CONFIG_FILE" 2>/dev/null)
  fi
  validate_exts="${validate_exts:-.json .yaml .yml .toml}"

  for vext in $validate_exts; do
    [[ "$ext" == "$vext" ]] && return 0
  done
  return 1
}

# ── Content Hash Deduplication (W16) ──────────────────────────────
_content_hash() {
  if command -v md5sum &>/dev/null; then
    md5sum "$1" 2>/dev/null | cut -d' ' -f1
  elif command -v md5 &>/dev/null; then
    md5 -q "$1" 2>/dev/null
  else
    echo ""
  fi
}

_dedup_check() {
  local file="$1"
  [[ "$CG_DEDUP" != "true" ]] && return 1  # dedup disabled, proceed

  local hash
  hash=$(_content_hash "$file")
  [[ -z "$hash" ]] && return 1  # can't hash, proceed

  local state_dir="${PEON_STATE_DIR:-$HOME/.claude/state}"
  local hash_file="${state_dir}/codeguard_hashes"
  mkdir -p "$state_dir" 2>/dev/null

  # Use base filename + size as key (avoids issues with path chars)
  local file_key
  file_key="$(basename "$file")_$(wc -c < "$file" 2>/dev/null | tr -d ' ')"

  if [[ -f "$hash_file" ]]; then
    local stored
    stored=$(grep "^${file_key}=" "$hash_file" 2>/dev/null | tail -1 | cut -d= -f2-)
    if [[ "$stored" == "$hash" ]]; then
      return 0  # same content, skip
    fi
  fi

  # Update hash — remove old entry, append new
  if [[ -f "$hash_file" ]]; then
    grep -v "^${file_key}=" "$hash_file" > "${hash_file}.tmp" 2>/dev/null || true
    mv "${hash_file}.tmp" "$hash_file" 2>/dev/null || true
  fi
  echo "${file_key}=${hash}" >> "$hash_file"

  # Prune hash file if it grows too large (keep last 200 entries)
  if [[ -f "$hash_file" ]]; then
    local line_count
    line_count=$(wc -l < "$hash_file" 2>/dev/null | tr -d ' ')
    if (( line_count > 200 )); then
      tail -n 100 "$hash_file" > "${hash_file}.tmp" 2>/dev/null
      mv "${hash_file}.tmp" "$hash_file" 2>/dev/null || true
    fi
  fi

  return 1  # hash differs (or new), proceed
}

# ── Millisecond Timestamp (macOS compat) ──────────────────────────
_now_ms() {
  if command -v gdate &>/dev/null; then
    gdate +%s%3N
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

# ── Language-Specific Review Prompts ───────────────────────────────
# Deep, data-engineering-informed checklists per language.
# The sentinel NO_ISSUES_FOUND is used for reliable output parsing.
_review_prompt_for() {
  local lang="$1"

  # If custom prompt is configured, use it
  if [[ -n "$CG_REVIEW_PROMPT" && "$CG_REVIEW_PROMPT" != "null" ]]; then
    echo "$CG_REVIEW_PROMPT"
    return
  fi

  local base="You are a senior code reviewer. Be concise — report only actual bugs, security issues, or logic errors. Skip style/formatting. If the code looks correct, respond with exactly: NO_ISSUES_FOUND"

  case "$lang" in
    python)
      echo "${base}

Check for:
- Mutable default arguments (def f(x=[]) — shared across calls)
- Unclosed resources: file handles, DB connections, sockets without context managers (with)
- SQL injection via string formatting/concatenation in queries (must use parameterized queries)
- f-string errors: mismatched braces, format spec on wrong type
- Type confusion: str/bytes mixing, comparing to None with == instead of is
- Exception anti-patterns: bare except, catching Exception without re-raise, swallowing errors
- open() without explicit encoding parameter (platform-dependent default encoding)
- Division by zero potential, especially in aggregation/averaging/normalization logic
- pandas: chained indexing (df[col][row]), SettingWithCopyWarning patterns, inplace=True in chains
- Unsafe deserialization: pickle.load, yaml.load (use yaml.safe_load), eval/exec on user data
- os.system or subprocess with shell=True and unsanitized input
- Import side effects at module level that break testability"
      ;;
    javascript|typescript)
      echo "${base}

Check for:
- Missing await on async function calls (floating promises — silent failures)
- Unhandled promise rejections: .then() without .catch(), no try/catch around await
- Prototype pollution via unchecked object merge/spread from external input
- XSS vectors: innerHTML, dangerouslySetInnerHTML, unsanitized user input in DOM
- Null/undefined access without optional chaining where the value may be absent
- Closure variable capture with var in for loops (use let)
- Memory leaks: addEventListener without removeEventListener, setInterval without clearInterval
- parseInt without radix parameter (parseInt('08') gotcha)
- == instead of === (especially comparisons involving null, undefined, 0, '')
- JSON.parse on untrusted input without try/catch
- Regex catastrophic backtracking (ReDoS) on user-supplied patterns
- Array mutation gotchas: sort() mutates in place, splice vs slice confusion"
      ;;
    shell)
      echo "${base}

Check for:
- Unquoted variable expansions (\$var instead of \"\$var\") — word splitting and glob expansion
- Command injection via eval, backticks, or unquoted \$(cmd) with external input
- TOCTOU races: test -f then operate on file (another process can modify between)
- Missing error handling: commands that can fail silently without || exit, set -e, or explicit checks
- Pipes without set -o pipefail (intermediate failures are hidden)
- Using [ ] instead of [[ ]] for string comparisons (word splitting, glob expansion inside [ ])
- Arithmetic with (( expr )) that evaluates to 0 — kills script under set -e
- Temporary files created without mktemp (predictable names = symlink attacks)
- Missing cleanup traps for temp files on EXIT/INT/TERM
- cd without || exit (if cd fails, subsequent commands run in wrong directory)
- Heredoc/variable expansion leaking secrets into logs or process table"
      ;;
    go)
      echo "${base}

Check for:
- Unchecked error returns (especially Close, Write, Scan, Rows.Err)
- Goroutine leaks: goroutines that can block forever on a channel or lock
- Race conditions: shared state accessed from multiple goroutines without sync
- Nil pointer dereference: especially after type assertion without comma-ok check
- Deferred Close on a value that may be nil (defer f.Close() before nil check)
- Context cancellation not propagated to downstream calls
- Slice append gotcha: appending to a sub-slice may modify the backing array
- String concatenation in loops (use strings.Builder)
- sql.Rows not closed (deferred Close must happen after error check on Query)
- HTTP response body not closed"
      ;;
    rust)
      echo "${base}

Check for:
- unsafe blocks: verify that safety invariants are actually upheld
- .unwrap() / .expect() on Result/Option in non-test production code
- Potential deadlocks: multiple Mutex locks without consistent ordering
- Integer overflow: debug panics but release wraps silently — use checked_ or saturating_ ops
- Unintended Clone on large structures (expensive copies hidden behind .clone())
- Lifetime issues that compile but may surface with different usage patterns
- Lock poisoning: Mutex::lock().unwrap() will panic if another thread panicked while holding the lock"
      ;;
    ruby)
      echo "${base}

Check for:
- SQL injection: string interpolation in ActiveRecord where() / find_by_sql()
- Mass assignment: params.permit missing required restrictions
- Open redirects: redirect_to with user-controlled input
- Unsafe deserialization: YAML.load (use YAML.safe_load), Marshal.load on untrusted data
- method_missing without corresponding respond_to_missing?
- N+1 queries: .each with nested queries — missing includes/preload/eager_load
- Mutable default values in method signatures"
      ;;
    sql)
      echo "${base}

Check for:
- Missing WHERE clause on UPDATE or DELETE statements (full-table modification)
- Cartesian joins: missing JOIN condition or inadvertent CROSS JOIN
- SELECT * in application/production code (fragile to schema changes, wastes bandwidth)
- SQL injection patterns: string concatenation for values instead of bind parameters
- Non-sargable WHERE clauses: functions wrapping indexed columns (WHERE UPPER(name) = ...)
- NULL handling: = NULL instead of IS NULL, NOT IN with nullable subquery (returns no rows)
- Implicit type conversions in comparisons that prevent index use
- Missing transaction boundaries for multi-statement operations that must be atomic
- ORDER BY on large result sets without LIMIT (unbounded memory)
- Correlated subqueries that could be rewritten as JOINs for performance"
      ;;
    *)
      echo "${base}"
      ;;
  esac
}

# ── Read Hook Input (JSON on stdin) ─────────────────────────────────
# W9: Limit stdin read to 64KB to prevent memory issues
_CG_INPUT=""
if [[ ! -t 0 ]]; then
  _CG_INPUT=$(head -c 65536)
fi

if [[ -z "$_CG_INPUT" ]]; then
  exit 0
fi

# Extract file path from tool_input
_extract_file_path() {
  if command -v jq &>/dev/null; then
    echo "$_CG_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true
  else
    echo "$_CG_INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null \
      | head -1 | sed 's/.*":\s*"//' | sed 's/"$//' || true
  fi
}

# Extract tool name (Write vs Edit)
_extract_tool_name() {
  if command -v jq &>/dev/null; then
    echo "$_CG_INPUT" | jq -r '.tool_name // empty' 2>/dev/null || true
  else
    echo "$_CG_INPUT" | grep -o '"tool_name"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null \
      | head -1 | sed 's/.*":\s*"//' | sed 's/"$//' || true
  fi
}

FILE_PATH=$(_extract_file_path)
TOOL_NAME=$(_extract_tool_name)

if [[ -z "$FILE_PATH" ]]; then
  peon_log debug "codeguard.no_file_path" "input_length=${#_CG_INPUT}"
  exit 0
fi

# ── Guard: File must exist ──────────────────────────────────────────
if [[ ! -f "$FILE_PATH" ]]; then
  peon_log debug "codeguard.file_not_found" "file=$FILE_PATH"
  exit 0
fi

# ── Guard: Skip vendor/generated directories (W11) ────────────────
if _is_skip_directory "$FILE_PATH"; then
  peon_log debug "codeguard.skip_directory" "file=$FILE_PATH"
  exit 0
fi

# ── Route: Data file or code file? (W10) ──────────────────────────
_CG_IS_DATA=false
if _is_data_file "$FILE_PATH"; then
  _CG_IS_DATA=true
elif _is_skip_extension "$FILE_PATH"; then
  peon_log debug "codeguard.skip_extension" "file=$FILE_PATH"
  exit 0
fi

# ── Guard: File size limit (W7/W8) ────────────────────────────────
_CG_FILE_SIZE_KB=0
if [[ "$(uname -s)" == "Darwin" ]]; then
  _CG_FILE_SIZE_KB=$(( $(stat -f %z "$FILE_PATH" 2>/dev/null || echo 0) / 1024 ))
else
  _CG_FILE_SIZE_KB=$(( $(stat -c %s "$FILE_PATH" 2>/dev/null || echo 0) / 1024 ))
fi
if (( _CG_FILE_SIZE_KB > CG_MAX_FILE_KB )); then
  peon_log info "codeguard.skip_large_file" "file=$FILE_PATH" "size_kb=$_CG_FILE_SIZE_KB" "max_kb=$CG_MAX_FILE_KB"
  exit 0
fi

# ── Guard: Deduplication (W16) ─────────────────────────────────────
if _dedup_check "$FILE_PATH"; then
  peon_log debug "codeguard.dedup_skip" "file=$FILE_PATH"
  exit 0
fi

export PEON_SESSION_ID="${PEON_SESSION_ID:-unknown}"

# ── Timing Start (W17) ────────────────────────────────────────────
_CG_START_MS=$(_now_ms)

peon_log info "codeguard.start" "file=$FILE_PATH" "tool=$TOOL_NAME" "is_data=$_CG_IS_DATA" "size_kb=$_CG_FILE_SIZE_KB"

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
LINT_RESULT=0
DEBUG_RAN=false
HAD_ERRORS=false
VALIDATE_PASSED=true

# ══════════════════════════════════════════════════════════════════
# PATH A: Data File Validation — JSON, YAML, TOML (W10/W25)
# ══════════════════════════════════════════════════════════════════
if [[ "$_CG_IS_DATA" == "true" ]]; then
  if [[ "$CG_VALIDATE_DATA" == "true" ]]; then
    VALIDATE_OUTPUT=""
    if VALIDATE_OUTPUT=$(peon_validate_data "$FILE_PATH"); then
      peon_log info "codeguard.validate_pass" "file=$FILE_PATH"
      echo "[CodeGuard] valid - $(basename "$FILE_PATH")"
      _play_event_sound "codeguard_pass"
    else
      VALIDATE_PASSED=false
      HAD_ERRORS=true
      peon_log info "codeguard.validate_fail" "file=$FILE_PATH"
      echo ""
      echo "--- CodeGuard: Syntax Errors ---"
      echo "$VALIDATE_OUTPUT"
      echo "--- End Syntax Errors ---"
      echo ""
      _play_event_sound "codeguard_lint_fail"
    fi
  fi

# ══════════════════════════════════════════════════════════════════
# PATH B: Code File — Lint + Debug Review
# ══════════════════════════════════════════════════════════════════
else
  # ── Step 1: Lint ─────────────────────────────────────────────────
  if [[ "$CG_LINT_ENABLED" == "true" ]]; then
    LINT_OUTPUT=""
    LINT_OUTPUT=$(peon_run_linter "$FILE_PATH" "$CG_LINT_TIMEOUT") && LINT_RESULT=0 || LINT_RESULT=$?

    case $LINT_RESULT in
      0)
        peon_log info "codeguard.lint_pass" "file=$FILE_PATH"
        ;;
      1)
        # Actual lint errors in the code
        LINT_PASSED=false
        HAD_ERRORS=true
        peon_log info "codeguard.lint_fail" "file=$FILE_PATH"
        echo ""
        echo "--- CodeGuard: Lint Errors ---"
        echo "$LINT_OUTPUT"
        echo "--- End Lint Errors ---"
        echo ""
        ;;
      2)
        # W6: Config/internal error — log and report, but don't block debug review
        peon_log warn "codeguard.lint_config_error" "file=$FILE_PATH"
        echo ""
        echo "--- CodeGuard: Linter Configuration Issue ---"
        echo "$LINT_OUTPUT"
        echo "(This is a tooling issue, not a code quality problem)"
        echo "--- End Linter Issue ---"
        echo ""
        # LINT_PASSED stays true — config errors shouldn't prevent debug review
        ;;
      3)
        # W5: Timeout — warn but don't claim "passed"
        peon_log warn "codeguard.lint_timeout" "file=$FILE_PATH"
        echo "$LINT_OUTPUT"
        # LINT_PASSED stays true so debug review can still run
        ;;
    esac
  fi

  # ── Step 1.5: Secondary Lint — type checkers (advisory) ──────────
  if [[ "$CG_SECONDARY_LINT" == "true" && "$LINT_PASSED" == "true" ]]; then
    SECONDARY_OUTPUT=""
    if SECONDARY_OUTPUT=$(peon_run_secondary_linter "$FILE_PATH" "$CG_LINT_TIMEOUT"); then
      peon_log info "codeguard.secondary_pass" "file=$FILE_PATH"
    else
      peon_log info "codeguard.secondary_issues" "file=$FILE_PATH"
      echo ""
      echo "--- CodeGuard: Type Check (advisory) ---"
      echo "$SECONDARY_OUTPUT"
      echo "--- End Type Check ---"
      echo ""
      # Advisory only — does NOT set HAD_ERRORS or block debug review
    fi
  fi

  # ── Step 2: Claude Debug Review ──────────────────────────────────
  if [[ "$CG_DEBUG_ENABLED" == "true" && "$LINT_PASSED" == "true" ]]; then
    if command -v claude &>/dev/null; then
      _CG_LANG=$(peon_detect_language "$FILE_PATH")
      _CG_REVIEW_PROMPT=$(_review_prompt_for "$_CG_LANG")

      peon_log info "codeguard.debug_start" "file=$FILE_PATH" "model=$CG_DEBUG_MODEL" "lang=$_CG_LANG"

      # W8: Use a temp file to avoid ARG_MAX limits on large files
      _CG_PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/codeguard_prompt.XXXXXX")
      trap 'rm -f "$_CG_PROMPT_FILE" 2>/dev/null' EXIT

      {
        echo "Review this code for bugs and issues:"
        echo ""
        cat "$FILE_PATH" 2>/dev/null || true
      } > "$_CG_PROMPT_FILE"

      # W18: Reuse peon_timeout_cmd from linter.sh instead of duplicating
      _CG_TMOUT=$(peon_timeout_cmd)
      _CG_TPFX=""
      if [[ -n "$_CG_TMOUT" ]]; then
        _CG_TPFX="$_CG_TMOUT ${CG_DEBUG_TIMEOUT}s"
      fi

      DEBUG_OUTPUT=""
      DEBUG_OUTPUT=$(unset CLAUDECODE; $_CG_TPFX claude -p \
        --model "$CG_DEBUG_MODEL" \
        --append-system-prompt "$_CG_REVIEW_PROMPT" \
        "$(cat "$_CG_PROMPT_FILE")" 2>&1) || {
        _cg_exit=$?
        if [[ $_cg_exit -eq 124 ]]; then
          peon_log warn "codeguard.debug_timeout" "file=$FILE_PATH" "timeout=${CG_DEBUG_TIMEOUT}s"
          echo "[CodeGuard] Debug review timed out after ${CG_DEBUG_TIMEOUT}s"
        else
          peon_log warn "codeguard.debug_error" "file=$FILE_PATH" "exit_code=$_cg_exit"
        fi
      }

      rm -f "$_CG_PROMPT_FILE" 2>/dev/null
      trap - EXIT

      if [[ -n "$DEBUG_OUTPUT" ]]; then
        DEBUG_RAN=true
        # W13: Use exact sentinel instead of fragile grep heuristic.
        # The system prompt instructs the model to respond with "NO_ISSUES_FOUND".
        if [[ "$DEBUG_OUTPUT" == *"NO_ISSUES_FOUND"* ]]; then
          peon_log info "codeguard.debug_clean" "file=$FILE_PATH"
        else
          HAD_ERRORS=true
          # W15: Persist debug output in structured log for audit trail
          peon_log info "codeguard.debug_issues" "file=$FILE_PATH" "output_length=${#DEBUG_OUTPUT}"
          echo ""
          echo "--- CodeGuard: Debug Review ---"
          echo "$DEBUG_OUTPUT"
          echo "--- End Debug Review ---"
          echo ""
        fi
      fi
    else
      peon_log warn "codeguard.claude_not_found" "file=$FILE_PATH"
    fi
  fi
fi

# ── Timing End (W17) ──────────────────────────────────────────────
_CG_END_MS=$(_now_ms)
_CG_DURATION_MS=0
if [[ "$_CG_START_MS" != "0" && "$_CG_END_MS" != "0" ]]; then
  _CG_DURATION_MS=$(( _CG_END_MS - _CG_START_MS ))
fi

# ── Summary & Sound ──────────────────────────────────────────────
if [[ "$_CG_IS_DATA" != "true" ]]; then
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
    echo "[CodeGuard] ${SUMMARY} - $(basename "$FILE_PATH") (${_CG_DURATION_MS}ms)"
    _play_event_sound "codeguard_pass"
  fi
fi

# ── Session Metrics (W22) ─────────────────────────────────────────
# Append to per-session metrics file for aggregate tracking
_CG_METRICS_FILE="${PEON_STATE_DIR:-$HOME/.claude/state}/codeguard_metrics_${PEON_SESSION_ID}"
{
  echo "{\"file\":\"$(basename "$FILE_PATH")\",\"is_data\":$_CG_IS_DATA,\"lint_passed\":$LINT_PASSED,\"lint_result\":$LINT_RESULT,\"debug_ran\":$DEBUG_RAN,\"had_errors\":$HAD_ERRORS,\"validate_passed\":$VALIDATE_PASSED,\"duration_ms\":$_CG_DURATION_MS,\"ts\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}"
} >> "$_CG_METRICS_FILE" 2>/dev/null || true

peon_log info "codeguard.done" \
  "file=$FILE_PATH" \
  "lint_passed=$LINT_PASSED" \
  "lint_result=$LINT_RESULT" \
  "debug_ran=$DEBUG_RAN" \
  "had_errors=$HAD_ERRORS" \
  "is_data=$_CG_IS_DATA" \
  "validate_passed=$VALIDATE_PASSED" \
  "duration_ms=$_CG_DURATION_MS"

# ── Exit Code (W21) ──────────────────────────────────────────────
# In blocking mode, a non-zero exit tells Claude Code to stop and fix.
if [[ "$CG_BLOCKING" == "true" && "$HAD_ERRORS" == "true" ]]; then
  exit 1
fi

exit 0
