# PeonNotify — Claude Code Project Guide

Audio notification system for Claude Code CLI. Plays Warcraft Peon sound clips in response to hook lifecycle events (session start/stop, tool use, prompts, errors, completions). Cross-platform (macOS/Linux/WSL).

## Architecture

```
peon-dispatch.sh  (entry point — registered for every hook event)
  ├── lib/config.sh   (config loading, platform detection, cooldown state, sound resolution)
  ├── lib/logger.sh   (structured JSON logging with rotation)
  └── lib/player.sh   (cross-platform async audio playback)
```

Flow: Claude Code fires hook → dispatch reads JSON from stdin → extracts `hook_event_name` + metadata → `resolve_event_key()` maps to sound category → checks cooldown → `peon_resolve_sound()` picks random MP3 → `peon_play()` runs audio player in background.

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

### Testing hooks manually
```bash
echo '{"hook_event_name":"Stop","session_id":"test"}' | bash -x ~/.claude/hooks/peon-dispatch.sh
```

## Bugs Fixed

### logger.sh crash under `set -e` (31f39a7)
`_rotate_log()` used `(( RANDOM % 20 == 0 ))` which returns exit 1 when the modulo is nonzero. Moved into an `if` guard.

### `$HOME` not expanded in hook commands (install.sh fix)
`settings.local.json` contained literal `$HOME` in command strings. Claude Code passes these as-is to the shell, but the command string is not shell-expanded by Claude Code itself. Fixed installer to `sed` `$HOME` → actual path at install time.

### PreCompact matchers don't match (settings.local.json fix)
`PreCompact` entries originally had `"matcher": "manual"` and `"matcher": "auto"` to differentiate compaction triggers. These matchers never matched the event payload, causing the hook to silently never fire. Fix: removed matchers entirely — the dispatch script already reads the `trigger` field from the JSON payload and routes to `compact_manual` or `compact_auto` internally.

## Known Fragility

- `peon-health.sh`: `((PASS++))`, `((FAIL++))`, `((WARN++))` are inside function bodies called after `if`/test context — safe by accident in some cases but fragile. `((FOUND++))` and `((MISSING++))` in the sound-check loop were directly exposed. All converted to pre-increment form.
- `config.sh` line `(( ${#sounds[@]} == 0 ))` — safe because it's used as a condition with `&&`, but would fail if used standalone under `set -e` when array is non-empty (expression evaluates to 0).
- Log rotation `(( line_count > max_lines ))` — safe inside `if` body.
