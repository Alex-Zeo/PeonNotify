#!/usr/bin/env bash
# lib/docguard.sh - Documentation maintenance library
# Accumulate+Flush architecture for maintaining CHANGELOG, CLAUDE.md, MEMORY.md
#
# Sources: config.sh and logger.sh must be sourced first
#
# Design: PostToolUse appends to a session manifest (fast, no AI).
#         Stop/SessionEnd flushes: scores significance, calls claude -p ONCE,
#         applies updates. One AI call per session, not per file.
#
# Audit hardening: W1-W27 (see CLAUDE.md for full weakness/mitigation table)

# ── Config Helper ──────────────────────────────────────────────────
_dg_target() {
  local key="$1" default="$2"
  if command -v jq &>/dev/null && [[ -f "${PEON_CONFIG_FILE:-}" ]]; then
    local val
    val=$(jq -r ".docguard.${key} // empty" "$PEON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && echo "$val" && return
  fi
  echo "$default"
}

# ── Timeout Command (macOS compat) ─────────────────────────────────
_docguard_timeout_cmd() {
  if command -v timeout &>/dev/null; then
    echo "timeout"
  elif command -v gtimeout &>/dev/null; then
    echo "gtimeout"
  else
    echo ""
  fi
}

# ── File Locking (multi-session safety) ────────────────────────────
# Serializes read-modify-write on shared doc files across concurrent sessions.
# Uses flock if available (Linux, Homebrew coreutils), falls back to mkdir lock.
_docguard_lock_file() {
  local target="$1"
  echo "${PEON_STATE_DIR:-$HOME/.claude/state}/docguard_write_$(echo "$target" | tr '/' '_').lk"
}

_docguard_acquire_lock() {
  local lockfile="$1"
  local max_wait="${2:-10}"  # seconds

  if command -v flock &>/dev/null; then
    # flock: proper advisory lock (Linux, Homebrew coreutils on macOS)
    mkdir -p "$(dirname "$lockfile")" 2>/dev/null
    exec 9>"$lockfile"
    flock -w "$max_wait" 9 && return 0
    return 1
  else
    # Fallback: mkdir-based lock with timeout
    local retries=0
    local max_retries=$(( max_wait * 20 ))  # 50ms per retry
    while ! mkdir "$lockfile" 2>/dev/null; do
      retries=$((retries + 1))
      if (( retries > max_retries )); then
        # Check for stale lock (older than 60s = crashed process)
        local lock_age=0
        if [[ "$(uname -s)" == "Darwin" ]]; then
          lock_age=$(( $(date +%s) - $(stat -f %m "$lockfile" 2>/dev/null || echo 0) ))
        else
          lock_age=$(( $(date +%s) - $(stat -c %Y "$lockfile" 2>/dev/null || echo 0) ))
        fi
        if (( lock_age > 60 )); then
          rmdir "$lockfile" 2>/dev/null
          continue
        fi
        return 1
      fi
      sleep 0.05
    done
    return 0
  fi
}

_docguard_release_lock() {
  local lockfile="$1"
  if command -v flock &>/dev/null; then
    exec 9>&-  # close fd, releases flock
    rm -f "$lockfile" 2>/dev/null
  else
    rmdir "$lockfile" 2>/dev/null
  fi
}

# H6: Global lock for entire flush operation — prevents fd 9 reuse from
# silently releasing the first lock when acquiring a second per-file lock.
_docguard_global_lock() {
  _docguard_acquire_lock "${PEON_STATE_DIR:-$HOME/.claude/state}/docguard_flush.lk" 10
}
_docguard_global_unlock() {
  _docguard_release_lock "${PEON_STATE_DIR:-$HOME/.claude/state}/docguard_flush.lk"
}

# ── Project Root ───────────────────────────────────────────────────
_docguard_project_root() {
  local root
  if root=$(git rev-parse --show-toplevel 2>/dev/null); then
    echo "$root"
  else
    pwd
  fi
}

# ── Manifest Path ──────────────────────────────────────────────────
# W2: Session-scoped filename prevents cross-session contamination
_docguard_manifest_path() {
  local session_id="${PEON_SESSION_ID:-unknown}"
  echo "${PEON_STATE_DIR:-$HOME/.claude/state}/docguard_manifest_${session_id}"
}

# ══════════════════════════════════════════════════════════════════
# ACCUMULATE PHASE — runs on PostToolUse, ~1ms per call
# ══════════════════════════════════════════════════════════════════

docguard_accumulate() {
  local file_path="$1"
  local tool_name="${2:-Edit}"

  # W7/W26: Skip doc files to prevent loops and noise
  local basename_lower
  basename_lower=$(basename "$file_path" | tr '[:upper:]' '[:lower:]')
  case "$basename_lower" in
    changelog.md|claude.md|readme.md|memory.md) return 0 ;;
  esac

  # Skip binary/asset files
  local ext="${file_path##*.}"
  ext=$(echo "$ext" | tr '[:upper:]' '[:lower:]')
  case "$ext" in
    png|jpg|jpeg|gif|ico|svg|woff|woff2|eot|ttf|lock|mp3|wav|ogg|mp4|zip|tar|gz) return 0 ;;
  esac

  local manifest
  manifest=$(_docguard_manifest_path)
  mkdir -p "$(dirname "$manifest")" 2>/dev/null

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # W1: Atomic append — safe for concurrent hooks (line < PIPE_BUF)
  echo "${ts}|${tool_name}|${file_path}" >> "$manifest"

  peon_log debug "docguard.accumulate" "file=$file_path" "tool=$tool_name"
}

# ══════════════════════════════════════════════════════════════════
# FLUSH PHASE — runs on Stop/SessionEnd, one claude -p call
# ══════════════════════════════════════════════════════════════════

# ── Score Manifest ─────────────────────────────────────────────────
# W17: Deduplicates by file path (each file counted once, last action wins)
# W22: Uses awk instead of bash associative arrays (macOS bash 3.2 compat)
_docguard_score() {
  local manifest="$1"
  [[ ! -f "$manifest" || ! -s "$manifest" ]] && echo 0 && return

  # Deduplicate by file. If ANY action is Write, keep Write (highest score).
  awk -F'|' '
    { if (!($3 in files) || $2 == "Write") files[$3] = $2 }
    END {
      score = 0
      for (f in files) {
        if (files[f] == "Write") score += 3
        else score += 1
      }
      print score
    }
  ' "$manifest"
}

# ── Build Context ──────────────────────────────────────────────────
# W4: Includes git diff stat for change magnitude
# W5: Includes existing changelog tail for style matching
# W22: Uses awk for dedup (bash 3.2 compat)
_docguard_build_context() {
  local manifest="$1"
  local proj_root="$2"

  echo "## Files Changed This Session"
  echo ""

  # Deduplicated file list with action type
  # M16: Cap manifest to last 50 unique files to stay within token limits
  local manifest_content
  manifest_content=$(awk -F'|' -v root="${proj_root}/" '
    { files[$3] = $2 }
    END {
      for (f in files) {
        relpath = f
        idx = index(f, root)
        if (idx == 1) relpath = substr(f, length(root) + 1)
        print "- [" files[f] "] " relpath
      }
    }
  ' "$manifest" | tail -n 50)
  echo "$manifest_content"

  echo ""

  # W24: Git context if available, graceful fallback
  if git -C "$proj_root" rev-parse --is-inside-work-tree &>/dev/null 2>&1; then
    local diff_stat
    diff_stat=$(git -C "$proj_root" diff --stat HEAD 2>/dev/null | tail -30)
    if [[ -n "$diff_stat" ]]; then
      echo "## Git Diff Summary"
      echo '```'
      echo "$diff_stat"
      echo '```'
      echo ""
    fi

    # M17: Include truncated diff content for better changelog accuracy
    local diff_content=""
    diff_content=$(git -C "$proj_root" diff HEAD 2>/dev/null | head -200)
    if [[ -n "$diff_content" ]]; then
      echo "## Git Diff Content (truncated)"
      echo '```diff'
      echo "$diff_content"
      echo '```'
      echo ""
    fi
  fi

  # W5/W18: Existing changelog for style matching and dedup awareness
  local changelog="${proj_root}/CHANGELOG.md"
  if [[ -f "$changelog" ]]; then
    echo "## Existing CHANGELOG (last 15 lines — do not duplicate these)"
    echo '```'
    tail -15 "$changelog"
    echo '```'
  fi
}

# ── Generate Changelog Entry ──────────────────────────────────────
# W3: Uses sonnet (not haiku) for quality
# W8: Validates response starts with ## (changelog header format)
_docguard_generate_changelog() {
  local context="$1"
  local model="$2"
  local timeout_sec="$3"

  local today
  today=$(date +%Y-%m-%d)

  local system_prompt
  system_prompt="You are a changelog generator. Given the session changes below, produce a CHANGELOG.md entry.

FORMAT (Keep a Changelog):
## ${today}
### Category
- Description

CATEGORIES (use only those that apply): Added | Changed | Fixed | Removed | Deprecated | Security

RULES:
- One line per logical change — group related file edits into a single entry
- Focus on user-visible impact, not implementation details
- Write from the project perspective: 'Added X for Y' not 'Modified file Z'
- Omit empty categories
- Do NOT duplicate entries already in the existing CHANGELOG
- If changes are too minor or routine to document, respond EXACTLY with: NO_DOC_UPDATES_NEEDED

Output ONLY the changelog entry. No preamble, no explanation."

  local tmout
  tmout=$(_docguard_timeout_cmd)
  local tpfx=""
  if [[ -n "$tmout" ]]; then
    tpfx="$tmout ${timeout_sec}s"
  fi

  # H9: Retry loop for transient claude -p failures (2 retries, 3s delay)
  local _dg_attempt=0
  local _dg_max_retries=2
  local output=""
  while (( _dg_attempt <= _dg_max_retries )); do
    output=$(unset CLAUDECODE; $tpfx claude -p \
      --model "$model" \
      --append-system-prompt "$system_prompt" \
      "$context" 2>&1) && break
    local exit_code=$?
    if [[ $exit_code -eq 124 ]]; then
      peon_log warn "docguard.generate_timeout" "timeout=${timeout_sec}s" "attempt=$((_dg_attempt + 1))"
    else
      peon_log warn "docguard.generate_error" "exit_code=$exit_code" "attempt=$((_dg_attempt + 1))"
    fi
    (( ++_dg_attempt ))
    if (( _dg_attempt <= _dg_max_retries )); then
      sleep 3
    fi
  done
  if (( _dg_attempt > _dg_max_retries )); then
    echo ""
    return 1
  fi

  # W8: Basic validation — response should start with ## or NO_DOC
  if [[ "$output" != "## "* && "$output" != *"NO_DOC_UPDATES_NEEDED"* ]]; then
    peon_log warn "docguard.generate_invalid" "output_start=$(echo "$output" | head -c 50)"
    # Save for debugging but don't apply
    echo "$output" > "${PEON_STATE_DIR:-$HOME/.claude/state}/docguard_invalid_response.md" 2>/dev/null || true
    echo ""
    return 1
  fi

  echo "$output"
}

# ── Extract Summary ────────────────────────────────────────────────
# W23: Uses while loop instead of paste (portable across macOS/Linux)
_docguard_extract_summary() {
  local entry="$1"
  local items=""
  while IFS= read -r line; do
    local text="${line#- }"
    if [[ -n "$items" ]]; then
      items="${items}; ${text}"
    else
      items="$text"
    fi
  done < <(echo "$entry" | grep '^- ' | head -5)
  echo "$items"
}

# ── Apply: CHANGELOG.md ───────────────────────────────────────────
# W11: Creates CHANGELOG.md if it doesn't exist
# W20: Session-scoped backups (concurrent sessions don't overwrite each other)
# Multi-session safe: flock/mkdir lock serializes read-modify-write
_docguard_apply_changelog() {
  local entry="$1"
  local changelog="$2"
  local state_dir="${PEON_STATE_DIR:-$HOME/.claude/state}"
  local session_id="${PEON_SESSION_ID:-unknown}"

  # H6: Per-file locking removed — caller (docguard_flush) holds global lock
  if [[ -f "$changelog" ]]; then
    # W20: Session-scoped backup (won't collide with other sessions)
    cp "$changelog" "${state_dir}/docguard_backup_CHANGELOG_${session_id}.md" 2>/dev/null || true

    # Find first version entry (## line) and insert before it
    local first_version_line
    first_version_line=$(grep -n '^## ' "$changelog" | head -1 | cut -d: -f1)

    if [[ -n "$first_version_line" ]]; then
      {
        head -n $((first_version_line - 1)) "$changelog"
        echo "$entry"
        echo ""
        tail -n +"$first_version_line" "$changelog"
      } > "${changelog}.tmp"
      mv "${changelog}.tmp" "$changelog"
    else
      {
        cat "$changelog"
        echo ""
        echo "$entry"
        echo ""
      } > "${changelog}.tmp"
      mv "${changelog}.tmp" "$changelog"
    fi
  else
    {
      echo "# Changelog"
      echo ""
      echo "$entry"
      echo ""
    } > "$changelog"
  fi

  peon_log info "docguard.changelog_updated" "file=$changelog"
}

# ── Apply: CLAUDE.md ───────────────────────────────────────────────
# W10: Checks both project root and .claude/ locations
# W19: Uses DOCGUARD section markers (doesn't parse human sections)
# W20: Session-scoped backups
# Multi-session safe: flock/mkdir lock serializes read-modify-write
_docguard_apply_claude_md() {
  local summary="$1"
  local claude_md="$2"
  local state_dir="${PEON_STATE_DIR:-$HOME/.claude/state}"
  local session_id="${PEON_SESSION_ID:-unknown}"

  [[ ! -f "$claude_md" ]] && return 0
  [[ -z "$summary" ]] && return 0

  local today
  today=$(date +%Y-%m-%d)
  local entry="- **${today}**: ${summary}"

  # H6: Per-file locking removed — caller (docguard_flush) holds global lock

  # W20: Session-scoped backup
  cp "$claude_md" "${state_dir}/docguard_backup_CLAUDE_${session_id}.md" 2>/dev/null || true

  if grep -q 'DOCGUARD:END' "$claude_md" 2>/dev/null; then
    # Insert before END marker
    local end_line
    end_line=$(grep -n 'DOCGUARD:END' "$claude_md" | head -1 | cut -d: -f1)
    if [[ -n "$end_line" ]]; then
      {
        head -n $((end_line - 1)) "$claude_md"
        echo "$entry"
        tail -n +"$end_line" "$claude_md"
      } > "${claude_md}.tmp"
      mv "${claude_md}.tmp" "$claude_md"
    fi
  else
    # Append DOCGUARD section at the end of the file
    {
      cat "$claude_md"
      echo ""
      echo "<!-- DOCGUARD:START -->"
      echo "## Session Log"
      echo "$entry"
      echo "<!-- DOCGUARD:END -->"
    } > "${claude_md}.tmp"
    mv "${claude_md}.tmp" "$claude_md"
  fi

  peon_log info "docguard.claude_md_updated" "file=$claude_md"
}

# ── Sync: memory/MEMORY.md ────────────────────────────────────────
# W12: Only runs if memory_dir is explicitly configured
# W13: Warns if MEMORY.md exceeds 180 lines (200-line truncation safety)
# Mechanical — no AI call. Scans directory, updates index.
_docguard_sync_memory() {
  local memory_dir="$1"

  [[ -z "$memory_dir" || ! -d "$memory_dir" ]] && return 0

  local memory_md="${memory_dir}/MEMORY.md"
  [[ ! -f "$memory_md" ]] && return 0

  # Collect all .md files except MEMORY.md
  local found_files=()
  while IFS= read -r f; do
    local bname
    bname=$(basename "$f")
    [[ "$bname" == "MEMORY.md" ]] && continue
    found_files+=("$bname")
  done < <(find "$memory_dir" -maxdepth 1 -name "*.md" -type f 2>/dev/null | sort)

  [[ ${#found_files[@]} -eq 0 ]] && return 0

  # Read existing referenced files from MEMORY.md
  local existing_refs
  existing_refs=$(grep -oE '\[[^]]*\.md\]' "$memory_md" 2>/dev/null | tr -d '[]' || true)

  # Add entries for new files
  local new_count=0
  for fname in "${found_files[@]}"; do
    if ! echo "$existing_refs" | grep -qx "$fname" 2>/dev/null; then
      # Read description from frontmatter
      local desc="No description"
      local fpath="${memory_dir}/${fname}"
      if [[ -f "$fpath" ]]; then
        local fd
        fd=$(head -10 "$fpath" | grep '^description:' | head -1 | sed 's/^description:[[:space:]]*//')
        [[ -n "$fd" ]] && desc="$fd"
      fi
      echo "- [${fname}](${fname}) — ${desc}" >> "$memory_md"
      new_count=$((new_count + 1))
    fi
  done

  if [[ $new_count -gt 0 ]]; then
    peon_log info "docguard.memory_synced" "new_entries=$new_count"
  fi

  # W13: Check line count
  local line_count
  line_count=$(wc -l < "$memory_md" 2>/dev/null | tr -d ' ')
  if (( line_count > 180 )); then
    peon_log warn "docguard.memory_large" "lines=$line_count" "max=200"
    echo "[DocGuard] Warning: MEMORY.md has ${line_count} lines (200-line truncation limit). Consider pruning."
  fi

  # Flag stale entries (files referenced but no longer on disk)
  while IFS= read -r ref; do
    [[ -z "$ref" ]] && continue
    if [[ ! -f "${memory_dir}/${ref}" ]]; then
      peon_log warn "docguard.memory_stale_ref" "file=$ref"
    fi
  done <<< "$existing_refs"
}

# ── Stale Manifest Check ──────────────────────────────────────────
# W2: Warns about manifests from crashed sessions. Does NOT auto-flush.
# Only flags manifests older than 1 hour — avoids false positives from
# concurrent active sessions in other terminal windows.
docguard_check_stale() {
  local state_dir="${PEON_STATE_DIR:-$HOME/.claude/state}"
  local current_manifest
  current_manifest=$(_docguard_manifest_path)
  local stale_threshold_sec=3600  # 1 hour

  for manifest in "${state_dir}"/docguard_manifest_*; do
    [[ ! -f "$manifest" ]] && continue
    [[ "$manifest" == "$current_manifest" ]] && continue

    local mod_time now_time age_sec
    if [[ "$(uname -s)" == "Darwin" ]]; then
      mod_time=$(stat -f %m "$manifest" 2>/dev/null || echo 0)
    else
      mod_time=$(stat -c %Y "$manifest" 2>/dev/null || echo 0)
    fi
    now_time=$(date +%s)
    age_sec=$(( now_time - mod_time ))

    # Skip recent manifests — likely an active session in another terminal
    if (( age_sec < stale_threshold_sec )); then
      peon_log debug "docguard.skip_active_manifest" "file=$(basename "$manifest")" "age_sec=$age_sec"
      continue
    fi

    local entries
    entries=$(wc -l < "$manifest" 2>/dev/null | tr -d ' ')
    local age_hours=$(( age_sec / 3600 ))

    peon_log warn "docguard.stale_manifest" "file=$manifest" "entries=$entries" "age_hours=$age_hours"
    echo "[DocGuard] Stale manifest: ${entries} changes, ${age_hours}h old. Run: peon-docguard.sh --flush"
  done
}

# ── Main Flush Orchestrator ───────────────────────────────────────
# Scores manifest → builds context → generates changelog → applies updates.
# One AI call per session.
docguard_flush() {
  local manifest="$1"
  local dry_run="${2:-false}"

  if [[ ! -f "$manifest" || ! -s "$manifest" ]]; then
    peon_log debug "docguard.flush_skip" "reason=empty_manifest"
    return 0
  fi

  # H6: Acquire global lock for entire flush (prevents fd 9 reuse across per-file locks)
  if ! _docguard_global_lock; then
    peon_log warn "docguard.flush_global_lock_failed"
    return 1
  fi

  # Read config
  local min_score
  min_score=$(_dg_target "min_score_threshold" "3")
  local model
  model=$(_dg_target "flush_model" "sonnet")
  local timeout_sec
  timeout_sec=$(_dg_target "flush_timeout_sec" "45")
  local memory_dir
  memory_dir=$(_dg_target "memory_dir" "")

  # W17: Score with deduplication
  local score
  score=$(_docguard_score "$manifest")
  peon_log info "docguard.flush_score" "score=$score" "threshold=$min_score"

  if (( score < min_score )); then
    peon_log info "docguard.flush_skip" "reason=below_threshold" "score=$score"
    rm -f "$manifest" 2>/dev/null
    _docguard_global_unlock
    return 0
  fi

  local proj_root
  proj_root=$(_docguard_project_root)

  # W4: Build context with manifest + git diff + existing changelog
  local context
  context=$(_docguard_build_context "$manifest" "$proj_root")

  # W19: Dry-run exits before AI call
  if [[ "$dry_run" == "true" ]]; then
    echo "=== DocGuard Dry Run ==="
    echo "Score: ${score} (threshold: ${min_score})"
    echo "Project: ${proj_root}"
    echo "Model: ${model}"
    echo ""
    echo "--- Prompt context ---"
    echo "$context"
    echo "--- End context ---"
    _docguard_global_unlock
    return 0
  fi

  # Generate changelog entry (one AI call)
  peon_log info "docguard.flush_generate" "model=$model" "score=$score"
  local changelog_entry
  changelog_entry=$(_docguard_generate_changelog "$context" "$model" "$timeout_sec")

  if [[ -z "$changelog_entry" ]]; then
    peon_log warn "docguard.flush_empty_response"
    rm -f "$manifest" 2>/dev/null
    _docguard_global_unlock
    return 0
  fi

  # W27: Check sentinel
  if [[ "$changelog_entry" == *"NO_DOC_UPDATES_NEEDED"* ]]; then
    peon_log info "docguard.flush_no_updates"
    echo "[DocGuard] No documentation updates needed for this session."
    rm -f "$manifest" 2>/dev/null
    _docguard_global_unlock
    return 0
  fi

  # W21: Save raw response for debugging
  local state_dir="${PEON_STATE_DIR:-$HOME/.claude/state}"
  echo "$changelog_entry" > "${state_dir}/docguard_last_response.md" 2>/dev/null || true

  # Read per-target config
  local do_changelog do_claude_md do_readme do_memory
  do_changelog=$(_dg_target "update_changelog" "true")
  do_claude_md=$(_dg_target "update_claude_md" "true")
  do_readme=$(_dg_target "suggest_readme" "false")
  do_memory=$(_dg_target "sync_memory_md" "true")

  # W7: Check if user edited doc files this session — skip those
  local user_edited_changelog=false user_edited_claude_md=false
  if grep -qi "CHANGELOG.md" "$manifest" 2>/dev/null; then user_edited_changelog=true; fi
  if grep -qi "CLAUDE.md" "$manifest" 2>/dev/null; then user_edited_claude_md=true; fi

  # Apply: CHANGELOG.md
  if [[ "$do_changelog" == "true" && "$user_edited_changelog" == "false" ]]; then
    _docguard_apply_changelog "$changelog_entry" "${proj_root}/CHANGELOG.md"
    echo "[DocGuard] Updated CHANGELOG.md"
  fi

  # Apply: CLAUDE.md
  if [[ "$do_claude_md" == "true" && "$user_edited_claude_md" == "false" ]]; then
    local claude_md=""
    [[ -f "${proj_root}/CLAUDE.md" ]] && claude_md="${proj_root}/CLAUDE.md"
    [[ -z "$claude_md" && -f "${proj_root}/.claude/CLAUDE.md" ]] && claude_md="${proj_root}/.claude/CLAUDE.md"
    if [[ -n "$claude_md" ]]; then
      local summary
      summary=$(_docguard_extract_summary "$changelog_entry")
      _docguard_apply_claude_md "$summary" "$claude_md"
      echo "[DocGuard] Updated CLAUDE.md session log"
    fi
  fi

  # Suggest: README.md (stdout only)
  if [[ "$do_readme" == "true" ]]; then
    if [[ -f "${proj_root}/README.md" ]]; then
      local summary
      summary=$(_docguard_extract_summary "$changelog_entry")
      if [[ -n "$summary" ]]; then
        echo ""
        echo "[DocGuard] README.md suggestion: consider updating to reflect: ${summary}"
        echo ""
      fi
    fi
  fi

  # Sync: memory/MEMORY.md
  if [[ "$do_memory" == "true" && -n "$memory_dir" ]]; then
    _docguard_sync_memory "$memory_dir"
  fi

  # Clear manifest
  rm -f "$manifest" 2>/dev/null

  # H6: Release global lock
  _docguard_global_unlock

  peon_log info "docguard.flush_complete" "score=$score"
}
