---
name: Known Issues
description: Deferred fixes and known limitations
type: project
---

- H13: Batch jq calls in codeguard — deferred because it requires renaming all CG_* variables downstream. Low ROI.
- macOS without gdate: Cooldowns use seconds*1000 (ms precision lost). Works correctly but timestamps are coarser.
- Obsidian flush_mode "hybrid" partially implemented — daily note is immediate, atomic notes require cron batching which is not yet wired.
- VQI calculation scans up to 200 notes per run — may be slow on very large vaults (1000+ notes). Consider indexing.
