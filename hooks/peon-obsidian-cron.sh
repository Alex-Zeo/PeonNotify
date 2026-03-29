#!/usr/bin/env bash
set -euo pipefail

##########################################################
# peon-obsidian-cron.sh — Daily Obsidian Vault Maintenance
# Run via launchd at 9am. Scans for gaps, aggregates
# trends, rebuilds index, manages note lifecycle.
##########################################################

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/config.sh"
source "${SCRIPT_DIR}/lib/logger.sh"
source "${SCRIPT_DIR}/lib/obsidian.sh"

peon_load_config

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
SKIP_AI=false
VAULT_PATH=""
CRON_GAP_DAYS=7
CRON_TREND_DAYS=7
ARCHIVE_AFTER_DAYS=90
META_DIR=""
STATE_DIR=""
CRON_VQI="0.0"
CRON_EVAL_COUNT=0

# ---------------------------------------------------------------------------
# Init: read config values
# ---------------------------------------------------------------------------
_init_cron() {
  local obsidian_enabled
  obsidian_enabled="$(peon_config_get "obsidian" "enabled" "false")"
  if [[ "$obsidian_enabled" != "true" ]]; then
    peon_log "info" "obsidian_cron" "Obsidian integration disabled in config"
    exit 0
  fi

  local cron_enabled
  cron_enabled="$(peon_config_get "obsidian" "cron_enabled" "true")"
  if [[ "$cron_enabled" != "true" ]]; then
    peon_log "info" "obsidian_cron" "Obsidian cron disabled in config"
    exit 0
  fi

  VAULT_PATH="$(peon_config_get "obsidian" "vault_path" "$HOME/Documents/Obsidian")"
  VAULT_PATH="${VAULT_PATH/#\~/$HOME}"

  if [[ ! -d "$VAULT_PATH" ]]; then
    peon_log "error" "obsidian_cron" "Vault path does not exist: $VAULT_PATH"
    exit 1
  fi

  CRON_GAP_DAYS="$(peon_config_get "obsidian" "cron_gap_days" "7")"
  CRON_TREND_DAYS="$(peon_config_get "obsidian" "cron_trend_days" "7")"
  ARCHIVE_AFTER_DAYS="$(peon_config_get "obsidian" "archive_after_days" "90")"
  META_DIR="${VAULT_PATH}/meta"
  STATE_DIR="${PEON_STATE_DIR:-$HOME/.claude/state}"

  mkdir -p "$META_DIR" "$STATE_DIR"
}

# ---------------------------------------------------------------------------
# Idempotency check (W-OBS-15)
# ---------------------------------------------------------------------------
_check_idempotency() {
  local last_run_file="${STATE_DIR}/obsidian_cron_last_run"
  if [[ -f "$last_run_file" ]]; then
    local last now
    last=$(cat "$last_run_file" 2>/dev/null || echo "0")
    now=$(date +%s)
    if (( now - last < 72000 )); then  # 20 hours
      peon_log "info" "obsidian_cron" "Already ran within 20 hours, skipping"
      exit 0
    fi
  fi
}

# ---------------------------------------------------------------------------
# Battery check (macOS) — skip AI calls on battery power
# ---------------------------------------------------------------------------
_check_battery() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    if pmset -g batt 2>/dev/null | grep -q 'Battery Power'; then
      SKIP_AI=true
      peon_log "info" "obsidian_cron" "On battery power — skipping AI calls"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Step 1: Rebuild index (meta/index.json)
# ---------------------------------------------------------------------------
_rebuild_index() {
  peon_log "info" "obsidian_cron" "Rebuilding vault index"

  local index_file="${META_DIR}/index.json"
  local tmp_index
  tmp_index="$(mktemp)"
  local count=0

  echo "[" > "$tmp_index"

  local first=true
  while IFS= read -r -d '' mdfile; do
    if (( count >= 500 )); then
      break
    fi

    local title="" note_type="" tags="" created=""

    # Extract title: first '# ' heading
    title="$(grep -m1 '^# ' "$mdfile" 2>/dev/null | sed 's/^# //' || true)"
    if [[ -z "$title" ]]; then
      title="$(basename "$mdfile" .md)"
    fi

    # Extract frontmatter type and tags
    if head -1 "$mdfile" 2>/dev/null | grep -q '^---$'; then
      local fm
      fm="$(awk '/^---$/{if(++c==2)exit}c' "$mdfile" 2>/dev/null || true)"
      note_type="$(echo "$fm" | grep -m1 '^type:' | sed 's/^type:[[:space:]]*//' || true)"
      tags="$(echo "$fm" | grep -m1 '^tags:' | sed 's/^tags:[[:space:]]*//' || true)"
    fi

    # Creation date from file stat
    if [[ "$(uname -s)" == "Darwin" ]]; then
      created="$(stat -f '%SB' -t '%Y-%m-%d' "$mdfile" 2>/dev/null || true)"
    else
      created="$(stat -c '%w' "$mdfile" 2>/dev/null | cut -d' ' -f1 || true)"
      if [[ "$created" == "-" || -z "$created" ]]; then
        created="$(stat -c '%y' "$mdfile" 2>/dev/null | cut -d' ' -f1 || true)"
      fi
    fi

    local rel_path="${mdfile#"$VAULT_PATH"/}"

    if [[ "$first" == "true" ]]; then
      first=false
    else
      echo "," >> "$tmp_index"
    fi

    # Use jq for safe JSON construction
    jq -n \
      --arg path "$rel_path" \
      --arg title "$title" \
      --arg type "$note_type" \
      --arg tags "$tags" \
      --arg created "$created" \
      '{path: $path, title: $title, type: $type, tags: $tags, created: $created}' \
      >> "$tmp_index"

    (( count += 1 ))
  done < <(find "$VAULT_PATH" -name '*.md' -not -path '*/\.*' -not -path '*/meta/*' -print0 2>/dev/null | head -z -c 500000)

  echo "]" >> "$tmp_index"

  # Validate and move
  if jq . "$tmp_index" > /dev/null 2>&1; then
    mv "$tmp_index" "$index_file"
    peon_log "info" "obsidian_cron" "Index rebuilt: $count notes"
  else
    peon_log "error" "obsidian_cron" "Index JSON invalid, keeping old index"
    rm -f "$tmp_index"
  fi
}

# ---------------------------------------------------------------------------
# Step 1b: Evaluate notes — Karpathy ratchet (measure → evaluate → keep/discard)
# ---------------------------------------------------------------------------
_evaluate_notes() {
  peon_log "info" "obsidian_cron" "Evaluating notes (Karpathy ratchet)"

  local vault="$VAULT_PATH"
  local index_file="${META_DIR}/index.json"
  local eval_file="${META_DIR}/evaluations.jsonl"
  local flush_model
  flush_model="$(peon_config_get "obsidian" "flush_model" "sonnet")"
  local max_evals=10
  local eval_count=0

  # Find fresh notes older than 2 days, not yet evaluated
  local cutoff
  cutoff=$(date -v-2d +%Y-%m-%d 2>/dev/null || date -d '2 days ago' +%Y-%m-%d 2>/dev/null || echo "")
  [[ -z "$cutoff" ]] && { peon_log "warn" "obsidian_cron" "Cannot compute cutoff date"; return; }

  while IFS= read -r -d '' note_path; do
    (( eval_count >= max_evals )) && break
    [[ ! -f "$note_path" ]] && continue

    # Skip if already evaluated
    grep -q '^evaluated: true' "$note_path" 2>/dev/null && continue

    # Skip if not fresh
    local status
    status=$(grep '^status:' "$note_path" | head -1 | awk '{print $2}')
    [[ "$status" != "fresh" ]] && continue

    # Skip if created recently (< 2 days)
    local created
    created=$(grep '^date:' "$note_path" | head -1 | awk '{print $2}')
    [[ -z "$created" || "$created" > "$cutoff" ]] && continue

    # Evaluate (skip if on battery / AI disabled)
    if [[ "$SKIP_AI" != "true" ]]; then
      local result
      result=$(_obsidian_evaluate_note "$note_path" "$vault" "$flush_model") || continue

      local confidence useful
      confidence=$(echo "$result" | jq -r '.confidence // 0.5' 2>/dev/null)
      useful=$(echo "$result" | jq -r '.useful // true' 2>/dev/null)

      # Log evaluation
      local note_name
      note_name=$(basename "$note_path" .md)
      echo "{\"date\":\"$(date +%Y-%m-%d)\",\"note\":\"${note_name}\",\"confidence\":${confidence},\"useful\":${useful}}" >> "$eval_file" 2>/dev/null

      # Determine new status based on evaluation
      local new_status="active"
      if [[ "$useful" != "true" ]] || awk "BEGIN { exit ($confidence < 0.3) ? 0 : 1 }" 2>/dev/null; then
        new_status="stale"
      elif awk "BEGIN { exit ($confidence >= 0.7) ? 0 : 1 }" 2>/dev/null; then
        new_status="active"
      else
        # Confidence between 0.3 and 0.7 and useful — keep as fresh, skip promotion
        (( ++eval_count ))
        peon_log "info" "obsidian_cron" "Evaluated: note=$note_name confidence=$confidence useful=$useful status=unchanged"
        continue
      fi

      # Update note frontmatter: change status and add evaluated/confidence
      _sed_inplace "s/^status: fresh$/status: ${new_status}/" "$note_path"
      # Append evaluated/confidence below status line (W-OBS-21: use _sed_inplace)
      if [[ "$(uname -s)" == "Darwin" ]]; then
        _sed_inplace "/^status:/a\\
evaluated: true\\
confidence: ${confidence}" "$note_path"
      else
        _sed_inplace "/^status:/a evaluated: true\nconfidence: ${confidence}" "$note_path"
      fi

      (( ++eval_count ))
      peon_log "info" "obsidian_cron" "Evaluated: note=$note_name confidence=$confidence useful=$useful status=$new_status"
    fi
  done < <(find "$vault" -name '*.md' \( -path '*/patterns/*' -o -path '*/decisions/*' -o -path '*/pitfalls/*' \) -print0 2>/dev/null)

  # Calculate and log VQI
  local vqi
  vqi=$(_obsidian_calculate_vqi "$vault")
  _obsidian_log_vqi "$vault" "$vqi"
  peon_log "info" "obsidian_cron" "VQI=$vqi evaluated=$eval_count"

  # Export for use in inbox/analysis
  CRON_VQI="$vqi"
  CRON_EVAL_COUNT="$eval_count"
}

# ---------------------------------------------------------------------------
# Step 2: Detect gaps
# ---------------------------------------------------------------------------
_detect_gaps() {
  peon_log "info" "obsidian_cron" "Detecting gaps"

  local daily_dir="${VAULT_PATH}/daily"
  local missing_days=()
  local stale_projects=()
  local orphan_count=0

  # 2a. Check daily notes for missing days
  if [[ -d "$daily_dir" ]]; then
    local i
    for (( i = 1; i <= CRON_GAP_DAYS; i++ )); do
      local check_date
      if [[ "$(uname -s)" == "Darwin" ]]; then
        check_date="$(date -v"-${i}d" +%Y-%m-%d)"
      else
        check_date="$(date -d "-${i} days" +%Y-%m-%d)"
      fi
      if [[ ! -f "${daily_dir}/${check_date}.md" ]]; then
        missing_days+=("$check_date")
      fi
    done
  fi

  # 2b. Find stale projects (MOC files not modified in 7+ days)
  local moc_dir="${VAULT_PATH}/projects"
  if [[ -d "$moc_dir" ]]; then
    while IFS= read -r -d '' moc; do
      local mod_time now_time age_days
      if [[ "$(uname -s)" == "Darwin" ]]; then
        mod_time="$(stat -f '%m' "$moc" 2>/dev/null || echo 0)"
      else
        mod_time="$(stat -c '%Y' "$moc" 2>/dev/null || echo 0)"
      fi
      now_time="$(date +%s)"
      age_days=$(( (now_time - mod_time) / 86400 ))
      if (( age_days > 7 )); then
        stale_projects+=("$(basename "$moc" .md) (${age_days}d)")
      fi
    done < <(find "$moc_dir" -maxdepth 1 -name '*.md' -print0 2>/dev/null)
  fi

  # 2c. Count orphaned notes (notes with 0 inbound wikilinks)
  local all_links_tmp
  all_links_tmp="$(mktemp)"
  # Collect all wikilink targets across the vault
  grep -roh '\[\[[^]|]*' "$VAULT_PATH" 2>/dev/null \
    | sed 's/^\[\[//' \
    | sort -u > "$all_links_tmp" || true

  while IFS= read -r -d '' note; do
    local note_name
    note_name="$(basename "$note" .md)"
    if ! grep -qxF "$note_name" "$all_links_tmp" 2>/dev/null; then
      (( orphan_count += 1 ))
    fi
  done < <(find "$VAULT_PATH" -name '*.md' -not -path '*/\.*' -not -path '*/meta/*' -not -path '*/daily/*' -print0 2>/dev/null)
  rm -f "$all_links_tmp"

  # Store gap report for later use
  GAP_MISSING_DAYS=("${missing_days[@]+"${missing_days[@]}"}")
  GAP_STALE_PROJECTS=("${stale_projects[@]+"${stale_projects[@]}"}")
  GAP_ORPHAN_COUNT=$orphan_count

  peon_log "info" "obsidian_cron" "Gaps: ${#missing_days[@]} missing days, ${#stale_projects[@]} stale projects, $orphan_count orphans"
}

# ---------------------------------------------------------------------------
# Step 3: Aggregate trends from meta/sessions.jsonl
# ---------------------------------------------------------------------------
_aggregate_trends() {
  peon_log "info" "obsidian_cron" "Aggregating session trends"

  local sessions_file="${META_DIR}/sessions.jsonl"
  if [[ ! -f "$sessions_file" ]]; then
    peon_log "info" "obsidian_cron" "No sessions.jsonl found, skipping trends"
    TREND_SUMMARY="No session data available yet."
    return
  fi

  local cutoff_date
  if [[ "$(uname -s)" == "Darwin" ]]; then
    cutoff_date="$(date -v"-${CRON_TREND_DAYS}d" +%Y-%m-%d)"
  else
    cutoff_date="$(date -d "-${CRON_TREND_DAYS} days" +%Y-%m-%d)"
  fi

  # Sessions per day
  local sessions_per_day
  sessions_per_day="$(jq -r "select(.date >= \"$cutoff_date\") | .date" "$sessions_file" 2>/dev/null \
    | sort | uniq -c | sort -rn | head -7 || echo "  (no data)")"

  # Top projects by session count
  local top_projects
  top_projects="$(jq -r "select(.date >= \"$cutoff_date\") | .project // \"untagged\"" "$sessions_file" 2>/dev/null \
    | sort | uniq -c | sort -rn | head -5 || echo "  (no data)")"

  # Notes created by type
  local notes_by_type
  notes_by_type="$(jq -r "select(.date >= \"$cutoff_date\") | .notes_created[]?.type // \"unknown\"" "$sessions_file" 2>/dev/null \
    | sort | uniq -c | sort -rn || echo "  (no data)")"

  # Average goal alignment score
  local avg_alignment
  avg_alignment="$(jq -r "select(.date >= \"$cutoff_date\") | .goal_alignment // empty" "$sessions_file" 2>/dev/null \
    | awk '{sum+=$1; n+=1} END {if(n>0) printf "%.1f/10 (n=%d)", sum/n, n; else print "N/A"}' || echo "N/A")"

  TREND_SUMMARY="## Trends (last ${CRON_TREND_DAYS} days)

### Sessions per day
${sessions_per_day}

### Top projects
${top_projects}

### Notes by type
${notes_by_type}

### Avg goal alignment: ${avg_alignment}"

  peon_log "info" "obsidian_cron" "Trend aggregation complete"
}

# ---------------------------------------------------------------------------
# Step 4: Retry failed manifests (W-OBS-14)
# ---------------------------------------------------------------------------
_retry_failed_manifests() {
  local failed_count=0
  local manifest_pattern="${STATE_DIR}/obsidian_manifest_*.failed"

  # shellcheck disable=SC2086
  for f in $manifest_pattern; do
    [[ -f "$f" ]] || continue
    (( failed_count += 1 ))
  done

  if (( failed_count > 0 )); then
    peon_log "info" "obsidian_cron" "Found $failed_count failed manifests, retrying flush"
    "${SCRIPT_DIR}/peon-obsidian.sh" --flush 2>/dev/null || {
      peon_log "warn" "obsidian_cron" "Flush retry returned non-zero"
    }
  fi
}

# ---------------------------------------------------------------------------
# Step 5: Note lifecycle (W-OBS-04, W-OBS-23)
# ---------------------------------------------------------------------------
_manage_note_lifecycle() {
  peon_log "info" "obsidian_cron" "Managing note lifecycle"

  local now_epoch
  now_epoch="$(date +%s)"
  local seven_days=$((7 * 86400))
  local archive_secs=$((ARCHIVE_AFTER_DAYS * 86400))
  local archive_dir="${VAULT_PATH}/archive"
  local promoted=0
  local staled=0
  local archived=0

  # Collect all wikilink targets for backlink detection
  local all_links_tmp
  all_links_tmp="$(mktemp)"
  grep -roh '\[\[[^]|]*' "$VAULT_PATH" 2>/dev/null \
    | sed 's/^\[\[//' \
    | sort -u > "$all_links_tmp" || true

  while IFS= read -r -d '' note; do
    # Read frontmatter status
    local status=""
    if head -1 "$note" 2>/dev/null | grep -q '^---$'; then
      status="$(awk '/^---$/{if(++c==2)exit}c' "$note" 2>/dev/null \
        | grep -m1 '^status:' | sed 's/^status:[[:space:]]*//' || true)"
    fi

    [[ -z "$status" ]] && continue

    local mod_time
    if [[ "$(uname -s)" == "Darwin" ]]; then
      mod_time="$(stat -f '%m' "$note" 2>/dev/null || echo "$now_epoch")"
    else
      mod_time="$(stat -c '%Y' "$note" 2>/dev/null || echo "$now_epoch")"
    fi
    local age_secs=$(( now_epoch - mod_time ))
    local note_name
    note_name="$(basename "$note" .md)"

    # Fresh notes older than 7 days → promote to active or mark stale
    if [[ "$status" == "fresh" ]] && (( age_secs > seven_days )); then
      local has_backlinks=false
      if grep -qxF "$note_name" "$all_links_tmp" 2>/dev/null; then
        has_backlinks=true
      fi

      if [[ "$has_backlinks" == "true" ]]; then
        _sed_inplace "s/^status: fresh/status: active/" "$note"
        (( promoted += 1 ))
      else
        _sed_inplace "s/^status: fresh/status: stale/" "$note"
        (( staled += 1 ))
      fi
    fi

    # Stale notes older than archive_after_days → move to archive/
    if [[ "$status" == "stale" ]] && (( age_secs > archive_secs )); then
      local auto_archive
      auto_archive="$(peon_config_get "obsidian" "auto_archive" "true")"
      if [[ "$auto_archive" == "true" ]]; then
        mkdir -p "$archive_dir"
        mv "$note" "${archive_dir}/$(basename "$note")"
        (( archived += 1 ))
      fi
    fi
  done < <(find "$VAULT_PATH" -name '*.md' -not -path '*/\.*' -not -path '*/meta/*' -not -path '*/archive/*' -print0 2>/dev/null)

  rm -f "$all_links_tmp"

  peon_log "info" "obsidian_cron" "Lifecycle: promoted=$promoted, staled=$staled, archived=$archived"
}

# ---------------------------------------------------------------------------
# Step 6: Generate inbox (W-OBS-20)
# ---------------------------------------------------------------------------
_generate_inbox() {
  peon_log "info" "obsidian_cron" "Generating inbox"

  local inbox_file="${META_DIR}/inbox.md"
  local today
  today="$(date +%Y-%m-%d)"

  cat > "$inbox_file" <<INBOX
---
generated: ${today}
type: dashboard
---
# Inbox — Unreviewed Notes

\`\`\`dataview
TABLE file.ctime AS "Created", type AS "Type"
FROM ""
WHERE status = "fresh" AND file.ctime >= date(today) - dur(7 days)
SORT file.ctime DESC
\`\`\`

## Gap Warnings

### Missing Daily Notes
$(if [[ ${#GAP_MISSING_DAYS[@]} -gt 0 ]]; then
  for d in "${GAP_MISSING_DAYS[@]}"; do echo "- [ ] $d"; done
else
  echo "- None"
fi)

### Stale Projects
$(if [[ ${#GAP_STALE_PROJECTS[@]} -gt 0 ]]; then
  for p in "${GAP_STALE_PROJECTS[@]}"; do echo "- $p"; done
else
  echo "- None"
fi)

### Orphaned Notes: ${GAP_ORPHAN_COUNT}
INBOX

  peon_log "info" "obsidian_cron" "Inbox written to $inbox_file"
}

# ---------------------------------------------------------------------------
# Step 7: AI trend analysis (skip if SKIP_AI=true)
# ---------------------------------------------------------------------------
_run_ai_analysis() {
  if [[ "$SKIP_AI" == "true" ]]; then
    peon_log "info" "obsidian_cron" "Skipping AI analysis (battery/config)"
    return
  fi

  local flush_model
  flush_model="$(peon_config_get "obsidian" "flush_model" "sonnet")"
  local flush_timeout
  flush_timeout="$(peon_config_get "obsidian" "flush_timeout_sec" "60")"

  peon_log "info" "obsidian_cron" "Running AI trend analysis with model=$flush_model"

  local context
  context="You are analyzing an Obsidian vault's weekly activity. Provide:
1. A brief summary of activity patterns
2. Key projects that need attention (stale or high-activity)
3. Suggestions for note organization improvements
4. Goal alignment assessment

--- VAULT TRENDS ---
${TREND_SUMMARY}

--- GAP REPORT ---
Missing daily notes: ${GAP_MISSING_DAYS[*]+"${GAP_MISSING_DAYS[*]}"}
Stale projects: ${GAP_STALE_PROJECTS[*]+"${GAP_STALE_PROJECTS[*]}"}
Orphaned notes: ${GAP_ORPHAN_COUNT}
---"

  local ai_response=""
  local attempt=0
  local max_retries=2
  local retry_delay=3

  while (( attempt <= max_retries )); do
    ai_response="$(unset CLAUDECODE; echo "$context" \
      | timeout "${flush_timeout}" claude -p --model "$flush_model" 2>/dev/null)" && break
    (( attempt += 1 ))
    if (( attempt <= max_retries )); then
      peon_log "warn" "obsidian_cron" "AI call failed, retry $attempt/$max_retries"
      sleep "$retry_delay"
    fi
  done

  if [[ -z "$ai_response" ]]; then
    peon_log "warn" "obsidian_cron" "AI analysis returned empty response after retries"
    return
  fi

  # Write weekly trends dashboard
  local today
  today="$(date +%Y-%m-%d)"

  cat > "${META_DIR}/weekly-trends.md" <<TRENDS
---
generated: ${today}
type: dashboard
---
# Weekly Trends

${ai_response}

---
*Generated by PeonNotify Obsidian Cron on ${today}*
TRENDS

  # Write goal tracker
  cat > "${META_DIR}/goal-tracker.md" <<GOALS
---
generated: ${today}
type: dashboard
---
# Goal Tracker

${ai_response}

---
*Generated by PeonNotify Obsidian Cron on ${today}*
GOALS

  # Append gap warnings to today's daily note
  local daily_dir="${VAULT_PATH}/daily"
  local daily_note="${daily_dir}/${today}.md"
  if [[ -f "$daily_note" ]]; then
    {
      echo ""
      echo "## Cron Gap Warnings"
      if [[ ${#GAP_MISSING_DAYS[@]} -gt 0 ]]; then
        echo "Missing daily notes: ${GAP_MISSING_DAYS[*]}"
      fi
      if [[ ${#GAP_STALE_PROJECTS[@]} -gt 0 ]]; then
        echo "Stale projects: ${GAP_STALE_PROJECTS[*]}"
      fi
      echo "Orphaned notes: ${GAP_ORPHAN_COUNT}"
    } >> "$daily_note"
    peon_log "info" "obsidian_cron" "Appended gap warnings to daily note"
  fi

  peon_log "info" "obsidian_cron" "AI analysis complete"
}

# ---------------------------------------------------------------------------
# Step 8: Update last run timestamp
# ---------------------------------------------------------------------------
_update_last_run() {
  date +%s > "${STATE_DIR}/obsidian_cron_last_run"
  peon_log "info" "obsidian_cron" "Cron run complete"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  _init_cron
  _check_idempotency
  _check_battery

  peon_log "info" "obsidian_cron" "Starting daily vault maintenance"

  _rebuild_index
  _evaluate_notes
  _detect_gaps
  _aggregate_trends
  _retry_failed_manifests
  _manage_note_lifecycle
  _generate_inbox
  _run_ai_analysis
  _update_last_run

  peon_log "info" "obsidian_cron" "Daily vault maintenance complete"
}

main "$@"
