# PeonNotify

Audio notification and code quality hooks for Claude Code CLI. Plays Warcraft Peon sound clips on hook events, runs lint/review pipelines, generates changelogs, and captures session knowledge to an Obsidian vault.

## File Map

### Hook Scripts (hooks/)

| File | Hook Event | Purpose |
|------|------------|---------|
| peon-dispatch.sh | All events | Routes events to sound categories, manages cooldowns |
| peon-codeguard.sh | PostToolUse | Lint + AI code review on Write/Edit |
| peon-docguard.sh | PostToolUse + Stop | Accumulate file changes, flush changelog at session end |
| peon-obsidian.sh | PostToolUse + Stop | Accumulate file changes, flush to Obsidian vault at session end |
| peon-obsidian-cron.sh | Daily 9am (launchd) | Vault maintenance: trends, gaps, lifecycle, index rebuild |
| peon-watchdog.sh | UserPromptSubmit | RSS memory monitor, kills runaway sessions |
| peon-health.sh | Manual | Diagnostics for deps, config, sounds, hook wiring |

### Libraries (hooks/lib/)

| File | Purpose |
|------|---------|
| config.sh | Config loading, profile merge, cooldowns, `_now_ms`, `peon_config_get`, GC |
| logger.sh | Structured JSON logging with rotation and locking |
| player.sh | Cross-platform audio playback with queue and drain loop |
| linter.sh | Language detection + linter dispatch (7 languages) |
| validators.sh | JSON (4-layer) / YAML / TOML syntax validation |
| docguard.sh | Accumulate/flush logic, changelog gen, memory sync |
| obsidian.sh | Vault I/O: notes, daily append, dedup, locking, VQI metric |

### Config + Templates

| File | Purpose |
|------|---------|
| config/peon.json | All tunables (sounds, codeguard, docguard, watchdog, obsidian, profiles) |
| settings.local.json | Claude Code hook wiring (paths expanded by installer) |
| config/com.peonnotify.obsidian-cron.plist | macOS LaunchAgent for daily cron |
| hooks/templates/obsidian/*.md | 6 note templates: daily, decision, pattern, pitfall, bug, project-moc |

### Other

| File | Purpose |
|------|---------|
| install.sh | Idempotent installer (copies files, expands `$HOME`, installs plist) |
| peon-claude | Wrapper: auto-restart on watchdog kill + `/exit` timeout fix |

## Architecture

### Dispatch Flow

```
Hook event -> peon-dispatch.sh
  reads JSON stdin -> extracts hook_event_name + metadata
  -> resolve_event_key() maps to sound category
  -> cooldown check -> peon_resolve_sound() picks random MP3
  -> peon_play() enqueues -> background drainer plays sequentially
```

### CodeGuard Flow

```
PostToolUse (Write|Edit) -> peon-codeguard.sh
  extract tool_input.file_path -> guard chain:
    exists? vendor dir? skip ext? data file? file size? dedup hash?
  ├─ Data files (.json/.yaml/.toml) -> peon_validate_data() (jq/python3)
  └─ Code files -> peon_run_linter() -> if pass -> claude -p review
  -> play codeguard_pass / codeguard_lint_fail / codeguard_error
```

### DocGuard Flow

```
PostToolUse -> peon-docguard.sh (accumulate, ~1ms)
  append file+action+timestamp to session manifest
  skip doc files + binaries (prevent loops)

Stop -> peon-docguard.sh (flush)
  read manifest -> dedup by path -> score significance
  if score >= threshold: build context (manifest + git diff + CHANGELOG tail)
  -> claude -p ONCE -> write CHANGELOG.md, CLAUDE.md, memory/MEMORY.md
  backups before every write
```

### Obsidian Flow

```
PostToolUse -> peon-obsidian.sh (accumulate, ~1ms)
  append file+action+timestamp to session manifest
  skip doc files + binaries

Stop -> peon-obsidian.sh (flush)
  read manifest -> dedup -> score significance
  if score >= threshold: build context (manifest + git diff)
  -> claude -p -> create/update daily note + atomic notes
  (decisions, patterns, pitfalls, bugs, project MOCs)

Daily 9am -> peon-obsidian-cron.sh (launchd)
  scan vault -> gap detection -> trend aggregation
  -> lifecycle management (archive old notes)
  -> index rebuild -> VQI metric update
```

## Critical Rules

### `set -e` safety in bash arithmetic

All scripts use `set -euo pipefail`. `((var++))` returns exit 1 when var=0. Use `(( ++var ))` or `(( var += 1 ))`. Wrap `(( RANDOM % N == 0 ))` in `if` or append `|| true`.

### Hook command paths must be absolute

Claude Code does NOT expand `$HOME` in hook command strings. The installer must `sed` `$HOME` to the actual path. Literal `$HOME` causes "command not found".

### `unset CLAUDECODE` before `claude -p`

CodeGuard, DocGuard, and Obsidian all call `claude -p`. Without `unset CLAUDECODE`, the nested CLI detects it's inside another session and refuses to run.

### Hook JSON fields

Standard: `hook_event_name`, `session_id`. Additional by event:

| Event | Extra Fields |
|-------|-------------|
| PreToolUse / PostToolUse | `tool_name`, `tool_input` |
| PostToolUse | `tool_response.success` (boolean) |
| Notification | `notification_type` (`permission_prompt`, `idle_prompt`) |
| SessionStart | `source` (`resume` vs startup) |
| PreCompact | `trigger` (`manual`, `auto`) |

### /exit timeout fix

Claude Code kills SessionEnd hooks after 1.5s. The `peon-claude` wrapper sets `CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS=10000`. Without the wrapper, set this env var in your shell profile.

### Testing hooks

```bash
echo '{"hook_event_name":"Stop","session_id":"test"}' | bash -x ~/.claude/hooks/peon-dispatch.sh
peon-docguard.sh --dry-run     # preview changelog
peon-docguard.sh --flush       # force flush
peon-obsidian.sh --dry-run     # preview vault writes
peon-obsidian.sh --flush       # force flush
```

## Config Reference

All config lives in `config/peon.json`.

### Top-Level

| Key | Default | Purpose |
|-----|---------|---------|
| `enabled` | `true` | Global master switch |
| `volume` | `0.6` | Playback volume |
| `mute` | `false` | Mute all sounds |
| `cooldown_ms` | `1500` | Default cooldown between sounds |
| `log_level` | `"info"` | `debug`, `info`, `warn`, `error` |
| `log_max_lines` | `5000` | Log rotation threshold |
| `sound_pack` | `"peon"` | Sound directory name |
| `platform_override` | `null` | Force `macos`, `linux`, or `wsl` |
| `active_profile` | `"default"` | Active profile name (or `PEON_PROFILE` env var) |

### codeguard.*

| Key | Default | Purpose |
|-----|---------|---------|
| `enabled` | `true` | Master switch |
| `lint_enabled` | `true` | Run linters on code files |
| `validate_data_files` | `true` | JSON/YAML/TOML validation |
| `claude_debug_enabled` | `true` | Run `claude -p` review |
| `claude_debug_model` | `"sonnet"` | Model for review |
| `blocking_mode` | `false` | Exit non-zero on lint errors |
| `max_file_size_kb` | `100` | Skip files larger than this |
| `max_reviews_per_file` | `3` | Cap per-file reviews per session |
| `max_reviews_per_session` | `20` | API budget per session |
| `dedup_enabled` | `true` | Skip unchanged files |
| `review_prompt` | `null` | Custom prompt (null = language defaults) |
| `skip_extensions` | `[".md",".txt",...]` | Extensions to skip |
| `skip_directories` | `["node_modules",...]` | Directories to skip |
| `validate_extensions` | `[".json",".yaml",...]` | Data file extensions |
| `secondary_lint_enabled` | `false` | Type checkers (mypy/pyright) |
| `lint_timeout_sec` | `5` | Linter timeout |
| `debug_timeout_sec` | `20` | Review timeout |

### docguard.*

| Key | Default | Purpose |
|-----|---------|---------|
| `enabled` | `true` | Master switch |
| `update_changelog` | `true` | Create/prepend CHANGELOG.md |
| `update_claude_md` | `true` | Append session log to CLAUDE.md |
| `suggest_readme` | `false` | Output README suggestions to stdout |
| `sync_memory_md` | `true` | Sync memory/MEMORY.md index |
| `min_score_threshold` | `3` | Minimum significance to trigger flush |
| `flush_model` | `"sonnet"` | Model for generation |
| `flush_timeout_sec` | `45` | Timeout for `claude -p` |
| `memory_dir` | `""` | Path to memory dir (empty = skip) |

### watchdog.*

| Key | Default | Purpose |
|-----|---------|---------|
| `enabled` | `true` | Master switch |
| `warn_mb` | `800` | RSS warning threshold (MB) |
| `kill_mb` | `1200` | RSS kill threshold (MB) |
| `warn_sound` | `"me_not_that_kind_of_orc.mp3"` | Warning sound |
| `kill_sound` | `"peon_death.mp3"` | Pre-kill sound |
| `warn_cooldown_sec` | `300` | Seconds between warnings |
| `auto_restart` | `true` | Write restart flag for peon-claude |

### obsidian.*

| Key | Default | Purpose |
|-----|---------|---------|
| `enabled` | `true` | Master switch |
| `vault_path` | `"~/Documents/Obsidian"` | Obsidian vault root |
| `flush_model` | `"sonnet"` | Model for note generation |
| `flush_timeout_sec` | `60` | Timeout for `claude -p` |
| `flush_mode` | `"hybrid"` | Flush strategy |
| `create_atomic_notes` | `true` | Create decision/pattern/pitfall/bug notes |
| `daily_notes` | `true` | Append to daily note |
| `project_tracking` | `true` | Maintain project MOC notes |
| `goal_tracking` | `true` | Track goals in vault |
| `max_atomic_notes_per_session` | `5` | Cap atomic notes per flush |
| `max_prompt_tokens` | `30000` | Token budget for AI prompt |
| `min_score_threshold` | `5` | Minimum significance to flush |
| `max_retries` | `2` | API retry count |
| `retry_delay_sec` | `3` | Delay between retries |
| `auto_archive` | `true` | Archive old notes |
| `archive_after_days` | `90` | Days before archiving |
| `cron_enabled` | `true` | Enable daily cron job |
| `cron_hour` | `9` | Cron execution hour |
| `cron_gap_days` | `7` | Gap detection window |
| `cron_trend_days` | `7` | Trend aggregation window |

### profiles.*

Profiles override base config. `active_profile` or `PEON_PROFILE` selects one. Merge rules: `event_sounds` = REPLACE (profile provides complete mapping); everything else = DEEP MERGE.

| Profile | Behavior |
|---------|----------|
| `default` | Base config as-is (no merging) |
| `developer` | 3 sounds only, codeguard/docguard/obsidian disabled |

### Supported Linters

| Language | Primary | Secondary (advisory) |
|----------|---------|---------------------|
| JavaScript/TypeScript | eslint | -- |
| Python | ruff > flake8 | mypy > pyright |
| Shell | shellcheck | -- |
| Go | go vet | -- |
| Rust | cargo clippy | -- |
| Ruby | rubocop | -- |
| SQL | sqlfluff | -- |

### JSON Validation Layers

| Layer | Catches | Tool |
|-------|---------|------|
| L1 Syntax | Parse errors, BOM, empty files | jq |
| L2 Integrity | Duplicate keys | python3 |
| L3 Structure | Deep nesting >20, mixed arrays | python3 |
| L4 Schema | Known-file rules (package.json, tsconfig) | python3 |

### Linter Return Codes

`0` = pass, `1` = lint errors, `2` = config error, `3` = timeout.

## Audit Log

### CodeGuard v2 (26 fixes: W1-W26)

Key categories: linter reliability (W1-W6), file guards (W7-W12), AI review hardening (W13-W16, W19), observability (W15, W17, W22), validation (W10, W25-W26), dedup (W16), timeout unification (W18), blocking mode (W21).

### DocGuard (19 fixes: W1-W27, non-contiguous)

Key categories: manifest safety (W1-W2), AI quality (W3-W5), doc conflict avoidance (W7-W8), project root (W9-W10), scoring dedup (W17), operational (W19-W22, W24), portability (W22).

### Comprehensive v3 (56 fixes across SWE, DE, AI perspectives)

4 critical: installer missing libs (C1), prompt injection defense (C2), review cap (C3), ARG_MAX fix (C4). 16 high: timestamp corruption (H1), session_id extraction (H2-H3), SIGTERM handling (H4), sentinel exact match (H5), flush lock (H6), JSON escaping (H7), signal traps (H8), API retry (H9), timeout centralization (H10), config validation (H11), shared helpers (H12, H14), review budget (H15), AI disclaimer (H16). 23 medium: logging, player, config, docguard, dispatch, wrapper improvements.

### Obsidian Ratchet (23 fixes)

Key categories: vault I/O safety, template engine, VQI metric, note evaluation, dedup, cron lifecycle, error handling, Karpathy feedback loop.

## Known Fragility

- `peon-health.sh`: `((PASS++))` etc. converted to pre-increment, but still fragile if refactored outside `if` context under `set -e`.
- `config.sh`: `(( ${#sounds[@]} == 0 ))` safe only as condition with `&&`; would fail standalone under `set -e` when array is non-empty.
- Log rotation `(( line_count > max_lines ))` safe inside `if` body only.
- `_json_get` grep fallback cannot parse nested keys or arrays; only works for flat string values.
