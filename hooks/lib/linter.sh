#!/usr/bin/env bash
# lib/linter.sh - Language detection, project root discovery, and linter dispatch
# Sources: config.sh and logger.sh must be sourced first
#
# Supports: JavaScript, TypeScript, Python, Shell, Go, Ruby, Rust, SQL
# Secondary linters: mypy/pyright (Python type checking)

# ── Project Root Detection ─────────────────────────────────────────
# Walks up from a directory looking for project markers.
# Used by linters that need config files (eslint, rubocop, cargo, etc.)
_find_project_root() {
  local dir="$1"
  while [[ "$dir" != "/" && "$dir" != "." ]]; do
    for marker in package.json tsconfig.json .eslintrc .eslintrc.js .eslintrc.json .eslintrc.yml eslint.config.js eslint.config.mjs go.mod go.sum Cargo.toml Gemfile Rakefile .rubocop.yml .sqlfluff setup.py pyproject.toml .git; do
      if [[ -e "$dir/$marker" ]]; then
        echo "$dir"
        return 0
      fi
    done
    dir=$(dirname "$dir")
  done
  echo "$1"  # fallback to input directory
}

# ── Language Detection ─────────────────────────────────────────────
# Returns a language identifier from file extension.
# Data formats (json, yaml, jsonl, toml) are returned for routing to validators.
peon_detect_language() {
  local file="$1"
  local ext="${file##*.}"
  ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')

  case "$ext" in
    js|jsx|mjs|cjs)    echo "javascript" ;;
    ts|tsx|mts|cts)    echo "typescript" ;;
    py|pyw)            echo "python" ;;
    sh|bash|zsh)       echo "shell" ;;
    go)                echo "go" ;;
    rb)                echo "ruby" ;;
    rs)                echo "rust" ;;
    sql)               echo "sql" ;;
    json)              echo "json" ;;
    jsonl|ndjson)      echo "jsonl" ;;
    yaml|yml)          echo "yaml" ;;
    toml)              echo "toml" ;;
    *)                 echo "unknown" ;;
  esac
}

# ── Timeout Command (macOS compat) ─────────────────────────────────
# Exported for reuse by codeguard and other modules.
# macOS doesn't ship `timeout`; use `gtimeout` from coreutils if available.
peon_timeout_cmd() {
  if command -v timeout &>/dev/null; then
    echo "timeout"
  elif command -v gtimeout &>/dev/null; then
    echo "gtimeout"
  else
    echo ""
  fi
}

# ── Linter Resolution ─────────────────────────────────────────────
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
    sql)
      if command -v sqlfluff &>/dev/null; then
        echo "sqlfluff"
      else
        peon_log warn "linter.not_found" "lang=$lang" "linter=sqlfluff"
        echo ""
      fi
      ;;
    *)
      echo ""
      ;;
  esac
}

# ── Run Linter ─────────────────────────────────────────────────────
# peon_run_linter <file_path> <timeout_sec>
# Runs the appropriate primary linter on the file.
#
# Return codes:
#   0 = lint passed (or skipped — no linter available, unknown/data language)
#   1 = lint errors found in the code
#   2 = linter config/internal error (not a code quality issue)
#   3 = linter timed out
#
# Lint output goes to stdout.
peon_run_linter() {
  local file="$1"
  local timeout_sec="${2:-5}"

  local lang
  lang=$(peon_detect_language "$file")

  # Data files and unknowns are handled by validators, not linters
  case "$lang" in
    unknown|json|jsonl|yaml|toml)
      peon_log debug "linter.skip" "file=$file" "lang=$lang"
      return 0
      ;;
  esac

  local linter
  linter=$(_resolve_linter "$lang")

  if [[ -z "$linter" ]]; then
    return 0
  fi

  # Resolve project root for linters that need directory context
  local file_dir
  file_dir=$(dirname "$file")
  local proj_root
  proj_root=$(_find_project_root "$file_dir")

  peon_log info "linter.run" "file=$file" "lang=$lang" "linter=$linter" "project_root=$proj_root" "timeout=${timeout_sec}s"

  local lint_output=""
  local lint_exit=0
  local tmout
  tmout=$(peon_timeout_cmd)

  # Build timeout prefix (empty string if no timeout command available)
  local tpfx=""
  if [[ -n "$tmout" ]]; then
    tpfx="$tmout ${timeout_sec}s"
  fi

  case "$linter" in
    eslint)
      # Run from project root so eslint finds its config
      lint_output=$(cd "$proj_root" && $tpfx eslint --no-color --format compact "$file" 2>&1) || lint_exit=$?
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
      # go vet operates on packages, not individual files.
      lint_output=$(cd "$file_dir" && $tpfx go vet . 2>&1) || lint_exit=$?
      ;;
    rubocop)
      # Run from project root so rubocop finds .rubocop.yml
      lint_output=$(cd "$proj_root" && $tpfx rubocop --format simple "$file" 2>&1) || lint_exit=$?
      ;;
    cargo)
      # cargo clippy operates on the crate — run from Cargo.toml directory
      if [[ -f "$proj_root/Cargo.toml" ]]; then
        lint_output=$(cd "$proj_root" && $tpfx cargo clippy --quiet -- -W clippy::all 2>&1) || lint_exit=$?
      else
        peon_log warn "linter.no_cargo_toml" "file=$file" "searched=$proj_root"
        return 0
      fi
      ;;
    sqlfluff)
      # sqlfluff lint operates on individual files; run from project root for .sqlfluff config
      lint_output=$(cd "$proj_root" && $tpfx sqlfluff lint --format human "$file" 2>&1) || lint_exit=$?
      # sqlfluff exits 0=clean, 1=violations, 2+=error
      ;;
  esac

  # Timeout — distinct exit code, not a pass
  if [[ $lint_exit -eq 124 ]]; then
    peon_log warn "linter.timeout" "file=$file" "linter=$linter" "timeout=${timeout_sec}s"
    echo "[CodeGuard] Lint timed out after ${timeout_sec}s ($linter)"
    return 3
  fi

  # Config/internal errors (exit >= 2 for most linters) are not code quality issues
  if [[ $lint_exit -ge 2 ]]; then
    peon_log warn "linter.config_error" "file=$file" "linter=$linter" "exit_code=$lint_exit"
    if [[ -n "$lint_output" ]]; then
      echo "[CodeGuard] $linter configuration issue (exit $lint_exit):"
      echo "$lint_output"
    else
      echo "[CodeGuard] $linter failed with exit code $lint_exit (no output)"
    fi
    return 2
  fi

  # Lint failure with empty output — report instead of silently passing
  if [[ $lint_exit -ne 0 ]]; then
    if [[ -n "$lint_output" ]]; then
      echo "$lint_output"
    else
      echo "[CodeGuard] $linter exited with code $lint_exit (no output — possible crash)"
    fi
    return 1
  fi

  return 0
}

# ── Secondary Linter (type checkers, security scanners) ───────────
# peon_run_secondary_linter <file_path> <timeout_sec>
# Runs advisory linters — type checkers, security scanners, etc.
# These provide additional signal but failures are informational,
# not blocking.
#
# Return codes:
#   0 = passed or skipped (no secondary linter available)
#   1 = issues found (advisory)
#
# Output on stdout.
peon_run_secondary_linter() {
  local file="$1"
  local timeout_sec="${2:-10}"

  local lang
  lang=$(peon_detect_language "$file")

  local linter=""
  case "$lang" in
    python)
      if command -v mypy &>/dev/null; then
        linter="mypy"
      elif command -v pyright &>/dev/null; then
        linter="pyright"
      fi
      ;;
    *)
      # No secondary linters for other languages yet
      return 0
      ;;
  esac

  [[ -z "$linter" ]] && return 0

  local tmout
  tmout=$(peon_timeout_cmd)
  local tpfx=""
  if [[ -n "$tmout" ]]; then
    tpfx="$tmout ${timeout_sec}s"
  fi

  local output=""
  local exit_code=0

  peon_log info "linter.secondary" "file=$file" "linter=$linter" "timeout=${timeout_sec}s"

  case "$linter" in
    mypy)
      # --ignore-missing-imports: avoid noise from missing stubs
      # --no-error-summary: cleaner output for hook context
      output=$($tpfx mypy --no-error-summary --no-color-output --ignore-missing-imports "$file" 2>&1) || exit_code=$?
      ;;
    pyright)
      output=$($tpfx pyright "$file" 2>&1) || exit_code=$?
      ;;
  esac

  # Timeout — skip silently
  if [[ $exit_code -eq 124 ]]; then
    peon_log warn "linter.secondary_timeout" "file=$file" "linter=$linter" "timeout=${timeout_sec}s"
    return 0
  fi

  if [[ $exit_code -ne 0 && -n "$output" ]]; then
    echo "$output"
    return 1
  fi

  return 0
}
