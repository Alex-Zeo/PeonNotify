#!/usr/bin/env bash
set -euo pipefail

# ╔══════════════════════════════════════════════════════════════════╗
# ║  peon-obsidian.sh — Obsidian Knowledge Graph Builder            ║
# ║                                                                  ║
# ║  Accumulate+Flush architecture:                                  ║
# ║    PostToolUse  → append file changes to session manifest (~1ms) ║
# ║    Stop         → flush session to vault (daily note + atomic)   ║
# ║                                                                  ║
# ║  Manual usage:                                                   ║
# ║    peon-obsidian.sh --flush      Flush all pending manifests     ║
# ║    peon-obsidian.sh --dry-run    Preview without writing         ║
# ║                                                                  ║
# ║  Targets: Obsidian vault — daily notes, decisions, patterns,     ║
# ║           pitfalls, bugs, project MOCs, session logs             ║
# ╚══════════════════════════════════════════════════════════════════╝

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Source Libraries ────────────────────────────────────────────────
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/obsidian.sh"

# ── Initialize ──────────────────────────────────────────────────────
peon_load_config

# ── Check Enabled ──────────────────────────────────────────────────
OBS_ENABLED=$(_obs_get "enabled" "false")

# ── SIGTERM trap ───────────────────────────────────────────────────
trap 'peon_log warn "obsidian.killed" "signal=TERM"' TERM

# ── Manual Invocation (--flush / --dry-run) ────────────────────────
# Handle flags BEFORE reading stdin to avoid blocking on terminal input
if [[ "${1:-}" == "--flush" || "${1:-}" == "--dry-run" ]]; then
  DRY_RUN="false"
  [[ "${1:-}" == "--dry-run" ]] && DRY_RUN="true"

  # Allow manual flush even if obsidian is disabled (for stale manifests)
  local_state="${PEON_STATE_DIR:-$HOME/.claude/state}"
  found_any=false
  # Rename .failed manifests back so they get retried (W-OBS-14)
  for f in "${local_state}"/obsidian_manifest_*.failed; do
    [[ ! -f "$f" ]] && continue
    local_renamed="${f%.failed}"
    mv "$f" "$local_renamed" 2>/dev/null || true
  done
  for manifest in "${local_state}"/obsidian_manifest_*; do
    [[ ! -f "$manifest" ]] && continue
    found_any=true
    # Extract session_id from filename for logging
    local_sid="${manifest##*_manifest_}"
    export PEON_SESSION_ID="${local_sid}"
    echo "[Obsidian] Processing manifest: $(basename "$manifest")"
    _obsidian_flush "$manifest" "$DRY_RUN"
  done
  if [[ "$found_any" == "false" ]]; then
    echo "[Obsidian] No pending manifests found."
  fi
  exit 0
fi

# ── Normal hook flow requires enabled ──────────────────────────────
if [[ "$OBS_ENABLED" != "true" ]]; then
  exit 0
fi

# ── Read Hook Input (JSON on stdin) ────────────────────────────────
_OBS_INPUT=""
if [[ ! -t 0 ]]; then
  _OBS_INPUT=$(head -c 65536)
fi

[[ -z "$_OBS_INPUT" ]] && exit 0

# ── Extract Fields ─────────────────────────────────────────────────
_obs_field() {
  local key="$1"
  if command -v jq &>/dev/null; then
    echo "$_OBS_INPUT" | jq -r ".$key // empty" 2>/dev/null || true
  else
    echo "$_OBS_INPUT" | grep -o "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" 2>/dev/null \
      | head -1 | sed 's/.*":\s*"//' | sed 's/"$//' || true
  fi
}

_obs_extract_file_path() {
  if command -v jq &>/dev/null; then
    echo "$_OBS_INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null || true
  else
    echo "$_OBS_INPUT" | grep -o '"file_path"[[:space:]]*:[[:space:]]*"[^"]*"' 2>/dev/null \
      | head -1 | sed 's/.*":\s*"//' | sed 's/"$//' || true
  fi
}

HOOK_EVENT=$(_obs_field "hook_event_name")
SESSION_ID=$(_obs_field "session_id")
TOOL_NAME=$(_obs_field "tool_name")

export PEON_SESSION_ID="${SESSION_ID:-unknown}"

# ── Manifest Path ─────────────────────────────────────────────────
_obsidian_manifest_path() {
  local session_id="${PEON_SESSION_ID:-unknown}"
  echo "${PEON_STATE_DIR:-$HOME/.claude/state}/obsidian_manifest_${session_id}"
}

# ══════════════════════════════════════════════════════════════════
# ACCUMULATE — PostToolUse, ~1ms per call
# ══════════════════════════════════════════════════════════════════

_obsidian_accumulate() {
  local file_path="$1"
  local tool_name="${2:-Edit}"

  # Skip doc files to prevent noise
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
  manifest=$(_obsidian_manifest_path)
  mkdir -p "$(dirname "$manifest")" 2>/dev/null

  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Atomic append — safe for concurrent hooks (line < PIPE_BUF)
  echo "${ts}|${tool_name}|${file_path}" >> "$manifest"

  peon_log debug "obsidian.accumulate" "file=$file_path" "tool=$tool_name"
}

# ── Template Engine (W-OBS-10) ─────────────────────────────────────
_apply_template() {
  local template_path="$1"
  local content=""
  if [[ -f "$template_path" ]]; then
    content=$(cat "$template_path")
  else
    # Fallback: inline construction
    return 1
  fi
  # Substitute {{variable}} placeholders
  shift
  while [[ $# -ge 2 ]]; do
    local key="$1" val="$2"
    content="${content//\{\{${key}\}\}/${val}}"
    shift 2
  done
  echo "$content"
}

# ══════════════════════════════════════════════════════════════════
# FLUSH — Stop/SessionEnd, one claude -p call
# ══════════════════════════════════════════════════════════════════

_obsidian_flush() {
  local manifest="$1"
  local dry_run="${2:-false}"

  if [[ ! -f "$manifest" || ! -s "$manifest" ]]; then
    peon_log debug "obsidian.flush_skip" "reason=empty_manifest"
    return 0
  fi

  # ── 1. Score manifest ──────────────────────────────────────────
  local score
  score=$(_obsidian_score_manifest "$manifest")
  local threshold
  threshold=$(_obs_get "min_score_threshold" "5")
  peon_log info "obsidian.flush_score" "score=$score" "threshold=$threshold"

  if (( score < threshold )); then
    peon_log info "obsidian.below_threshold" "score=$score" "threshold=$threshold"
    rm -f "$manifest" 2>/dev/null
    return 0
  fi

  # ── 2. Check for trivial session (W-OBS-08) ───────────────────
  local git_diff_stat=""
  if git rev-parse --git-dir &>/dev/null 2>&1; then
    git_diff_stat=$(git diff --stat HEAD 2>/dev/null || true)
  fi
  local trivial_session=false
  local manifest_lines
  manifest_lines=$(wc -l < "$manifest" 2>/dev/null | tr -d ' ')
  if [[ -z "$git_diff_stat" && "${manifest_lines:-0}" -lt 3 ]]; then
    trivial_session=true
    peon_log info "obsidian.trivial_session" "no_net_changes=true" "manifest_lines=${manifest_lines:-0}"
    # Still append a minimal entry to daily note, but skip AI call
  fi

  # ── 3. Collect context ─────────────────────────────────────────
  local vault
  vault=$(_obsidian_vault_path)

  # Ensure vault structure exists
  _obsidian_ensure_structure

  # ── Feature flags (W-OBS-16) ──────────────────────────────────
  local create_atomic=$(_obs_get "create_atomic_notes" "true")
  local daily_notes=$(_obs_get "daily_notes" "true")
  local project_tracking=$(_obs_get "project_tracking" "true")
  local goal_tracking=$(_obs_get "goal_tracking" "true")

  # Manifest content (capped at 30 unique files)
  local manifest_content
  manifest_content=$(awk -F'|' '{ files[$3] = $2 } END { for (f in files) print files[f] "|" f }' "$manifest" | tail -n 30)

  # Git context
  local git_stat_ctx=""
  local git_diff_ctx=""
  local git_log_ctx=""
  if git rev-parse --git-dir &>/dev/null 2>&1; then
    git_stat_ctx=$(git diff --stat HEAD 2>/dev/null | head -50 || true)
    git_diff_ctx=$(git diff HEAD 2>/dev/null | head -150 || true)
    git_log_ctx=$(git log --oneline -5 2>/dev/null || true)
  fi

  # Project slug
  local project_slug
  project_slug=$(_obsidian_project_slug "$PWD")

  # Existing note titles (capped at 50)
  local existing_decisions=""
  local existing_patterns=""
  local existing_pitfalls=""
  local existing_bugs=""
  existing_decisions=$(_obsidian_get_existing_titles "$vault" "decision" 2>/dev/null || true)
  existing_patterns=$(_obsidian_get_existing_titles "$vault" "pattern" 2>/dev/null || true)
  existing_pitfalls=$(_obsidian_get_existing_titles "$vault" "pitfall" 2>/dev/null || true)
  existing_bugs=$(_obsidian_get_existing_titles "$vault" "bug" 2>/dev/null || true)

  local existing_titles=""
  [[ -n "$existing_decisions" ]] && existing_titles="${existing_titles}Decisions:
${existing_decisions}
"
  [[ -n "$existing_patterns" ]] && existing_titles="${existing_titles}Patterns:
${existing_patterns}
"
  [[ -n "$existing_pitfalls" ]] && existing_titles="${existing_titles}Pitfalls:
${existing_pitfalls}
"
  [[ -n "$existing_bugs" ]] && existing_titles="${existing_titles}Bugs:
${existing_bugs}
"

  # ── XML escaping (W-OBS-22) ──────────────────────────────────────
  _xml_escape() {
    local s="$1"
    s="${s//&/&amp;}"
    s="${s//</&lt;}"
    s="${s//>/&gt;}"
    echo "$s"
  }

  # Apply to manifest and diff content before inserting into prompt
  manifest_content=$(_xml_escape "$manifest_content")
  git_diff_ctx=$(_xml_escape "$git_diff_ctx")

  # Build full context
  local goal_prompt=""
  if [[ "$goal_tracking" == "true" ]]; then
    goal_prompt="

GOAL EVALUATION:
Infer the project's current goal from the working directory, file types, and recent commits.
Rate goal_alignment as a number 0.0-1.0 (not just high/medium/low).
Include goal_statement (what we aimed to do) and goal_outcome (did we achieve it)."
  fi

  local full_context=""
  full_context="<session_context>
<project>${project_slug}</project>
<date>$(date +%Y-%m-%d)</date>
<session_id>${PEON_SESSION_ID:-unknown}</session_id>

<files_changed>
${manifest_content}
</files_changed>

<git_diff_stat>
${git_stat_ctx}
</git_diff_stat>

<git_diff_content>
${git_diff_ctx}
</git_diff_content>

<git_log>
${git_log_ctx}
</git_log>
</session_context>${goal_prompt}"

  # ── 4. Token budget check (W-OBS-09) ───────────────────────────
  local approx_tokens=$(( ${#full_context} / 4 ))
  local max_tokens
  max_tokens=$(_obs_get "max_prompt_tokens" "30000")

  # Progressive truncation if over budget
  if (( approx_tokens > max_tokens )); then
    # Truncate git diff content first (largest section)
    git_diff_ctx=$(echo "$git_diff_ctx" | head -50)
    full_context="<session_context>
<project>${project_slug}</project>
<date>$(date +%Y-%m-%d)</date>
<session_id>${PEON_SESSION_ID:-unknown}</session_id>

<files_changed>
${manifest_content}
</files_changed>

<git_diff_stat>
${git_stat_ctx}
</git_diff_stat>

<git_diff_content>
${git_diff_ctx}
</git_diff_content>

<git_log>
${git_log_ctx}
</git_log>
</session_context>${goal_prompt}"
    peon_log info "obsidian.context_truncated" "approx_tokens=$approx_tokens" "max=$max_tokens"
  fi

  # ── Dry-run exits before AI call ───────────────────────────────
  if [[ "$dry_run" == "true" ]]; then
    echo "=== Obsidian Dry Run ==="
    echo "Score: ${score} (threshold: ${threshold})"
    echo "Project: ${project_slug}"
    echo "Vault: ${vault}"
    echo "Trivial: ${trivial_session}"
    echo ""
    echo "--- Existing vault notes ---"
    echo "$existing_titles"
    echo "--- Prompt context ---"
    echo "$full_context"
    echo "--- End context ---"
    return 0
  fi

  # ── Trivial session: minimal daily entry, no AI call ───────────
  if [[ "$trivial_session" == "true" ]]; then
    if [[ "$daily_notes" == "true" ]]; then
      local today
      today=$(date +%Y-%m-%d)
      local ts_hm
      ts_hm=$(date +"%H:%M")
      local file_count
      file_count=$(echo "$manifest_content" | wc -l | tr -d ' ')

      local minimal_entry="### ${ts_hm} - ${project_slug} (trivial)

Browsing/reading session. ${file_count} files touched, no net code changes."

      _obsidian_append_to_daily "$today" "$minimal_entry"
      peon_log info "obsidian.trivial_daily_appended" "project=$project_slug"
    fi
    rm -f "$manifest" 2>/dev/null
    echo "[Obsidian] Trivial session logged to daily note."
    return 0
  fi

  # ── 4b. Build feedback context from past evaluations (Karpathy ratchet)
  local feedback_context=""
  local eval_file="${vault}/meta/evaluations.jsonl"
  if [[ -f "$eval_file" ]]; then
    # Get recent high-confidence notes (these are validated knowledge)
    local high_conf
    high_conf=$(tail -50 "$eval_file" | jq -r 'select(.confidence >= 0.7) | .note' 2>/dev/null | head -10)
    if [[ -n "$high_conf" ]]; then
      feedback_context="VALIDATED KNOWLEDGE (high-confidence notes from past sessions — build on these):
${high_conf}
"
    fi

    # Get recent low-confidence notes (avoid repeating these)
    local low_conf
    low_conf=$(tail -50 "$eval_file" | jq -r 'select(.confidence < 0.4) | .note' 2>/dev/null | head -5)
    if [[ -n "$low_conf" ]]; then
      feedback_context="${feedback_context}
LOW-VALUE NOTES (avoid generating similar — these were marked low-confidence):
${low_conf}
"
    fi

    # Get VQI trend
    local vqi_file="${vault}/meta/vqi_history.jsonl"
    if [[ -f "$vqi_file" ]]; then
      local latest_vqi prev_vqi trend
      latest_vqi=$(tail -1 "$vqi_file" | jq -r '.vqi' 2>/dev/null || echo "0")
      prev_vqi=$(tail -2 "$vqi_file" | head -1 | jq -r '.vqi' 2>/dev/null || echo "0")
      trend=$(awk "BEGIN { diff = $latest_vqi - $prev_vqi; if (diff > 0.01) print \"improving\"; else if (diff < -0.01) print \"declining\"; else print \"stable\" }")
      feedback_context="${feedback_context}
VAULT QUALITY: VQI=${latest_vqi} (trend: ${trend}). Generate notes that INCREASE link density and reduce orphan rate.
"
    fi
  fi

  # ── 5. System prompt ───────────────────────────────────────────
  local SYSTEM_PROMPT
  read -r -d '' SYSTEM_PROMPT <<'SYSPROMPT' || true
You are a knowledge graph builder for an Obsidian vault. Given a coding session's context, extract structured knowledge.

RULES:
1. Respond with ONLY valid JSON. No markdown fences, no preamble, no explanation.
2. Every decision, pattern, pitfall, or bug MUST cite specific evidence from the session (file paths, diff hunks, error messages).
3. Check EXISTING VAULT NOTES below. If a concept already exists, use "links_to_existing": "LINK_EXISTING" with the exact existing title instead of creating a duplicate.
4. For trivial sessions (config tweaks, typo fixes, dependency bumps), respond EXACTLY with: NO_VAULT_UPDATES_NEEDED
5. Decisions = architectural choices with alternatives considered. NOT every code change.
6. Patterns = reusable techniques that apply beyond this session.
7. Pitfalls = mistakes made, subtle bugs found, things that wasted time.
8. Bugs = specific bugs discovered and fixed (with root cause).

JSON SCHEMA:
{
  "project": "string (project slug)",
  "session_summary": "string (1-2 sentences describing what was accomplished)",
  "file_count": number,
  "goal_alignment": {"goal_statement":"what we aimed to do","goal_outcome":"what we achieved","score":0.5},
  "decisions": [
    {
      "title": "string (concise, noun-phrase)",
      "summary": "string (what was decided and why)",
      "alternatives": "string (what was considered but rejected)",
      "evidence": "string (file paths or diff context)",
      "tags": "string (space-separated)",
      "links_to_existing": "string or null (LINK_EXISTING if duplicate, null if new)"
    }
  ],
  "patterns": [
    {
      "title": "string",
      "summary": "string (the reusable technique)",
      "evidence": "string",
      "tags": "string (space-separated)",
      "links_to_existing": "string or null"
    }
  ],
  "pitfalls": [
    {
      "title": "string",
      "summary": "string (what went wrong and the fix)",
      "evidence": "string",
      "tags": "string (space-separated)",
      "links_to_existing": "string or null"
    }
  ],
  "bugs": [
    {
      "title": "string",
      "summary": "string (root cause and fix)",
      "evidence": "string",
      "tags": "string (space-separated)",
      "links_to_existing": "string or null"
    }
  ]
}
SYSPROMPT

  # Build user context with existing notes and feedback
  local USER_CONTEXT=""
  if [[ -n "$existing_titles" ]]; then
    USER_CONTEXT="EXISTING VAULT NOTES (do NOT duplicate these — use LINK_EXISTING instead):
${existing_titles}

${feedback_context}${full_context}"
  else
    USER_CONTEXT="${feedback_context}${full_context}"
  fi

  # ── 6. Call claude -p with retry (W-OBS-14) ────────────────────
  local flush_model
  flush_model=$(_obs_get "flush_model" "sonnet")
  local flush_timeout
  flush_timeout=$(_obs_get "flush_timeout_sec" "60")
  local max_retries
  max_retries=$(_obs_get "max_retries" "2")
  local retry_delay
  retry_delay=$(_obs_get "retry_delay_sec" "3")
  local tmout
  tmout=$(peon_timeout_cmd)
  local tpfx=""
  [[ -n "$tmout" ]] && tpfx="$tmout ${flush_timeout}s"

  peon_log info "obsidian.flush_generate" "model=$flush_model" "score=$score" "project=$project_slug"

  local response=""
  local attempt=0
  while (( attempt <= max_retries )); do
    response=$(unset CLAUDECODE; $tpfx claude -p \
      --model "$flush_model" \
      --append-system-prompt "$SYSTEM_PROMPT" \
      "$USER_CONTEXT" 2>&1) && break
    local exit_code=$?
    if [[ $exit_code -eq 124 ]]; then
      peon_log warn "obsidian.generate_timeout" "timeout=${flush_timeout}s" "attempt=$((attempt + 1))"
    else
      peon_log warn "obsidian.generate_error" "exit_code=$exit_code" "attempt=$((attempt + 1))"
    fi
    (( ++attempt ))
    if (( attempt <= max_retries )); then
      peon_log info "obsidian.retry" "attempt=$attempt"
      sleep "$retry_delay"
    fi
  done

  if (( attempt > max_retries )); then
    peon_log error "obsidian.generate_failed" "retries_exhausted=$max_retries"
    # Rename manifest so it can be retried manually
    mv "$manifest" "${manifest}.failed" 2>/dev/null || true
    return 0
  fi

  # ── 7. Check for sentinel ──────────────────────────────────────
  local trimmed_response
  trimmed_response=$(echo "$response" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  if [[ "$trimmed_response" == "NO_VAULT_UPDATES_NEEDED" ]]; then
    peon_log info "obsidian.no_updates_needed" "project=$project_slug"
    echo "[Obsidian] No vault updates needed for this session."
    rm -f "$manifest" 2>/dev/null
    return 0
  fi

  # ── 8. Strip markdown fences if present ────────────────────────
  # Models sometimes wrap JSON in ```json ... ``` despite instructions
  if [[ "$trimmed_response" == '```'* ]]; then
    trimmed_response=$(echo "$trimmed_response" | sed '1{/^```/d;}' | sed '${/^```/d;}')
  fi

  # ── 9. Validate JSON (W-OBS-06, 3-layer) ──────────────────────
  if ! _obsidian_validate_json "$trimmed_response"; then
    peon_log warn "obsidian.invalid_json" "response_len=${#response}"
    # Save response for debugging, rename manifest to .failed
    local state_dir="${PEON_STATE_DIR:-$HOME/.claude/state}"
    echo "$response" > "${state_dir}/obsidian_last_invalid_response.json" 2>/dev/null || true
    mv "$manifest" "${manifest}.failed" 2>/dev/null || true
    return 0
  fi

  # Save raw response for debugging
  local state_dir="${PEON_STATE_DIR:-$HOME/.claude/state}"
  echo "$trimmed_response" > "${state_dir}/obsidian_last_response.json" 2>/dev/null || true

  # ── 10. Acquire global lock (W-OBS-13) ─────────────────────────
  if ! _obsidian_global_lock; then
    peon_log warn "obsidian.flush_global_lock_failed"
    return 1
  fi

  # ── 11. Write vault notes ──────────────────────────────────────
  local today
  today=$(date +%Y-%m-%d)
  local notes_created=0
  local created_notes=()
  local max_atomic
  max_atomic=$(_obs_get "max_atomic_notes_per_session" "5")

  local session_start
  session_start=$(head -1 "$manifest" | cut -d'|' -f1)
  local session_end
  session_end=$(tail -1 "$manifest" | cut -d'|' -f1)
  local duration="session"
  local duration_min="0"
  # Calculate rough duration if timestamps are parseable (W-OBS-20)
  if command -v gdate &>/dev/null; then
    local start_epoch end_epoch
    start_epoch=$(gdate -d "$session_start" +%s 2>/dev/null || echo 0)
    end_epoch=$(gdate -d "$session_end" +%s 2>/dev/null || echo 0)
    if (( start_epoch > 0 && end_epoch > 0 )); then
      duration_min=$(( (end_epoch - start_epoch) / 60 ))
      if (( duration_min > 0 )); then
        duration="${duration_min}m"
      fi
    fi
  fi

  # ── 11a. Daily note append (gated by daily_notes flag) ──────────
  if [[ "$daily_notes" == "true" ]]; then
    local daily_entry
    daily_entry=$(_obsidian_build_daily_entry "$trimmed_response" "$project_slug" "$duration")
    if [[ -n "$daily_entry" ]]; then
      _obsidian_append_to_daily "$today" "$daily_entry"
      peon_log info "obsidian.daily_appended" "date=$today" "project=$project_slug"
    fi
  fi

  # ── 11b. Project MOC update (gated by project_tracking flag) ────
  local project_dir
  project_dir=$(_obsidian_project_dir "$project_slug")
  local moc_path="${project_dir}/MOC.md"

  if [[ "$project_tracking" == "true" && -f "$moc_path" ]]; then
    local session_summary
    session_summary=$(echo "$trimmed_response" | jq -r '.session_summary // "No summary"' 2>/dev/null)
    local moc_line="- **${today}**: ${session_summary}"

    # Append under ## Sessions in MOC
    if grep -q '^## Sessions' "$moc_path" 2>/dev/null; then
      local sessions_line
      sessions_line=$(grep -n '^## Sessions' "$moc_path" | head -1 | cut -d: -f1)
      local total_lines
      total_lines=$(wc -l < "$moc_path" 2>/dev/null | tr -d ' ')
      {
        head -n "$total_lines" "$moc_path"
        echo "$moc_line"
      } > "${moc_path}.tmp" 2>/dev/null
      mv "${moc_path}.tmp" "$moc_path" 2>/dev/null
    else
      {
        echo ""
        echo "$moc_line"
      } >> "$moc_path" 2>/dev/null
    fi
    peon_log debug "obsidian.moc_updated" "project=$project_slug"
  fi

  # ── 11c. Atomic notes (gated by create_atomic flag) ────────────
  local note_types=("decisions" "patterns" "pitfalls" "bugs")
  local note_type_dirs=("decisions" "patterns" "pitfalls" "pitfalls")
  # bugs go into project-scoped bugs dir
  local total_atomic=0

  if [[ "$create_atomic" != "true" ]]; then
    peon_log debug "obsidian.atomic_notes_disabled"
  fi

  for idx in 0 1 2 3; do
    [[ "$create_atomic" != "true" ]] && continue
    local ntype="${note_types[$idx]}"
    local ncount
    ncount=$(echo "$trimmed_response" | jq -r ".${ntype} | length" 2>/dev/null || echo 0)

    (( ncount == 0 )) && continue

    local i=0
    while (( i < ncount && total_atomic < max_atomic )); do
      local item
      item=$(echo "$trimmed_response" | jq -c ".${ntype}[$i]" 2>/dev/null)

      local title
      title=$(echo "$item" | jq -r '.title // empty' 2>/dev/null)
      [[ -z "$title" ]] && { (( ++i )); continue; }

      local links_to
      links_to=$(echo "$item" | jq -r '.links_to_existing // empty' 2>/dev/null)

      # If LINK_EXISTING, still record the link even though we didn't create a new note
      if [[ "$links_to" == "LINK_EXISTING" ]]; then
        # Derive filename from existing title for linking
        local existing_filename
        existing_filename=$(echo "$title" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')
        created_notes+=("${existing_filename} (linked)")
        peon_log debug "obsidian.link_existing" "title=$title" "type=$ntype"
        (( ++i ))
        continue
      fi

      # Determine target directory
      local target_dir
      if [[ "$ntype" == "bugs" ]]; then
        target_dir="${project_dir}/bugs"
      elif [[ "$ntype" == "decisions" ]]; then
        target_dir="${project_dir}/decisions"
      else
        target_dir="${vault}/${ntype}"
      fi

      # Dedup check
      if _obsidian_note_exists "$target_dir" "$title"; then
        peon_log debug "obsidian.note_already_exists" "title=$title" "type=$ntype"
        (( ++i ))
        continue
      fi

      # Extract fields
      local summary
      summary=$(echo "$item" | jq -r '.summary // ""' 2>/dev/null)
      local evidence
      evidence=$(echo "$item" | jq -r '.evidence // ""' 2>/dev/null)
      local tags
      tags=$(echo "$item" | jq -r '.tags // ""' 2>/dev/null)
      local alternatives
      alternatives=$(echo "$item" | jq -r '.alternatives // ""' 2>/dev/null)

      # Build note content — try template first, fallback to inline (W-OBS-10)
      local template_dir="${SCRIPT_DIR}/templates/obsidian"
      local note_content
      if note_content=$(_apply_template "${template_dir}/${ntype}.md" \
        "title" "$title" \
        "project" "$project_slug" \
        "date" "$today" \
        "created" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "context" "$summary" \
        "rationale" "$summary" \
        "alternatives" "$alternatives" \
        "evidence" "$evidence" \
        "description" "$summary" \
        "when_to_use" "$summary" \
        "how_to_avoid" "$summary" \
        "root_cause" "$summary" \
        "solution" "$summary" \
        "lesson" "$summary" \
        "name" "$title" \
        "language" "" \
        "tags" "$tags" \
        "session_id" "${PEON_SESSION_ID:-unknown}"); then
        : # template applied successfully
      else
        # Fallback to inline construction (existing code)
        note_content=$(_obsidian_frontmatter "$ntype" "$project_slug" "$today" "$tags")

        note_content="${note_content}
# ${title}

${summary}"

        if [[ -n "$alternatives" && "$alternatives" != "null" && "$alternatives" != "" ]]; then
          note_content="${note_content}

## Alternatives Considered

${alternatives}"
        fi

        if [[ -n "$evidence" && "$evidence" != "null" ]]; then
          note_content="${note_content}

## Evidence

${evidence}"
        fi

        note_content="${note_content}

---
*Session: ${PEON_SESSION_ID:-unknown} | Project: ${project_slug}*"
      fi

      # Create note (temp-then-mv via library)
      local created_filename
      created_filename=$(_obsidian_create_note "$target_dir" "$title" "$note_content")

      if [[ -n "$created_filename" ]]; then
        created_notes+=("${ntype}/${created_filename}.md")
        (( ++notes_created ))
        (( ++total_atomic ))
        peon_log info "obsidian.note_created_hook" "type=$ntype" "title=$title" "file=$created_filename"
      fi

      (( ++i ))
    done

    # ── W-OBS-05: Log dropped notes when cap is reached ──────────
    if (( total_atomic >= max_atomic && i < ncount )); then
      local total_items=$ncount
      peon_log info "obsidian.note_cap_reached" "max=$max_atomic" "dropped=$(( total_items - i ))"
    fi
  done

  # ── 11d. Session log ───────────────────────────────────────────
  local session_json
  session_json=$(jq -n \
    --arg sid "${PEON_SESSION_ID:-unknown}" \
    --arg proj "$project_slug" \
    --arg date "$today" \
    --arg ts "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
    --argjson score "$score" \
    --argjson notes "$notes_created" \
    --argjson duration_min "${duration_min:-0}" \
    --arg summary "$(echo "$trimmed_response" | jq -r '.session_summary // ""' 2>/dev/null)" \
    '{session_id: $sid, project: $proj, date: $date, timestamp: $ts, score: $score, notes_created: $notes, duration_min: $duration_min, summary: $summary}' \
    2>/dev/null || true)

  if [[ -n "$session_json" ]]; then
    _obsidian_append_session_log "$vault" "$session_json"
  fi

  # ── 12. Release lock ───────────────────────────────────────────
  _obsidian_global_unlock

  # ── 13. Print summary (W-OBS-17) ──────────────────────────────
  echo "[Obsidian] Session captured: ${notes_created} notes"
  for note in "${created_notes[@]+"${created_notes[@]}"}"; do
    echo "  - $note"
  done

  # ── 14. Play completion sound ──────────────────────────────────
  source "${SCRIPT_DIR}/lib/player.sh" 2>/dev/null || true
  local sound_file
  sound_file=$(peon_resolve_sound "codeguard_pass" 2>/dev/null || true)
  [[ -n "${sound_file:-}" ]] && peon_play "$sound_file" 2>/dev/null || true

  # ── 15. Clean up manifest (only on success — W-OBS-14) ────────
  rm -f "$manifest" 2>/dev/null

  peon_log info "obsidian.flush_complete" "score=$score" "notes=$notes_created" "project=$project_slug"
}

# ── Route by Event ─────────────────────────────────────────────────
case "$HOOK_EVENT" in

  PostToolUse)
    FILE_PATH=$(_obs_extract_file_path)
    [[ -z "$FILE_PATH" ]] && exit 0
    _obsidian_accumulate "$FILE_PATH" "$TOOL_NAME"
    ;;

  Stop|SessionEnd)
    MANIFEST=$(_obsidian_manifest_path)
    _obsidian_flush "$MANIFEST" "false"
    ;;

  *)
    exit 0
    ;;
esac

exit 0
