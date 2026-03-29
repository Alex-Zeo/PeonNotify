# PeonNotify — Claude Code Project Guide

Audio notification system for Claude Code CLI. Plays Warcraft Peon sound clips in response to hook lifecycle events (session start/stop, tool use, prompts, errors, completions). Cross-platform (macOS/Linux/WSL).

## Architecture

```
peon-dispatch.sh     (entry point — registered for every hook event)
  ├── lib/config.sh    (config loading, platform detection, cooldown state, sound resolution)
  ├── lib/logger.sh    (structured JSON logging with rotation)
  └── lib/player.sh    (cross-platform audio playback with queue)

peon-codeguard.sh    (PostToolUse hook — code quality pipeline)
  ├── lib/config.sh    (shared config loader)
  ├── lib/logger.sh    (shared logging)
  ├── lib/linter.sh    (language detection, project root discovery, linter dispatch)
  ├── lib/validators.sh (JSON/YAML/TOML syntax validation)
  └── lib/player.sh    (sound feedback on pass/fail)

peon-docguard.sh     (PostToolUse + Stop hook — documentation maintenance)
  ├── lib/config.sh    (shared config loader)
  ├── lib/logger.sh    (shared logging)
  ├── lib/docguard.sh  (accumulate/flush logic, changelog gen, memory sync)
  └── lib/player.sh    (completion sound on flush)

peon-watchdog.sh     (UserPromptSubmit hook — memory leak detector)
  ├── lib/config.sh    (shared config loader + profile merge)
  ├── lib/logger.sh    (shared logging)
  └── lib/player.sh    (alert sounds on warn/kill)

peon-claude           (wrapper script — auto-restart + /exit fix)
  └── claude           (launches Claude Code with env var overrides)
```

### Dispatch Flow
Claude Code fires hook → dispatch reads JSON from stdin → extracts `hook_event_name` + metadata → `resolve_event_key()` maps to sound category → checks cooldown → `peon_resolve_sound()` picks random MP3 → `peon_play()` enqueues sound → background drainer plays sequentially.

### CodeGuard Flow
Claude writes/edits file → `peon-codeguard.sh` receives PostToolUse JSON on stdin → extracts `tool_input.file_path` → applies guard chain (exists? vendor dir? skip extension? data file? file size? dedup hash?) → routes to one of two paths:

**Path A — Data files** (`.json`, `.yaml`, `.yml`, `.toml`): `peon_validate_data()` runs syntax validation via jq/python3. Reports parse errors with line numbers.

**Path B — Code files**: Step 1: `peon_run_linter()` detects language, finds project root, runs linter from correct directory. Returns distinct exit codes (0=pass, 1=lint error, 2=config error, 3=timeout). Step 2 (if lint passes): `claude -p` with language-specific review prompt. Uses `NO_ISSUES_FOUND` sentinel for reliable detection.

Plays `codeguard_pass`, `codeguard_lint_fail`, or `codeguard_error` sound. Logs timing metrics. Writes per-session metrics file for aggregate tracking.

### DocGuard Flow
Two-phase architecture — accumulate during session, flush at end:

**Phase 1 — Accumulate (PostToolUse, ~1ms):** Appends file path + action + timestamp to a session-scoped manifest file. Skips doc files (CHANGELOG, CLAUDE.md, README) and binary files to prevent loops. No AI call.

**Phase 2 — Flush (Stop/SessionEnd):** Reads manifest → deduplicates by file path → scores significance (Write=3, Edit=1 per unique file) → if score ≥ threshold: builds context (manifest + `git diff --stat` + existing CHANGELOG tail) → calls `claude -p` ONCE → applies updates to CHANGELOG.md, CLAUDE.md session log, and syncs memory/MEMORY.md.

**Safety:** Backs up every doc before writing. Skips docs the user edited this session (prevents conflicts). Saves raw AI response for debugging. `NO_DOC_UPDATES_NEEDED` sentinel for trivial sessions. `--dry-run` flag for preview. Stale manifest detection on SessionStart.

**Important**: The `claude -p` call must run with `unset CLAUDECODE` to avoid Claude Code detecting a nested invocation and refusing to run.

Config lives in `~/.claude/config/peon.json`. Hook wiring lives in `~/.claude/settings.local.json`.

## Critical Rules

### `set -e` safety in bash arithmetic
All scripts use `set -euo pipefail`. The expression `((var++))` (post-increment) returns exit code 1 when `var` starts at 0 because the expression evaluates to 0 (falsy). This kills the script under `set -e`. Use `(( ++var ))` (pre-increment) or `(( var += 1 ))` instead. Same applies to `(( RANDOM % N == 0 ))` — wrap in `if` or append `|| true`.

### Hook command paths must be absolute
Claude Code does NOT expand `$HOME` in hook command strings. The `settings.local.json` template uses `$HOME/.claude/hooks/peon-dispatch.sh` — the installer must `sed` this to the actual path at install time. Literal `$HOME` in the command string causes "command not found".

### Claude Code hook JSON fields
Standard fields on every event: `hook_event_name`, `session_id`. Additional fields vary:
- `PreToolUse` / `PostToolUse`: `tool_name`, `tool_input`
- `PostToolUse`: `tool_response.success` (boolean, not string)
- `Notification`: `notification_type` (`permission_prompt`, `idle_prompt`)
- `SessionStart`: `source` (`resume` vs startup)
- `PreCompact`: `trigger` (`manual`, `auto`)
- `PermissionRequest`: `tool_name`

### CodeGuard-specific fields used
- `PostToolUse` → `tool_input.file_path`: absolute path to the written/edited file
- `PostToolUse` → `tool_name`: `Write` or `Edit` (used for logging context)
- CodeGuard reads `codeguard.*` keys from `peon.json` for all its settings
- The `unset CLAUDECODE` before `claude -p` is required — without it, the Claude CLI detects it's running inside another Claude Code session and exits

### CodeGuard config keys
| Key | Default | Purpose |
|-----|---------|---------|
| `enabled` | `true` | Master switch |
| `lint_enabled` | `true` | Run linters on code files |
| `validate_data_files` | `true` | Multi-layer validation on JSON/JSONL/YAML/TOML |
| `claude_debug_enabled` | `true` | Run claude -p debug review |
| `claude_debug_model` | `"sonnet"` | Model for debug review |
| `blocking_mode` | `false` | Exit non-zero on errors (blocks Claude Code) |
| `max_file_size_kb` | `500` | Skip files larger than this |
| `dedup_enabled` | `true` | Skip if file content unchanged since last check |
| `review_prompt` | `null` | Custom review prompt (null = language-specific defaults) |
| `skip_extensions` | `[...]` | File extensions to skip entirely |
| `skip_directories` | `[...]` | Directory names to skip (vendor, generated, etc.) |
| `validate_extensions` | `[".json",".jsonl",".ndjson",".yaml",".yml",".toml"]` | Data file extensions to validate |
| `secondary_lint_enabled` | `false` | Run type checkers (mypy/pyright) as advisory step |
| `lint_timeout_sec` | `5` | Linter timeout |
| `debug_timeout_sec` | `20` | Debug review timeout |

### Linter return codes
`peon_run_linter()` returns structured exit codes:
- `0` — lint passed (or skipped: no linter available, unknown language)
- `1` — lint errors found in the code
- `2` — linter config/internal error (not a code quality issue)
- `3` — linter timed out

### JSON validation layers
`peon_validate_json()` applies four layers (requires python3 for layers 2-4):

| Layer | What it catches | Example |
|-------|----------------|---------|
| L1 Syntax | Parse errors, encoding, BOM, empty files | `{"key": value}` → missing quotes |
| L2 Integrity | Duplicate keys (silent data loss) | `{"port": 3000, "port": 8080}` |
| L3 Structure | Deep nesting (>20), mixed-type arrays, oversized strings | `[1, "two", true]` in data array |
| L4 Schema | Known-file validation (package.json, tsconfig.json) | `"lodash": "*"` wildcard dep |

Layers 2-4 are unavailable when falling back to jq-only (no python3).

### JSONL/NDJSON validation
`peon_validate_jsonl()` checks each line as independent JSON. Reports line number and column of first error. Caps at 10,000 lines and 5 errors to avoid blocking on large files.

### Supported linters
| Language | Primary linter | Secondary (advisory) |
|----------|---------------|---------------------|
| JavaScript/TypeScript | eslint | — |
| Python | ruff > flake8 | mypy > pyright |
| Shell | shellcheck | — |
| Go | go vet | — |
| Rust | cargo clippy | — |
| Ruby | rubocop | — |
| SQL | sqlfluff | — |

### DocGuard config keys
| Key | Default | Purpose |
|-----|---------|---------|
| `enabled` | `false` | Master switch (opt-in) |
| `update_changelog` | `true` | Create/prepend CHANGELOG.md entries |
| `update_claude_md` | `true` | Append to CLAUDE.md DOCGUARD session log section |
| `suggest_readme` | `false` | Output README update suggestions to stdout |
| `sync_memory_md` | `true` | Mechanical sync of memory/MEMORY.md index |
| `min_score_threshold` | `3` | Minimum significance score to trigger flush |
| `flush_model` | `"sonnet"` | Model for changelog generation |
| `flush_timeout_sec` | `45` | Timeout for the claude -p call |
| `memory_dir` | `""` | Path to memory directory (empty = skip sync) |

### DocGuard significance scoring
Each unique file scores once (dedup by path, highest action wins):
- `Write` (new file): **+3**
- `Edit` (modification): **+1**
- Doc files (CHANGELOG, CLAUDE.md, README): **skipped** (prevent loops)
- Binary files (png, mp3, zip, etc.): **skipped**

Default threshold: **≥ 3** → 1 new file, or 3+ code edits, triggers flush.

### Testing hooks manually
```bash
echo '{"hook_event_name":"Stop","session_id":"test"}' | bash -x ~/.claude/hooks/peon-dispatch.sh
# DocGuard: preview what would be generated
peon-docguard.sh --dry-run
# DocGuard: manually flush pending manifests
peon-docguard.sh --flush
```

## Bugs Fixed

### logger.sh crash under `set -e` (31f39a7)
`_rotate_log()` used `(( RANDOM % 20 == 0 ))` which returns exit 1 when the modulo is nonzero. Moved into an `if` guard.

### `$HOME` not expanded in hook commands (install.sh fix)
`settings.local.json` contained literal `$HOME` in command strings. Claude Code passes these as-is to the shell, but the command string is not shell-expanded by Claude Code itself. Fixed installer to `sed` `$HOME` → actual path at install time.

### PreCompact matchers don't match (settings.local.json fix)
`PreCompact` entries originally had `"matcher": "manual"` and `"matcher": "auto"` to differentiate compaction triggers. These matchers never matched the event payload, causing the hook to silently never fire. Fix: removed matchers entirely — the dispatch script already reads the `trigger` field from the JSON payload and routes to `compact_manual` or `compact_auto` internally.

## CodeGuard Audit (v2 — 10-iteration upgrade)

### Fixes applied

| ID | Weakness | Fix |
|----|----------|-----|
| W1 | `go vet` on individual files doesn't work | Runs `go vet .` from file's directory (package-level) |
| W2 | `cargo clippy` ignores file, runs from wrong dir | Runs from Cargo.toml directory; skips if no Cargo.toml found |
| W3 | Linters can't find configs (eslint, rubocop) | `_find_project_root()` walks up to project markers; linters `cd` there |
| W4 | Silent failure: linter exits non-zero with empty output | Reports crash with exit code instead of passing silently |
| W5 | Linter timeout returns exit 0 (misleading "pass") | Returns exit 3; logged as warning; doesn't claim "passed" |
| W6 | No distinction: config errors vs lint errors | Exit >= 2 labeled as config issue, doesn't block debug review |
| W7 | No file size limit (huge files waste tokens/timeout) | `max_file_size_kb` config (default 500KB), skips large files |
| W8 | File content in bash arg string hits ARG_MAX | Uses temp file for prompt construction |
| W9 | Unbounded stdin read | `head -c 65536` caps at 64KB |
| W10 | JSON/YAML/TOML completely skipped (in skip_extensions) | Removed from skip list; routed to new validators module |
| W11 | No skip for vendor/generated directories | `skip_directories` config; checks path for node_modules, dist, .git, etc. |
| W12 | Minified/bundle files not excluded | Pattern match on `.min.js`, `.bundle.js`, etc. |
| W13 | `grep -qi "no issues found"` heuristic is fragile | Model instructed to use exact sentinel `NO_ISSUES_FOUND`; matched with `==` |
| W14 | Same review prompt for all languages | Language-specific prompts with targeted focus areas |
| W15 | Debug review output not in structured log | `output_length` logged; full output available in hook stdout |
| W16 | No dedup — same file linted repeatedly | Content-hash dedup with `codeguard_hashes` state file |
| W17 | No timing metrics | `_now_ms()` timestamps; duration logged and displayed |
| W18 | `_timeout_cmd()` duplicated in linter.sh and codeguard.sh | `peon_timeout_cmd()` exported from linter.sh; codeguard reuses it |
| W19 | Review prompt hardcoded in bash | `review_prompt` config key; `null` = language-specific defaults |
| W20 | Missing file extensions (.cjs, .cts, .pyw, .zsh) | Added to `peon_detect_language()` |
| W21 | Always exits 0 — can't block Claude Code | `blocking_mode` config; exits 1 on errors when enabled |
| W22 | No session-level aggregate metrics | Per-session metrics JSONL file in state directory |
| W25 | No validators module | New `lib/validators.sh` with JSON (jq/python3), YAML, TOML validation |
| W26 | Health check doesn't cover new features | Added validator deps, feature flags, dedup state to health check |

## DocGuard Audit (10-iteration design hardening)

| # | Weakness | Mitigation |
|---|----------|------------|
| W1 | Manifest corruption under concurrent hooks | `echo >> file` is atomic for lines < PIPE_BUF on local fs |
| W2 | Manifest spans crashed sessions | Session-scoped manifest filenames; stale detection on SessionStart |
| W3 | Haiku produces shallow summaries | Default to sonnet (one call per session — cost negligible) |
| W4 | Manifest has file names but no diffs | `git diff --stat HEAD` included in context |
| W5 | No style examples in prompt | Existing CHANGELOG tail included for style matching |
| W7 | User has uncommitted manual edits to doc files | Skip docs that appear in manifest (user edited this session) |
| W8 | Generated markdown is malformed | Validate response starts with `## `; save invalid responses for debug |
| W9 | Project root ambiguity | `git rev-parse --show-toplevel` with CWD fallback |
| W10 | Multiple CLAUDE.md locations | Checks both project root and `.claude/` |
| W11 | CHANGELOG.md doesn't exist | Creates with standard header (low-risk) |
| W12 | Memory dir path encoding is fragile | Explicit `memory_dir` config instead of auto-detection |
| W13 | MEMORY.md 200-line truncation | Warns if >180 lines; 1 line per entry |
| W17 | Multiple edits to same file inflate score | Dedup by file path; highest action wins (Write > Edit) |
| W19 | No dry-run mode | `--dry-run` flag outputs context without writing |
| W20 | No undo mechanism | Backups in state dir before every write |
| W21 | Generated content not inspectable | Raw response saved to `docguard_last_response.md` |
| W22 | Associative arrays require bash 4+ | Uses awk for dedup (bash 3.2 / macOS compat) |
| W24 | Non-git projects have no diff context | All git ops wrapped in `if git rev-parse; then` |
| W27 | Sentinel in legitimate output | Extremely unlikely in changelog format |

## Profile System

Profiles let you switch between named config presets without editing the base config.

### How it works
- `active_profile` key in `peon.json` (default: `"default"`)
- `PEON_PROFILE` env var overrides the config key
- `_peon_apply_profile()` in `config.sh` generates a merged JSON file at load time
- `PEON_CONFIG_FILE` is redirected to the merged file → all downstream scripts (dispatch, codeguard, docguard) work transparently with zero changes

### Merge rules
- `event_sounds`: **REPLACE** — profile provides complete mapping; missing keys = silent
- Everything else: **DEEP MERGE** — profile overrides only what it specifies

### Built-in profiles
| Profile | Behavior |
|---------|----------|
| `default` | All sounds play (no merging, base config as-is) |
| `developer` | Only 3 sounds: `permission_prompt` → something_need_doing, `stop` → work_complete, `subagent_stop` → jobs_done. CodeGuard and DocGuard disabled. |

### Adding custom profiles
Add to `profiles` object in `peon.json`:
```json
"profiles": {
  "quiet": {
    "mute": true
  },
  "loud": {
    "volume": 1.0,
    "cooldown_ms": 0
  }
}
```

### Switching profiles
```bash
# Via config (persistent)
jq '.active_profile = "developer"' ~/.claude/config/peon.json > /tmp/peon.json && mv /tmp/peon.json ~/.claude/config/peon.json

# Via env var (per-terminal)
export PEON_PROFILE=developer
```

### Profile requires jq
Without jq, `_peon_apply_profile` silently falls back to the base config.

## Memory Watchdog

`peon-watchdog.sh` monitors Claude Code RSS and kills runaway sessions.

### How it works
1. Registered as `UserPromptSubmit` hook (fires every prompt)
2. Gets Claude PID via `$PPID`, validates it's actually a Claude/node process
3. Reads RSS via `ps -o rss=` (KB → MB)
4. Below `warn_mb`: silent exit
5. At `warn_mb`: log warning + play *"Me not that kind of orc!"* (with cooldown)
6. At `kill_mb`: play Peon death grunt → write restart flag → `kill -TERM $PPID`

### Config keys
| Key | Default | Purpose |
|-----|---------|---------|
| `enabled` | `true` | Master switch |
| `warn_mb` | `800` | RSS threshold for warning (MB) |
| `kill_mb` | `1200` | RSS threshold for kill (MB) |
| `warn_sound` | `me_not_that_kind_of_orc.mp3` | Sound on warning |
| `kill_sound` | `peon_death.mp3` | Sound before kill |
| `warn_cooldown_sec` | `300` | Minimum seconds between warnings |
| `auto_restart` | `true` | Write restart flag for peon-claude wrapper |

### Auto-restart with peon-claude
`peon-claude` is a wrapper script that runs `claude` in a loop. When the watchdog kills a session:
1. Watchdog writes `~/.claude/state/watchdog_restart.json` with `{sessionId, cwd, rss_mb}`
2. Claude process exits
3. Wrapper reads the flag, waits 2s, runs `claude --resume SESSION_ID`
4. Max 5 restarts before giving up

Also sets `CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS=10000` which fixes the `/exit` error.

### Safety
- PPID command is verified to contain "claude" or "node" before any kill
- Only SIGTERM (graceful), never SIGKILL
- If `peon-claude` is not used, watchdog still kills but no auto-restart

## /exit Error Fix

### Root cause
Claude Code force-kills SessionEnd hooks after 1.5 seconds regardless of `timeout` in `settings.local.json`.

### Fix
The `peon-claude` wrapper sets `CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS=10000` (10 seconds). Users who don't use the wrapper should set this env var in their shell profile.

## Known Fragility

- `peon-health.sh`: `((PASS++))`, `((FAIL++))`, `((WARN++))` are inside function bodies called after `if`/test context — safe by accident in some cases but fragile. `((FOUND++))` and `((MISSING++))` in the sound-check loop were directly exposed. All converted to pre-increment form.
- `config.sh` line `(( ${#sounds[@]} == 0 ))` — safe because it's used as a condition with `&&`, but would fail if used standalone under `set -e` when array is non-empty (expression evaluates to 0).
- Log rotation `(( line_count > max_lines ))` — safe inside `if` body.
