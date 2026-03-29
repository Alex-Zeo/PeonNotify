# PeonNotify Memory Index

Project-scoped memory for AI agents working on this codebase.

## Architecture
- [architecture.md](architecture.md) — 5 hook systems: dispatch (sounds), codeguard (lint+review), docguard (changelog), watchdog (memory), obsidian (knowledge graph)

## Key Decisions
- [karpathy-ratchet.md](karpathy-ratchet.md) — Obsidian uses measure→evaluate→keep/discard→repeat loop. VQI metric tracks vault quality. Notes evaluated 2+ days after creation.
- [profile-merge.md](profile-merge.md) — Profiles use merged config files. event_sounds REPLACED, everything else DEEP MERGED.

## Known Issues
- [known-issues.md](known-issues.md) — H13 (batch jq) deferred. Cooldown files use seconds*1000 on macOS (no gdate).
