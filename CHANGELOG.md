# Changelog

All notable changes to PeonNotify.

## [Unreleased]

### Added
- Obsidian knowledge graph integration (peon-obsidian.sh, lib/obsidian.sh, peon-obsidian-cron.sh)
  - Session summaries auto-captured to daily notes
  - Atomic notes for decisions, patterns, pitfalls, bugs
  - Karpathy ratchet: VQI metric, note evaluation, feedback loop
  - Daily cron: trends, gaps, lifecycle management, index rebuild
  - LaunchAgent for daily 9am execution
- Profile system with merged config (default + developer profiles)
- Memory watchdog (peon-watchdog.sh) with auto-restart wrapper (peon-claude)
- Comprehensive audit v3: 56 issues fixed across SWE, DE, AI perspectives
- Obsidian audit: 23 issues fixed including Karpathy ratchet loop

### Changed
- CodeGuard: prompt injection defense, exact sentinel match, API retry, per-file review cap
- Logger: proper JSON escaping, rotation lock, schema version, real timestamps
- Player: SIGHUP trap, lock refresh, queue cap, cached player detection
- Config: centralized _now_ms, peon_config_get, peon_timeout_cmd, config validation, state GC
- DocGuard: global flush lock, manifest cap, diff content, retry logic
- Dispatch: stdin cap, start event logging
- Installer: copies all library files, obsidian section, plist installation

### Fixed
- macOS cooldown timestamps corrupted (literal "3N" in values)
- CodeGuard session_id always "unknown" (41% of logs unattributable)
- 76% of CodeGuard executions killed by hook timeout (increased to 60s)
- flock fd 9 reuse silently releasing first lock in docguard
- peon-claude not forwarding signals to child process
- Settings.local.json literal $HOME causing silent hook failure

## [1.0.0] - 2026-03-22

### Added
- CodeGuard v2 audit: 26 fixes (W1-W26)
- DocGuard hook with accumulate/flush architecture
- Deep JSON validation (4-layer), YAML, TOML validation
- Language-specific review prompts for 7 languages

## [0.2.0] - 2026-03-04

### Added
- CodeGuard pipeline: lint + Claude debug review on file writes
- Separate error sounds: never_mind (tool), leave_me_alone (system), more_gold (limits)

## [0.1.0] - 2026-02-26

### Added
- Initial release: Peon Notify audio notification system
- Event dispatch with 15 sound categories
- Cross-platform audio (macOS/Linux/WSL)
- Cooldown system, config-driven behavior
- Health check script
- Installer with dry-run support
