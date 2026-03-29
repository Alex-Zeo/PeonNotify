#!/usr/bin/env bash
# lib/obsidian.sh - Obsidian knowledge graph integration library
# Vault operations: note creation, daily logs, project discovery, session indexing
#
# Sources: config.sh and logger.sh must be sourced first
#
# Design: Pure functions, sourced by hook scripts. No set -e (library file).
#         All file writes use temp-then-mv pattern. Thread-safe via mkdir locks.
#         Deterministic filename sanitization enables dedup across sessions.

# ── Cross-platform sed -i (W-OBS-21) ────────────────────────────────
# macOS sed requires '' after -i; GNU sed does not.
_sed_inplace() {
  if [[ "$(uname -s)" == "Darwin" ]]; then
    sed -i '' "$@"
  else
    sed -i "$@"
  fi
}

# ── Config Accessor ──────────────────────────────────────────────────
_obs_get() {
  local key="$1" default="${2:-}"
  if command -v jq &>/dev/null && [[ -f "${PEON_CONFIG_FILE:-}" ]]; then
    local val
    val=$(jq -r ".obsidian.${key} // empty" "$PEON_CONFIG_FILE" 2>/dev/null)
    [[ -n "$val" ]] && echo "$val" && return
  fi
  echo "$default"
}

# ── Vault Path ───────────────────────────────────────────────────────
# Returns expanded vault path. Expands ~ to $HOME.
_obsidian_vault_path() {
  local raw
  raw=$(_obs_get "vault_path" "$HOME/Documents/Obsidian")
  # Expand leading ~ to $HOME
  if [[ "$raw" == "~/"* ]]; then
    raw="${HOME}/${raw#\~/}"
  elif [[ "$raw" == "~" ]]; then
    raw="$HOME"
  fi
  echo "$raw"
}

# ── Ensure Vault Structure ───────────────────────────────────────────
# Creates vault subdirectories on first run. Idempotent via marker file.
_obsidian_ensure_structure() {
  local vault
  vault=$(_obsidian_vault_path)
  local marker="${vault}/.peon_initialized"

  [[ -f "$marker" ]] && return 0

  local dirs=(daily projects patterns pitfalls decisions meta archive templates)
  local dir
  for dir in "${dirs[@]}"; do
    mkdir -p "${vault}/${dir}" 2>/dev/null || true
  done

  # Write marker
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$marker" 2>/dev/null || true

  peon_log info "obsidian.vault_initialized" "vault=$vault"
}

# ── Filename Sanitization ────────────────────────────────────────────
# Deterministic: lowercase, non-alphanumeric → hyphens, collapse, cap 60 chars.
# Dedup depends on this being stable — do NOT change the algorithm.
_obsidian_sanitize_filename() {
  local title="$1"

  # Lowercase
  local sanitized
  sanitized=$(echo "$title" | tr '[:upper:]' '[:lower:]')

  # Replace non-alphanumeric (except hyphens) with hyphens
  sanitized=$(echo "$sanitized" | sed 's/[^a-z0-9-]/-/g')

  # Collapse multiple hyphens
  sanitized=$(echo "$sanitized" | sed 's/-\{2,\}/-/g')

  # Strip leading/trailing hyphens
  sanitized=$(echo "$sanitized" | sed 's/^-//;s/-$//')

  # Cap at 60 chars
  sanitized="${sanitized:0:60}"

  # Strip trailing hyphen again (truncation may expose one)
  sanitized="${sanitized%-}"

  echo "$sanitized"
}

# ── Note Existence Check ─────────────────────────────────────────────
# Returns 0 if note with sanitized filename exists in dir, 1 if new.
_obsidian_note_exists() {
  local dir="$1" title="$2"

  local filename
  filename=$(_obsidian_sanitize_filename "$title")
  [[ -f "${dir}/${filename}.md" ]] && return 0
  return 1
}

# ── Frontmatter Generation ───────────────────────────────────────────
# Generates YAML frontmatter block. tags_string is space-separated.
_obsidian_frontmatter() {
  local type="$1"
  local project="$2"
  local date="$3"
  local tags_string="$4"
  local extra_yaml="${5:-}"

  local created
  if command -v gdate &>/dev/null; then
    created=$(gdate -u +"%Y-%m-%dT%H:%M:%S.%3NZ")
  else
    created=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  fi

  echo "---"
  echo "type: ${type}"
  echo "project: ${project}"
  echo "date: ${date}"

  # Convert space-separated tags to YAML array
  echo "tags:"
  local tag
  for tag in $tags_string; do
    echo "  - ${tag}"
  done

  echo "status: fresh"
  echo "created: ${created}"

  # Append extra YAML lines if provided
  if [[ -n "$extra_yaml" ]]; then
    echo "$extra_yaml"
  fi

  echo "---"
}

# ── Atomic Note Creation ─────────────────────────────────────────────
# Writes to .tmp first, then mv. Skips if file already exists (dedup).
# Returns filename (without .md extension).
_obsidian_create_note() {
  local dir="$1" title="$2" content="$3"

  local filename
  filename=$(_obsidian_sanitize_filename "$title")
  local filepath="${dir}/${filename}.md"

  # Dedup: skip if file already exists
  if [[ -f "$filepath" ]]; then
    peon_log debug "obsidian.note_exists" "file=$filepath"
    echo "$filename"
    return 0
  fi

  # Content-hash dedup (W-OBS-07): check if same content exists under different title
  local content_hash
  if command -v md5sum &>/dev/null; then
    content_hash=$(echo "$content" | md5sum | cut -d' ' -f1)
  elif command -v md5 &>/dev/null; then
    content_hash=$(echo "$content" | md5 -q)
  fi
  if [[ -n "${content_hash:-}" ]]; then
    local hash_file="${PEON_STATE_DIR:-$HOME/.claude/state}/obsidian_content_hashes"
    if grep -q "^${content_hash}$" "$hash_file" 2>/dev/null; then
      peon_log info "obsidian.content_dedup" "title=$title" "hash=$content_hash"
      echo ""  # return empty = skipped
      return 0
    fi
    echo "$content_hash" >> "$hash_file" 2>/dev/null || true
  fi

  mkdir -p "$dir" 2>/dev/null || true

  # Atomic write: temp then mv
  local tmpfile="${filepath}.tmp"
  echo "$content" > "$tmpfile" 2>/dev/null
  mv "$tmpfile" "$filepath" 2>/dev/null

  peon_log info "obsidian.note_created" "file=$filepath" "title=$title"
  echo "$filename"
}

# ── Daily Note Path ──────────────────────────────────────────────────
# Returns path to $vault/daily/YYYY-MM-DD.md. Creates from template if missing.
_obsidian_daily_note_path() {
  local date="$1"
  local vault
  vault=$(_obsidian_vault_path)
  local daily_path="${vault}/daily/${date}.md"

  if [[ ! -f "$daily_path" ]]; then
    mkdir -p "${vault}/daily" 2>/dev/null || true

    local template="${vault}/templates/daily.md"
    local tmpfile="${daily_path}.tmp"

    if [[ -f "$template" ]]; then
      # Use template, substituting {{date}} placeholder
      sed "s/{{date}}/${date}/g" "$template" > "$tmpfile" 2>/dev/null
    else
      # Default daily note structure
      {
        echo "---"
        echo "type: daily"
        echo "date: ${date}"
        echo "---"
        echo ""
        echo "# ${date}"
        echo ""
        echo "## Sessions"
        echo ""
      } > "$tmpfile" 2>/dev/null
    fi

    mv "$tmpfile" "$daily_path" 2>/dev/null
    peon_log debug "obsidian.daily_created" "date=$date"
  fi

  echo "$daily_path"
}

# ── Thread-Safe Daily Append ─────────────────────────────────────────
# Appends content below ## Sessions marker. Uses mkdir-based lock.
_obsidian_append_to_daily() {
  local date="$1" content="$2"
  local state_dir="${PEON_STATE_DIR:-$HOME/.claude/state}"
  local lock_dir="${state_dir}/obsidian_daily.lk"

  # Acquire lock (mkdir-based, 10s timeout)
  local retries=0
  local max_retries=200  # 50ms * 200 = 10s
  while ! mkdir "$lock_dir" 2>/dev/null; do
    retries=$((retries + 1))
    if (( retries > max_retries )); then
      # Stale lock detection (120s)
      local lock_age=0
      if [[ "$(uname -s)" == "Darwin" ]]; then
        lock_age=$(( $(date +%s) - $(stat -f %m "$lock_dir" 2>/dev/null || echo 0) ))
      else
        lock_age=$(( $(date +%s) - $(stat -c %Y "$lock_dir" 2>/dev/null || echo 0) ))
      fi
      if (( lock_age > 120 )); then
        rmdir "$lock_dir" 2>/dev/null
        continue
      fi
      peon_log warn "obsidian.daily_lock_timeout" "date=$date"
      return 1
    fi
    sleep 0.05
  done

  # Ensure daily note exists
  local daily_path
  daily_path=$(_obsidian_daily_note_path "$date")

  # Find ## Sessions marker and append after it
  if grep -q '^## Sessions' "$daily_path" 2>/dev/null; then
    local sessions_line
    sessions_line=$(grep -n '^## Sessions' "$daily_path" | head -1 | cut -d: -f1)
    if [[ -n "$sessions_line" ]]; then
      # Find next ## heading or EOF to insert before
      local total_lines
      total_lines=$(wc -l < "$daily_path" 2>/dev/null | tr -d ' ')
      local next_heading_line=""
      next_heading_line=$(tail -n +"$((sessions_line + 1))" "$daily_path" \
        | grep -n '^## ' | head -1 | cut -d: -f1)

      local insert_line
      if [[ -n "$next_heading_line" ]]; then
        insert_line=$(( sessions_line + next_heading_line - 1 ))
      else
        insert_line="$total_lines"
      fi

      {
        head -n "$insert_line" "$daily_path"
        echo ""
        echo "$content"
        if [[ -n "$next_heading_line" ]]; then
          tail -n +"$((insert_line + 1))" "$daily_path"
        fi
      } > "${daily_path}.tmp" 2>/dev/null
      mv "${daily_path}.tmp" "$daily_path" 2>/dev/null
    fi
  else
    # No Sessions marker — append at end
    {
      echo ""
      echo "$content"
    } >> "$daily_path" 2>/dev/null
  fi

  # Release lock
  rmdir "$lock_dir" 2>/dev/null
  peon_log debug "obsidian.daily_appended" "date=$date"
}

# ── Project Slug ─────────────────────────────────────────────────────
# Derives project name from git remote, git root, or cwd basename.
_obsidian_project_slug() {
  local cwd="$1"

  local slug=""

  # Try git remote URL first
  local remote_url
  remote_url=$(git -C "$cwd" remote get-url origin 2>/dev/null) || true
  if [[ -n "$remote_url" ]]; then
    # Extract repo name from URL: strip .git suffix, take last path component
    slug=$(echo "$remote_url" | sed 's/\.git$//' | sed 's|.*/||')
  fi

  # Fallback to git root basename
  if [[ -z "$slug" ]]; then
    local git_root
    git_root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) || true
    if [[ -n "$git_root" ]]; then
      slug=$(basename "$git_root")
    fi
  fi

  # Fallback to cwd basename
  if [[ -z "$slug" ]]; then
    slug=$(basename "$cwd")
  fi

  # Sanitize to lowercase/hyphens
  slug=$(echo "$slug" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/-\{2,\}/-/g' | sed 's/^-//;s/-$//')

  echo "$slug"
}

# ── Project Directory ────────────────────────────────────────────────
# Returns $vault/projects/$slug/. Creates MOC.md and subdirs on first access.
_obsidian_project_dir() {
  local slug="$1"
  local vault
  vault=$(_obsidian_vault_path)
  local project_dir="${vault}/projects/${slug}"

  if [[ ! -d "$project_dir" ]]; then
    mkdir -p "${project_dir}/decisions" "${project_dir}/bugs" "${project_dir}/sessions" 2>/dev/null || true

    # Create MOC (Map of Content)
    local moc="${project_dir}/MOC.md"
    if [[ ! -f "$moc" ]]; then
      local tmpfile="${moc}.tmp"
      {
        echo "---"
        echo "type: moc"
        echo "project: ${slug}"
        echo "created: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
        echo "---"
        echo ""
        echo "# ${slug}"
        echo ""
        echo "## Decisions"
        echo ""
        echo "## Bugs"
        echo ""
        echo "## Sessions"
        echo ""
      } > "$tmpfile" 2>/dev/null
      mv "$tmpfile" "$moc" 2>/dev/null
    fi

    peon_log info "obsidian.project_created" "slug=$slug" "dir=$project_dir"
  fi

  echo "$project_dir"
}

# ── Wiki Link ────────────────────────────────────────────────────────
_obsidian_link() {
  local title="$1"
  echo "[[${title}]]"
}

# ── Global Lock / Unlock ─────────────────────────────────────────────
# mkdir-based lock at $PEON_STATE_DIR/obsidian_flush.lk
# 10s timeout, 120s stale detection. Same pattern as docguard.
_obsidian_global_lock() {
  local state_dir="${PEON_STATE_DIR:-$HOME/.claude/state}"
  local lock_dir="${state_dir}/obsidian_flush.lk"
  local max_wait=10
  local retries=0
  local max_retries=$(( max_wait * 20 ))  # 50ms per retry

  mkdir -p "$state_dir" 2>/dev/null || true

  while ! mkdir "$lock_dir" 2>/dev/null; do
    retries=$((retries + 1))
    if (( retries > max_retries )); then
      # Stale lock detection (120s)
      local lock_age=0
      if [[ "$(uname -s)" == "Darwin" ]]; then
        lock_age=$(( $(date +%s) - $(stat -f %m "$lock_dir" 2>/dev/null || echo 0) ))
      else
        lock_age=$(( $(date +%s) - $(stat -c %Y "$lock_dir" 2>/dev/null || echo 0) ))
      fi
      if (( lock_age > 120 )); then
        rmdir "$lock_dir" 2>/dev/null
        continue
      fi
      peon_log warn "obsidian.global_lock_timeout"
      return 1
    fi
    # Jitter (W-OBS-13): random 0-100ms delay to prevent thundering herd
    local jitter=$(( RANDOM % 100 ))
    sleep "0.0${jitter}" 2>/dev/null || sleep 1
  done
  return 0
}

_obsidian_global_unlock() {
  local state_dir="${PEON_STATE_DIR:-$HOME/.claude/state}"
  rmdir "${state_dir}/obsidian_flush.lk" 2>/dev/null || true
}

# ── Session Log ──────────────────────────────────────────────────────
# Appends a JSON line to $vault/meta/sessions.jsonl. Atomic append.
_obsidian_append_session_log() {
  local vault="$1" json_line="$2"

  local sessions_file="${vault}/meta/sessions.jsonl"
  mkdir -p "${vault}/meta" 2>/dev/null || true

  # Atomic: write to tmp, append via cat, or use direct append (line < PIPE_BUF)
  echo "$json_line" >> "$sessions_file" 2>/dev/null || true

  peon_log debug "obsidian.session_logged" "file=$sessions_file"
}

# ── Load Index ───────────────────────────────────────────────────────
# Reads $vault/meta/index.json if it exists. Returns JSON array of note entries.
_obsidian_load_index() {
  local vault="$1"
  local index_file="${vault}/meta/index.json"

  if [[ -f "$index_file" ]] && command -v jq &>/dev/null; then
    jq -r '.' "$index_file" 2>/dev/null
  else
    echo "[]"
  fi
}

# ── Get Existing Titles ──────────────────────────────────────────────
# Reads index.json, filters by type and optionally language.
# Returns newline-delimited list of titles. Capped at 50 entries.
_obsidian_get_existing_titles() {
  local vault="$1" type="$2" language="${3:-}"
  local index_file="${vault}/meta/index.json"

  if [[ ! -f "$index_file" ]] || ! command -v jq &>/dev/null; then
    return 0
  fi

  local filter
  if [[ -n "$language" ]]; then
    filter="[.[] | select(.type == \"${type}\" and .language == \"${language}\")] | .[0:50] | .[].title"
  else
    filter="[.[] | select(.type == \"${type}\")] | .[0:50] | .[].title"
  fi

  jq -r "$filter" "$index_file" 2>/dev/null || true
}

# ── JSON Response Validation ─────────────────────────────────────────
# 3-layer validation of claude -p JSON response.
# Returns 0 on success, 1 on failure. Saves invalid response to state dir.
_obsidian_validate_json() {
  local response="$1"
  local state_dir="${PEON_STATE_DIR:-$HOME/.claude/state}"

  if ! command -v jq &>/dev/null; then
    peon_log warn "obsidian.validate_no_jq"
    return 1
  fi

  # Layer 1: Valid JSON
  if ! echo "$response" | jq -e . &>/dev/null; then
    peon_log warn "obsidian.validate_fail" "layer=1" "reason=invalid_json"
    echo "$response" > "${state_dir}/obsidian_invalid_response.json" 2>/dev/null || true
    return 1
  fi

  # Layer 2: Required fields (session_summary and project)
  if ! echo "$response" | jq -e '.session_summary and .project' &>/dev/null; then
    peon_log warn "obsidian.validate_fail" "layer=2" "reason=missing_required_fields"
    echo "$response" > "${state_dir}/obsidian_invalid_response.json" 2>/dev/null || true
    return 1
  fi

  # Layer 3: Structure (decisions must be an array)
  if ! echo "$response" | jq -e '.decisions | type == "array"' &>/dev/null; then
    peon_log warn "obsidian.validate_fail" "layer=3" "reason=decisions_not_array"
    echo "$response" > "${state_dir}/obsidian_invalid_response.json" 2>/dev/null || true
    return 1
  fi

  return 0
}

# ── Score Manifest ───────────────────────────────────────────────────
# Score files: Write=3, Edit=1, dedup by path (highest action wins).
# Same pattern as docguard. Returns score as integer.
_obsidian_score_manifest() {
  local manifest="$1"
  [[ ! -f "$manifest" || ! -s "$manifest" ]] && echo 0 && return

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

# ── Build Daily Entry ────────────────────────────────────────────────
# Takes parsed JSON response and formats as a markdown section for the daily note.
# Includes session summary, file count, goal alignment score, links to created notes.
_obsidian_build_daily_entry() {
  local json_response="$1" project="$2" duration="$3"

  if ! command -v jq &>/dev/null; then
    peon_log warn "obsidian.build_daily_no_jq"
    return 1
  fi

  local summary
  summary=$(echo "$json_response" | jq -r '.session_summary // "No summary"' 2>/dev/null)
  local file_count
  file_count=$(echo "$json_response" | jq -r '.file_count // 0' 2>/dev/null)
  local goal_score
  goal_score=$(echo "$json_response" | jq -r '.goal_alignment // "N/A"' 2>/dev/null)

  local session_id="${PEON_SESSION_ID:-unknown}"
  local ts
  ts=$(date +"%H:%M")

  # Build entry
  {
    echo "### ${ts} - ${project} (${duration})"
    echo ""
    echo "${summary}"
    echo ""
    echo "- Files: ${file_count} | Goal alignment: ${goal_score}"

    # Extract and link decisions
    local decision_count
    decision_count=$(echo "$json_response" | jq -r '.decisions | length' 2>/dev/null)
    if [[ "$decision_count" -gt 0 ]] 2>/dev/null; then
      echo "- Decisions:"
      echo "$json_response" | jq -r '.decisions[]? | "  - [[" + .title + "]]"' 2>/dev/null || true
    fi

    # Extract and link patterns
    local pattern_count
    pattern_count=$(echo "$json_response" | jq -r 'if .patterns then (.patterns | length) else 0 end' 2>/dev/null)
    if [[ "$pattern_count" -gt 0 ]] 2>/dev/null; then
      echo "- Patterns:"
      echo "$json_response" | jq -r '.patterns[]? | "  - [[" + .title + "]]"' 2>/dev/null || true
    fi

    # Extract and link pitfalls
    local pitfall_count
    pitfall_count=$(echo "$json_response" | jq -r 'if .pitfalls then (.pitfalls | length) else 0 end' 2>/dev/null)
    if [[ "$pitfall_count" -gt 0 ]] 2>/dev/null; then
      echo "- Pitfalls:"
      echo "$json_response" | jq -r '.pitfalls[]? | "  - [[" + .title + "]]"' 2>/dev/null || true
    fi

    echo ""
  }
}

# ── Note Lifecycle Management (W-OBS-04) ──────────────────────────
_obsidian_promote_note() {
  local note_path="$1" new_status="$2"
  [[ ! -f "$note_path" ]] && return 1
  _sed_inplace "s/^status: .*$/status: ${new_status}/" "$note_path"
}

_obsidian_archive_note() {
  local note_path="$1" vault="$2"
  [[ ! -f "$note_path" ]] && return 1
  local archive_dir="${vault}/archive"
  mkdir -p "$archive_dir" 2>/dev/null
  local filename
  filename=$(basename "$note_path")
  mv "$note_path" "${archive_dir}/${filename}" 2>/dev/null
  peon_log info "obsidian.archived" "note=$filename"
}

# ── Vault Quality Index (VQI) — Karpathy ratchet metric ────────────
# Composite score 0.0-1.0. Higher = better knowledge graph.
# Components:
#   link_density: avg links per note / 8 (capped at 1.0)
#   orphan_rate: 1 - (orphans / total)
#   freshness: active_notes / total
#   evaluation_score: avg confidence of evaluated notes
_obsidian_calculate_vqi() {
  local vault="$1"
  local index_file="${vault}/meta/index.json"
  [[ ! -f "$index_file" ]] && echo "0.0" && return

  # Count metrics from index
  local total
  total=$(jq 'length' "$index_file" 2>/dev/null || echo 0)
  [[ "$total" == "0" ]] && echo "0.0" && return

  # Link density: scan for [[wikilinks]] in all notes
  local total_links=0
  local notes_counted=0
  while IFS= read -r note_path; do
    [[ ! -f "$note_path" ]] && continue
    local links
    links=$(grep -o '\[\[[^]]*\]\]' "$note_path" 2>/dev/null | wc -l | tr -d ' ')
    total_links=$(( total_links + links ))
    (( ++notes_counted ))
  done < <(find "$vault" -name '*.md' -not -path '*/.obsidian/*' -not -path '*/archive/*' 2>/dev/null | head -200)

  local avg_links=0
  (( notes_counted > 0 )) && avg_links=$(( total_links / notes_counted ))

  # Link density score (target: 8 links per note)
  local link_score
  if (( avg_links >= 8 )); then
    link_score="1.0"
  else
    link_score=$(awk "BEGIN { printf \"%.2f\", $avg_links / 8.0 }")
  fi

  # Orphan rate from index
  local orphans
  orphans=$(jq '[.[] | select(.backlinks == 0)] | length' "$index_file" 2>/dev/null || echo 0)
  local orphan_score
  orphan_score=$(awk "BEGIN { printf \"%.2f\", 1.0 - ($orphans / $total) }")

  # Freshness (active notes / total)
  local active
  active=$(jq '[.[] | select(.status == "active" or .status == "fresh")] | length' "$index_file" 2>/dev/null || echo 0)
  local fresh_score
  fresh_score=$(awk "BEGIN { printf \"%.2f\", $active / $total }")

  # Evaluation score from evaluations.jsonl
  local eval_file="${vault}/meta/evaluations.jsonl"
  local avg_confidence="0.5"
  if [[ -f "$eval_file" ]]; then
    avg_confidence=$(jq -s '[.[].confidence // 0.5] | add / length' "$eval_file" 2>/dev/null || echo "0.5")
  fi

  # Composite VQI (weighted average)
  local vqi
  vqi=$(awk "BEGIN { printf \"%.3f\", ($link_score * 0.25) + ($orphan_score * 0.20) + ($fresh_score * 0.20) + ($avg_confidence * 0.35) }")

  echo "$vqi"
}

# ── Note Evaluation — Karpathy ratchet evaluate step ───────────────
# Evaluates a note 2+ days after creation.
# Returns JSON: {confidence: 0.0-1.0, useful: bool, reason: "..."}
_obsidian_evaluate_note() {
  local note_path="$1" vault="$2" model="${3:-sonnet}"

  [[ ! -f "$note_path" ]] && return 1

  local note_content
  note_content=$(cat "$note_path" 2>/dev/null)
  local note_title
  note_title=$(head -20 "$note_path" | grep '^# ' | head -1 | sed 's/^# //')
  local note_type
  note_type=$(grep '^type:' "$note_path" | head -1 | awk '{print $2}')

  # Check if note was referenced by other notes (backlinks)
  local backlink_count=0
  local sanitized
  sanitized=$(_obsidian_sanitize_filename "$note_title")
  backlink_count=$(grep -rl "\[\[.*${sanitized}.*\]\]" "$vault" 2>/dev/null | grep -v "$note_path" | wc -l | tr -d ' ')

  # Check if note was corrected by user
  local user_corrected=false
  grep -q '^corrected: true' "$note_path" 2>/dev/null && user_corrected=true

  local eval_prompt="Evaluate this ${note_type} note for quality and usefulness.

NOTE CONTENT:
${note_content}

CONTEXT:
- Backlinks from other notes: ${backlink_count}
- User manually corrected: ${user_corrected}

Score this note on a 0.0-1.0 scale for 'confidence' (is the content accurate and well-evidenced?) and determine if it's 'useful' (would a developer benefit from having this in their knowledge base?).

RESPOND WITH ONLY VALID JSON:
{\"confidence\": 0.0, \"useful\": true, \"reason\": \"brief explanation\", \"suggestion\": \"how to improve or empty string\"}"

  local tmout
  tmout=$(peon_timeout_cmd)
  local tpfx=""
  [[ -n "$tmout" ]] && tpfx="$tmout 30s"

  local eval_result
  eval_result=$(unset CLAUDECODE; $tpfx claude -p --model "$model" "$eval_prompt" 2>/dev/null) || return 1

  # Strip markdown fences if present
  if [[ "$eval_result" == '```'* ]]; then
    eval_result=$(echo "$eval_result" | sed '1{/^```/d;}' | sed '${/^```/d;}')
  fi

  # Validate JSON
  echo "$eval_result" | jq -e . &>/dev/null || return 1

  echo "$eval_result"
}

# ── VQI History — track ratchet progress over time ─────────────────
_obsidian_log_vqi() {
  local vault="$1" vqi="$2"
  local vqi_file="${vault}/meta/vqi_history.jsonl"
  local today
  today=$(date +%Y-%m-%d)
  echo "{\"date\":\"${today}\",\"vqi\":${vqi},\"ts\":$(date +%s)}" >> "$vqi_file" 2>/dev/null || true
}
