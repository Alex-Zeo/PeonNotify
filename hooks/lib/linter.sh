#!/usr/bin/env bash
# lib/linter.sh - Language detection and linter dispatch
# Sources: config.sh and logger.sh must be sourced first

# ── Language Detection ─────────────────────────────────────────────
# Returns a language identifier from file extension
peon_detect_language() {
  local file="$1"
  local ext="${file##*.}"
  ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

  case "$ext" in
    js|jsx|mjs)   echo "javascript" ;;
    ts|tsx|mts)   echo "typescript" ;;
    py)           echo "python" ;;
    sh|bash)      echo "shell" ;;
    go)           echo "go" ;;
    rb)           echo "ruby" ;;
    rs)           echo "rust" ;;
    *)            echo "unknown" ;;
  esac
}

# ── Linter Resolution ─────────────────────────────────────────────
# Returns the linter command for a given language, or empty if unavailable
_resolve_linter() {
  local lang="$1"

  case "$lang" in
    javascript|typescript)
      if command -v eslint &>/dev/null; then
        echo "eslint"
      else
        peon_log warn "linter.not_found" "lang=$lang" "linter=eslint"
        echo ""
      fi
      ;;
    python)
      if command -v ruff &>/dev/null; then
        echo "ruff"
      elif command -v flake8 &>/dev/null; then
        echo "flake8"
      else
        peon_log warn "linter.not_found" "lang=$lang" "linter=ruff|flake8"
        echo ""
      fi
      ;;
    shell)
      if command -v shellcheck &>/dev/null; then
        echo "shellcheck"
      else
        peon_log warn "linter.not_found" "lang=$lang" "linter=shellcheck"
        echo ""
      fi
      ;;
    go)
      if command -v go &>/dev/null; then
        echo "go"
      else
        peon_log warn "linter.not_found" "lang=$lang" "linter=go"
        echo ""
      fi
      ;;
    ruby)
      if command -v rubocop &>/dev/null; then
        echo "rubocop"
      else
        peon_log warn "linter.not_found" "lang=$lang" "linter=rubocop"
        echo ""
      fi
      ;;
    rust)
      if command -v cargo &>/dev/null; then
        echo "cargo"
      else
        peon_log warn "linter.not_found" "lang=$lang" "linter=cargo"
        echo ""
      fi
      ;;
    *)
      echo ""
      ;;
  esac
}

# ── Timeout Command (macOS compat) ─────────────────────────────────
# macOS doesn't ship `timeout`; use `gtimeout` from coreutils if available
_timeout_cmd() {
  if command -v timeout &>/dev/null; then
    echo "timeout"
  elif command -v gtimeout &>/dev/null; then
    echo "gtimeout"
  else
    echo ""
  fi
}

# ── Run Linter ─────────────────────────────────────────────────────
# peon_run_linter <file_path> <timeout_sec>
# Runs the appropriate linter on the file. Returns:
#   0 = lint passed (or skipped)
#   1 = lint errors found
# Output (lint results) goes to stdout
peon_run_linter() {
  local file="$1"
  local timeout_sec="${2:-5}"

  local lang
  lang=$(peon_detect_language "$file")

  if [[ "$lang" == "unknown" ]]; then
    peon_log debug "linter.skip_unknown" "file=$file"
    return 0
  fi

  local linter
  linter=$(_resolve_linter "$lang")

  if [[ -z "$linter" ]]; then
    return 0
  fi

  peon_log info "linter.run" "file=$file" "lang=$lang" "linter=$linter" "timeout=${timeout_sec}s"

  local lint_output=""
  local lint_exit=0
  local tmout
  tmout=$(_timeout_cmd)

  # Build timeout prefix (empty if no timeout command available)
  local tpfx=""
  if [[ -n "$tmout" ]]; then
    tpfx="$tmout ${timeout_sec}s"
  fi

  case "$linter" in
    eslint)
      lint_output=$($tpfx eslint --no-color --format compact "$file" 2>&1) || lint_exit=$?
      ;;
    ruff)
      lint_output=$($tpfx ruff check --no-fix "$file" 2>&1) || lint_exit=$?
      ;;
    flake8)
      lint_output=$($tpfx flake8 "$file" 2>&1) || lint_exit=$?
      ;;
    shellcheck)
      lint_output=$($tpfx shellcheck -f gcc "$file" 2>&1) || lint_exit=$?
      ;;
    go)
      lint_output=$($tpfx go vet "$file" 2>&1) || lint_exit=$?
      ;;
    rubocop)
      lint_output=$($tpfx rubocop --format simple "$file" 2>&1) || lint_exit=$?
      ;;
    cargo)
      lint_output=$($tpfx cargo clippy -- -W clippy::all 2>&1) || lint_exit=$?
      ;;
  esac

  # timeout exits 124
  if [[ $lint_exit -eq 124 ]]; then
    peon_log warn "linter.timeout" "file=$file" "linter=$linter" "timeout=${timeout_sec}s"
    echo "[CodeGuard] Lint timed out after ${timeout_sec}s ($linter)"
    return 0
  fi

  if [[ $lint_exit -ne 0 && -n "$lint_output" ]]; then
    echo "$lint_output"
    return 1
  fi

  return 0
}
