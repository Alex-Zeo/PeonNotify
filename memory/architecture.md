---
name: PeonNotify Architecture
description: 5 hook subsystems plus shared libraries and config
type: reference
---

PeonNotify has 5 hook scripts + 7 libraries + 1 wrapper + 1 cron job.

Hook scripts fire on Claude Code lifecycle events:
- peon-dispatch.sh: ALL events → play Warcraft Peon sounds
- peon-codeguard.sh: PostToolUse (Write|Edit) → lint + AI code review
- peon-docguard.sh: PostToolUse + Stop → accumulate file changes, flush to CHANGELOG
- peon-obsidian.sh: PostToolUse + Stop → accumulate file changes, flush to Obsidian vault
- peon-watchdog.sh: UserPromptSubmit → check RSS, warn/kill on leak

Libraries are sourced (not executed):
- config.sh: load peon.json, profiles, cooldowns, _now_ms, peon_config_get, GC
- logger.sh: structured JSON logging with rotation + locking
- player.sh: cross-platform audio with queue + background drainer
- linter.sh: language detection + linter dispatch (eslint, ruff, shellcheck, go, rubocop, clippy)
- validators.sh: 4-layer JSON + JSONL + YAML + TOML validation
- docguard.sh: accumulate/flush for changelog, global lock, claude -p calls
- obsidian.sh: vault I/O, daily notes, atomic notes, dedup, locking, VQI metric

Config: single peon.json with sections for each subsystem + profiles.
All state in ~/.claude/state/. All logs in ~/.claude/logs/peon.log.
